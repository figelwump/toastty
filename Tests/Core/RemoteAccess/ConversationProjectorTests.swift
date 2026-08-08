import Foundation
import Testing
@testable import CoreState

struct ConversationProjectorTests {
    static let conversationID = RemoteConversationID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    static let bindingID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let resumedBindingID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let epochDate = Date(timeIntervalSince1970: 1_786_000_000)

    static func makeProjector() -> ConversationProjector {
        ConversationProjector(
            conversationID: conversationID,
            provider: .codex,
            bindingID: bindingID,
            at: epochDate
        )
    }

    static func observations(_ contents: String) -> [ProviderTranscriptObservation] {
        CodexRolloutTranscriptParser.parseContents(contents).observations
    }

    @Test func transcriptFidelityOnceAndInOrder() {
        var projector = Self.makeProjector()
        for observation in Self.observations(CodexRolloutFixtures.basicSession) {
            projector.ingest(observation)
        }

        let messages = projector.events.compactMap { event -> String? in
            switch event.payload {
            case .userMessage(let payload): return "u:\(payload.text)"
            case .assistantMessage(let payload): return "a:\(payload.text)"
            default: return nil
            }
        }
        #expect(messages == [
            "u:Add a retry to the sync job",
            "a:Looking at the sync job first.",
            "a:Added a retry with backoff to sync.py.",
            "u:Also log each retry.\nUse the existing logger.\nThanks!",
            "a:Retries now log through the sync logger.",
        ])

        let sequences = projector.events.map(\.sequence)
        #expect(sequences == sequences.sorted())
        #expect(Set(sequences).count == sequences.count)
        #expect(sequences.first == 1)

        let toolEvents = projector.events.filter {
            $0.kind == .toolStarted || $0.kind == .toolFinished
        }
        #expect(toolEvents.count == 2)
    }

    @Test func reIngestingSameObservationsAppendsNothing() {
        var projector = Self.makeProjector()
        let observations = Self.observations(CodexRolloutFixtures.basicSession)
        for observation in observations {
            projector.ingest(observation)
        }
        let eventCountAfterFirstPass = projector.events.count

        for observation in observations {
            let emitted = projector.ingest(observation)
            #expect(emitted.isEmpty)
        }
        #expect(projector.events.count == eventCountAfterFirstPass)
    }

    @Test func promptOpensOnlyAfterCompletedTurn() {
        var projector = Self.makeProjector()
        #expect(projector.state == .starting)
        #expect(projector.inputAvailability == .unavailable(reason: .starting))
        #expect(projector.inputAvailability.allowsRemoteSend == false)

        let observations = Self.observations(CodexRolloutFixtures.basicSession)

        // Ingest through the first user message: prompt must close.
        for observation in observations.prefix(2) {
            projector.ingest(observation)
        }
        #expect(projector.state == .working)
        #expect(projector.inputAvailability == .unavailable(reason: .working))

        for observation in observations {
            projector.ingest(observation)
        }
        #expect(projector.state == .awaitingInput)
        guard case .openPrompt(let epoch) = projector.inputAvailability else {
            Issue.record("Expected openPrompt, got \(projector.inputAvailability)")
            return
        }
        #expect(epoch.bindingID == Self.bindingID)
        // Two completed turns => two prompt-open transitions.
        #expect(epoch.counter == 2)
        #expect(projector.inputAvailability.allowsRemoteSend)
    }

    @Test func abortedTurnLeavesInputUnavailable() {
        var projector = Self.makeProjector()
        for observation in Self.observations(CodexRolloutFixtures.subagentAndInterruptSession) {
            projector.ingest(observation)
        }
        #expect(projector.state == .interrupted)
        #expect(projector.inputAvailability == .unavailable(reason: .interrupted))
        #expect(projector.inputAvailability.allowsRemoteSend == false)
    }

    @Test func statusChangedEventsAreCoalesced() {
        var projector = Self.makeProjector()
        for observation in Self.observations(CodexRolloutFixtures.basicSession) {
            projector.ingest(observation)
        }
        let statusPayloads = projector.events.compactMap { event -> ConversationStatusChangedPayload? in
            guard case .statusChanged(let payload) = event.payload else { return nil }
            return payload
        }
        // working -> openPrompt -> working -> openPrompt; the user message and
        // its task_started must not double-emit "working".
        #expect(statusPayloads.count == 4)
        for (index, payload) in statusPayloads.enumerated().dropFirst() {
            #expect(statusPayloads[index - 1] != payload)
        }
    }

    @Test func approvalLifecycleResolvesThroughToolOutput() {
        var projector = Self.makeProjector()
        let observations = Self.observations(CodexRolloutFixtures.approvalSession)

        // Ingest up to and including the approval request.
        var index = 0
        while index < observations.count {
            let observation = observations[index]
            projector.ingest(observation)
            index += 1
            if case .interactionPresented = observation.payload { break }
        }

        #expect(projector.state == .awaitingInput)
        #expect(projector.pendingInteractions.count == 1)
        let interaction = projector.pendingInteractions[0]
        #expect(interaction.kind == .permission)
        #expect(interaction.providerApprovalID == "appr_0101")
        #expect(interaction.state == .pending)
        guard case .pendingInteraction(let interactionIDs) = projector.inputAvailability else {
            Issue.record("Expected pendingInteraction availability")
            return
        }
        #expect(interactionIDs == [interaction.id])
        #expect(projector.inputAvailability.allowsRemoteSend == false)

        // The matching tool output resolves the approval.
        while index < observations.count {
            let observation = observations[index]
            projector.ingest(observation)
            index += 1
            if case .transcript(.toolFinished) = observation.payload { break }
        }
        #expect(projector.pendingInteractions.isEmpty)
        let resolutions = projector.events.compactMap { event -> ConversationInteractionResolvedPayload? in
            guard case .interactionResolved(let payload) = event.payload else { return nil }
            return payload
        }
        #expect(resolutions.map(\.resolution) == [.resolved])
        #expect(resolutions.first?.interactionID == interaction.id)
    }

    @Test func questionSupersededByNextTurn() {
        var projector = Self.makeProjector()
        for observation in Self.observations(CodexRolloutFixtures.approvalSession) {
            projector.ingest(observation)
        }
        let resolutions = projector.events.compactMap { event -> ConversationInteractionResolvedPayload? in
            guard case .interactionResolved(let payload) = event.payload else { return nil }
            return payload
        }
        #expect(resolutions.map(\.resolution) == [.resolved, .superseded])
        #expect(projector.pendingInteractions.isEmpty)
        #expect(projector.state == .awaitingInput)
        #expect(projector.inputAvailability.allowsRemoteSend)
    }

    @Test func bindingChangeMintsUnmatchableFreshEpoch() {
        var projector = Self.makeProjector()
        for observation in Self.observations(CodexRolloutFixtures.basicSession) {
            projector.ingest(observation)
        }
        guard case .openPrompt(let staleEpoch) = projector.inputAvailability else {
            Issue.record("Expected openPrompt before rebinding")
            return
        }

        let bindingEvents = projector.noteBinding(
            reason: .runtimeResumed,
            providerSessionID: CodexRolloutFixtures.sessionID,
            bindingID: Self.resumedBindingID,
            at: Self.epochDate.addingTimeInterval(7200)
        )
        #expect(bindingEvents.contains { $0.kind == .sessionBindingChanged })
        #expect(projector.state == .starting)
        #expect(projector.inputAvailability == .unavailable(reason: .unknownProviderState))

        for observation in Self.observations(CodexRolloutFixtures.resumeContinuation) {
            projector.ingest(observation)
        }
        guard case .openPrompt(let freshEpoch) = projector.inputAvailability else {
            Issue.record("Expected openPrompt after resumed turns")
            return
        }
        #expect(freshEpoch.bindingID == Self.resumedBindingID)
        #expect(freshEpoch != staleEpoch)
        // Even an equal counter can never match across bindings.
        #expect(RemoteInputEpoch(bindingID: Self.bindingID, counter: freshEpoch.counter) != freshEpoch)
    }

    @Test func runtimeEndedGoesOfflineAndSupersedesPending() {
        var projector = Self.makeProjector()
        let observations = Self.observations(CodexRolloutFixtures.approvalSession)
        for observation in observations {
            projector.ingest(observation)
            if case .interactionPresented = observation.payload { break }
        }
        #expect(projector.pendingInteractions.count == 1)

        projector.noteBinding(
            reason: .runtimeEnded,
            bindingID: Self.bindingID,
            at: Self.epochDate.addingTimeInterval(600)
        )
        #expect(projector.state == .offline)
        #expect(projector.inputAvailability == .unavailable(reason: .offline))
        #expect(projector.pendingInteractions.isEmpty)
    }

    @Test func offlineProjectionNeverPublishesOpenPrompt() {
        var projector = ConversationProjector(
            conversationID: Self.conversationID,
            provider: .codex,
            bindingID: Self.bindingID,
            runtimeBound: false,
            at: Self.epochDate
        )
        #expect(projector.state == .offline)

        for observation in Self.observations(CodexRolloutFixtures.basicSession) {
            projector.ingest(observation)
        }
        // The transcript is fully readable...
        #expect(projector.events.contains { $0.kind == .userMessage })
        #expect(projector.events.contains { $0.kind == .assistantMessage })
        // ...but the historical task_complete records never surface a live
        // prompt: no runtime exists to honor it.
        #expect(projector.state == .offline)
        #expect(projector.inputAvailability == .unavailable(reason: .offline))
        let publishedOpenPrompt = projector.events.contains { event in
            guard case .statusChanged(let payload) = event.payload else { return false }
            return payload.inputAvailability.allowsRemoteSend
        }
        #expect(publishedOpenPrompt == false)

        // Binding a runtime re-enables live transitions.
        projector.noteBinding(reason: .runtimeResumed, bindingID: Self.resumedBindingID, at: Self.epochDate.addingTimeInterval(60))
        for observation in Self.observations(CodexRolloutFixtures.resumeContinuation) {
            projector.ingest(observation)
        }
        #expect(projector.state == .awaitingInput)
        #expect(projector.inputAvailability.allowsRemoteSend)
    }

    @Test func providerDerivedEventsRebuildDeterministically() {
        func buildEvents() -> [ConversationEvent] {
            var projector = Self.makeProjector()
            for observation in Self.observations(CodexRolloutFixtures.basicSession) {
                projector.ingest(observation)
            }
            return projector.events
        }
        let first = buildEvents()
        let second = buildEvents()
        #expect(first == second)
        #expect(first.contains { $0.kind.isProviderDerived })

        for event in first where event.kind.isProviderDerived {
            #expect(event.eventID.hasPrefix("codex:"))
        }
    }
}
