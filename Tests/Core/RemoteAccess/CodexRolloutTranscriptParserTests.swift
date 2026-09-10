import Foundation
import RemoteProtocol
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
            "profile:gpt-5.5:high",
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

    @Test func parsesCompletedUserItemWithoutLeakingInjectedContext() throws {
        let result = CodexRolloutTranscriptParser.parseContents(CodexRolloutFixtures.completedItemUserSession)
        let userObservations = result.observations.filter { observation in
            if case .transcript(.userMessage) = observation.payload { return true }
            return false
        }

        let observation = try #require(userObservations.first)
        #expect(userObservations.count == 1)
        guard case .transcript(.userMessage(let payload)) = observation.payload else {
            Issue.record("Expected a user-message observation")
            return
        }
        #expect(payload.text == "Summarize previous commit")
        #expect(observation.turnID == "turn-601")
        #expect(observation.providerIdentity == "item-user-0601")
        #expect(observation.fingerprint == "user_item:item-user-0601")
        #expect(result.observations.contains { candidate in
            guard case .transcript(.userMessage(let candidatePayload)) = candidate.payload else { return false }
            return candidatePayload.text.contains("private host context")
        } == false)
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

        let modernFirst = CodexRolloutTranscriptParser.parseContents(CodexRolloutFixtures.completedItemUserSession)
        let modernSecond = CodexRolloutTranscriptParser.parseContents(CodexRolloutFixtures.completedItemUserSession)
        #expect(modernFirst.observations == modernSecond.observations)
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
        case .executionProfileReported(let profile):
            return "profile:\(profile.modelIdentifier ?? "nil"):\(profile.reasoningEffort ?? "nil")"
        case .contextCompacted:
            return "contextCompacted"
        }
    }
}

struct CodexExecutionProfileParserTests {
    @Test func nullOrFalseSubagentMarkersDoNotHideRootIdentityOrMetadata() {
        for marker in ["null", "false"] {
            let contents = "{\"timestamp\":\"2026-08-07T10:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"root\",\"source\":{\"subagent\":\(marker)}}}\n" +
                #"{"timestamp":"2026-08-07T10:00:01Z","type":"turn_context","payload":{"model":"root-model"}}"#
            let observations = CodexRolloutTranscriptParser.parseContents(contents).observations
            #expect(observations.contains { $0.payload == .providerSessionObserved(providerSessionID: "root") })
            #expect(observations.contains { $0.payload == .executionProfileReported(.init(modelIdentifier: "root-model")) })
        }
    }

    @Test func profileFilteringDoesNotBroadenExistingSessionIdentityExclusion() {
        let contents = #"{"timestamp":"2026-08-07T10:00:00Z","type":"session_meta","payload":{"id":"session","parent_thread_id":"parent","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent","depth":1}}}}}"#
        let observations = CodexRolloutTranscriptParser.parseContents(contents).observations
        #expect(observations.contains { $0.payload == .providerSessionObserved(providerSessionID: "session") })
    }

    @Test func structuredTurnContextsPreserveModelSwitchesAndReplayIdentity() {
        let contents = [
            #"{"timestamp":"2026-08-07T10:00:00Z","type":"session_meta","payload":{"id":"root","model":"not-authoritative"}}"#,
            #"{"timestamp":"2026-08-07T10:00:01Z","type":"turn_context","payload":{"model":"model-a","effort":"high"}}"#,
            #"{"timestamp":"2026-08-07T10:00:02Z","type":"turn_context","payload":{"model":"model-b"}}"#,
            #"{"timestamp":"2026-08-07T10:00:03Z","type":"turn_context","payload":{"model":"model-a","effort":"high"}}"#,
            #"{"timestamp":"2026-08-07T10:00:04Z","type":"event_msg","payload":{"type":"agent_message","message":"model=model-text effort=low"}}"#,
            #"{"timestamp":"2026-08-07T10:00:05Z","type":"turn_context","payload":{"model":" ","effort":" "}}"#,
        ].joined(separator: "\n")
        let observations = CodexRolloutTranscriptParser.parseContents(contents).observations
        let reports = observations.filter { if case .executionProfileReported = $0.payload { return true }; return false }
        #expect(reports.compactMap { observation -> RemoteSessionExecutionProfile? in
            guard case .executionProfileReported(let profile) = observation.payload else { return nil }
            return profile
        } == [
            .init(modelIdentifier: "model-a", reasoningEffort: "high"),
            .init(modelIdentifier: "model-b"),
            .init(modelIdentifier: "model-a", reasoningEffort: "high"),
        ])
        #expect(Set(reports.map(\.fingerprint)).count == 3)
        #expect(CodexRolloutTranscriptParser.parseContents(contents).observations == observations)
        var projector = ConversationProjectorTests.makeProjector()
        for observation in observations { projector.ingest(observation) }
        #expect(projector.executionProfile == .init(modelIdentifier: "model-a", reasoningEffort: "high"))
        for observation in observations { projector.ingest(observation) }
        #expect(projector.executionProfile == .init(modelIdentifier: "model-a", reasoningEffort: "high"))
    }

    @Test func childSessionMetadataCannotReportTheRootProfile() {
        for marker in [#""agent_role":"worker""#, #""parent_thread_id":"parent""#, #""source":{"subagent":{"thread_spawn":{}}}"#] {
            let contents = "{\"timestamp\":\"2026-08-07T10:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"child\",\(marker)}}\n" +
                #"{"timestamp":"2026-08-07T10:00:01Z","type":"turn_context","payload":{"model":"child-model","effort":"low"}}"#
            let result = CodexRolloutTranscriptParser.parseContents(contents)
            #expect(result.malformedLineCount == 0)
            #expect(!result.observations.contains { if case .executionProfileReported = $0.payload { return true }; return false })
        }
    }
}
