import Combine
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

extension SessionRuntimeStoreTests {
    @Test
    func codexSessionLogApprovalSuppressesNeverPolicyWithExplicitNullReviewer() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-session-log-never-approval",
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
            sessionID: "sess-codex-session-log-never-approval",
            status: SessionStatus(kind: .working, summary: "Working", detail: "Running"),
            at: startedAt.addingTimeInterval(1)
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-session-log-never-approval",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            threadID: "thread-root",
            turnID: "turn-root",
            approvalPolicyField: .string("never"),
            approvalsReviewerField: .null
        )

        let accepted = store.handleCodexSessionLogApproval(
            sessionID: "sess-codex-session-log-never-approval",
            detail: "Needs approval",
            threadID: "thread-root",
            turnID: "turn-root",
            callID: nil,
            approvalID: nil,
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        let status = store.sessionRegistry.activeSession(
            sessionID: "sess-codex-session-log-never-approval"
        )?.status
        #expect(status?.kind == .working)
        #expect(status?.detail == "Running")
    }

    @Test
    func codexHookEventUpdatesStatusAndLatchesRootThread() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-hook",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-1",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Set up hooks"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Set up hooks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        #expect(accepted)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-hook")?.status
        #expect(status?.kind == .working)
        #expect(status?.detail == "Set up hooks")
    }

    @Test
    func codexHookPermissionRequestIsSuppressedForMatchingAutoReviewTurn() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let store = SessionRuntimeStore()
        store.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-auto-review",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-auto-review",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            turnID: "turn-root",
            approvalPolicy: "never",
            approvalsReviewer: "reviewer"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-auto-review",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Run checks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-auto-review",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-auto-review")?.status?.kind == .working)
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs.isEmpty)
    }

    @Test
    func codexHookPermissionRequestReplayFromAutoReviewedPriorTurnIsIgnored() throws {
        let appState = makeTwoPanelAppState()
        let appStore = AppStore(state: appState, persistTerminalFontPreference: false)
        let store = SessionRuntimeStore()
        store.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let oldFingerprint = CodexInputFingerprint.fingerprint(for: "Run checks")
        let newFingerprint = CodexInputFingerprint.fingerprint(for: "Continue")

        store.startSession(
            sessionID: "sess-codex-replayed-auto-review",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexPendingTurnContext(
            sessionID: "sess-codex-replayed-auto-review",
            approvalPolicy: "on-request",
            approvalsReviewer: "guardian_subagent"
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-replayed-auto-review",
            fingerprint: oldFingerprint,
            turnID: "turn-old",
            approvalPolicy: "on-request"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-replayed-auto-review",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-old",
                promptFingerprint: oldFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "Run checks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let initialApprovalAccepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-replayed-auto-review",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-old",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-replayed-auto-review",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-new",
                promptFingerprint: newFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "Continue"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(3)
        )

        let replayAccepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-replayed-auto-review",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-old",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(4)
        )

        #expect(initialApprovalAccepted == false)
        #expect(replayAccepted == false)
        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-replayed-auto-review")?.status
        #expect(status?.kind == .working)
        #expect(status?.detail == "Continue")
        let workspaceAfter = try #require(appStore.state.workspacesByID[selection.workspaceID])
        #expect(workspaceAfter.unreadPanelIDs.isEmpty)
    }

    @Test
    func codexHookPermissionRequestFromPriorManualTurnIsIgnoredAfterRootAdvances() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-prior-manual-turn",
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
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-prior-manual-turn",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            turnID: "turn-old",
            approvalPolicyField: .string("on-request"),
            approvalsReviewerField: .null
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-prior-manual-turn",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-old",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Run checks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-prior-manual-turn",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-new",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Continue"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Continue"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-prior-manual-turn",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-old",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(3)
        )

        #expect(accepted == false)
        #expect(
            store.sessionRegistry.activeSession(sessionID: "sess-codex-prior-manual-turn")?.status?.kind ==
                .working
        )
    }

    @Test
    func codexHookPermissionRequestForCurrentTurnWinsOverPreviouslyAutoReviewedTurnID() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-reused-auto-reviewed-turn",
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
        store.recordCodexPendingTurnContext(
            sessionID: "sess-codex-reused-auto-reviewed-turn",
            approvalPolicy: "on-request",
            approvalsReviewer: "guardian_subagent"
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-reused-auto-reviewed-turn",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            turnID: "turn-reused",
            approvalPolicy: "on-request"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-reused-auto-reviewed-turn",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-reused",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Run checks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )
        let firstSuppressed = store.handleCodexHookEvent(
            sessionID: "sess-codex-reused-auto-reviewed-turn",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-reused",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        store.recordCodexPendingTurnContext(
            sessionID: "sess-codex-reused-auto-reviewed-turn",
            approvalPolicy: "on-request",
            approvalsReviewer: nil
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-reused-auto-reviewed-turn",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Other turn"),
            turnID: "turn-other",
            approvalPolicy: "on-request"
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-reused-auto-reviewed-turn",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Manual turn"),
            turnID: "turn-reused",
            approvalPolicy: "on-request"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-reused-auto-reviewed-turn",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-reused",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Manual turn"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Manual turn"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(3)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-reused-auto-reviewed-turn",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-reused",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(4)
        )

        #expect(firstSuppressed == false)
        #expect(accepted)
        #expect(
            store.sessionRegistry.activeSession(sessionID: "sess-codex-reused-auto-reviewed-turn")?.status?.kind ==
                .needsApproval
        )
    }

    @Test
    func codexHookPermissionRequestSurfacesWhenReviewerIsExplicitlyNull() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-no-auto-review",
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
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-no-auto-review",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            turnID: "turn-root",
            approvalPolicyField: .string("on-request"),
            approvalsReviewerField: .null
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-no-auto-review",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Run checks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-no-auto-review",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-no-auto-review")?.status?.kind == .needsApproval)
    }

    @Test
    func codexHookPermissionRequestIsSuppressedWhenReviewerIsPresentForOnRequestPolicy() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-reviewer-non-auto-policy",
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
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-reviewer-non-auto-policy",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            turnID: "turn-root",
            approvalPolicy: "on-request",
            approvalsReviewer: "reviewer"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-reviewer-non-auto-policy",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Run checks"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-reviewer-non-auto-policy",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        #expect(
            store.sessionRegistry.activeSession(sessionID: "sess-codex-reviewer-non-auto-policy")?.status?.kind ==
                .working
        )
    }

}
