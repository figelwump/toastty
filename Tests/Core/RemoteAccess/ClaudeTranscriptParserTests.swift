import RemoteProtocol
import Foundation
import Testing
@testable import CoreState

struct ClaudeTranscriptParserTests {
    @Test func parsesBasicSessionInOrder() {
        let result = ClaudeTranscriptParser.parseContents(ClaudeTranscriptFixtures.basicSession)
        #expect(result.malformedLineCount == 0)

        let described = result.observations.map(Self.describe)
        #expect(described == [
            "providerSession",
            "user:Add a retry to the sync job",
            "profile:claude-opus-5:nil",
            "assistant(commentary):Looking at the sync job first.",
            "toolStarted:Bash:toolu_0001",
            "toolFinished:toolu_0001:succeeded",
            "profile:claude-opus-5:nil",
            "assistant(final):Added a retry with backoff to sync.py.",
            "user:Also log each retry.",
            "profile:claude-opus-5:nil",
            "assistant(final):Retries now log through the sync logger.",
        ])
    }

    @Test func extractsToolDetailAndTurnIDs() {
        let result = ClaudeTranscriptParser.parseContents(ClaudeTranscriptFixtures.basicSession)
        let toolStarted = result.observations.compactMap { observation -> ConversationToolStartedPayload? in
            guard case .transcript(.toolStarted(let payload)) = observation.payload else { return nil }
            return payload
        }
        #expect(toolStarted.first?.toolName == "Bash")
        #expect(toolStarted.first?.detail == "grep -n retry sync.py")

        // The tool_result user record shares the initiating prompt's turn ID.
        let toolFinished = result.observations.first { observation in
            if case .transcript(.toolFinished) = observation.payload { return true }
            return false
        }
        #expect(toolFinished?.turnID == "prompt-1")
    }

    @Test func failedToolResultSurfacesFailure() {
        let result = ClaudeTranscriptParser.parseContents(ClaudeTranscriptFixtures.toolFailureSession)
        let outcomes = result.observations.compactMap { observation -> ConversationToolOutcome? in
            guard case .transcript(.toolFinished(let payload)) = observation.payload else { return nil }
            return payload.outcome
        }
        #expect(outcomes == [.failed])
    }

    @Test func skipsMetaSidechainAndUnknownRecords() {
        let result = ClaudeTranscriptParser.parseContents(ClaudeTranscriptFixtures.noiseSession)
        // Only the "not valid json" line counts as malformed; skipped record
        // types are not errors.
        #expect(result.malformedLineCount == 1)

        let userMessages = result.observations.compactMap { observation -> String? in
            guard case .transcript(.userMessage(let payload)) = observation.payload else { return nil }
            return payload.text
        }
        #expect(userMessages == ["Real question"])

        let assistantMessages = result.observations.compactMap { observation -> String? in
            guard case .transcript(.assistantMessage(let payload)) = observation.payload else { return nil }
            return payload.text
        }
        // The subagent sidechain reply must not appear in the root transcript.
        #expect(assistantMessages == ["Real answer."])
    }

    @Test func skipsTaskNotificationsUsingOnlyStructuredOriginKind() {
        let result = ClaudeTranscriptParser.parseContents(ClaudeTranscriptFixtures.taskNotificationVariants)
        #expect(result.malformedLineCount == 0)

        let userMessages = result.observations.compactMap { observation -> String? in
            guard case .transcript(.userMessage(let payload)) = observation.payload else { return nil }
            return payload.text
        }
        #expect(userMessages == [
            "<task-notification><task-id>typed-literally</task-id><status>completed</status></task-notification>",
            "<task-notification>promptSource alone is not a discriminator</task-notification>",
            "User message without origin",
            "User message with malformed origin",
            "User message with malformed origin kind",
        ])
    }

    @Test func neverEmitsCompletedTurnEnd() {
        // Claude transcripts carry no authoritative composer-open signal, so
        // the parser must not emit turnEnded(.completed) — that keeps Claude
        // conversations read-only downstream.
        let result = ClaudeTranscriptParser.parseContents(ClaudeTranscriptFixtures.basicSession)
        let completedTurnEnds = result.observations.contains { observation in
            if case .turnEnded(_, reason: .completed) = observation.payload { return true }
            return false
        }
        #expect(completedTurnEnds == false)
    }

    @Test func skipsCompactionSummariesUsingOnlyStructuredFlag() {
        let result = ClaudeTranscriptParser.parseContents(ClaudeTranscriptFixtures.compactionSummaryVariants)
        #expect(result.malformedLineCount == 0)

        let userMessages = result.observations.compactMap { observation -> String? in
            guard case .transcript(.userMessage(let payload)) = observation.payload else { return nil }
            return payload.text
        }
        #expect(userMessages == [
            "This session is being continued from a previous conversation.",
            "Transcript visibility alone is not a compaction flag",
            "A normal message with a false flag",
            "A normal message with a malformed flag",
        ])
    }

    @Test func compactionAtTranscriptStartPreservesSessionIdentityAndFollowingOutput() throws {
        var parser = ClaudeTranscriptParser()
        let summaryLine = try #require(ClaudeTranscriptFixtures.compactionSummaryVariants.split(separator: "\n").first)
        let summary = parser.parseLine(String(summaryLine))
        #expect(summary.map(Self.describe) == ["providerSession"])
        guard case .providerSessionObserved(let sessionID) = summary.first?.payload else {
            Issue.record("The compaction summary did not preserve session identity")
            return
        }
        #expect(sessionID == ClaudeTranscriptFixtures.sessionID)

        let assistant = #"{"type":"assistant","sessionId":"\#(ClaudeTranscriptFixtures.sessionID)","uuid":"after-initial-compaction","timestamp":"2026-08-07T09:02:01.000Z","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"The saved result remains available."}]}}"#
        let output = parser.parseLine(assistant)
        #expect(output.map(Self.describe) == ["assistant(final):The saved result remains available."])
        #expect(output.first?.turnID == nil)
        #expect(parser.malformedLineCount == 0)
    }

    @Test func repeatedIdenticalUserMessagesFingerprintDistinctly() {
        let contents = ClaudeTranscriptFixtures.basicSession + ClaudeTranscriptFixtures.resumeContinuation
        let result = ClaudeTranscriptParser.parseContents(contents)
        let yesFingerprints = result.observations.compactMap { observation -> String? in
            guard case .transcript(.userMessage(let payload)) = observation.payload,
                  payload.text == "yes" else {
                return nil
            }
            return observation.fingerprint
        }
        #expect(yesFingerprints.count == 2)
        #expect(Set(yesFingerprints).count == 2)
    }

    @Test func reparsingProducesIdenticalObservations() {
        let first = ClaudeTranscriptParser.parseContents(ClaudeTranscriptFixtures.basicSession)
        let second = ClaudeTranscriptParser.parseContents(ClaudeTranscriptFixtures.basicSession)
        #expect(first.observations == second.observations)
    }

    @Test func taskNotificationEmitsNoUserMessage() {
        let result = ClaudeTranscriptParser.parseContents(ClaudeTranscriptFixtures.taskNotificationFollowedByActivity)
        #expect(result.malformedLineCount == 0)
        #expect(!result.observations.contains { observation in
            if case .transcript(.userMessage) = observation.payload { return true }
            return false
        })
    }

    private static func describe(_ observation: ProviderTranscriptObservation) -> String {
        switch observation.payload {
        case .transcript(.userMessage(let payload)):
            return "user:\(payload.text)"
        case .transcript(.assistantMessage(let payload)):
            let phase: String
            switch payload.phase {
            case .commentary: phase = "commentary"
            case .final: phase = "final"
            case .unknown: phase = "unknown"
            }
            return "assistant(\(phase)):\(payload.text)"
        case .transcript(.toolStarted(let payload)):
            return "toolStarted:\(payload.toolName):\(payload.callID)"
        case .transcript(.toolFinished(let payload)):
            let outcome: String
            switch payload.outcome {
            case .succeeded: outcome = "succeeded"
            case .failed: outcome = "failed"
            case .unknown: outcome = "unknown"
            }
            return "toolFinished:\(payload.callID):\(outcome)"
        case .transcript(let payload):
            return "transcript:\(payload.kind.rawValue)"
        case .interactionPresented(let interaction):
            return "interaction:\(interaction.kind.rawValue)"
        case .turnStarted(let turnID):
            return "turnStarted:\(turnID ?? "nil")"
        case .turnEnded(let turnID, let reason):
            return "turnEnded:\(turnID ?? "nil"):\(reason.rawValue)"
        case .providerSessionObserved:
            return "providerSession"
        case .executionProfileReported(let profile):
            return "profile:\(profile.modelIdentifier ?? "nil"):\(profile.reasoningEffort ?? "nil")"
        case .contextCompacted:
            return "contextCompacted"
        }
    }
}

struct ClaudeProjectionFidelityTests {
    static let conversationID = RemoteConversationID(rawValue: UUID(uuidString: "cccccccc-0000-4000-8000-00000000c1a0")!)
    static let bindingID = UUID(uuidString: "cccccccc-0000-4000-8000-00000000b1d0")!
    static let date = Date(timeIntervalSince1970: 1_786_000_000)

    @Test func idleCompactionPreservesFinalReplyAndOpenPromptUntilRealInput() throws {
        var parser = ClaudeTranscriptParser()
        var projector = ConversationProjector(
            conversationID: Self.conversationID,
            provider: .claude,
            bindingID: Self.bindingID,
            at: Self.date
        )
        for line in ClaudeTranscriptFixtures.basicSession.split(separator: "\n") {
            for observation in parser.parseLine(String(line)) {
                projector.ingest(observation)
            }
        }
        let completionDate = try #require(projector.events.last?.timestamp).addingTimeInterval(1)
        projector.ingest(ProviderTranscriptObservation(
            timestamp: completionDate,
            turnID: "prompt-2",
            fingerprint: "claude:completed-before-idle-compaction",
            payload: .turnEnded(turnID: "prompt-2", reason: .completed)
        ))
        let token = try #require(projector.pendingPromptStabilizationToken)
        projector.completePromptStabilization(token: token, at: completionDate.addingTimeInterval(1))
        #expect(projector.state == .awaitingInput)
        #expect(projector.inputAvailability.allowsRemoteSend)
        let eventsBeforeCompaction = projector.events
        let availabilityBeforeCompaction = projector.inputAvailability

        for line in ClaudeTranscriptFixtures.idleCompaction.split(separator: "\n") {
            for observation in parser.parseLine(String(line)) {
                projector.ingest(observation)
            }
        }

        #expect(projector.events == eventsBeforeCompaction)
        #expect(projector.state == .awaitingInput)
        #expect(projector.inputAvailability == availabilityBeforeCompaction)
        let finalReply = projector.events.last { event in
            if case .assistantMessage = event.payload { return true }
            return false
        }
        guard case .assistantMessage(let reply) = finalReply?.payload else {
            Issue.record("The final assistant reply is missing")
            return
        }
        #expect(reply.text == "Retries now log through the sync logger.")
        #expect(reply.phase == .final)

        let passiveAssistant = #"{"type":"assistant","sessionId":"\#(ClaudeTranscriptFixtures.sessionID)","uuid":"idle-update-after-compaction","timestamp":"2026-08-07T09:02:01.000Z","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"The saved result remains available."}]}}"#
        let passiveEvents = parser.parseLine(passiveAssistant).flatMap { projector.ingest($0) }
        let passiveMessage = passiveEvents.first { event in
            if case .assistantMessage = event.payload { return true }
            return false
        }
        #expect(passiveMessage?.turnID == "prompt-2")
        #expect(projector.state == .awaitingInput)
        #expect(projector.inputAvailability == availabilityBeforeCompaction)

        let realPrompt = #"{"type":"user","sessionId":"\#(ClaudeTranscriptFixtures.sessionID)","uuid":"after-idle-compaction","timestamp":"2026-08-07T09:03:00.000Z","promptId":"prompt-3","message":{"role":"user","content":"Also add a timeout."}}"#
        let emitted = parser.parseLine(realPrompt).flatMap { projector.ingest($0) }
        #expect(emitted.contains { event in
            if case .userMessage(let message) = event.payload { return message.text == "Also add a timeout." }
            return false
        })
        #expect(projector.state == .working)
        #expect(projector.inputAvailability == .unavailable(reason: .working))
        #expect(parser.malformedLineCount == 0)
    }

    @Test func activeCompactionPreservesCurrentTurnAndWorkingState() {
        var parser = ClaudeTranscriptParser()
        var projector = ConversationProjector(
            conversationID: Self.conversationID,
            provider: .claude,
            bindingID: Self.bindingID,
            at: Self.date
        )
        for line in ClaudeTranscriptFixtures.basicSession.split(separator: "\n") {
            for observation in parser.parseLine(String(line)) {
                projector.ingest(observation)
            }
        }
        #expect(projector.state == .working)
        let eventsBeforeCompaction = projector.events
        for line in ClaudeTranscriptFixtures.idleCompaction.split(separator: "\n") {
            for observation in parser.parseLine(String(line)) {
                projector.ingest(observation)
            }
        }
        #expect(projector.events == eventsBeforeCompaction)
        #expect(projector.state == .working)
        #expect(projector.inputAvailability == .unavailable(reason: .working))

        let continuation = #"{"type":"assistant","sessionId":"\#(ClaudeTranscriptFixtures.sessionID)","uuid":"after-active-compaction","timestamp":"2026-08-07T09:02:01.000Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"text","text":"Continuing the current task."}]}}"#
        let emitted = parser.parseLine(continuation).flatMap { projector.ingest($0) }
        let message = emitted.first { event in
            if case .assistantMessage = event.payload { return true }
            return false
        }
        #expect(message?.turnID == "prompt-2")
        #expect(projector.state == .working)
        #expect(parser.malformedLineCount == 0)
    }

    @Test func claudeConversationRendersFullTranscriptButStaysReadOnly() {
        var projector = ConversationProjector(
            conversationID: Self.conversationID,
            provider: .claude,
            bindingID: Self.bindingID,
            at: Self.date
        )
        for observation in ClaudeTranscriptParser.parseContents(ClaudeTranscriptFixtures.basicSession).observations {
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
            "u:Also log each retry.",
            "a:Retries now log through the sync logger.",
        ])

        // No authoritative prompt-open signal ⇒ read-only throughout.
        #expect(projector.inputAvailability.allowsRemoteSend == false)
        let everOpenedPrompt = projector.events.contains { event in
            guard case .statusChanged(let payload) = event.payload else { return false }
            return payload.inputAvailability.allowsRemoteSend
        }
        #expect(everOpenedPrompt == false)

        // Provider-derived events carry the claude namespace and rebuild
        // deterministically.
        for event in projector.events where event.kind.isProviderDerived {
            #expect(event.eventID.hasPrefix("claude:"))
        }
    }

    @Test func toolCompletionStatePreserved() {
        var projector = ConversationProjector(
            conversationID: Self.conversationID,
            provider: .claude,
            bindingID: Self.bindingID,
            at: Self.date
        )
        for observation in ClaudeTranscriptParser.parseContents(ClaudeTranscriptFixtures.toolFailureSession).observations {
            projector.ingest(observation)
        }
        let toolFinished = projector.events.compactMap { event -> ConversationToolOutcome? in
            guard case .toolFinished(let payload) = event.payload else { return nil }
            return payload.outcome
        }
        #expect(toolFinished == [.failed])
    }

    @Test func filteredTaskNotificationPreservesFollowingTranscriptAndOpenPrompt() {
        var projector = ConversationProjector(
            conversationID: Self.conversationID,
            provider: .claude,
            bindingID: Self.bindingID,
            at: Self.date
        )
        _ = projector.noteBinding(
            reason: .runtimeResumed,
            providerSessionFilePath: "/tmp/claude-task-notification.jsonl",
            bindingID: Self.bindingID,
            at: Self.date
        )
        _ = projector.bootstrapConfirmedOpenPrompt(at: Self.date.addingTimeInterval(1))
        let stateBeforeNotice = projector.state
        let availabilityBeforeNotice = projector.inputAvailability

        let observations = ClaudeTranscriptParser.parseContents(ClaudeTranscriptFixtures.taskNotificationFollowedByActivity).observations
        let emitted = observations.flatMap { projector.ingest($0) }

        #expect(!emitted.contains { event in
            if case .userMessage = event.payload { return true }
            return false
        })

        let preservedTranscript = projector.events.compactMap { event -> String? in
            switch event.payload {
            case .assistantMessage(let payload): return "assistant:\(payload.text)"
            case .toolStarted(let payload): return "toolStarted:\(payload.callID)"
            case .toolFinished(let payload): return "toolFinished:\(payload.callID)"
            case .userMessage: return "user"
            default: return nil
            }
        }
        #expect(preservedTranscript == [
            "toolStarted:toolu_task_only",
            "toolFinished:toolu_task_only",
            "assistant:Background task finished.",
        ])

        let followingTranscriptEvents = projector.events.filter { event in
            switch event.payload {
            case .assistantMessage, .toolStarted, .toolFinished: return true
            default: return false
            }
        }
        #expect(followingTranscriptEvents.count == 3)
        #expect(followingTranscriptEvents.allSatisfy { $0.turnID == "prompt-task-only" })
        #expect(projector.state == stateBeforeNotice)
        #expect(projector.inputAvailability == availabilityBeforeNotice)
    }
}

struct ClaudeExecutionProfileParserTests {
    @Test func syntheticErrorRecordsPreserveReportedModelAndRemainReadable() {
        // Provider error envelope: https://github.com/anthropics/claude-code/issues/22843.
        let contents = [
            #"{"type":"assistant","uuid":"real","timestamp":"2026-08-07T10:00:01Z","message":{"model":"model-a"}}"#,
            #"{"type":"assistant","uuid":"synthetic","timestamp":"2026-08-07T10:00:02Z","message":{"model":"<synthetic>","content":[{"type":"text","text":"API Error"}]}}"#,
            #"{"type":"assistant","uuid":"error","timestamp":"2026-08-07T10:00:03Z","isApiErrorMessage":true,"message":{"model":"unconfirmed-model","content":[{"type":"text","text":"Try again"}]}}"#,
        ].joined(separator: "\n")
        let observations = ClaudeTranscriptParser.parseContents(contents).observations
        let profiles = observations.compactMap { observation -> RemoteSessionExecutionProfile? in
            guard case .executionProfileReported(let profile) = observation.payload else { return nil }
            return profile
        }
        #expect(profiles == [.init(modelIdentifier: "model-a")])
        let text = observations.compactMap { observation -> String? in
            guard case .transcript(.assistantMessage(let message)) = observation.payload else { return nil }
            return message.text
        }
        #expect(text == ["API Error", "Try again"])
    }

    @Test func assistantModelWithoutContentReportsMetadataAndIgnoresSidechainsAndText() {
        let contents = [
            #"{"type":"assistant","uuid":"a","timestamp":"2026-08-07T10:00:01Z","message":{"model":"model-a"}}"#,
            #"{"type":"assistant","uuid":"b","timestamp":"2026-08-07T10:00:02Z","message":{"model":"model-b","content":[]}}"#,
            #"{"type":"assistant","uuid":"child","isSidechain":true,"timestamp":"2026-08-07T10:00:03Z","message":{"model":"child-model"}}"#,
            #"{"type":"assistant","uuid":"a-again","timestamp":"2026-08-07T10:00:04Z","message":{"model":"model-a"}}"#,
            #"{"type":"assistant","uuid":"text","timestamp":"2026-08-07T10:00:05Z","message":{"content":[{"type":"text","text":"model=pretend reasoning=high"}]}}"#,
        ].joined(separator: "\n")
        let observations = ClaudeTranscriptParser.parseContents(contents).observations
        let profiles = observations.compactMap { observation -> RemoteSessionExecutionProfile? in
            guard case .executionProfileReported(let profile) = observation.payload else { return nil }
            return profile
        }
        #expect(profiles == [.init(modelIdentifier: "model-a"), .init(modelIdentifier: "model-b"), .init(modelIdentifier: "model-a")])
        #expect(ClaudeTranscriptParser.parseContents(contents).observations == observations)
        var projector = ConversationProjectorTests.makeClaudeProjector()
        for observation in observations { projector.ingest(observation) }
        #expect(projector.executionProfile == .init(modelIdentifier: "model-a"))
        #expect(!projector.inputAvailability.allowsRemoteSend)
    }
}
