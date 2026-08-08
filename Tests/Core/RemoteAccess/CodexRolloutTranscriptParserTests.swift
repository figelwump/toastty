import Foundation
import Testing
@testable import CoreState

struct CodexRolloutTranscriptParserTests {
    @Test func parsesBasicSessionInOrder() {
        let result = CodexRolloutTranscriptParser.parseContents(CodexRolloutFixtures.basicSession)
        #expect(result.malformedLineCount == 0)

        let kinds = result.observations.map(Self.describe)
        #expect(kinds == [
            "providerSession",
            "user:Add a retry to the sync job",
            "turnStarted:turn-001",
            "assistant(commentary):Looking at the sync job first.",
            "toolStarted:exec_command:call_0001",
            "toolFinished:call_0001:succeeded",
            "assistant(final):Added a retry with backoff to sync.py.",
            "turnEnded:turn-001:completed",
            "user:Also log each retry.\nUse the existing logger.\nThanks!",
            "turnStarted:turn-002",
            "assistant(final):Retries now log through the sync logger.",
            "turnEnded:turn-002:completed",
        ])
    }

    @Test func extractsToolDetailAndTurnIDs() {
        let result = CodexRolloutTranscriptParser.parseContents(CodexRolloutFixtures.basicSession)
        let toolStarted = result.observations.compactMap { observation -> ConversationToolStartedPayload? in
            guard case .transcript(.toolStarted(let payload)) = observation.payload else { return nil }
            return payload
        }
        #expect(toolStarted.count == 1)
        #expect(toolStarted.first?.toolName == "exec_command")
        #expect(toolStarted.first?.detail == "grep -n retry sync.py")

        let assistantTurnIDs = result.observations.compactMap { observation -> String? in
            guard case .transcript(.assistantMessage) = observation.payload else { return nil }
            return observation.turnID
        }
        #expect(assistantTurnIDs == ["turn-001", "turn-001", "turn-002"])
    }

    @Test func parsesApprovalAndQuestionInteractions() {
        let result = CodexRolloutTranscriptParser.parseContents(CodexRolloutFixtures.approvalSession)
        let interactions = result.observations.compactMap { observation -> ProviderInteractionObservation? in
            guard case .interactionPresented(let interaction) = observation.payload else { return nil }
            return interaction
        }
        #expect(interactions.count == 2)

        let approval = try? #require(interactions.first)
        #expect(approval?.kind == .permission)
        #expect(approval?.providerCallID == "call_0101")
        #expect(approval?.providerApprovalID == "appr_0101")
        #expect(approval?.prompt == "Approve rm -rf build")

        let question = interactions.last
        #expect(question?.kind == .question)
        #expect(question?.providerCallID == "call_0102")
        #expect(question?.prompt == "Use the fast setup or the full setup?")
    }

    @Test func parsesSubagentActivityAndAbortedTurn() {
        let result = CodexRolloutTranscriptParser.parseContents(CodexRolloutFixtures.subagentAndInterruptSession)
        let subagents = result.observations.compactMap { observation -> ConversationSubagentSummaryPayload? in
            guard case .transcript(.subagentSummary(let payload)) = observation.payload else { return nil }
            return payload
        }
        #expect(subagents.map(\.phase) == [.started, .finished])
        #expect(subagents.first?.displayName == "audit_worker_queue")
        #expect(subagents.first?.subagentID == "01900000-bbbb-7000-8000-000000000001")

        let aborted = result.observations.contains { observation in
            if case .turnEnded(_, reason: .aborted) = observation.payload { return true }
            return false
        }
        #expect(aborted)
    }

    @Test func skipsCompactionReplayRecords() {
        let result = CodexRolloutTranscriptParser.parseContents(CodexRolloutFixtures.compactionSession)
        let userMessages = result.observations.compactMap { observation -> String? in
            guard case .transcript(.userMessage(let payload)) = observation.payload else { return nil }
            return payload.text
        }
        // The replayed "Summarize the repo layout" inside the compacted record
        // must not appear a second time.
        #expect(userMessages == ["Summarize the repo layout", "Now list the tests"])
        #expect(result.observations.contains { observation in
            if case .contextCompacted = observation.payload { return true }
            return false
        })
    }

    @Test func countsMalformedLinesAndKeepsParsing() {
        let result = CodexRolloutTranscriptParser.parseContents(CodexRolloutFixtures.malformedSession)
        // "not json" + missing-timestamp line.
        #expect(result.malformedLineCount == 2)
        let userMessages = result.observations.compactMap { observation -> String? in
            guard case .transcript(.userMessage(let payload)) = observation.payload else { return nil }
            return payload.text
        }
        #expect(userMessages == ["Still works?"])
    }

    @Test func skipsSubagentRolloutSessionIdentity() {
        let result = CodexRolloutTranscriptParser.parseContents(CodexRolloutFixtures.subagentRolloutFile)
        let sessionObservations = result.observations.filter { observation in
            if case .providerSessionObserved = observation.payload { return true }
            return false
        }
        #expect(sessionObservations.isEmpty)
    }

    @Test func repeatedIdenticalUserMessagesFingerprintDistinctly() {
        let contents = CodexRolloutFixtures.basicSession + CodexRolloutFixtures.resumeContinuation
        let result = CodexRolloutTranscriptParser.parseContents(contents)
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
        let first = CodexRolloutTranscriptParser.parseContents(CodexRolloutFixtures.basicSession)
        let second = CodexRolloutTranscriptParser.parseContents(CodexRolloutFixtures.basicSession)
        #expect(first.observations == second.observations)
    }

    @Test func resumeAppendsSecondSessionMetaWithSameIdentity() {
        let contents = CodexRolloutFixtures.basicSession + CodexRolloutFixtures.resumeContinuation
        let result = CodexRolloutTranscriptParser.parseContents(contents)
        let sessionIDs = result.observations.compactMap { observation -> String? in
            guard case .providerSessionObserved(let sessionID) = observation.payload else { return nil }
            return sessionID
        }
        #expect(sessionIDs == [CodexRolloutFixtures.sessionID, CodexRolloutFixtures.sessionID])
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
        case .transcript(.subagentSummary(let payload)):
            return "subagent:\(payload.subagentID)"
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
