import Darwin
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

struct AutomationSocketServerResumeRecordTests: AutomationSocketServerTestSupport {
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

}
