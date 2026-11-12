import RemoteProtocol
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// An agent hook sends all the updates of one hook event as one batch.
struct AutomationSocketServerEventBatchTests: AutomationSocketServerTestSupport {
    /// A Claude Stop hook sends its Ready status and its turn end together.
    /// Both must reach the session, or the conversation stays "working".
    @Test
    func batchAppliesEveryEventInOrderAndAuditsEachOne() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run { try makeServer(socketPath: socketPath) }
        defer { withExtendedLifetime(server.server) {} }
        try waitForSocket(at: socketPath)

        let sessionID = "sess-claude-batch"
        try startBoundClaudeSession(sessionID: sessionID, panelID: server.panelID, socketPath: socketPath)
        #expect(try sendEvent(statusEvent(.working, sessionID: sessionID), socketPath: socketPath).ok)

        let turnEnd = ProviderTranscriptObservation(
            timestamp: Date(timeIntervalSince1970: 1_786_000_000),
            fingerprint: "managed:claude:prompt-open:turn-7",
            payload: .turnEnded(turnID: "turn-7", reason: .completed)
        )
        let response = try sendEvent(
            try AutomationEventEnvelope.batch(
                [
                    statusEvent(.ready, sessionID: sessionID),
                    try observationEvent(turnEnd, sessionID: sessionID, panelID: server.panelID),
                ],
                requestID: "batch-stop"
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        #expect(response.requestID == "batch-stop")
        guard case .array(let results)? = response.result?["results"] else {
            Issue.record("expected one result for each event")
            return
        }
        #expect(results.count == 2)

        let (status, observations) = await MainActor.run {
            (
                server.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID)?.status,
                server.sessionRuntimeStore.providerConversationFeed(managedSessionID: sessionID)?.observations
            )
        }
        #expect(status?.kind == .ready)
        #expect(observations?.last == turnEnd)

        let diagnostics = try sendRequest(
            AutomationRequestEnvelope(
                requestID: "audit-query",
                command: AutomationSocketProtocol.diagnosticsRecentRequestsCommand
            ),
            socketPath: socketPath
        )
        let eventTypes = try automationSection(from: diagnostics).recentRequests.compactMap(\.eventType)
        #expect(Array(eventTypes.suffix(2)) == ["session.status", "session.provider_conversation.observation"])
        #expect(eventTypes.contains(AutomationSocketProtocol.eventBatchEventType) == false)
    }

    @Test
    func batchRejectsAMalformedEventBeforeApplyingAny() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run { try makeServer(socketPath: socketPath) }
        defer { withExtendedLifetime(server.server) {} }
        try waitForSocket(at: socketPath)

        let sessionID = "sess-claude-malformed-batch"
        try startBoundClaudeSession(sessionID: sessionID, panelID: server.panelID, socketPath: socketPath)
        #expect(try sendEvent(statusEvent(.working, sessionID: sessionID), socketPath: socketPath).ok)

        let nested = try AutomationEventEnvelope.batch([statusEvent(.error, sessionID: sessionID)])
        let batch = try AutomationEventEnvelope.batch([statusEvent(.ready, sessionID: sessionID), nested])
        let response = try sendEvent(batch, socketPath: socketPath)

        #expect(response.ok == false)
        #expect(response.error?.code == "INVALID_PAYLOAD")
        #expect(response.error?.message.contains("events[1]") == true)

        // A member gets the protocol check that a top-level event gets.
        let compatible = try AutomationEventEnvelope.batch([
            statusEvent(.ready, sessionID: sessionID),
            statusEvent(.error, sessionID: sessionID),
        ])
        guard case .array(var members)? = compatible.payload["events"],
              case .object(var member) = members[1] else {
            Issue.record("expected the batched events")
            return
        }
        member["protocolVersion"] = .string("2.0")
        members[1] = .object(member)
        let incompatible = AutomationEventEnvelope(
            eventType: AutomationSocketProtocol.eventBatchEventType,
            requestID: UUID().uuidString,
            payload: ["events": .array(members)]
        )
        let versionResponse = try sendEvent(incompatible, socketPath: socketPath)
        #expect(versionResponse.ok == false)
        #expect(versionResponse.error?.code == "INCOMPATIBLE_PROTOCOL")

        let statusKind = await currentStatusKind(server.sessionRuntimeStore, sessionID: sessionID)
        #expect(statusKind == .working)
    }

    @Test
    func batchStopsAtTheFirstFailingEvent() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run { try makeServer(socketPath: socketPath) }
        defer { withExtendedLifetime(server.server) {} }
        try waitForSocket(at: socketPath)

        let sessionID = "sess-claude-failing-batch"
        try startBoundClaudeSession(sessionID: sessionID, panelID: server.panelID, socketPath: socketPath)

        let invalidStatus = AutomationEventEnvelope(
            eventType: "session.status",
            sessionID: sessionID,
            requestID: UUID().uuidString,
            payload: ["kind": .string("not-a-kind"), "summary": .string("Broken")]
        )
        let response = try sendEvent(
            try AutomationEventEnvelope.batch([
                statusEvent(.working, sessionID: sessionID),
                invalidStatus,
                statusEvent(.ready, sessionID: sessionID),
            ]),
            socketPath: socketPath
        )

        #expect(response.ok == false)
        #expect(response.error?.code == "INVALID_PAYLOAD")
        #expect(response.error?.message.hasPrefix("event 2 of 3 (session.status): ") == true)
        let statusKind = await currentStatusKind(server.sessionRuntimeStore, sessionID: sessionID)
        #expect(statusKind == .working)
    }

    private func startBoundClaudeSession(sessionID: String, panelID: UUID, socketPath: String) throws {
        let nativeSessionID = "claude-root"
        for event in [
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: panelID.uuidString,
                requestID: UUID().uuidString,
                payload: ["agent": .string(AgentKind.claude.rawValue), "cwd": .string("/tmp/repo")]
            ),
            AutomationEventEnvelope(
                eventType: "session.update_resume_record",
                sessionID: sessionID,
                panelID: panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.claude.rawValue),
                    "nativeSessionID": .string(nativeSessionID),
                    "sessionFilePath": .string("/tmp/claude-root.jsonl"),
                    "cwd": .string("/tmp/repo"),
                ]
            ),
            AutomationEventEnvelope(
                eventType: "session.provider_conversation.reset",
                sessionID: sessionID,
                panelID: panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "provider": .string(AgentKind.claude.rawValue),
                    "nativeSessionID": .string(nativeSessionID),
                    "snapshotID": .string("claude:\(nativeSessionID)"),
                ]
            ),
        ] {
            let response = try sendEvent(event, socketPath: socketPath)
            #expect(response.ok, "\(event.eventType) failed: \(String(describing: response.error))")
        }
    }

    private func statusEvent(_ kind: SessionStatusKind, sessionID: String) -> AutomationEventEnvelope {
        AutomationEventEnvelope(
            eventType: "session.status",
            sessionID: sessionID,
            requestID: UUID().uuidString,
            payload: ["kind": .string(kind.rawValue), "summary": .string(kind.rawValue)]
        )
    }

    private func observationEvent(
        _ observation: ProviderTranscriptObservation,
        sessionID: String,
        panelID: UUID
    ) throws -> AutomationEventEnvelope {
        AutomationEventEnvelope(
            eventType: "session.provider_conversation.observation",
            sessionID: sessionID,
            panelID: panelID.uuidString,
            requestID: UUID().uuidString,
            payload: [
                "provider": .string(AgentKind.claude.rawValue),
                "nativeSessionID": .string("claude-root"),
                "snapshotID": .string("claude:claude-root"),
                "observationJSON": .string(String(decoding: try JSONEncoder().encode(observation), as: UTF8.self)),
            ]
        )
    }

    private func currentStatusKind(_ store: SessionRuntimeStore, sessionID: String) async -> SessionStatusKind? {
        await MainActor.run { store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind }
    }
}
