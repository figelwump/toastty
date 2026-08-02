import Darwin
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

struct AutomationSocketServerCodexHookTests: AutomationSocketServerTestSupport {
    @Test
    func codexHookPayloadDecoderPreservesOptionalOperationIdentifiers() throws {
        let event = try CodexHookEventPayloadDecoder.decode([
            "hookEventName": .string("PermissionRequest"),
            "toolUseID": .string(" tool-1 "),
            "callID": .string(" call-1 "),
            "approvalID": .string(" approval-1 "),
            "spawnToolUseID": .string("spawn-1"),
            "spawnTaskName": .string("review"),
        ])

        #expect(event.toolUseID == "tool-1")
        #expect(event.callID == "call-1")
        #expect(event.approvalID == "approval-1")
        #expect(event.spawnMetadata == CodexSpawnHookMetadata(
            toolUseID: "spawn-1",
            taskName: "review"
        ))
    }

    @Test
    func codexHookPayloadDecoderIgnoresAbsentOrUnusableOptionalIdentifiers() throws {
        let missing = try CodexHookEventPayloadDecoder.decode([
            "hookEventName": .string("PermissionRequest"),
            "toolUseID": .string("tool-only"),
        ])
        #expect(missing.toolUseID == "tool-only")
        #expect(missing.callID == nil)
        #expect(missing.approvalID == nil)
        #expect(missing.spawnMetadata == nil)

        let unusable = try CodexHookEventPayloadDecoder.decode([
            "hookEventName": .string("PermissionRequest"),
            "toolUseID": .null,
            "callID": .string("  "),
            "approvalID": .int(42),
        ])
        #expect(unusable.toolUseID == nil)
        #expect(unusable.callID == nil)
        #expect(unusable.approvalID == nil)
    }

    @Test
    func codexHookEventUpdatesManagedCodexSessionStatus() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-codex-hook"
        try await MainActor.run {
            server.sessionRuntimeStore.startSession(
                sessionID: sessionID,
                agent: .codex,
                panelID: server.panelID,
                windowID: try #require(server.store.state.windows.first?.id),
                workspaceID: server.workspaceID,
                usesSessionStatusNotifications: true,
                cwd: "/tmp/repo",
                repoRoot: "/tmp/repo",
                at: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.codex_hook_event",
                sessionID: sessionID,
                requestID: UUID().uuidString,
                payload: [
                    "hookEventName": .string("PreToolUse"),
                    "permissionMode": .string("default"),
                    "threadID": .string("thread-root"),
                    "kind": .string(SessionStatusKind.working.rawValue),
                    "summary": .string("Working"),
                    "detail": .string("Running tests"),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        #expect(response.result?.string("eventType") == "session.codex_hook_event")
        #expect(response.result?.string("status") == "accepted")
        let status = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID)?.status
        }
        #expect(status?.kind == .working)
        #expect(status?.detail == "Running tests")
    }

    @Test
    func codexSubagentHookEventsProjectAndReopenBackgroundActivity() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-codex-subagent-hook"
        try await MainActor.run {
            server.sessionRuntimeStore.startSession(
                sessionID: sessionID,
                agent: .codex,
                panelID: server.panelID,
                windowID: try #require(server.store.state.windows.first?.id),
                workspaceID: server.workspaceID,
                usesSessionStatusNotifications: true,
                codexStatusTrackingSource: .hooks,
                cwd: "/tmp/repo",
                repoRoot: "/tmp/repo",
                at: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }

        func sendSubagentEvent(_ eventName: String) throws -> AutomationResponseEnvelope {
            try sendEvent(
                AutomationEventEnvelope(
                    eventType: "session.codex_hook_event",
                    sessionID: sessionID,
                    requestID: UUID().uuidString,
                    payload: [
                        "hookEventName": .string(eventName),
                        "threadID": .string("thread-root"),
                        "turnID": .string("turn-root"),
                        "subagentID": .string("agent-child"),
                        "subagentType": .string("default"),
                    ]
                ),
                socketPath: socketPath
            )
        }


        let metadataResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.codex_hook_event",
                sessionID: sessionID,
                requestID: UUID().uuidString,
                payload: [
                    "hookEventName": .string("PreToolUse"),
                    "threadID": .string("thread-root"),
                    "spawnToolUseID": .string("call-spawn"),
                    "spawnTaskName": .string("security_privacy"),
                    "spawnMessage": .string("Review the security and privacy implications"),
                ]
            ),
            socketPath: socketPath
        )
        #expect(metadataResponse.result?.string("status") == "accepted")
        await MainActor.run {
            #expect(server.sessionRuntimeStore.handleCodexSubagentRolloutObservation(
                sessionID: sessionID,
                observation: .started(CodexSessionBackgroundActivity(
                    activityID: "agent-child",
                    hookActivityID: "agent-child",
                    spawnToolUseID: "call-spawn",
                    kind: .subagent,
                    displayName: "security_privacy"
                )),
                at: Date(timeIntervalSince1970: 1_700_000_001)
            ))
            #expect(server.sessionRuntimeStore.sessionRegistry
                .activeSession(sessionID: sessionID)?
                .backgroundActivitiesByID.isEmpty == true)
        }

        #expect(try sendSubagentEvent("SubagentStart").result?.string("status") == "accepted")
        var activity = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry
                .activeSession(sessionID: sessionID)?
                .backgroundActivitiesByID["agent-child"]
        }
        #expect(activity?.displayName == "security_privacy")
        #expect(activity?.command == "Review the security and privacy implications")

        #expect(try sendSubagentEvent("SubagentStop").result?.string("status") == "accepted")
        activity = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry
                .activeSession(sessionID: sessionID)?
                .backgroundActivitiesByID["agent-child"]
        }
        #expect(activity == nil)

        #expect(try sendSubagentEvent("SubagentStart").result?.string("status") == "accepted")
        activity = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry
                .activeSession(sessionID: sessionID)?
                .backgroundActivitiesByID["agent-child"]
        }
        #expect(activity != nil)
    }

    @Test
    func codexHookSessionStartUpdatesResumeRecordOnlyWhenAccepted() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-codex-hook-resume"
        try await MainActor.run {
            server.sessionRuntimeStore.startSession(
                sessionID: sessionID,
                agent: .codex,
                panelID: server.panelID,
                windowID: try #require(server.store.state.windows.first?.id),
                workspaceID: server.workspaceID,
                usesSessionStatusNotifications: true,
                cwd: "/tmp/repo",
                repoRoot: "/tmp/repo",
                at: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }

        let rootResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.codex_hook_event",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "hookEventName": .string("SessionStart"),
                    "source": .string("startup"),
                    "threadID": .string("thread-root"),
                    "nativeSessionID": .string("thread-root"),
                    "sessionFilePath": .string("/tmp/codex/root.jsonl"),
                    "cwd": .string("/tmp/repo"),
                ]
            ),
            socketPath: socketPath
        )

        #expect(rootResponse.ok)
        #expect(rootResponse.result?.string("status") == "accepted")
        var resumeRecord = await terminalPanelResumeRecord(in: server.store, panelID: server.panelID)
        #expect(resumeRecord?.agent == .codex)
        #expect(resumeRecord?.nativeSessionID == "thread-root")
        #expect(resumeRecord?.sessionFilePath == "/tmp/codex/root.jsonl")

        let childResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.codex_hook_event",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "hookEventName": .string("SessionStart"),
                    "threadID": .string("thread-child"),
                    "nativeSessionID": .string("thread-child"),
                    "sessionFilePath": .string("/tmp/codex/child.jsonl"),
                    "cwd": .string("/tmp/repo"),
                ]
            ),
            socketPath: socketPath
        )

        #expect(childResponse.ok)
        #expect(childResponse.result?.string("status") == "ignored")
        resumeRecord = await terminalPanelResumeRecord(in: server.store, panelID: server.panelID)
        #expect(resumeRecord?.nativeSessionID == "thread-root")
        #expect(resumeRecord?.sessionFilePath == "/tmp/codex/root.jsonl")

        let clearResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.codex_hook_event",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "hookEventName": .string("SessionStart"),
                    "source": .string("clear"),
                    "threadID": .string("thread-clear"),
                    "nativeSessionID": .string("thread-clear"),
                    "sessionFilePath": .string("/tmp/codex/clear.jsonl"),
                    "cwd": .string("/tmp/repo"),
                ]
            ),
            socketPath: socketPath
        )

        #expect(clearResponse.ok)
        #expect(clearResponse.result?.string("status") == "accepted")
        resumeRecord = await terminalPanelResumeRecord(in: server.store, panelID: server.panelID)
        #expect(resumeRecord?.nativeSessionID == "thread-clear")
        #expect(resumeRecord?.sessionFilePath == "/tmp/codex/clear.jsonl")
    }

}
