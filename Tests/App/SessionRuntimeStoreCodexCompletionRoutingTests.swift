import Combine
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

extension SessionRuntimeStoreTests {
    @Test
    func codexNotifyCompletionIgnoresChildThreadBeforeRootCompletes() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let rootFingerprint = CodexInputFingerprint.fingerprint(for: "Fix the sidebar state")

        store.startSession(
            sessionID: "sess-codex-notify",
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
            sessionID: "sess-codex-notify",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Fix the sidebar state"),
            at: startedAt.addingTimeInterval(1)
        )
        store.recordCodexRootTurnInput(sessionID: "sess-codex-notify", fingerprint: rootFingerprint)

        let ignoredChild = store.handleCodexNotifyCompletion(
            sessionID: "sess-codex-notify",
            completion: CodexNotifyCompletion(
                notificationType: "agent-turn-complete",
                threadID: "thread-child",
                turnID: "turn-child",
                lastInputMessageFingerprint: CodexInputFingerprint.fingerprint(for: "Inspect parser wiring"),
                inputMessageCount: 1,
                detail: "Child finished"
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(ignoredChild == false)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-notify")?.status?.kind == .working)

        let acceptedRoot = store.handleCodexNotifyCompletion(
            sessionID: "sess-codex-notify",
            completion: CodexNotifyCompletion(
                notificationType: "agent-turn-complete",
                threadID: "thread-root",
                turnID: "turn-root",
                lastInputMessageFingerprint: rootFingerprint,
                inputMessageCount: 1,
                detail: "Root finished"
            ),
            at: startedAt.addingTimeInterval(3)
        )

        #expect(acceptedRoot)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-notify")?.status
        #expect(status?.kind == .ready)
        #expect(status?.detail == "Root finished")
    }

    @Test
    func codexNotifyCompletionIgnoresDifferentThreadAfterRootThreadIsLatched() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let rootFingerprint = CodexInputFingerprint.fingerprint(for: "Fix the sidebar state")

        store.startSession(
            sessionID: "sess-codex-root-latched",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexRootTurnInput(sessionID: "sess-codex-root-latched", fingerprint: rootFingerprint)
        _ = store.handleCodexNotifyCompletion(
            sessionID: "sess-codex-root-latched",
            completion: CodexNotifyCompletion(
                notificationType: "agent-turn-complete",
                threadID: "thread-root",
                turnID: "turn-root-1",
                lastInputMessageFingerprint: rootFingerprint,
                inputMessageCount: 1,
                detail: "Root finished"
            ),
            at: startedAt.addingTimeInterval(1)
        )
        store.updateStatus(
            sessionID: "sess-codex-root-latched",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Next turn"),
            at: startedAt.addingTimeInterval(2)
        )

        let ignoredChild = store.handleCodexNotifyCompletion(
            sessionID: "sess-codex-root-latched",
            completion: CodexNotifyCompletion(
                notificationType: "agent-turn-complete",
                threadID: "thread-child",
                turnID: "turn-child",
                lastInputMessageFingerprint: CodexInputFingerprint.fingerprint(for: "Child task"),
                inputMessageCount: 1,
                detail: "Child finished"
            ),
            at: startedAt.addingTimeInterval(3)
        )

        #expect(ignoredChild == false)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-root-latched")?.status?.kind == .working)
    }

    @Test
    func codexRootTurnInputThreadIDCanReplaceLatchedThreadForLaterGoal() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let firstFingerprint = CodexInputFingerprint.fingerprint(for: "Fix the sidebar state")
        let goalFingerprint = CodexInputFingerprint.fingerprint(for: "Implement the saved goal")

        store.startSession(
            sessionID: "sess-codex-goal-thread",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-goal-thread",
            fingerprint: firstFingerprint,
            threadID: "thread-first"
        )
        store.updateStatus(
            sessionID: "sess-codex-goal-thread",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Implement the saved goal"),
            at: startedAt.addingTimeInterval(1)
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-goal-thread",
            fingerprint: goalFingerprint,
            threadID: "thread-goal"
        )

        let ignoredPreviousThread = store.handleCodexNotifyCompletion(
            sessionID: "sess-codex-goal-thread",
            completion: CodexNotifyCompletion(
                notificationType: "agent-turn-complete",
                threadID: "thread-first",
                turnID: "turn-first",
                lastInputMessageFingerprint: firstFingerprint,
                inputMessageCount: 1,
                detail: "Earlier thread finished"
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(ignoredPreviousThread == false)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-goal-thread")?.status?.kind == .working)

        let acceptedGoalThread = store.handleCodexNotifyCompletion(
            sessionID: "sess-codex-goal-thread",
            completion: CodexNotifyCompletion(
                notificationType: "agent-turn-complete",
                threadID: "thread-goal",
                turnID: "turn-goal",
                lastInputMessageFingerprint: nil,
                inputMessageCount: 0,
                detail: "Goal finished"
            ),
            at: startedAt.addingTimeInterval(3)
        )

        #expect(acceptedGoalThread)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-goal-thread")?.status
        #expect(status?.kind == .ready)
        #expect(status?.detail == "Goal finished")
    }

    @Test
    func codexNotifyCompletionIgnoresThreadedInputWhenRootInputWasNotRecorded() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-missing-root-input",
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
            sessionID: "sess-codex-missing-root-input",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Root still running"),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexNotifyCompletion(
            sessionID: "sess-codex-missing-root-input",
            completion: CodexNotifyCompletion(
                notificationType: "agent-turn-complete",
                threadID: "thread-unknown",
                turnID: "turn-unknown",
                lastInputMessageFingerprint: CodexInputFingerprint.fingerprint(for: "Maybe a child task"),
                inputMessageCount: 1,
                detail: "Thread finished"
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-missing-root-input")?.status?.kind == .working)
    }

    @Test
    func codexNotifyCompletionIgnoresThreadedCompletionWithoutInputMetadata() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-threaded-no-input",
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
            sessionID: "sess-codex-threaded-no-input",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Root still running"),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexNotifyCompletion(
            sessionID: "sess-codex-threaded-no-input",
            completion: CodexNotifyCompletion(
                notificationType: "agent-turn-complete",
                threadID: "thread-unknown",
                turnID: "turn-unknown",
                lastInputMessageFingerprint: nil,
                inputMessageCount: 0,
                detail: "Thread finished"
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-threaded-no-input")?.status?.kind == .working)
    }

    @Test
    func codexNotifyCompletionAcceptsUnthreadedLegacyCompletionWithoutInputMetadata() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-legacy-notify",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        let accepted = store.handleCodexNotifyCompletion(
            sessionID: "sess-codex-legacy-notify",
            completion: CodexNotifyCompletion(
                notificationType: "task_complete",
                threadID: nil,
                turnID: nil,
                lastInputMessageFingerprint: nil,
                inputMessageCount: 0,
                detail: "Legacy finished"
            ),
            at: startedAt.addingTimeInterval(1)
        )

        #expect(accepted)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-legacy-notify")?.status
        #expect(status?.kind == .ready)
        #expect(status?.detail == "Legacy finished")
    }

    @Test
    func codexNotifyCompletionIgnoresFallbackEventWhenSessionUsesHooks() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-hooks-ignore-notify",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.updateStatus(
            sessionID: "sess-codex-hooks-ignore-notify",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Root still running"),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexNotifyCompletion(
            sessionID: "sess-codex-hooks-ignore-notify",
            completion: CodexNotifyCompletion(
                notificationType: "agent-turn-complete",
                threadID: nil,
                turnID: nil,
                lastInputMessageFingerprint: nil,
                inputMessageCount: 0,
                detail: "Notify finished"
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-hooks-ignore-notify")?.status
        #expect(status?.kind == .working)
        #expect(status?.detail == "Root still running")
    }

    @Test
    func codexSessionLogCompletionIgnoresMismatchedTurnBeforeRootCompletes() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-session-log-turn",
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
            sessionID: "sess-codex-session-log-turn",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Root still running"),
            at: startedAt.addingTimeInterval(1)
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-session-log-turn",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Root still running"),
            threadID: "thread-root",
            turnID: "turn-root"
        )

        let ignoredChild = store.handleCodexSessionLogCompletion(
            sessionID: "sess-codex-session-log-turn",
            detail: "Child finished",
            threadID: "thread-root",
            turnID: "turn-child",
            at: startedAt.addingTimeInterval(2)
        )

        #expect(ignoredChild == false)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-session-log-turn")?.status?.kind == .working)

        let acceptedRoot = store.handleCodexSessionLogCompletion(
            sessionID: "sess-codex-session-log-turn",
            detail: "Root finished",
            threadID: "thread-root",
            turnID: "turn-root",
            at: startedAt.addingTimeInterval(3)
        )

        #expect(acceptedRoot)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-session-log-turn")?.status
        #expect(status?.kind == .ready)
        #expect(status?.detail == "Root finished")
    }

    @Test
    func codexSessionLogCompletionIgnoresMismatchedThreadBeforeRootCompletes() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-session-log-thread",
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
            sessionID: "sess-codex-session-log-thread",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Root still running"),
            at: startedAt.addingTimeInterval(1)
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-session-log-thread",
            fingerprint: nil,
            threadID: "thread-root"
        )

        let ignoredChild = store.handleCodexSessionLogCompletion(
            sessionID: "sess-codex-session-log-thread",
            detail: "Child finished",
            threadID: "thread-child",
            turnID: nil,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(ignoredChild == false)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-session-log-thread")?.status?.kind == .working)
    }

    @Test
    func codexSessionLogCompletionIgnoresIdentifiedTurnWhenRootTurnIsUnknown() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-session-log-missing-root-turn",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .sessionLogFallback(reason: "test"),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.updateStatus(
            sessionID: "sess-codex-session-log-missing-root-turn",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Root still running"),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexSessionLogCompletion(
            sessionID: "sess-codex-session-log-missing-root-turn",
            detail: "Child finished",
            threadID: nil,
            turnID: "turn-child",
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        #expect(
            store.sessionRegistry.activeSession(
                sessionID: "sess-codex-session-log-missing-root-turn"
            )?.status?.kind == .working
        )
    }

    @Test
    func codexSessionLogCompletionIgnoresFallbackEventWhenSessionUsesHooks() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-hooks-ignore-log",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        let accepted = store.handleCodexSessionLogCompletion(
            sessionID: "sess-codex-hooks-ignore-log",
            detail: "Session log finished",
            threadID: nil,
            turnID: nil,
            at: startedAt.addingTimeInterval(1)
        )

        #expect(accepted == false)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-hooks-ignore-log")?.status?.kind == nil)
    }

    @Test
    func codexHookEventIgnoresHookWhenSessionUsesSessionLogFallback() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-fallback-ignore-hook",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .sessionLogFallback(reason: "hooks_needsUpdate"),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.updateStatus(
            sessionID: "sess-codex-fallback-ignore-hook",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Root still running"),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-fallback-ignore-hook",
            event: CodexHookEvent(
                hookEventName: "Stop",
                threadID: nil,
                turnID: nil,
                promptFingerprint: nil,
                status: SessionStatus(kind: .ready, summary: "Ready", detail: "Hook finished"),
                nativeSessionID: nil,
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-fallback-ignore-hook")?.status
        #expect(status?.kind == .working)
        #expect(status?.detail == "Root still running")
    }

    @Test
    func codexRootTurnInputKeepsTurnWhenThreadIsLatchedAfterTurn() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-thread-after-turn",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .sessionLogFallback(reason: "test"),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-thread-after-turn",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Fix sidebar"),
            turnID: "turn-root"
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-thread-after-turn",
            fingerprint: nil,
            threadID: "thread-root"
        )

        let accepted = store.handleCodexSessionLogCompletion(
            sessionID: "sess-codex-thread-after-turn",
            detail: "Root finished",
            threadID: "thread-root",
            turnID: "turn-root",
            at: startedAt.addingTimeInterval(1)
        )

        #expect(accepted)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-thread-after-turn")?.status
        #expect(status?.kind == .ready)
        #expect(status?.detail == "Root finished")
    }

    @Test
    func codexRolloutTurnFailureMarksOnlyTheCurrentHookTurnAsAnError() {
        let store = SessionRuntimeStore()
        let sessionID = "sess-codex-rollout-failure"
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        func promptSubmit(turnID: String) -> CodexHookEvent {
            CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: turnID,
                promptFingerprint: nil,
                status: SessionStatus(kind: .working, summary: "Working", detail: "Evaluate approaches"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            )
        }

        store.startSession(
            sessionID: sessionID,
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        _ = store.handleCodexHookEvent(
            sessionID: sessionID,
            event: promptSubmit(turnID: "turn-1"),
            at: startedAt.addingTimeInterval(1)
        )

        let acceptedStale = store.handleCodexRolloutTurnFailure(
            sessionID: sessionID,
            turnID: "turn-0",
            detail: "Stale failure",
            at: startedAt.addingTimeInterval(2)
        )
        #expect(acceptedStale == false)
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind == .working)

        let acceptedCurrent = store.handleCodexRolloutTurnFailure(
            sessionID: sessionID,
            turnID: "turn-1",
            detail: "401 Unauthorized: Incorrect API key provided",
            at: startedAt.addingTimeInterval(3)
        )
        #expect(acceptedCurrent)
        let failedStatus = store.sessionRegistry.activeSession(sessionID: sessionID)?.status
        #expect(failedStatus?.kind == .error)
        #expect(failedStatus?.detail == "401 Unauthorized: Incorrect API key provided")

        // An error already on the row, such as the visible-text usage-limit banner, keeps its text.
        #expect(store.handleCodexRolloutTurnFailure(
            sessionID: sessionID,
            turnID: "turn-1",
            detail: "Different failure text",
            at: startedAt.addingTimeInterval(3.5)
        ) == false)
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.detail == "401 Unauthorized: Incorrect API key provided")

        // The next prompt clears the error, and a replay of the old failure cannot restore it.
        _ = store.handleCodexHookEvent(
            sessionID: sessionID,
            event: promptSubmit(turnID: "turn-2"),
            at: startedAt.addingTimeInterval(4)
        )
        let acceptedReplay = store.handleCodexRolloutTurnFailure(
            sessionID: sessionID,
            turnID: "turn-1",
            detail: "401 Unauthorized: Incorrect API key provided",
            at: startedAt.addingTimeInterval(5)
        )
        #expect(acceptedReplay == false)
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind == .working)
    }

    @Test
    func codexSessionLogFallbackReportsAFailedTurnAsAnError() {
        let store = SessionRuntimeStore()
        let sessionID = "sess-codex-fallback-failure"
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: sessionID,
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .sessionLogFallback(reason: "test"),
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexRootTurnInput(
            sessionID: sessionID,
            fingerprint: CodexInputFingerprint.fingerprint(for: "Fix sidebar"),
            turnID: "turn-root"
        )
        store.updateStatus(
            sessionID: sessionID,
            status: SessionStatus(kind: .working, summary: "Working", detail: "Fix sidebar"),
            at: startedAt.addingTimeInterval(1)
        )

        // The fallback session log owns completion, so the rollout path stays out of it.
        #expect(store.handleCodexRolloutTurnFailure(
            sessionID: sessionID,
            turnID: "turn-root",
            detail: "Selected model is at capacity",
            at: startedAt.addingTimeInterval(2)
        ) == false)
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind == .working)

        let accepted = store.handleCodexSessionLogCompletion(
            sessionID: sessionID,
            detail: "Turn complete",
            threadID: nil,
            turnID: "turn-root",
            turnError: "Selected model is at capacity",
            at: startedAt.addingTimeInterval(3)
        )

        #expect(accepted)
        let status = store.sessionRegistry.activeSession(sessionID: sessionID)?.status
        #expect(status?.kind == .error)
        #expect(status?.detail == "Selected model is at capacity")
    }
}
