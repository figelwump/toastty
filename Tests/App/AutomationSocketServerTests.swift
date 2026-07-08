import Darwin
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

struct AutomationSocketServerTests {
    @Test
    func removedLegacySessionEventsAreRejected() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        for eventType in ["session.progress", "session.needs_input", "session.error"] {
            let response = try sendEvent(type: eventType, socketPath: socketPath)
            #expect(response.ok == false)
            #expect(response.error?.code == "UNKNOWN_EVENT_TYPE")
        }
    }

    @Test
    func sessionStartResponseIncludesSessionID() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-123"
        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        #expect(response.result?.string("sessionID") == sessionID)
    }

    @Test
    func sessionScopeCommandsMutateActiveSessionScope() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-scope-socket"
        let startResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startResponse.ok)

        let setCurrentResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: "scope-set-current",
                command: "session.scope.set_current",
                callerSessionID: sessionID,
                payload: [
                    "sessionID": .string(sessionID),
                    "panelID": .string(server.panelID.uuidString),
                ]
            ),
            socketPath: socketPath
        )

        #expect(setCurrentResponse.ok)
        #expect(setCurrentResponse.result?.bool("isScoped") == true)
        #expect(setCurrentResponse.result?.stringArray("workspaceIDs") == [])
        #expect(setCurrentResponse.result?.stringArray("effectiveWorkspaceIDs") == [server.workspaceID.uuidString])
        let currentOnlyScope = await MainActor.run {
            server.sessionRuntimeStore.scope(ofSessionID: sessionID)
        }
        #expect(currentOnlyScope == Optional(Set<UUID>()))

        let extraWorkspaceID = UUID()
        let setResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: "scope-set",
                command: "session.scope.set",
                callerSessionID: sessionID,
                payload: [
                    "sessionID": .string(sessionID),
                    "workspaceIDs": .array([.string(extraWorkspaceID.uuidString)]),
                ]
            ),
            socketPath: socketPath
        )

        #expect(setResponse.ok)
        #expect(setResponse.result?.bool("isScoped") == true)
        #expect(setResponse.result?.stringArray("workspaceIDs") == [extraWorkspaceID.uuidString])
        let storedScope = await MainActor.run {
            server.sessionRuntimeStore.scope(ofSessionID: sessionID)
        }
        #expect(storedScope == Optional(Set([extraWorkspaceID])))

        let clearResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: "scope-clear",
                command: "session.scope.clear",
                callerSessionID: sessionID,
                payload: [
                    "sessionID": .string(sessionID),
                ]
            ),
            socketPath: socketPath
        )

        #expect(clearResponse.ok)
        #expect(clearResponse.result?.bool("isScoped") == false)
        let clearedScope = await MainActor.run {
            server.sessionRuntimeStore.scope(ofSessionID: sessionID)
        }
        #expect(clearedScope == nil)
    }

    @Test
    func sessionStatusCanResolveActiveSessionWithoutPanelID() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-status-only"
        let startResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startResponse.ok)

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.status",
                sessionID: sessionID,
                requestID: UUID().uuidString,
                payload: [
                    "kind": .string(SessionStatusKind.working.rawValue),
                    "summary": .string("editing 3 files"),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        #expect(response.result?.string("eventType") == "session.status")
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

    @Test
    func codexHookSessionStartCancelsNativeSessionObservation() async throws {
        let socketPath = temporarySocketPath()
        let observer = await MainActor.run { SpyNativeSessionObserverRegistry() }
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath, nativeSessionObserverRegistry: observer)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-codex-hook-cancel"
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

        #expect(response.ok)
        #expect(response.result?.string("status") == "accepted")
        let cancelledSessionIDs = await MainActor.run { observer.cancelledSessionIDs }
        #expect(cancelledSessionIDs.contains(sessionID))
    }

    @Test
    func sessionUpdateResumeRecordCancelsNativeSessionObservation() async throws {
        let socketPath = temporarySocketPath()
        let observer = await MainActor.run { SpyNativeSessionObserverRegistry() }
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath, nativeSessionObserverRegistry: observer)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-claude-resume-cancel"
        let startResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.claude.rawValue),
                    "cwd": .string("/tmp/repo"),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startResponse.ok)

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.update_resume_record",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.claude.rawValue),
                    "nativeSessionID": .string("db4f311b-12d0-4f61-ba81-0ae44ed10492"),
                    "sessionFilePath": .string("/tmp/claude/session.jsonl"),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        let cancelledSessionIDs = await MainActor.run { observer.cancelledSessionIDs }
        #expect(cancelledSessionIDs.contains(sessionID))
    }

    @Test
    func sessionUpdateResumeRecordRefusesLiveOwnedNativeSessionClaim() async throws {
        let socketPath = temporarySocketPath()
        let observer = await MainActor.run { SpyNativeSessionObserverRegistry() }
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath, nativeSessionObserverRegistry: observer)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let ownerSessionID = "sess-claude-owner"
        let claimantSessionID = "sess-claude-claimant"
        let nativeSessionID = "db4f311b-12d0-4f61-ba81-0ae44ed10492"
        let ownerScopeID = UUID()
        let ownerRecord = ManagedAgentResumeRecord(
            agent: .claude,
            nativeSessionID: nativeSessionID,
            sessionFilePath: "/tmp/claude/owner.jsonl",
            cwd: "/tmp/repo",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            scopedWorkspaceIDs: [ownerScopeID]
        )
        let claimantRecord = ManagedAgentResumeRecord(
            agent: .claude,
            nativeSessionID: "005b99c5-d8b8-467a-ac60-184e41fe7403",
            sessionFilePath: "/tmp/claude/claimant.jsonl",
            cwd: "/tmp/repo",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_010)
        )

        let ownerStart = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: ownerSessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.claude.rawValue),
                    "cwd": .string("/tmp/repo"),
                ]
            ),
            socketPath: socketPath
        )
        #expect(ownerStart.ok)

        let claimantPanelID = try await MainActor.run {
            #expect(server.store.send(.updateTerminalPanelResumeRecord(
                panelID: server.panelID,
                resumeRecord: ownerRecord
            )))
            #expect(server.store.send(.splitFocusedSlotInDirection(
                workspaceID: server.workspaceID,
                direction: .right
            )))
            let workspace = try #require(server.store.state.workspacesByID[server.workspaceID])
            return try #require(workspace.focusedPanelID)
        }

        let claimantStart = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: claimantSessionID,
                panelID: claimantPanelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.claude.rawValue),
                    "cwd": .string("/tmp/repo"),
                ]
            ),
            socketPath: socketPath
        )
        #expect(claimantStart.ok)

        await MainActor.run {
            #expect(server.store.send(.updateTerminalPanelResumeRecord(
                panelID: claimantPanelID,
                resumeRecord: claimantRecord
            )))
        }

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.update_resume_record",
                sessionID: claimantSessionID,
                panelID: claimantPanelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.claude.rawValue),
                    "nativeSessionID": .string(nativeSessionID),
                    "sessionFilePath": .string("/tmp/claude/stolen.jsonl"),
                    "cwd": .string("/tmp/repo"),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        let ownerRecordAfter = await terminalPanelResumeRecord(in: server.store, panelID: server.panelID)
        let claimantRecordAfter = await terminalPanelResumeRecord(in: server.store, panelID: claimantPanelID)
        #expect(ownerRecordAfter == ownerRecord)
        #expect(claimantRecordAfter == claimantRecord)
        let cancelledSessionIDs = await MainActor.run { observer.cancelledSessionIDs }
        #expect(cancelledSessionIDs.contains(claimantSessionID) == false)
    }

    @Test
    func codexHookResumeRecordRefusesLiveOwnedNativeSessionClaim() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let ownerSessionID = "sess-codex-owner"
        let claimantSessionID = "sess-codex-claimant"
        let nativeSessionID = "019e2823-f520-7690-91b6-cd84eb52dd8a"
        let ownerRecord = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: nativeSessionID,
            sessionFilePath: "/tmp/codex/owner.jsonl",
            cwd: "/tmp/repo",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            scopedWorkspaceIDs: [UUID()]
        )
        let claimantRecord = ManagedAgentResumeRecord(
            agent: .codex,
            nativeSessionID: "019e2823-f520-7690-91b6-cd84eb52dd8b",
            sessionFilePath: "/tmp/codex/claimant.jsonl",
            cwd: "/tmp/repo",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_010)
        )

        let claimantPanelID = try await MainActor.run {
            let windowID = try #require(server.store.state.windows.first?.id)
            server.sessionRuntimeStore.startSession(
                sessionID: ownerSessionID,
                agent: .codex,
                panelID: server.panelID,
                windowID: windowID,
                workspaceID: server.workspaceID,
                usesSessionStatusNotifications: true,
                cwd: "/tmp/repo",
                repoRoot: "/tmp/repo",
                at: Date(timeIntervalSince1970: 1_700_000_000)
            )
            #expect(server.store.send(.updateTerminalPanelResumeRecord(
                panelID: server.panelID,
                resumeRecord: ownerRecord
            )))
            #expect(server.store.send(.splitFocusedSlotInDirection(
                workspaceID: server.workspaceID,
                direction: .right
            )))
            let workspace = try #require(server.store.state.workspacesByID[server.workspaceID])
            let claimantPanelID = try #require(workspace.focusedPanelID)
            server.sessionRuntimeStore.startSession(
                sessionID: claimantSessionID,
                agent: .codex,
                panelID: claimantPanelID,
                windowID: windowID,
                workspaceID: server.workspaceID,
                usesSessionStatusNotifications: true,
                cwd: "/tmp/repo",
                repoRoot: "/tmp/repo",
                at: Date(timeIntervalSince1970: 1_700_000_010)
            )
            #expect(server.store.send(.updateTerminalPanelResumeRecord(
                panelID: claimantPanelID,
                resumeRecord: claimantRecord
            )))
            return claimantPanelID
        }

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.codex_hook_event",
                sessionID: claimantSessionID,
                panelID: claimantPanelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "hookEventName": .string("SessionStart"),
                    "source": .string("startup"),
                    "threadID": .string(nativeSessionID),
                    "nativeSessionID": .string(nativeSessionID),
                    "sessionFilePath": .string("/tmp/codex/stolen.jsonl"),
                    "cwd": .string("/tmp/repo"),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        #expect(response.result?.string("status") == "accepted")
        let ownerRecordAfter = await terminalPanelResumeRecord(in: server.store, panelID: server.panelID)
        let claimantRecordAfter = await terminalPanelResumeRecord(in: server.store, panelID: claimantPanelID)
        #expect(ownerRecordAfter == ownerRecord)
        #expect(claimantRecordAfter == claimantRecord)
    }

    @Test
    func sessionUpdateResumeRecordCanReclaimStoppedOwnerRecord() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let ownerSessionID = "sess-claude-stopped-owner"
        let claimantSessionID = "sess-claude-stale-reclaim"
        let nativeSessionID = "db4f311b-12d0-4f61-ba81-0ae44ed10492"
        let ownerRecord = ManagedAgentResumeRecord(
            agent: .claude,
            nativeSessionID: nativeSessionID,
            sessionFilePath: "/tmp/claude/owner.jsonl",
            cwd: "/tmp/repo",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let ownerStart = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: ownerSessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.claude.rawValue),
                    "cwd": .string("/tmp/repo"),
                ]
            ),
            socketPath: socketPath
        )
        #expect(ownerStart.ok)

        let claimantPanelID = try await MainActor.run {
            #expect(server.store.send(.updateTerminalPanelResumeRecord(
                panelID: server.panelID,
                resumeRecord: ownerRecord
            )))
            server.sessionRuntimeStore.stopSession(
                sessionID: ownerSessionID,
                at: Date(timeIntervalSince1970: 1_700_000_005)
            )
            #expect(server.store.send(.splitFocusedSlotInDirection(
                workspaceID: server.workspaceID,
                direction: .right
            )))
            let workspace = try #require(server.store.state.workspacesByID[server.workspaceID])
            return try #require(workspace.focusedPanelID)
        }

        let claimantStart = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: claimantSessionID,
                panelID: claimantPanelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.claude.rawValue),
                    "cwd": .string("/tmp/repo"),
                ]
            ),
            socketPath: socketPath
        )
        #expect(claimantStart.ok)

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.update_resume_record",
                sessionID: claimantSessionID,
                panelID: claimantPanelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.claude.rawValue),
                    "nativeSessionID": .string(nativeSessionID),
                    "sessionFilePath": .string("/tmp/claude/reclaimed.jsonl"),
                    "cwd": .string("/tmp/repo"),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        let ownerRecordAfter = await terminalPanelResumeRecord(in: server.store, panelID: server.panelID)
        let claimantRecordAfter = await terminalPanelResumeRecord(in: server.store, panelID: claimantPanelID)
        #expect(ownerRecordAfter == nil)
        #expect(claimantRecordAfter?.nativeSessionID == nativeSessionID)
        #expect(claimantRecordAfter?.sessionFilePath == "/tmp/claude/reclaimed.jsonl")
    }

    @Test
    func sessionStatusCanResolveActiveSessionForBackgroundTabPanel() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let initialContext = try await MainActor.run {
            let selection = try #require(server.store.state.selectedWorkspaceSelection())
            return (
                workspaceID: selection.workspaceID,
                originalTabID: try #require(selection.workspace.resolvedSelectedTabID),
                panelID: try #require(selection.workspace.focusedPanelID)
            )
        }

        let sessionID = "sess-background-tab"
        let startResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: initialContext.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startResponse.ok)

        _ = try await MainActor.run {
            #expect(server.store.send(.createWorkspaceTab(workspaceID: initialContext.workspaceID, seed: nil)))
            let workspace = try #require(server.store.state.workspacesByID[initialContext.workspaceID])
            let backgroundTabID = try #require(workspace.resolvedSelectedTabID)
            #expect(backgroundTabID != initialContext.originalTabID)
            return backgroundTabID
        }

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.status",
                sessionID: sessionID,
                requestID: UUID().uuidString,
                payload: [
                    "kind": .string(SessionStatusKind.working.rawValue),
                    "summary": .string("editing in background tab"),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        let activeSession = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID)
        }
        #expect(activeSession?.status?.kind == .working)
    }

    @Test
    func sessionStatusRejectsMismatchedPanelIDForActiveSession() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-mismatch"
        let startResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startResponse.ok)

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.status",
                sessionID: sessionID,
                panelID: UUID().uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "kind": .string(SessionStatusKind.working.rawValue),
                    "summary": .string("editing 3 files"),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok == false)
        #expect(response.error?.code == "INVALID_PAYLOAD")
        #expect(response.error?.message == "panelID does not match active session")
    }

    @Test
    func sessionBackgroundActivityProjectsWorkingAndFinishesIdempotently() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-background-activity"
        let startSessionResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.claude.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startSessionResponse.ok)

        let readyResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.status",
                sessionID: sessionID,
                requestID: UUID().uuidString,
                payload: [
                    "kind": .string(SessionStatusKind.ready.rawValue),
                    "summary": .string("Ready"),
                    "detail": .string("Root turn completed"),
                ]
            ),
            socketPath: socketPath
        )
        #expect(readyResponse.ok)

        let activityPayload: [String: AutomationJSONValue] = [
            "phase": .string(SessionBackgroundActivityPhase.start.rawValue),
            "activityID": .string("child-activity"),
            "kind": .string(SessionBackgroundActivityKind.childAgent.rawValue),
            "displayName": .string("Codex"),
            "command": .string("codex review"),
        ]
        let activityResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.background_activity",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                timestamp: "2026-01-01T00:00:00Z",
                requestID: UUID().uuidString,
                payload: activityPayload
            ),
            socketPath: socketPath
        )
        #expect(activityResponse.ok)
        #expect(activityResponse.result?.string("status") == "accepted")

        let projectedStatus = await MainActor.run {
            server.sessionRuntimeStore.workspaceStatuses(for: server.workspaceID).first
        }
        #expect(projectedStatus?.status.kind == .working)
        #expect(projectedStatus?.status.detail == "Root turn completed")
        #expect(projectedStatus?.projection == .waitingOnChildren(
            childCount: 1,
            pendingBackgroundTaskCount: 0
        ))

        let duplicateStartResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.background_activity",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: activityPayload
            ),
            socketPath: socketPath
        )
        #expect(duplicateStartResponse.ok)
        #expect(duplicateStartResponse.result?.string("status") == "noop")
        #expect(duplicateStartResponse.result?.int("stateVersion") == activityResponse.result?.int("stateVersion"))

        let unknownFinishResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.background_activity",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "phase": .string(SessionBackgroundActivityPhase.finish.rawValue),
                    "activityID": .string("missing-child"),
                    "kind": .string(SessionBackgroundActivityKind.childAgent.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(unknownFinishResponse.ok)
        #expect(unknownFinishResponse.result?.string("status") == "noop")
        #expect(unknownFinishResponse.result?.int("stateVersion") == activityResponse.result?.int("stateVersion"))

        let finishResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.background_activity",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "phase": .string(SessionBackgroundActivityPhase.finish.rawValue),
                    "activityID": .string("child-activity"),
                    "kind": .string(SessionBackgroundActivityKind.childAgent.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(finishResponse.ok)
        #expect(finishResponse.result?.string("status") == "accepted")

        let finalStatus = await MainActor.run {
            server.sessionRuntimeStore.workspaceStatuses(for: server.workspaceID).first?.status
        }
        #expect(finalStatus?.kind == .working)
        #expect(finalStatus?.detail == "Resuming…")
        let finalProjection = await MainActor.run {
            server.sessionRuntimeStore.workspaceStatuses(for: server.workspaceID).first?.projection
        }
        #expect(finalProjection == .resuming)
    }

    @Test
    func sessionBackgroundActivitySyncAcceptedAndClearsSubagents() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-background-sync"
        let startSessionResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.claude.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startSessionResponse.ok)

        let readyResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.status",
                sessionID: sessionID,
                requestID: UUID().uuidString,
                payload: [
                    "kind": .string(SessionStatusKind.ready.rawValue),
                    "summary": .string("Ready"),
                    "detail": .string("Root turn completed"),
                ]
            ),
            socketPath: socketPath
        )
        #expect(readyResponse.ok)

        let syncResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.background_activity",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                timestamp: "2026-01-01T00:00:00Z",
                requestID: UUID().uuidString,
                payload: [
                    "phase": .string(SessionBackgroundActivityPhase.sync.rawValue),
                    "kind": .string(SessionBackgroundActivityKind.subagent.rawValue),
                    "entries": .array([
                        .object([
                            "id": .string("agent-1"),
                            "displayName": .string("general-purpose"),
                            "command": .string("Review the diff"),
                        ]),
                    ]),
                    "pendingCount": .int(1),
                ]
            ),
            socketPath: socketPath
        )
        #expect(syncResponse.ok)
        #expect(syncResponse.result?.string("status") == "accepted")

        let syncedRecord = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.sessionsByID[sessionID]
        }
        #expect(syncedRecord?.backgroundActivitiesByID["agent-1"]?.kind == .subagent)
        #expect(syncedRecord?.backgroundActivitiesByID["agent-1"]?.displayName == "general-purpose")
        #expect(syncedRecord?.pendingBackgroundTaskCount == 1)
        let waitingStatus = await MainActor.run {
            server.sessionRuntimeStore.workspaceStatuses(for: server.workspaceID).first?.status
        }
        #expect(waitingStatus?.kind == .working)

        let clearResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.background_activity",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "phase": .string(SessionBackgroundActivityPhase.sync.rawValue),
                    "kind": .string(SessionBackgroundActivityKind.subagent.rawValue),
                    "entries": .array([]),
                    "pendingCount": .int(0),
                ]
            ),
            socketPath: socketPath
        )
        #expect(clearResponse.ok)
        #expect(clearResponse.result?.string("status") == "accepted")

        let clearedRecord = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.sessionsByID[sessionID]
        }
        #expect(clearedRecord?.backgroundActivitiesByID.isEmpty == true)
        #expect(clearedRecord?.pendingBackgroundTaskCount == 0)
        let finalStatus = await MainActor.run {
            server.sessionRuntimeStore.workspaceStatuses(for: server.workspaceID).first?.status
        }
        #expect(finalStatus?.kind == .working)
        #expect(finalStatus?.detail == "Resuming…")
        let finalProjection = await MainActor.run {
            server.sessionRuntimeStore.workspaceStatuses(for: server.workspaceID).first?.projection
        }
        #expect(finalProjection == .resuming)
    }

    @Test
    func sessionBackgroundActivitySyncValidatesPayload() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-background-sync-invalid"
        let startSessionResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.claude.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startSessionResponse.ok)

        let missingEntriesResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.background_activity",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "phase": .string(SessionBackgroundActivityPhase.sync.rawValue),
                    "kind": .string(SessionBackgroundActivityKind.subagent.rawValue),
                    "pendingCount": .int(0),
                ]
            ),
            socketPath: socketPath
        )
        #expect(missingEntriesResponse.ok == false)
        #expect(missingEntriesResponse.error?.code == "INVALID_PAYLOAD")
        #expect(missingEntriesResponse.error?.message == "entries must be an array")

        let negativePendingResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.background_activity",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "phase": .string(SessionBackgroundActivityPhase.sync.rawValue),
                    "kind": .string(SessionBackgroundActivityKind.subagent.rawValue),
                    "entries": .array([]),
                    "pendingCount": .int(-1),
                ]
            ),
            socketPath: socketPath
        )
        #expect(negativePendingResponse.ok == false)
        #expect(negativePendingResponse.error?.code == "INVALID_PAYLOAD")
        #expect(negativePendingResponse.error?.message == "pendingCount must be a non-negative integer")

        let invalidEntryResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.background_activity",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "phase": .string(SessionBackgroundActivityPhase.sync.rawValue),
                    "kind": .string(SessionBackgroundActivityKind.subagent.rawValue),
                    "entries": .array([.object(["id": .string("   "), "displayName": .int(1)])]),
                    "pendingCount": .int(0),
                ]
            ),
            socketPath: socketPath
        )
        #expect(invalidEntryResponse.ok == false)
        #expect(invalidEntryResponse.error?.code == "INVALID_PAYLOAD")
        #expect(invalidEntryResponse.error?.message == "entry id is required")
    }

    @Test
    func sessionUpdateFilesCanResolveActiveSessionWithoutPanelID() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-files-only"
        let startResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startResponse.ok)

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.update_files",
                sessionID: sessionID,
                requestID: UUID().uuidString,
                payload: [
                    "files": .array([.string("/tmp/a.swift")]),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        #expect(response.result?.string("eventType") == "session.update_files")
        #expect(response.result?.int("queuedFiles") == 1)
    }

    @Test
    func sessionUpdateResumeRecordUpdatesTerminalPanelState() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-resume-record"
        let startResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.pi.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startResponse.ok)

        let capturedAt = "2026-05-16T12:34:56Z"
        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.update_resume_record",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                timestamp: capturedAt,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.pi.rawValue),
                    "nativeSessionID": .string("019e31af-e0ed-718b-a695-37afddc7e494"),
                    "sessionFilePath": .string("/tmp/pi sessions/session.jsonl"),
                    "cwd": .string("/tmp/repo with spaces"),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        #expect(response.result?.string("eventType") == "session.update_resume_record")

        let resumeRecord = await terminalPanelResumeRecord(in: server.store, panelID: server.panelID)
        #expect(resumeRecord?.agent == .pi)
        #expect(resumeRecord?.nativeSessionID == "019e31af-e0ed-718b-a695-37afddc7e494")
        #expect(resumeRecord?.sessionFilePath == "/tmp/pi sessions/session.jsonl")
        #expect(resumeRecord?.cwd == "/tmp/repo with spaces")
        #expect(resumeRecord?.capturedAt == ISO8601DateFormatter().date(from: capturedAt))
    }

    @Test
    func sessionUpdateResumeRecordFallsBackToActiveSessionCwd() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-resume-record-cwd-fallback"
        let startResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.claude.rawValue),
                    "cwd": .string("/tmp/active-session-repo"),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startResponse.ok)

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.update_resume_record",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.claude.rawValue),
                    "nativeSessionID": .string("db4f311b-12d0-4f61-ba81-0ae44ed10492"),
                    "sessionFilePath": .string("/tmp/claude/session.jsonl"),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        let resumeRecord = await terminalPanelResumeRecord(in: server.store, panelID: server.panelID)
        #expect(resumeRecord?.agent == .claude)
        #expect(resumeRecord?.nativeSessionID == "db4f311b-12d0-4f61-ba81-0ae44ed10492")
        #expect(resumeRecord?.sessionFilePath == "/tmp/claude/session.jsonl")
        #expect(resumeRecord?.cwd == "/tmp/active-session-repo")
    }

    @Test
    func sessionUpdateResumeRecordRejectsMismatchedAgent() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-resume-record-mismatch"
        let startResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startResponse.ok)

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.update_resume_record",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.pi.rawValue),
                    "nativeSessionID": .string("019e31af-e0ed-718b-a695-37afddc7e494"),
                    "sessionFilePath": .string("/tmp/session.jsonl"),
                    "cwd": .string("/tmp/repo"),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok == false)
        #expect(response.error?.code == "INVALID_PAYLOAD")
        #expect(response.error?.message == "agent does not match active session")
    }

    @Test
    func sessionUpdateResumeRecordRequiresPanelID() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-resume-record-requires-panel"
        let startResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.pi.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startResponse.ok)

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.update_resume_record",
                sessionID: sessionID,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.pi.rawValue),
                    "nativeSessionID": .string("019e31af-e0ed-718b-a695-37afddc7e494"),
                    "sessionFilePath": .string("/tmp/session.jsonl"),
                    "cwd": .string("/tmp/repo"),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok == false)
        #expect(response.error?.code == "INVALID_PAYLOAD")
        #expect(response.error?.message == "panelID must be a UUID")
    }

    @Test
    func sessionStopCanResolveActiveSessionWithoutPanelID() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-stop-only"
        let startResponse = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(startResponse.ok)

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.stop",
                sessionID: sessionID,
                requestID: UUID().uuidString,
                payload: [:]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        #expect(response.result?.string("eventType") == "session.stop")
    }

    @Test
    func automationLaunchAgentUsesSharedLaunchService() async throws {
        let socketPath = temporarySocketPath()
        let terminalRouter = TestTerminalCommandRouter()
        await MainActor.run {
            terminalRouter.defaultPromptState = .idleAtPrompt
        }
        let server = try await MainActor.run {
            try makeServer(
                socketPath: socketPath,
                automationConfig: AutomationConfig(
                    runID: "launch-agent",
                    fixtureName: nil,
                    artifactsDirectory: nil,
                    socketPath: socketPath,
                    disableAnimations: true,
                    fixedLocaleIdentifier: nil,
                    fixedTimeZoneIdentifier: nil
                ),
                terminalCommandRouter: terminalRouter
            )
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let response = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "automation.launch_agent",
                payload: [
                    "profileID": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        let sessionID = try #require(response.result?.string("sessionID"))
        let command = try #require(response.result?.string("command"))
        #expect(response.result?.string("profileID") == AgentKind.codex.rawValue)
        #expect(response.result?.string("agent") == AgentKind.codex.rawValue)
        #expect(response.result?.string("panelID") == server.panelID.uuidString)
        #expect(response.result?.string("workspaceID") == server.workspaceID.uuidString)
        #expect(command.contains("TOASTTY_SESSION_ID=\(sessionID)"))
        #expect(command.contains("TOASTTY_PANEL_ID=\(server.panelID.uuidString)"))
        #expect(command.contains("codex -c "))
        #expect(command.contains("notify=["))
        #expect(command.contains("codex-notify.sh"))
        let activeAgent = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID)?.agent
        }
        #expect(activeAgent == .codex)
    }

    @Test
    func appControlListsActionsWithoutAutomationMode() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let response = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "app_control.list_actions"
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        let commands: [AutomationJSONValue]
        switch response.result?["commands"] {
        case .array(let values):
            commands = values
        default:
            Issue.record("expected commands array")
            return
        }
        let ids = commands.compactMap { entry -> String? in
            guard case .object(let object) = entry else {
                return nil
            }
            return object.string("id")
        }
        #expect(ids.contains("window.create"))
        #expect(ids.contains("window.sidebar.toggle"))
        #expect(ids.contains("workspace.move"))
        #expect(ids.contains("workspace.tab.move"))
        #expect(ids.contains("panel.close"))
        #expect(ids.contains("agent.launch"))
        #expect(ids.contains("config.reload") == false)
    }

    @Test
    func appControlRunActionCanToggleSidebarWithoutAutomationMode() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let initialSidebarVisible = await MainActor.run {
            server.store.state.windows.first?.sidebarVisible
        }
        #expect(initialSidebarVisible == true)

        let response = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "app_control.run_action",
                payload: [
                    "id": .string("window.sidebar.toggle"),
                    "args": .object([:]),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        #expect(response.result?.int("stateVersion") == 1)
        let toggledSidebarVisible = await MainActor.run {
            server.store.state.windows.first?.sidebarVisible
        }
        #expect(toggledSidebarVisible == false)
    }

    @Test
    func appControlRunActionRejectsNonObjectArgs() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let response = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "app_control.run_action",
                payload: [
                    "id": .string("window.sidebar.toggle"),
                    "args": .string("not-an-object"),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok == false)
        #expect(response.error?.code == "INVALID_PAYLOAD")
        #expect(response.error?.message == "args must be an object")
    }

    @Test
    func appControlRunQueryReturnsWorkspaceSnapshotWithoutAutomationMode() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let response = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "app_control.run_query",
                payload: [
                    "id": .string("workspace.snapshot"),
                    "args": .object([:]),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        #expect(response.result?.string("workspaceID") == server.workspaceID.uuidString)
        #expect(response.result?.int("panelCount") == 1)
    }

    @Test
    func automationDiagnosticsRecentRequestsCapturesSanitizedAppControlAction() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-audit-caller"
        let (windowID, targetWorkspaceID) = try await MainActor.run {
            let windowID = try #require(server.store.state.windows.first?.id)
            server.sessionRuntimeStore.startSession(
                sessionID: sessionID,
                agent: .codex,
                panelID: server.panelID,
                windowID: windowID,
                workspaceID: server.workspaceID,
                cwd: "/tmp/repo",
                repoRoot: "/tmp/repo",
                at: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let existingWorkspaceIDs = Set(server.store.state.window(id: windowID)?.workspaceIDs ?? [])
            #expect(
                server.store.send(
                    .createWorkspace(
                        windowID: windowID,
                        title: "Audit Target",
                        activate: false
                    )
                )
            )
            let targetWorkspaceID = try #require(
                server.store.state.window(id: windowID)?.workspaceIDs.first {
                    existingWorkspaceIDs.contains($0) == false
                }
            )
            return (windowID, targetWorkspaceID)
        }

        let pingResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: "audit-ping",
                command: "automation.ping"
            ),
            socketPath: socketPath
        )
        #expect(pingResponse.ok)

        let response = try sendRequest(
            AutomationRequestEnvelope(
                requestID: "audit-workspace-select",
                command: "app_control.run_action",
                callerSessionID: sessionID,
                payload: [
                    "id": .string("workspace.select"),
                    "args": .object([
                        "workspaceID": .string(targetWorkspaceID.uuidString),
                        "windowID": .string(windowID.uuidString),
                        "focusUnreadSessionPanel": .bool(false),
                        "title": .string("do not store this value"),
                    ]),
                ]
            ),
            socketPath: socketPath
        )
        #expect(response.ok)

        let diagnosticsResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: "audit-query",
                command: AutomationSocketProtocol.diagnosticsRecentRequestsCommand
            ),
            socketPath: socketPath
        )

        #expect(diagnosticsResponse.ok)
        let automation = try automationSection(from: diagnosticsResponse)
        #expect(automation.status == .available)
        #expect(automation.recentRequests.count == 1)
        let entry = try #require(automation.recentRequests.first)
        #expect(entry.kind == "request")
        #expect(entry.requestID == "audit-workspace-select")
        #expect(entry.command == "app_control.run_action")
        #expect(entry.callerSessionID == sessionID)
        #expect(entry.callerAgent == AgentKind.codex.rawValue)
        #expect(entry.actionID == "workspace.select")
        #expect(entry.queryID == nil)
        #expect(entry.argumentKeys == ["focusUnreadSessionPanel", "title", "windowID", "workspaceID"])
        #expect(entry.selectors["workspaceID"] == .string(targetWorkspaceID.uuidString))
        #expect(entry.selectors["windowID"] == .string(windowID.uuidString))
        #expect(entry.selectors["title"] == nil)
        #expect(entry.flags["focusUnreadSessionPanel"] == .bool(false))
        #expect(entry.ok)
        #expect(entry.errorCode == nil)
        #expect(entry.durationMs >= 0)
    }

    @Test
    func automationDiagnosticsRecentRequestsPreservesNumericSelectors() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let response = try sendRequest(
            AutomationRequestEnvelope(
                requestID: "audit-numeric-selector",
                command: "app_control.run_action",
                payload: [
                    "id": .string("unsupported.action"),
                    "args": .object([
                        "index": .double(2.0),
                        "toIndex": .int(3),
                        "secret-key-value": .string("do not retain this key name"),
                    ]),
                ]
            ),
            socketPath: socketPath
        )
        #expect(response.ok == false)

        let diagnosticsResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: "audit-query",
                command: AutomationSocketProtocol.diagnosticsRecentRequestsCommand
            ),
            socketPath: socketPath
        )

        #expect(diagnosticsResponse.ok)
        let automation = try automationSection(from: diagnosticsResponse)
        let entry = try #require(automation.recentRequests.first)
        #expect(entry.requestID == "audit-numeric-selector")
        #expect(entry.selectors["index"] == .int(2))
        #expect(entry.selectors["toIndex"] == .int(3))
        #expect(entry.argumentKeys == ["index", "other", "toIndex"])
        #expect(entry.errorCode == "INVALID_PAYLOAD")
    }

    @Test
    func automationDiagnosticsRecentRequestsCapturesSessionEvents() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let sessionID = "sess-audit-event"
        try await MainActor.run {
            let windowID = try #require(server.store.state.windows.first?.id)
            server.sessionRuntimeStore.startSession(
                sessionID: sessionID,
                agent: .claude,
                panelID: server.panelID,
                windowID: windowID,
                workspaceID: server.workspaceID,
                cwd: "/tmp/repo",
                repoRoot: "/tmp/repo",
                at: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.status",
                sessionID: sessionID,
                panelID: server.panelID.uuidString,
                requestID: "audit-session-event",
                payload: [
                    "kind": .string(SessionStatusKind.working.rawValue),
                    "summary": .string("do not retain this summary"),
                ]
            ),
            socketPath: socketPath
        )
        #expect(response.ok)

        let diagnosticsResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: "audit-query",
                command: AutomationSocketProtocol.diagnosticsRecentRequestsCommand
            ),
            socketPath: socketPath
        )

        #expect(diagnosticsResponse.ok)
        let automation = try automationSection(from: diagnosticsResponse)
        let entry = try #require(automation.recentRequests.first)
        #expect(entry.kind == "event")
        #expect(entry.requestID == "audit-session-event")
        #expect(entry.eventType == "session.status")
        #expect(entry.callerAgent == AgentKind.claude.rawValue)
        #expect(entry.sessionID == sessionID)
        #expect(entry.panelID == server.panelID.uuidString)
        #expect(entry.argumentKeys == ["kind", "summary"])
        #expect(entry.ok)
    }

    @Test
    func automationDiagnosticsRecentRequestsRetainsLast250Calls() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        for index in 0..<252 {
            let response = try sendRequest(
                AutomationRequestEnvelope(
                    requestID: "unknown-\(index)",
                    command: "unknown.command.\(index)"
                ),
                socketPath: socketPath
            )
            #expect(response.ok == false)
        }

        let diagnosticsResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: "audit-query",
                command: AutomationSocketProtocol.diagnosticsRecentRequestsCommand
            ),
            socketPath: socketPath
        )

        #expect(diagnosticsResponse.ok)
        let automation = try automationSection(from: diagnosticsResponse)
        #expect(automation.recentRequests.count == 250)
        #expect(automation.recentRequests.first?.requestID == "unknown-2")
        #expect(automation.recentRequests.last?.requestID == "unknown-251")
        #expect(automation.recentRequests.last?.errorCode == "UNKNOWN_COMMAND")
    }

    @Test
    func appControlRunActionCanLaunchAgentWithoutAutomationMode() async throws {
        let socketPath = temporarySocketPath()
        let terminalRouter = TestTerminalCommandRouter()
        await MainActor.run {
            terminalRouter.defaultPromptState = .idleAtPrompt
        }
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath, terminalCommandRouter: terminalRouter)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let response = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "app_control.run_action",
                payload: [
                    "id": .string("agent.launch"),
                    "args": .object([
                        "profileID": .string(AgentKind.codex.rawValue),
                    ]),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        let sessionID = try #require(response.result?.string("sessionID"))
        #expect(response.result?.string("panelID") == server.panelID.uuidString)
        #expect(response.result?.int("stateVersion") == 1)
        let activeAgent = await MainActor.run {
            server.sessionRuntimeStore.sessionRegistry.activeSession(sessionID: sessionID)?.agent
        }
        #expect(activeAgent == .codex)
    }

    @Test
    func automationPerformActionRemainsGatedWithoutAutomationMode() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let response = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "automation.perform_action",
                payload: [
                    "action": .string("window.sidebar.toggle"),
                    "args": .object([:]),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok == false)
        #expect(response.error?.message == "automation.perform_action requires automation mode")
    }

    @Test
    func automationPerformActionCanToggleSidebar() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(
                socketPath: socketPath,
                automationConfig: AutomationConfig(
                    runID: "toggle-sidebar",
                    fixtureName: nil,
                    artifactsDirectory: nil,
                    socketPath: socketPath,
                    disableAnimations: true,
                    fixedLocaleIdentifier: nil,
                    fixedTimeZoneIdentifier: nil
                )
            )
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let initialSidebarVisible = await MainActor.run {
            server.store.state.windows.first?.sidebarVisible
        }
        #expect(initialSidebarVisible == true)

        let response = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "automation.perform_action",
                payload: [
                    "action": .string("window.sidebar.toggle"),
                    "args": .object([:]),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        let toggledSidebarVisible = await MainActor.run {
            server.store.state.windows.first?.sidebarVisible
        }
        #expect(toggledSidebarVisible == false)
    }

    @Test
    func prepareManagedLaunchReturnsStructuredPlan() async throws {
        let socketPath = temporarySocketPath()
        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let initialHasEverLaunchedAgent = await MainActor.run {
            server.store.hasEverLaunchedAgent
        }
        #expect(initialHasEverLaunchedAgent == false)

        let response = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "agent.prepare_managed_launch",
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                    "panelID": .string(server.panelID.uuidString),
                    "cwd": .string("/tmp/repo"),
                    "argv": .array([.string("codex"), .string("--model"), .string("gpt-5.4")]),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        let sessionID = try #require(response.result?.string("sessionID"))
        #expect(response.result?.string("agent") == AgentKind.codex.rawValue)
        #expect(response.result?.string("panelID") == server.panelID.uuidString)
        #expect(response.result?.string("workspaceID") == server.workspaceID.uuidString)
        #expect(response.result?.string("cwd") == "/tmp/repo")
        guard case .array(let argv)? = response.result?["argv"] else {
            Issue.record("expected argv array in response")
            return
        }
        let argvStrings = argv.compactMap { value -> String? in
            guard case .string(let stringValue) = value else { return nil }
            return stringValue
        }
        #expect(argvStrings.count == 5)
        #expect(argvStrings[0] == "codex")
        #expect(argvStrings[1] == "-c")
        #expect(argvStrings[2].contains("notify=[\"/bin/sh\",\""))
        #expect(argvStrings[2].contains("codex-notify.sh"))
        #expect(argvStrings[3] == "--model")
        #expect(argvStrings[4] == "gpt-5.4")
        guard case .object(let environment)? = response.result?["environment"] else {
            Issue.record("expected environment object in response")
            return
        }
        #expect(environment["TOASTTY_SESSION_ID"] == .string(sessionID))
        #expect(environment["TOASTTY_PANEL_ID"] == .string(server.panelID.uuidString))
        #expect(environment["TOASTTY_SOCKET_PATH"] == .string(socketPath))
        #expect(environment["TOASTTY_CWD"] == .string("/tmp/repo"))
        let hasEverLaunchedAgent = await MainActor.run {
            server.store.hasEverLaunchedAgent
        }
        #expect(hasEverLaunchedAgent)
    }

    @Test
    func prepareManagedLaunchInteractivePreflightReturnsPendingWithoutStartingSession() async throws {
        let socketPath = temporarySocketPath()
        let missingStatus = codexHookInstallStatus(state: .notInstalled)
        let presentedWindowID = CapturedWindowID()
        let server = try await MainActor.run {
            try makeServer(
                socketPath: socketPath,
                codexStatusHooksPreflightProvider: { _ in .needsSetup(missingStatus) },
                codexStatusHooksWarningPresenter: { _, windowID, _ in
                    presentedWindowID.set(windowID)
                }
            )
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let response = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "agent.prepare_managed_launch",
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                    "panelID": .string(server.panelID.uuidString),
                    "cwd": .string("/tmp/repo"),
                    "preflightPolicy": .string(ManagedAgentLaunchPreflightPolicy.interactive.rawValue),
                    "argv": .array([.string("codex")]),
                ]
            ),
            socketPath: socketPath
        )

        #expect(response.ok)
        #expect(response.result?.string("kind") == ManagedAgentLaunchPreparationKind.preflightRequired.rawValue)
        let preflight = try #require(response.result?.object("preflight"))
        let token = try #require(preflight.string("token"))
        #expect(preflight.string("agent") == AgentKind.codex.rawValue)
        #expect(preflight.string("panelID") == server.panelID.uuidString)
        let preflightState = await MainActor.run {
            (
                presentedWindowID: presentedWindowID.snapshot(),
                firstWindowID: server.store.state.windows.first?.id,
                sessionCount: server.sessionRuntimeStore.sessionRegistry.sessionsByID.count,
                hasEverLaunchedAgent: server.store.hasEverLaunchedAgent
            )
        }
        #expect(preflightState.presentedWindowID == preflightState.firstWindowID)
        #expect(preflightState.sessionCount == 0)
        #expect(preflightState.hasEverLaunchedAgent == false)

        let decisionResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "agent.managed_launch_preflight_decision",
                payload: ["token": .string(token)]
            ),
            socketPath: socketPath
        )

        #expect(decisionResponse.ok)
        #expect(decisionResponse.result?.string("kind") == ManagedAgentLaunchPreflightDecisionKind.pending.rawValue)
    }

    @Test
    func prepareManagedLaunchCanProceedAfterInteractivePreflightRunAnyway() async throws {
        let socketPath = temporarySocketPath()
        let missingStatus = codexHookInstallStatus(state: .notInstalled)
        let server = try await MainActor.run {
            try makeServer(
                socketPath: socketPath,
                codexStatusHooksPreflightProvider: { _ in .needsSetup(missingStatus) },
                codexStatusHooksWarningPresenter: { _, _, completion in
                    completion(.runAnyway)
                }
            )
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)

        let preflightResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "agent.prepare_managed_launch",
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                    "panelID": .string(server.panelID.uuidString),
                    "cwd": .string("/tmp/repo"),
                    "preflightPolicy": .string(ManagedAgentLaunchPreflightPolicy.interactive.rawValue),
                    "argv": .array([.string("codex")]),
                ]
            ),
            socketPath: socketPath
        )

        let preflight = try #require(preflightResponse.result?.object("preflight"))
        let token = try #require(preflight.string("token"))
        let decisionResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "agent.managed_launch_preflight_decision",
                payload: ["token": .string(token)]
            ),
            socketPath: socketPath
        )
        #expect(decisionResponse.result?.string("kind") == ManagedAgentLaunchPreflightDecisionKind.runAnyway.rawValue)

        let launchResponse = try sendRequest(
            AutomationRequestEnvelope(
                requestID: UUID().uuidString,
                command: "agent.prepare_managed_launch",
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                    "panelID": .string(server.panelID.uuidString),
                    "cwd": .string("/tmp/repo"),
                    "preflightPolicy": .string(ManagedAgentLaunchPreflightPolicy.skip.rawValue),
                    "argv": .array([.string("codex")]),
                ]
            ),
            socketPath: socketPath
        )

        #expect(launchResponse.ok)
        #expect(launchResponse.result?.string("sessionID") != nil)
        let launchState = await MainActor.run {
            (
                sessionCount: server.sessionRuntimeStore.sessionRegistry.sessionsByID.count,
                hasEverLaunchedAgent: server.store.hasEverLaunchedAgent
            )
        }
        #expect(launchState.sessionCount == 1)
        #expect(launchState.hasEverLaunchedAgent)
    }

    @Test
    func secondServerCannotStealALiveSocketPath() async {
        let socketPath = temporarySocketPath()
        let firstServer: (
            server: AutomationSocketServer,
            store: AppStore,
            panelID: UUID,
            workspaceID: UUID,
            sessionRuntimeStore: SessionRuntimeStore
        )
        do {
            firstServer = try await MainActor.run {
                try makeServer(socketPath: socketPath)
            }
        } catch {
            Issue.record("failed to start first server: \(error)")
            return
        }
        defer {
            withExtendedLifetime(firstServer.server) {}
        }

        do {
            try waitForSocket(at: socketPath)
        } catch {
            Issue.record("first server never became reachable: \(error)")
            return
        }

        do {
            _ = try await MainActor.run {
                _ = try makeServer(socketPath: socketPath)
            }
            Issue.record("second server unexpectedly started on an occupied socket path")
        } catch let startupError as AutomationSocketStartupError {
            #expect(startupError == .liveSocketPathInUse(socketPath))
        } catch {
            Issue.record("second server failed with unexpected error: \(error)")
        }

        do {
            let response = try sendEvent(
                AutomationEventEnvelope(
                    eventType: "session.start",
                    sessionID: "sess-still-live",
                    panelID: firstServer.panelID.uuidString,
                    requestID: UUID().uuidString,
                    payload: [
                        "agent": .string(AgentKind.codex.rawValue),
                    ]
                ),
                socketPath: socketPath
            )
            #expect(response.ok)
        } catch {
            Issue.record("first server stopped responding after second startup attempt: \(error)")
        }
    }

    @Test
    func recommendedSocketPathFallsBackWhenRuntimePreferredPathIsLive() throws {
        let runtimeSocketEnvironment = try makeRuntimeSocketEnvironment()
        defer {
            try? FileManager.default.removeItem(at: runtimeSocketEnvironment.rootURL)
        }
        let environment = runtimeSocketEnvironment.environment
        let runtimePaths = ToasttyRuntimePaths.resolve(environment: environment)
        let preferredSocketPath = try #require(runtimePaths.automationSocketFileURL?.path)
        let liveSocketFD = try bindAndListenRawSocket(socketPath: preferredSocketPath)
        defer {
            close(liveSocketFD)
            try? FileManager.default.removeItem(atPath: preferredSocketPath)
        }

        let resolvedSocketPath = AutomationSocketServer.recommendedSocketPath(
            preferredSocketPath: preferredSocketPath,
            environment: environment,
            processID: 4242
        )

        #expect(resolvedSocketPath != preferredSocketPath)
        #expect(resolvedSocketPath.hasSuffix("/events-v1-4242.sock"))
    }

    @Test
    func staleSocketFileCanBeReplacedDuringStartup() async throws {
        let socketPath = temporarySocketPath()
        let staleSocketFD = try bindAndListenRawSocket(socketPath: socketPath)
        close(staleSocketFD)

        let server = try await MainActor.run {
            try makeServer(socketPath: socketPath)
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: "sess-stale-replaced",
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(response.ok)
    }

    @Test
    func fatalAcceptErrorsRestartTheListenerOnTheSameSocketPath() async throws {
        let socketPath = temporarySocketPath()
        let probe = ListenerRecoveryProbe()
        let acceptOverride = OneShotAcceptOverride(errorNumber: EBADF)
        let server = try await MainActor.run {
            try makeServer(
                socketPath: socketPath,
                recoveryPolicy: AutomationSocketServerRecoveryPolicy(retryDelays: [0]),
                testHooks: AutomationSocketServerTestHooks(
                    acceptOverride: { _ in acceptOverride.nextResult() },
                    listenerDidStart: { _, recoveryAttempt in
                        probe.recordListenerStart(recoveryAttempt: recoveryAttempt)
                    },
                    recoveryDidSchedule: { attempt, errorNumber, delay in
                        probe.recordRecoverySchedule(attempt: attempt, errorNumber: errorNumber, delay: delay)
                    }
                )
            )
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)
        try connectAndClose(socketPath: socketPath)
        try waitUntil("listener recovery was scheduled") {
            probe.recoverySchedulesSnapshot().count == 1
        }
        try waitUntil("listener restarted after fatal accept error") {
            probe.listenerStartsSnapshot().count >= 2
        }

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: "sess-recovery",
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(response.ok)
        let recoverySchedules = probe.recoverySchedulesSnapshot()
        let listenerStarts = probe.listenerStartsSnapshot()
        #expect(recoverySchedules.map { $0.attempt } == [1])
        #expect(recoverySchedules.map { $0.errorNumber } == [EBADF])
        #expect(listenerStarts == [nil, 1])
    }

    @Test
    func transientAcceptErrorsDoNotRestartTheListener() async throws {
        let socketPath = temporarySocketPath()
        let probe = ListenerRecoveryProbe()
        let acceptOverride = OneShotAcceptOverride(errorNumber: EINTR)
        let server = try await MainActor.run {
            try makeServer(
                socketPath: socketPath,
                recoveryPolicy: AutomationSocketServerRecoveryPolicy(retryDelays: [0]),
                testHooks: AutomationSocketServerTestHooks(
                    acceptOverride: { _ in acceptOverride.nextResult() },
                    listenerDidStart: { _, recoveryAttempt in
                        probe.recordListenerStart(recoveryAttempt: recoveryAttempt)
                    },
                    recoveryDidSchedule: { attempt, errorNumber, delay in
                        probe.recordRecoverySchedule(attempt: attempt, errorNumber: errorNumber, delay: delay)
                    }
                )
            )
        }
        defer {
            withExtendedLifetime(server.server) {}
        }

        try waitForSocket(at: socketPath)
        try connectAndClose(socketPath: socketPath)
        try await Task.sleep(for: .milliseconds(100))

        let response = try sendEvent(
            AutomationEventEnvelope(
                eventType: "session.start",
                sessionID: "sess-transient",
                panelID: server.panelID.uuidString,
                requestID: UUID().uuidString,
                payload: [
                    "agent": .string(AgentKind.codex.rawValue),
                ]
            ),
            socketPath: socketPath
        )
        #expect(response.ok)
        #expect(probe.recoverySchedulesSnapshot().isEmpty)
        #expect(probe.listenerStartsSnapshot() == [nil])
    }

    private func temporarySocketPath() -> String {
        "/tmp/toastty-tests-\(UUID().uuidString.prefix(8)).sock"
    }

    private func waitForSocket(at socketPath: String) throws {
        let deadline = Date().addingTimeInterval(1)
        while true {
            guard FileManager.default.fileExists(atPath: socketPath) else {
                guard Date() < deadline else {
                    throw SocketTestError.timeoutWaitingForSocket
                }
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }

            do {
                try connectAndClose(socketPath: socketPath)
                return
            } catch SocketTestError.socket(let errorNumber) where errorNumber == ENOENT || errorNumber == ECONNREFUSED {
                // The path exists but the listener is not yet accepting connections.
            }

            guard Date() < deadline else {
                throw SocketTestError.timeoutWaitingForSocket
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    @MainActor
    private func terminalPanelResumeRecord(in store: AppStore, panelID: UUID) -> ManagedAgentResumeRecord? {
        guard let workspace = store.selectedWorkspace,
              case .terminal(let terminalState) = workspace.panels[panelID] else {
            return nil
        }
        return terminalState.resumeRecord
    }

    @MainActor
    private func makeServer(
        socketPath: String,
        automationConfig: AutomationConfig? = nil,
        terminalCommandRouter: (any TerminalCommandRouting)? = nil,
        recoveryPolicy: AutomationSocketServerRecoveryPolicy = .default,
        testHooks: AutomationSocketServerTestHooks = .disabled,
        codexStatusTrackingSourceProvider: @escaping @MainActor () -> CodexStatusTrackingSource = {
            .sessionLogFallback(reason: "test")
        },
        codexStatusHooksPreflightProvider: @escaping CodexStatusHooksPreflightProvider = { _ in .ready },
        codexStatusHooksWarningPresenter: @escaping CodexStatusHooksAsyncWarningPresenter = { _, _, completion in
            completion(.cancel)
        },
        nativeSessionObserverRegistry: (any ManagedAgentNativeSessionObserving)? = nil
    ) throws -> (
        server: AutomationSocketServer,
        store: AppStore,
        panelID: UUID,
        workspaceID: UUID,
        sessionRuntimeStore: SessionRuntimeStore
    ) {
        let store = AppStore(persistTerminalFontPreference: false)
        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        let webPanelRuntimeRegistry = WebPanelRuntimeRegistry()
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        webPanelRuntimeRegistry.bind(store: store)
        let agentCatalogProvider = TestAgentCatalogProvider()
        let focusedPanelCommandController = FocusedPanelCommandController(
            store: store,
            runtimeRegistry: terminalRuntimeRegistry,
            slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
        )

        let workspace = try #require(store.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelID)
        let workspaceID = workspace.id
        let agentLaunchService = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalCommandRouter ?? terminalRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: agentCatalogProvider,
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { socketPath },
            codexStatusTrackingSourceProvider: codexStatusTrackingSourceProvider,
            nativeSessionObserverRegistry: nativeSessionObserverRegistry
        )
        let server = try AutomationSocketServer(
            socketPath: socketPath,
            automationConfig: automationConfig,
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            webPanelRuntimeRegistry: webPanelRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            focusedPanelCommandController: focusedPanelCommandController,
            agentLaunchService: agentLaunchService,
            codexStatusHooksPreflightProvider: codexStatusHooksPreflightProvider,
            codexStatusHooksWarningPresenter: codexStatusHooksWarningPresenter,
            recoveryPolicy: recoveryPolicy,
            testHooks: testHooks
        )
        return (server, store, panelID, workspaceID, sessionRuntimeStore)
    }

    private func sendEvent(type eventType: String, socketPath: String) throws -> AutomationResponseEnvelope {
        try sendEvent(
            AutomationEventEnvelope(
                eventType: eventType,
                requestID: UUID().uuidString,
                payload: [:]
            ),
            socketPath: socketPath
        )
    }

    private func sendEvent(_ request: AutomationEventEnvelope, socketPath: String) throws -> AutomationResponseEnvelope {
        let payload = try JSONEncoder().encode(request) + Data([0x0A])
        let responseData = try send(payload, to: socketPath)
        return try JSONDecoder().decode(AutomationResponseEnvelope.self, from: responseData)
    }

    private func sendRequest(_ request: AutomationRequestEnvelope, socketPath: String) throws -> AutomationResponseEnvelope {
        let payload = try JSONEncoder().encode(request) + Data([0x0A])
        let responseData = try send(payload, to: socketPath)
        return try JSONDecoder().decode(AutomationResponseEnvelope.self, from: responseData)
    }

    private func automationSection(from response: AutomationResponseEnvelope) throws -> DiagnosticsAutomationSection {
        let result = try #require(response.result)
        let data = try JSONEncoder().encode(result)
        return try JSONDecoder().decode(DiagnosticsAutomationSection.self, from: data)
    }

    private func send(_ payload: Data, to socketPath: String) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketTestError.socket(errno)
        }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maxPathLength else {
            throw SocketTestError.socketPathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { source in
                if let destinationAddress = buffer.baseAddress, let sourceAddress = source.baseAddress {
                    memcpy(destinationAddress, sourceAddress, pathBytes.count)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw SocketTestError.socket(errno)
        }

        let bytesWritten = payload.withUnsafeBytes { buffer in
            write(fd, buffer.baseAddress, payload.count)
        }
        guard bytesWritten == payload.count else {
            throw SocketTestError.shortWrite
        }

        var response = Data()
        var byte: UInt8 = 0
        while true {
            let bytesRead = read(fd, &byte, 1)
            if bytesRead == 0 {
                break
            }
            guard bytesRead > 0 else {
                throw SocketTestError.socket(errno)
            }
            if byte == 0x0A {
                return response
            }
            response.append(byte)
        }

        throw SocketTestError.missingResponseTerminator
    }

    private func connectAndClose(socketPath: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketTestError.socket(errno)
        }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maxPathLength else {
            throw SocketTestError.socketPathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { source in
                if let destinationAddress = buffer.baseAddress, let sourceAddress = source.baseAddress {
                    memcpy(destinationAddress, sourceAddress, pathBytes.count)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw SocketTestError.socket(errno)
        }
    }

    private func bindAndListenRawSocket(socketPath: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketTestError.socket(errno)
        }

        let socketURL = URL(fileURLWithPath: socketPath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = unlink(socketPath)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= maxPathLength else {
            close(fd)
            throw SocketTestError.socketPathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { source in
                if let destinationAddress = buffer.baseAddress, let sourceAddress = source.baseAddress {
                    memcpy(destinationAddress, sourceAddress, pathBytes.count)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let errorNumber = errno
            close(fd)
            throw SocketTestError.socket(errorNumber)
        }

        guard listen(fd, SOMAXCONN) == 0 else {
            let errorNumber = errno
            close(fd)
            throw SocketTestError.socket(errorNumber)
        }

        return fd
    }

    private func makeRuntimeSocketEnvironment() throws -> (rootURL: URL, environment: [String: String]) {
        let rootURL = try makeShortTemporaryDirectory(prefix: "tts")
        let runtimeHomeURL = rootURL.appendingPathComponent("runtime-home", isDirectory: true)
        let temporaryDirectoryURL = rootURL.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        return (
            rootURL,
            [
                "TOASTTY_RUNTIME_HOME": runtimeHomeURL.path,
                "TMPDIR": temporaryDirectoryURL.path + "/",
            ]
        )
    }

    private func makeShortTemporaryDirectory(prefix: String) throws -> URL {
        var template = "/tmp/\(prefix).XXXXXX".utf8CString
        let createdPath = template.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let baseAddress = buffer.baseAddress, mkdtemp(baseAddress) != nil else {
                return nil
            }
            return String(cString: baseAddress)
        }
        guard let createdPath else {
            throw SocketTestError.socket(errno)
        }
        return URL(fileURLWithPath: createdPath, isDirectory: true)
    }

    private func codexHookInstallStatus(
        state: CodexStatusHookInstallState
    ) -> CodexStatusHookInstallStatus {
        let rootURL = URL(fileURLWithPath: "/tmp/toastty-codex-hooks-\(state.rawValue)", isDirectory: true)
        return CodexStatusHookInstallStatus(
            hooksFileURL: rootURL.appendingPathComponent("hooks.json", isDirectory: false),
            forwarderScriptURL: rootURL.appendingPathComponent("forwarder.sh", isDirectory: false),
            state: state
        )
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 1,
        pollInterval: TimeInterval = 0.01,
        condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while condition() == false {
            guard Date() < deadline else {
                throw SocketTestError.timeout(description)
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }
}

private enum SocketTestError: Error {
    case missingResponseTerminator
    case shortWrite
    case socket(Int32)
    case socketPathTooLong
    case timeoutWaitingForSocket
    case timeout(String)
}

private final class ListenerRecoveryProbe: @unchecked Sendable {
    private let lock = NSLock()

    private var listenerStarts: [Int?] = []
    private var recoverySchedules: [(attempt: Int, errorNumber: Int32, delay: TimeInterval)] = []

    func recordListenerStart(recoveryAttempt: Int?) {
        lock.lock()
        listenerStarts.append(recoveryAttempt)
        lock.unlock()
    }

    func recordRecoverySchedule(attempt: Int, errorNumber: Int32, delay: TimeInterval) {
        lock.lock()
        recoverySchedules.append((attempt, errorNumber, delay))
        lock.unlock()
    }

    func listenerStartsSnapshot() -> [Int?] {
        lock.lock()
        defer { lock.unlock() }
        return listenerStarts
    }

    func recoverySchedulesSnapshot() -> [(attempt: Int, errorNumber: Int32, delay: TimeInterval)] {
        lock.lock()
        defer { lock.unlock() }
        return recoverySchedules
    }
}

private final class OneShotAcceptOverride: @unchecked Sendable {
    private let lock = NSLock()
    private let errorNumber: Int32
    private var didFire = false

    init(errorNumber: Int32) {
        self.errorNumber = errorNumber
    }

    func nextResult() -> AutomationSocketServerTestHooks.AcceptResult {
        lock.lock()
        defer { lock.unlock() }

        if didFire {
            return .useSystemAccept
        }
        didFire = true
        return .fail(errorNumber)
    }
}

private final class CapturedWindowID: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UUID?

    func set(_ value: UUID?) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func snapshot() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
private final class SpyNativeSessionObserverRegistry: ManagedAgentNativeSessionObserving {
    private(set) var observations: [ManagedAgentNativeSessionObservationContext] = []
    private(set) var cancelledSessionIDs: [String] = []

    func startObservation(_ observation: ManagedAgentNativeSessionObservationContext) {
        observations.append(observation)
    }

    func cancelObservation(sessionID: String) {
        cancelledSessionIDs.append(sessionID)
    }
}
