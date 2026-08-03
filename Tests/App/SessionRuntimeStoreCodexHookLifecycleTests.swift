import Combine
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

extension SessionRuntimeStoreTests {
    @Test
    func codexHookEventIgnoresDifferentThreadAfterRootThreadIsLatched() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-hook-latched",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-latched",
            event: CodexHookEvent(
                hookEventName: "SessionStart",
                threadID: "thread-root",
                turnID: nil,
                promptFingerprint: nil,
                status: nil,
                nativeSessionID: "thread-root",
                sessionFilePath: "/tmp/session.jsonl",
                cwd: "/repo"
            ),
            at: startedAt.addingTimeInterval(1)
        )
        store.updateStatus(
            sessionID: "sess-codex-hook-latched",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Root still running"),
            at: startedAt.addingTimeInterval(2)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-latched",
            event: CodexHookEvent(
                hookEventName: "Stop",
                threadID: "thread-child",
                turnID: "turn-child",
                promptFingerprint: nil,
                status: SessionStatus(kind: .ready, summary: "Ready", detail: "Child finished"),
                nativeSessionID: "thread-child",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(3)
        )

        #expect(accepted == false)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-hook-latched")?.status
        #expect(status?.kind == .working)
        #expect(status?.detail == "Root still running")
    }

    @Test
    func codexHookStopDoesNotLatchThreadBeforeRootIdentityIsKnown() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-hook-missing-root",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.updateStatus(
            sessionID: "sess-codex-hook-missing-root",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Root still running"),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-missing-root",
            event: CodexHookEvent(
                hookEventName: "Stop",
                threadID: "thread-child",
                turnID: "turn-child",
                promptFingerprint: nil,
                status: SessionStatus(kind: .ready, summary: "Ready", detail: "Child finished"),
                nativeSessionID: "thread-child",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-hook-missing-root")?.status
        #expect(status?.kind == .working)
        #expect(status?.detail == "Root still running")
    }

    @Test
    func codexHookStopCompletesWhenRootThreadMatches() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-hook-root-stop",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-root-stop",
            event: CodexHookEvent(
                hookEventName: "SessionStart",
                threadID: "thread-root",
                turnID: nil,
                promptFingerprint: nil,
                status: nil,
                nativeSessionID: "thread-root",
                sessionFilePath: "/tmp/session.jsonl",
                cwd: "/repo"
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-root-stop",
            event: CodexHookEvent(
                hookEventName: "Stop",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .ready, summary: "Ready", detail: "Root finished"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-hook-root-stop")?.status
        #expect(status?.kind == .ready)
        #expect(status?.detail == "Root finished")
    }

    @Test
    func codexHookStopCompletesWhenRootThreadMatchesEvenWithDifferentTurn() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-hook-root-stop-different-turn",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-root-stop-different-turn",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root-previous",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Fix the sidebar state"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Fix the sidebar state"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-root-stop-different-turn",
            event: CodexHookEvent(
                hookEventName: "Stop",
                threadID: "thread-root",
                turnID: "turn-root-next",
                promptFingerprint: nil,
                status: SessionStatus(kind: .ready, summary: "Ready", detail: "Root finished"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted)
        let status = store.sessionRegistry.activeSession(
            sessionID: "sess-codex-hook-root-stop-different-turn"
        )?.status
        #expect(status?.kind == .ready)
        #expect(status?.detail == "Root finished")
    }

    @Test
    func codexHookStopCanMatchRootTurnWhenThreadIsMissing() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-hook-turn-match",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-turn-match",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Fix the sidebar state"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Fix the sidebar state"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-turn-match",
            event: CodexHookEvent(
                hookEventName: "Stop",
                threadID: nil,
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .ready, summary: "Ready", detail: "Root finished"),
                nativeSessionID: nil,
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-hook-turn-match")?.status
        #expect(status?.kind == .ready)
        #expect(status?.detail == "Root finished")
    }

    @Test
    func codexHookStopIgnoresDifferentTurnWhenThreadIsMissing() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-hook-turn-mismatch",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-turn-mismatch",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Fix the sidebar state"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Fix the sidebar state"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-turn-mismatch",
            event: CodexHookEvent(
                hookEventName: "Stop",
                threadID: nil,
                turnID: "turn-child",
                promptFingerprint: nil,
                status: SessionStatus(kind: .ready, summary: "Ready", detail: "Child finished"),
                nativeSessionID: nil,
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-hook-turn-mismatch")?.status
        #expect(status?.kind == .working)
        #expect(status?.detail == "Fix the sidebar state")
    }

    @Test
    func codexHookUnidentifiedStopBeforeRootIdentityIsAcceptedForCompatibility() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-hook-legacy-stop",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.updateStatus(
            sessionID: "sess-codex-hook-legacy-stop",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Root still running"),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-legacy-stop",
            event: CodexHookEvent(
                hookEventName: "Stop",
                threadID: nil,
                turnID: nil,
                promptFingerprint: nil,
                status: SessionStatus(kind: .ready, summary: "Ready", detail: "Turn complete"),
                nativeSessionID: nil,
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-hook-legacy-stop")?.status
        #expect(status?.kind == .ready)
        #expect(status?.detail == "Turn complete")
    }

    @Test
    func codexHookClearSessionStartReplacesLatchedRootThread() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-hook-clear",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-clear",
            event: CodexHookEvent(
                hookEventName: "SessionStart",
                threadID: "thread-root",
                turnID: nil,
                promptFingerprint: nil,
                status: nil,
                nativeSessionID: "thread-root",
                sessionFilePath: "/tmp/root.jsonl",
                cwd: "/repo"
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let acceptedClear = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-clear",
            event: CodexHookEvent(
                hookEventName: "SessionStart",
                source: "clear",
                threadID: "thread-clear",
                turnID: nil,
                promptFingerprint: nil,
                status: nil,
                nativeSessionID: "thread-clear",
                sessionFilePath: "/tmp/clear.jsonl",
                cwd: "/repo"
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(acceptedClear)

        let acceptedNewThread = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-clear",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-clear",
                turnID: "turn-clear",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Continue after clear"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Continue after clear"),
                nativeSessionID: "thread-clear",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(3)
        )

        #expect(acceptedNewThread)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-hook-clear")?.status
        #expect(status?.kind == .working)
        #expect(status?.detail == "Continue after clear")
    }

}
