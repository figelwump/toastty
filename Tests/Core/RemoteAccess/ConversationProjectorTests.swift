import RemoteProtocol
import Foundation
import Testing
@testable import CoreState

struct ConversationProjectorTests {
    @Test func questionChannelExpiryKeepsNativeQuestionAndCompletionEnrichesAnswers() throws {
        var projector = Self.makeClaudeProjector()
        let question = RemoteInteractionQuestion(id: "q", header: "Choice", question: "Pick one", options: [
            .init(id: "a", label: "First"), .init(id: "b", label: "Second"),
        ])
        func observation(_ fingerprint: String, _ payload: ProviderObservationPayload) -> ProviderTranscriptObservation {
            .init(timestamp: Self.epochDate.addingTimeInterval(1), fingerprint: fingerprint, payload: payload)
        }
        let presented = observation("question", .interactionPresented(.init(kind: .question,
            providerCallID: "call", prompt: question.question, questions: [question],
            responseID: "response", responseExpiresAt: Self.epochDate.addingTimeInterval(300))))
        projector.ingest(presented)
        let interaction = try #require(projector.pendingInteractions.first)
        #expect(interaction.questions == [question])
        #expect(interaction.responseID == "response")
        projector.ingest(observation("closed", .transcript(.interactionResponseClosed(.init(
            interactionID: interaction.id, reason: .expired)))))
        #expect(projector.pendingInteractions.count == 1)
        #expect(projector.pendingInteractions[0].responseID == nil)
        #expect(projector.pendingInteractions[0].state == .pending)
        projector.ingest(observation("finished", .transcript(.toolFinished(.init(callID: "call")))))
        #expect(projector.pendingInteractions.isEmpty)
        let answers = [RemoteInteractionAnswer(questionID: "q", selectedOptionIDs: ["b"])]
        let completion = observation("accepted", .transcript(.interactionResolved(.init(
            interactionID: interaction.id, resolution: .resolved, answers: answers))))
        let events = projector.ingest(completion)
        #expect(events.contains { event in
            guard case .interactionResolved(let value) = event.payload else { return false }
            return value.answers == answers
        })
        #expect(projector.ingest(completion).isEmpty)
        #expect(projector.inputAvailability == .unavailable(reason: .working))
    }

    @Test func historicalQuestionCannotExposeLiveResponseAuthority() {
        var projector = Self.makeClaudeProjector()
        projector.ingest(.init(timestamp: Self.epochDate, fingerprint: "historical",
            payload: .interactionPresented(.init(kind: .question, providerCallID: "old", prompt: "Old",
                responseID: "old-response", responseExpiresAt: Self.epochDate.addingTimeInterval(300))),
            mayAuthorizeCurrentRuntime: false))
        #expect(projector.pendingInteractions.isEmpty)
        #expect(projector.events.contains { event in
            guard case .interactionPresented(let value) = event.payload else { return false }
            return value.responseID == nil && value.responseExpiresAt == nil
        })
    }

    static let conversationID = RemoteConversationID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    static let bindingID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let resumedBindingID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let epochDate = Date(timeIntervalSince1970: 1_786_000_000)
    static let restoredBindingDate = Date(timeIntervalSince1970: 1_786_098_000)

    static func makeProjector() -> ConversationProjector {
        ConversationProjector(
            conversationID: conversationID,
            provider: .codex,
            bindingID: bindingID,
            at: epochDate
        )
    }

    static func makeClaudeProjector() -> ConversationProjector {
        ConversationProjector(
            conversationID: conversationID,
            provider: .claude,
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

    @Test func completedUserItemReachesConversationEvents() {
        var projector = Self.makeProjector()
        for observation in Self.observations(CodexRolloutFixtures.completedItemUserSession) {
            projector.ingest(observation)
        }

        let userMessages = projector.events.compactMap { event -> ConversationUserMessagePayload? in
            guard case .userMessage(let payload) = event.payload else { return nil }
            return payload
        }
        #expect(userMessages.map(\.text) == ["Summarize previous commit"])
        #expect(projector.events.contains { event in
            guard case .userMessage(let payload) = event.payload else { return false }
            return payload.text.contains("private host context")
        } == false)
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

    @Test func claudeCompletedTurnOpensOnlyAfterExactStabilizationCompletes() throws {
        var projector = Self.makeClaudeProjector()
        _ = projector.ingest(ProviderTranscriptObservation(
            timestamp: Self.epochDate.addingTimeInterval(1),
            fingerprint: "claude:user-1",
            payload: .transcript(.userMessage(.init(text: "Run it")))
        ))
        _ = projector.ingest(ProviderTranscriptObservation(
            timestamp: Self.epochDate.addingTimeInterval(2),
            fingerprint: "claude:turn-end-1",
            payload: .turnEnded(turnID: "turn-1", reason: .completed)
        ))

        let token = try #require(projector.pendingPromptStabilizationToken)
        #expect(projector.state == .awaitingInput)
        #expect(projector.inputAvailability == .unavailable(reason: .unknownProviderState))
        #expect(projector.inputAvailability.allowsRemoteSend == false)

        let wrongToken = ConversationPromptStabilizationToken(
            observationFingerprint: "claude:another-turn"
        )
        #expect(projector.completePromptStabilization(
            token: wrongToken,
            at: Self.epochDate.addingTimeInterval(2.4)
        ).isEmpty)

        let emitted = projector.completePromptStabilization(
            token: token,
            at: Self.epochDate.addingTimeInterval(2.5)
        )
        #expect(emitted.contains { $0.kind == .statusChanged })
        #expect(projector.pendingPromptStabilizationToken == nil)
        #expect(projector.inputAvailability.allowsRemoteSend)
    }

    @Test func claudePromptStabilizationSurvivesLatePassiveObservations() throws {
        var projector = Self.makeClaudeProjector()
        _ = projector.ingest(ProviderTranscriptObservation(
            timestamp: Self.epochDate.addingTimeInterval(1),
            fingerprint: "claude:turn-end-passive",
            payload: .turnEnded(turnID: "turn-1", reason: .completed)
        ))
        let token = try #require(projector.pendingPromptStabilizationToken)

        let passiveObservations: [ProviderTranscriptObservation] = [
            ProviderTranscriptObservation(
                timestamp: Self.epochDate.addingTimeInterval(1.1),
                turnID: "turn-1",
                fingerprint: "claude:assistant-late",
                payload: .transcript(.assistantMessage(.init(text: "Done")))
            ),
            ProviderTranscriptObservation(
                timestamp: Self.epochDate.addingTimeInterval(1.2),
                turnID: "turn-1",
                fingerprint: "claude:tool-started-late",
                payload: .transcript(.toolStarted(.init(
                    callID: "call-1",
                    toolName: "Read"
                )))
            ),
            ProviderTranscriptObservation(
                timestamp: Self.epochDate.addingTimeInterval(1.3),
                turnID: "turn-1",
                fingerprint: "claude:tool-finished-late",
                payload: .transcript(.toolFinished(.init(
                    callID: "call-1",
                    toolName: "Read",
                    outcome: .succeeded
                )))
            ),
            ProviderTranscriptObservation(
                timestamp: Self.epochDate.addingTimeInterval(1.4),
                turnID: "turn-1",
                fingerprint: "claude:subagent-late",
                payload: .transcript(.subagentSummary(.init(
                    subagentID: "subagent-1",
                    displayName: "Explorer",
                    phase: .finished
                )))
            ),
            ProviderTranscriptObservation(
                timestamp: Self.epochDate.addingTimeInterval(1.5),
                fingerprint: "claude:session-observed-late",
                payload: .providerSessionObserved(providerSessionID: "session-1")
            ),
            ProviderTranscriptObservation(
                timestamp: Self.epochDate.addingTimeInterval(1.6),
                fingerprint: "claude:compaction-late",
                payload: .contextCompacted
            ),
        ]

        for observation in passiveObservations {
            _ = projector.ingest(observation)
            #expect(projector.pendingPromptStabilizationToken == token)
            #expect(projector.state == .awaitingInput)
            #expect(projector.inputAvailability == .unavailable(reason: .unknownProviderState))
        }

        let emitted = projector.completePromptStabilization(
            token: token,
            at: Self.epochDate.addingTimeInterval(1.7)
        )
        #expect(emitted.contains { $0.kind == .statusChanged })
        #expect(projector.inputAvailability.allowsRemoteSend)
    }

    @Test func promptInvalidatingActivityCancelsClaudeStabilization() throws {
        let invalidatingPayloads: [ProviderObservationPayload] = [
            .transcript(.userMessage(.init(text: "One more thing"))),
            .interactionPresented(.init(
                kind: .permission,
                providerCallID: "call-1",
                prompt: "Allow this command?"
            )),
            .turnStarted(turnID: "turn-2"),
            .turnEnded(turnID: "turn-2", reason: .aborted),
        ]

        for (index, payload) in invalidatingPayloads.enumerated() {
            var projector = Self.makeClaudeProjector()
            _ = projector.ingest(ProviderTranscriptObservation(
                timestamp: Self.epochDate.addingTimeInterval(1),
                fingerprint: "claude:turn-end-before-invalidation-\(index)",
                payload: .turnEnded(turnID: "turn-1", reason: .completed)
            ))
            let token = try #require(projector.pendingPromptStabilizationToken)

            _ = projector.ingest(ProviderTranscriptObservation(
                timestamp: Self.epochDate.addingTimeInterval(1.1),
                fingerprint: "claude:prompt-invalidating-\(index)",
                payload: payload
            ))

            #expect(projector.pendingPromptStabilizationToken == nil)
            #expect(projector.completePromptStabilization(
                token: token,
                at: Self.epochDate.addingTimeInterval(1.5)
            ).isEmpty)
            #expect(projector.inputAvailability.allowsRemoteSend == false)
        }
    }

    @Test func supersedingClaudeCompletionReplacesStabilizationToken() throws {
        var projector = Self.makeClaudeProjector()
        _ = projector.ingest(ProviderTranscriptObservation(
            timestamp: Self.epochDate.addingTimeInterval(1),
            fingerprint: "claude:turn-end-original",
            payload: .turnEnded(turnID: "turn-1", reason: .completed)
        ))
        let originalToken = try #require(projector.pendingPromptStabilizationToken)

        _ = projector.ingest(ProviderTranscriptObservation(
            timestamp: Self.epochDate.addingTimeInterval(1.1),
            fingerprint: "claude:turn-end-superseding",
            payload: .turnEnded(turnID: "turn-2", reason: .completed)
        ))
        let supersedingToken = try #require(projector.pendingPromptStabilizationToken)

        #expect(supersedingToken != originalToken)
        #expect(projector.completePromptStabilization(
            token: originalToken,
            at: Self.epochDate.addingTimeInterval(1.5)
        ).isEmpty)
        #expect(projector.completePromptStabilization(
            token: supersedingToken,
            at: Self.epochDate.addingTimeInterval(1.6)
        ).isEmpty == false)
        #expect(projector.inputAvailability.allowsRemoteSend)
    }

    @Test func localInputCancellationPreventsClaudePromptFromOpening() throws {
        var projector = Self.makeClaudeProjector()
        _ = projector.ingest(ProviderTranscriptObservation(
            timestamp: Self.epochDate.addingTimeInterval(1),
            fingerprint: "claude:turn-end-cancelled",
            payload: .turnEnded(turnID: "turn-1", reason: .completed)
        ))
        let token = try #require(projector.pendingPromptStabilizationToken)

        let cancelled = projector.cancelPromptStabilization()
        #expect(cancelled)
        #expect(projector.completePromptStabilization(
            token: token,
            at: Self.epochDate.addingTimeInterval(2)
        ).isEmpty)
        #expect(projector.inputAvailability == .unavailable(reason: .unknownProviderState))
    }

    @Test func historicalCompletedTurnCannotAuthorizeFreshRuntimeBinding() {
        var projector = ConversationProjector(
            conversationID: Self.conversationID,
            provider: .codex,
            bindingID: Self.resumedBindingID,
            at: Self.restoredBindingDate
        )

        for observation in Self.observations(CodexRolloutFixtures.basicSession) {
            projector.ingest(observation)
        }

        #expect(projector.events.contains { $0.kind == .assistantMessage })
        #expect(projector.state == .starting)
        #expect(projector.inputAvailability == .unavailable(reason: .starting))

        var coordinator = RemoteInputCoordinator()
        coordinator.setProviderAvailability(projector.inputAvailability, for: Self.conversationID)
        coordinator.noteLocalInput(for: Self.conversationID)
        #expect(coordinator.availability(for: Self.conversationID) == .unavailable(reason: .starting))
        #expect(coordinator.evaluate(
            RemoteMessageSendRequest(
                conversationID: Self.conversationID,
                clientRequestID: "restore-window-send",
                expectedInputEpoch: RemoteInputEpoch(bindingID: Self.resumedBindingID),
                text: "do not deliver"
            ),
            context: RemoteInputCoordinator.DeliveryContext(
                deviceHasSendScope: true,
                sessionWritesEnabled: true,
                isBoundToLiveSurface: true,
                isSurfaceReadyForInput: true
            )
        ) == .reject(.promptNotOpen))

        for observation in Self.observations(CodexRolloutFixtures.resumeContinuation) {
            projector.ingest(observation)
        }
        #expect(projector.state == .awaitingInput)
        guard case .openPrompt(let epoch) = projector.inputAvailability else {
            Issue.record("Expected a current-runtime prompt after the resumed turn")
            return
        }
        #expect(epoch.bindingID == Self.resumedBindingID)
    }

    @Test func displayOnlySnapshotCannotAuthorizeEvenWhenTimestampIsCurrent() {
        var projector = Self.makeProjector()
        let emitted = projector.ingest(ProviderTranscriptObservation(
            timestamp: Self.epochDate.addingTimeInterval(10),
            fingerprint: "managed:pi:historical-turn-end",
            payload: .turnEnded(turnID: "turn-1", reason: .completed),
            mayAuthorizeCurrentRuntime: false
        ))

        #expect(emitted.isEmpty)
        #expect(projector.state == .starting)
        #expect(projector.inputAvailability == .unavailable(reason: .starting))
    }

    @Test func confirmedRuntimeBootstrapOpensOnlyTheFirstUnknownPromptPerBinding() {
        var projector = Self.makeProjector()
        _ = projector.noteBinding(
            reason: .runtimeResumed,
            providerSessionFilePath: "/tmp/resumed-rollout.jsonl",
            bindingID: Self.resumedBindingID,
            at: Self.restoredBindingDate
        )
        #expect(projector.inputAvailability == .unavailable(reason: .unknownProviderState))

        let emitted = projector.bootstrapConfirmedOpenPrompt(
            at: Self.restoredBindingDate.addingTimeInterval(1)
        )
        guard case .openPrompt(let epoch) = projector.inputAvailability else {
            Issue.record("Expected confirmed runtime bootstrap to open the prompt")
            return
        }
        #expect(epoch.bindingID == Self.resumedBindingID)
        #expect(epoch.counter == 1)
        #expect(emitted.contains { $0.kind == .statusChanged })

        #expect(projector.bootstrapConfirmedOpenPrompt(
            at: Self.restoredBindingDate.addingTimeInterval(2)
        ).isEmpty)
        #expect(projector.inputAvailability == .openPrompt(epoch: epoch))

        let invalidated = projector.invalidateConfirmedOpenPrompt(
            expectedEpoch: epoch,
            state: .working,
            reason: .working,
            at: Self.restoredBindingDate.addingTimeInterval(3)
        )
        #expect(invalidated.contains { $0.kind == .statusChanged })
        #expect(projector.state == .working)
        #expect(projector.inputAvailability == .unavailable(reason: .working))
        #expect(projector.bootstrapConfirmedOpenPrompt(
            at: Self.restoredBindingDate.addingTimeInterval(4)
        ).isEmpty)
    }

    @Test func clearingTranscriptBindingInvalidatesPromptAndFileAuthority() {
        var projector = Self.makeProjector()
        _ = projector.noteBinding(
            reason: .runtimeBound,
            providerSessionFilePath: "/tmp/old-rollout.jsonl",
            bindingID: Self.bindingID,
            at: Self.epochDate
        )
        for observation in Self.observations(CodexRolloutFixtures.basicSession) {
            projector.ingest(observation)
        }
        #expect(projector.inputAvailability.allowsRemoteSend)

        let emitted = projector.noteBinding(
            reason: .runtimeResumed,
            clearsProviderSessionFilePath: true,
            bindingID: Self.resumedBindingID,
            at: Self.restoredBindingDate
        )

        #expect(projector.providerSessionFilePath == nil)
        #expect(projector.state == .starting)
        #expect(projector.inputAvailability == .unavailable(reason: .unknownProviderState))
        #expect(emitted.contains { event in
            guard case .sessionBindingChanged(let payload) = event.payload else { return false }
            return payload.providerSessionFilePath == nil
        })
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

    @Test func runtimeResumeSupersedesPendingInteractionFromPreviousBinding() {
        var projector = Self.makeProjector()
        for observation in Self.observations(CodexRolloutFixtures.approvalSession) {
            projector.ingest(observation)
            if case .interactionPresented = observation.payload { break }
        }
        #expect(projector.pendingInteractions.count == 1)

        projector.noteBinding(
            reason: .runtimeResumed,
            bindingID: Self.resumedBindingID,
            at: Self.restoredBindingDate.addingTimeInterval(7_200)
        )

        #expect(projector.pendingInteractions.isEmpty)
        #expect(projector.state == .starting)
        #expect(projector.inputAvailability == .unavailable(reason: .unknownProviderState))
        #expect(projector.events.contains { event in
            guard case .interactionResolved(let payload) = event.payload else { return false }
            return payload.resolution == .superseded
        })
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

struct ConversationExecutionProfileTests {
    private static let date = ConversationProjectorTests.epochDate

    private static func report(_ id: String, _ profile: RemoteSessionExecutionProfile, offset: TimeInterval = 0) -> ProviderTranscriptObservation {
        .init(timestamp: date.addingTimeInterval(offset), fingerprint: id,
              payload: .executionProfileReported(profile), mayAuthorizeCurrentRuntime: false)
    }

    @Test func profileReplacesFieldsByNewestTimestampWithoutEmittingEventsOrOpeningInput() throws {
        var projector = ConversationProjectorTests.makeProjector()
        let state = projector.state
        let availability = projector.inputAvailability
        let count = projector.events.count
        let full = Self.report("full", .init(modelIdentifier: "model-a", reasoningEffort: "high"), offset: 2)
        #expect(projector.ingest(full).isEmpty)
        #expect(projector.executionProfile == .init(modelIdentifier: "model-a", reasoningEffort: "high"))
        projector.ingest(Self.report("older", .init(modelIdentifier: "old"), offset: 1))
        #expect(projector.executionProfile?.modelIdentifier == "model-a")
        projector.ingest(Self.report("partial", .init(modelIdentifier: "model-b"), offset: 2))
        #expect(projector.executionProfile == .init(modelIdentifier: "model-b"))
        #expect(projector.ingest(full).isEmpty)
        #expect(projector.executionProfile == .init(modelIdentifier: "model-b"))
        #expect(projector.state == state)
        #expect(projector.inputAvailability == availability)
        #expect(projector.events.count == count)
        let encoded = try ConversationEventCoding.makeEncoder().encode(full)
        #expect(try ConversationEventCoding.makeDecoder().decode(ProviderTranscriptObservation.self, from: encoded) == full)
        projector.ingest(Self.report("empty", .init(), offset: 3))
        #expect(projector.executionProfile == nil)
    }

    @Test func runtimeExitAndSameIdentityResumeRetainProfileButRebindingClearsIt() {
        var projector = ConversationProjectorTests.makeProjector()
        let bindingID = ConversationProjectorTests.bindingID
        projector.noteBinding(reason: .runtimeBound, providerSessionID: "session-a",
                              providerSessionFilePath: "/tmp/a.jsonl", bindingID: bindingID, at: Self.date)
        projector.ingest(Self.report("a", .init(modelIdentifier: "model-a"), offset: 1))
        projector.noteBinding(reason: .runtimeEnded, bindingID: bindingID, at: Self.date.addingTimeInterval(2))
        #expect(projector.executionProfile?.modelIdentifier == "model-a")
        let offlineState = projector.state
        let offlineAvailability = projector.inputAvailability
        projector.ingest(Self.report("historical", .init(modelIdentifier: "model-b"), offset: 3))
        #expect(projector.executionProfile?.modelIdentifier == "model-b")
        #expect(projector.state == offlineState)
        #expect(projector.inputAvailability == offlineAvailability)
        projector.noteBinding(reason: .runtimeResumed, providerSessionID: "session-a",
                              providerSessionFilePath: "/tmp/a.jsonl", bindingID: UUID(), at: Self.date.addingTimeInterval(4))
        #expect(projector.executionProfile?.modelIdentifier == "model-b")
        projector.noteBinding(reason: .runtimeResumed, providerSessionID: "session-b",
                              bindingID: UUID(), at: Self.date.addingTimeInterval(5))
        #expect(projector.executionProfile == nil)
        // A new identity must not inherit the previous report's timestamp boundary.
        projector.ingest(Self.report("new-session", .init(reasoningEffort: "low")))
        #expect(projector.executionProfile == .init(reasoningEffort: "low"))
        projector.noteBinding(reason: .runtimeResumed, providerSessionFilePath: "/tmp/b.jsonl",
                              bindingID: UUID(), at: Self.date.addingTimeInterval(6))
        #expect(projector.executionProfile == nil)
        projector.ingest(Self.report("new-file", .init(modelIdentifier: "model-c")))
        projector.noteBinding(reason: .runtimeResumed, clearsProviderSessionFilePath: true,
                              bindingID: UUID(), at: Self.date.addingTimeInterval(7))
        #expect(projector.executionProfile == nil)
    }

    @Test func changedObservedProviderIdentityClearsReportedMetadata() {
        var projector = ConversationProjectorTests.makeProjector()
        projector.ingest(.init(timestamp: Self.date, fingerprint: "session-a", payload: .providerSessionObserved(providerSessionID: "a")))
        projector.ingest(Self.report("profile", .init(modelIdentifier: "model-a")))
        projector.ingest(.init(timestamp: Self.date, fingerprint: "same-session", payload: .providerSessionObserved(providerSessionID: "a")))
        #expect(projector.executionProfile?.modelIdentifier == "model-a")
        projector.ingest(.init(timestamp: Self.date, fingerprint: "session-b", payload: .providerSessionObserved(providerSessionID: "b")))
        #expect(projector.executionProfile == nil)
    }
}
