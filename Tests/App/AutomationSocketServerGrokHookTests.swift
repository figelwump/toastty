import CoreState
import Foundation
import Testing
@testable import ToasttyApp

struct AutomationSocketServerGrokHookTests: AutomationSocketServerTestSupport {
    @Test
    func decoderPreservesNormalizedIdentityTimestampAndOptionalMetadata() throws {
        let nativeID = UUID()
        let promptID = UUID()
        var payload = grokPayload(kind: .notification, nativeID: nativeID, timestamp: 1_700_000_000.123456)
        payload["promptID"] = .string(promptID.uuidString)
        payload["notificationType"] = .string(" idle_prompt ")
        payload["toolName"] = .string(" read_file ")
        payload["toolUseID"] = .string(" call-123 ")
        payload["sessionFilePath"] = .string("/tmp/👩‍💻 session.json ")
        payload["cwd"] = .string("/tmp/👩‍💻 repo ")
        let event = try GrokHookEventPayloadDecoder.decode(payload)
        #expect(event.kind == .notification)
        #expect(event.nativeSessionID == nativeID.uuidString.lowercased())
        #expect(event.promptID == promptID.uuidString.lowercased())
        #expect(abs(event.timestamp.timeIntervalSince1970 - 1_700_000_000.123456) < 0.000001)
        #expect(event.notificationType == "idle_prompt")
        #expect(event.toolName == "read_file")
        #expect(event.toolUseID == "call-123")
        #expect(event.sessionFilePath == "/tmp/👩‍💻 session.json ")
        #expect(event.cwd == "/tmp/👩‍💻 repo ")
        #expect(!event.isSubagent)

        payload.removeValue(forKey: "promptID")
        payload["timestamp"] = .int(1_700_000_000)
        #expect(try GrokHookEventPayloadDecoder.decode(payload).promptID == nil)
        #expect(try GrokHookEventPayloadDecoder.decode(payload).timestamp == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test
    func decoderRejectsMissingMalformedAndUnboundedMetadata() throws {
        let valid = grokPayload(kind: .sessionStart, nativeID: UUID(), timestamp: 1_700_000_000)
        for key in ["kind", "nativeSessionID", "timestamp", "isSubagent"] {
            var payload = valid
            payload.removeValue(forKey: key)
            #expect(throws: (any Error).self) { try GrokHookEventPayloadDecoder.decode(payload) }
        }
        let malformedFields: [(String, AutomationJSONValue)] = [
            ("kind", .string("future_event")),
            ("nativeSessionID", .string("not-a-uuid")),
            ("promptID", .string("not-a-uuid")),
            ("timestamp", .string("2026-10-02T12:20:00Z")),
            ("timestamp", .double(.infinity)),
            ("timestamp", .double(.nan)),
            ("timestamp", .double(253_402_300_800)),
            ("isSubagent", .string("false")),
            ("notificationType", .string(String(repeating: "n", count: 129))),
            ("notificationType", .string(String(repeating: "é", count: 65))),
            ("notificationType", .string("idle\nprompt")),
            ("toolName", .string(String(repeating: "x", count: 257))),
            ("toolUseID", .string(String(repeating: "é", count: 129))),
            ("toolName", .string("read\nfile")),
            ("toolUseID", .int(123)),
            ("cwd", .string(String(repeating: "x", count: 4097))),
            ("sessionFilePath", .string(String(repeating: "x", count: 4097))),
            ("sessionFilePath", .string("/tmp/session\u{0}.json")),
            ("cwd", .int(12)),
        ]
        for (key, value) in malformedFields {
            var payload = valid
            payload[key] = value
            #expect(throws: (any Error).self) { try GrokHookEventPayloadDecoder.decode(payload) }
        }
        var bounded = valid
        bounded["notificationType"] = .string(String(repeating: "n", count: 128))
        bounded["cwd"] = .string("/" + String(repeating: "x", count: 4095))
        bounded["sessionFilePath"] = .string("/" + String(repeating: "x", count: 4095))
        #expect(try GrokHookEventPayloadDecoder.decode(bounded).notificationType?.utf8.count == 128)
        #expect(try GrokHookEventPayloadDecoder.decode(bounded).cwd?.utf8.count == 4096)
    }

    @Test
    func socketReconcilesRootPromptResumeAndCompletionWhileRejectingForeignEvents() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(
                socketPath: socketPath,
                sessionRuntimeStore: SessionRuntimeStore(
                    sendSessionStatusNotification: { _, _, _, _, _ in },
                    isApplicationActive: { false }
                )
            )
        }
        defer { withExtendedLifetime(server.server) {} }
        try waitForSocket(at: socketPath)
        let rootURL = try makeShortTemporaryDirectory(prefix: "ttg")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sessionFileURL = rootURL.appendingPathComponent("session.json")
        try Data("{}".utf8).write(to: sessionFileURL)
        let sessionID = "sess-grok-hook"
        let nativeID = UUID()
        let firstPromptID = UUID()
        let secondPromptID = UUID()
        try await MainActor.run {
            server.sessionRuntimeStore.startSession(
                sessionID: sessionID, agent: .grok, panelID: server.panelID,
                windowID: try #require(server.store.state.windows.first?.id),
                workspaceID: server.workspaceID, usesSessionStatusNotifications: true,
                cwd: rootURL.path, repoRoot: rootURL.path,
                at: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }

        func send(_ payload: [String: AutomationJSONValue], panelID: UUID? = nil) throws -> AutomationResponseEnvelope {
            try sendEvent(AutomationEventEnvelope(
                eventType: "session.grok_hook_event", sessionID: sessionID,
                panelID: (panelID ?? server.panelID).uuidString,
                requestID: UUID().uuidString, payload: payload
            ), socketPath: socketPath)
        }

        let start = try send(grokPayload(kind: .sessionStart, nativeID: nativeID, timestamp: 1_700_000_001))
        #expect(start.result?.string("status") == "accepted")
        await expectStatus(.idle, sessionID: sessionID, runtime: server.sessionRuntimeStore)

        var prompt = grokPayload(kind: .userPromptSubmit, nativeID: nativeID, promptID: firstPromptID, timestamp: 1_700_000_002)
        prompt["sessionFilePath"] = .string(sessionFileURL.path)
        prompt["cwd"] = .string(rootURL.path)
        #expect(try send(prompt).result?.string("status") == "accepted")
        await expectStatus(.working, sessionID: sessionID, runtime: server.sessionRuntimeStore)
        let capturedResumeRecord = await MainActor.run {
            terminalPanelResumeRecord(in: server.store, panelID: server.panelID)
        }
        let resumeRecord = try #require(capturedResumeRecord)
        #expect(resumeRecord.agent == .grok)
        #expect(resumeRecord.nativeSessionID == nativeID.uuidString.lowercased())
        #expect(resumeRecord.sessionFilePath == sessionFileURL.path)
        #expect(resumeRecord.cwd == rootURL.path)

        let foreignPanel = try send(
            grokPayload(kind: .stop, nativeID: nativeID, promptID: firstPromptID, timestamp: 1_700_000_003),
            panelID: UUID()
        )
        #expect(!foreignPanel.ok)
        #expect(foreignPanel.error?.code == "INVALID_PAYLOAD")
        var malformed = grokPayload(kind: .stop, nativeID: nativeID, promptID: firstPromptID, timestamp: 1_700_000_003)
        malformed["timestamp"] = .string("invalid")
        let malformedResponse = try send(malformed)
        #expect(!malformedResponse.ok)
        #expect(malformedResponse.error?.code == "INVALID_PAYLOAD")
        var nested = grokPayload(kind: .stop, nativeID: nativeID, promptID: firstPromptID, timestamp: 1_700_000_003)
        nested["isSubagent"] = .bool(true)
        nested["sessionFilePath"] = .string("/tmp/nested-session.json")
        #expect(try send(nested).result?.string("status") == "ignored")
        #expect(try send(grokPayload(kind: .stop, nativeID: UUID(), promptID: firstPromptID, timestamp: 1_700_000_003)).result?.string("status") == "ignored")
        await expectStatus(.working, sessionID: sessionID, runtime: server.sessionRuntimeStore)
        let unchangedRecord = await MainActor.run {
            terminalPanelResumeRecord(in: server.store, panelID: server.panelID)
        }
        #expect(unchangedRecord == resumeRecord)

        // Actual Grok tool events have a call ID but omit the prompt ID.
        var tool = grokPayload(kind: .preToolUse, nativeID: nativeID, timestamp: 1_700_000_003)
        tool["toolName"] = .string("run_terminal_command")
        tool["toolUseID"] = .string("call-123")
        #expect(try send(tool).result?.string("status") == "accepted")
        await expectStatus(.working, detail: "Running a command", sessionID: sessionID, runtime: server.sessionRuntimeStore)
        var permission = grokPayload(kind: .notification, nativeID: nativeID, timestamp: 1_700_000_003.5)
        permission["notificationType"] = .string("permission_prompt")
        #expect(try send(permission).result?.string("status") == "accepted")
        await expectStatus(.needsApproval, detail: "Waiting for command approval", sessionID: sessionID, runtime: server.sessionRuntimeStore)
        tool["kind"] = .string(GrokHookEvent.Kind.postToolUse.rawValue)
        tool["timestamp"] = .double(1_700_000_004)
        #expect(try send(tool).result?.string("status") == "accepted")
        await expectStatus(.working, detail: "Responding to your prompt", sessionID: sessionID, runtime: server.sessionRuntimeStore)

        #expect(try send(grokPayload(kind: .userPromptSubmit, nativeID: nativeID, promptID: secondPromptID, timestamp: 1_700_000_005)).result?.string("status") == "accepted")
        #expect(try send(grokPayload(kind: .stop, nativeID: nativeID, promptID: firstPromptID, timestamp: 1_700_000_006)).result?.string("status") == "ignored")
        #expect(try send(prompt).result?.string("status") == "ignored")
        await expectStatus(.working, sessionID: sessionID, runtime: server.sessionRuntimeStore)
        #expect(try send(grokPayload(kind: .stop, nativeID: nativeID, promptID: secondPromptID, timestamp: 1_700_000_007)).result?.string("status") == "accepted")
        await expectStatus(.idle, sessionID: sessionID, runtime: server.sessionRuntimeStore)
        var idle = grokPayload(kind: .notification, nativeID: nativeID, timestamp: 1_700_000_008)
        idle["notificationType"] = .string("idle_prompt")
        #expect(try send(idle).result?.string("status") == "accepted")
        await expectStatus(.ready, sessionID: sessionID, runtime: server.sessionRuntimeStore)

        await MainActor.run {
            server.sessionRuntimeStore.stopSession(sessionID: sessionID, at: Date(timeIntervalSince1970: 1_700_000_009))
        }
        idle["timestamp"] = .double(1_700_000_010)
        let afterTeardown = try send(idle)
        #expect(!afterTeardown.ok)
        #expect(afterTeardown.error?.code == "INVALID_PAYLOAD")
    }

    private func grokPayload(
        kind: GrokHookEvent.Kind, nativeID: UUID, promptID: UUID? = nil, timestamp: Double
    ) -> [String: AutomationJSONValue] {
        var payload: [String: AutomationJSONValue] = [
            "kind": .string(kind.rawValue), "nativeSessionID": .string(nativeID.uuidString),
            "timestamp": .double(timestamp), "isSubagent": .bool(false),
        ]
        if let promptID { payload["promptID"] = .string(promptID.uuidString) }
        return payload
    }

    private func expectStatus(_ kind: SessionStatusKind, detail: String? = nil, sessionID: String, runtime: SessionRuntimeStore) async {
        let status = await MainActor.run { runtime.sessionRegistry.activeSession(sessionID: sessionID)?.status }
        #expect(status?.kind == kind)
        if let detail { #expect(status?.detail == detail) }
    }
}
