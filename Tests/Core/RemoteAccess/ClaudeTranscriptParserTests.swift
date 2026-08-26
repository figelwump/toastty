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
            "assistant(commentary):Looking at the sync job first.",
            "toolStarted:Bash:toolu_0001",
            "toolFinished:toolu_0001:succeeded",
            "assistant(final):Added a retry with backoff to sync.py.",
            "user:Also log each retry.",
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
        case .contextCompacted:
            return "contextCompacted"
        }
    }
}

struct ClaudeProjectionFidelityTests {
    static let conversationID = RemoteConversationID(rawValue: UUID(uuidString: "cccccccc-0000-4000-8000-00000000c1a0")!)
    static let bindingID = UUID(uuidString: "cccccccc-0000-4000-8000-00000000b1d0")!
    static let date = Date(timeIntervalSince1970: 1_786_000_000)

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
