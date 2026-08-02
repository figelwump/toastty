import Combine
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

extension SessionRuntimeStoreTests {
    @Test
    func codexHookPermissionRequestUsesPendingOverrideContextForTurnlessUserTurn() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let promptFingerprint = CodexInputFingerprint.fingerprint(for: "continue")

        store.startSession(
            sessionID: "sess-codex-override-context",
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
            sessionID: "sess-codex-override-context",
            approvalPolicy: "on-request",
            approvalsReviewer: "guardian_subagent"
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-override-context",
            fingerprint: promptFingerprint,
            approvalPolicy: "on-request"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-override-context",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: promptFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "continue"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-override-context",
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
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-override-context")?.status?.kind == .working)
    }

    @Test
    func codexHookPermissionRequestUsesPendingOverrideContextWhenHookArrivesBeforeTurnlessUserTurn() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let promptFingerprint = CodexInputFingerprint.fingerprint(for: "continue")

        store.startSession(
            sessionID: "sess-codex-hook-first-override-context",
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
            sessionID: "sess-codex-hook-first-override-context",
            approvalPolicy: "on-request",
            approvalsReviewer: "guardian_subagent"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-first-override-context",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: promptFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "continue"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )
        let deferred = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-first-override-context",
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

        #expect(deferred == false)
        #expect(
            store.sessionRegistry.activeSession(sessionID: "sess-codex-hook-first-override-context")?.status?.kind ==
                .working
        )

        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-hook-first-override-context",
            fingerprint: promptFingerprint,
            approvalPolicy: "on-request"
        )

        let suppressed = store.handleCodexHookEvent(
            sessionID: "sess-codex-hook-first-override-context",
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
            at: startedAt.addingTimeInterval(3)
        )

        #expect(suppressed == false)
        #expect(
            store.sessionRegistry.activeSession(sessionID: "sess-codex-hook-first-override-context")?.status?.kind ==
                .working
        )
    }

    @Test
    func codexHookPermissionRequestReusesOverrideContextAcrossRepeatedPrompts() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let promptFingerprint = CodexInputFingerprint.fingerprint(for: "continue")

        store.startSession(
            sessionID: "sess-codex-repeated-prompt",
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
            sessionID: "sess-codex-repeated-prompt",
            approvalPolicy: "on-request",
            approvalsReviewer: "guardian_subagent"
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-repeated-prompt",
            fingerprint: promptFingerprint,
            approvalPolicy: "on-request"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-repeated-prompt",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-one",
                promptFingerprint: promptFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "continue"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-repeated-prompt",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-one",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-repeated-prompt",
            fingerprint: promptFingerprint,
            approvalPolicy: "on-request"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-repeated-prompt",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-two",
                promptFingerprint: promptFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "continue again"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(3)
        )

        let suppressed = store.handleCodexHookEvent(
            sessionID: "sess-codex-repeated-prompt",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-two",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(4)
        )

        #expect(suppressed == false)
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-repeated-prompt")?.status?.kind == .working)
    }

    @Test
    func codexHookPermissionRequestDoesNotCarryOverrideContextAcrossClearSessionStart() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let firstPromptFingerprint = CodexInputFingerprint.fingerprint(for: "continue")
        let secondPromptFingerprint = CodexInputFingerprint.fingerprint(for: "manual")

        store.startSession(
            sessionID: "sess-codex-clear-session-start",
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
            sessionID: "sess-codex-clear-session-start",
            approvalPolicy: "on-request",
            approvalsReviewer: "guardian_subagent"
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-clear-session-start",
            fingerprint: firstPromptFingerprint,
            approvalPolicy: "on-request"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-clear-session-start",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-one",
                turnID: "turn-one",
                promptFingerprint: firstPromptFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "continue"),
                nativeSessionID: "thread-one",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )
        let firstSuppressed = store.handleCodexHookEvent(
            sessionID: "sess-codex-clear-session-start",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-one",
                turnID: "turn-one",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-one",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )
        #expect(firstSuppressed == false)

        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-clear-session-start",
            event: CodexHookEvent(
                hookEventName: "SessionStart",
                source: "clear",
                threadID: "thread-two",
                turnID: nil,
                promptFingerprint: nil,
                status: nil,
                nativeSessionID: "thread-two",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(3)
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-clear-session-start",
            fingerprint: secondPromptFingerprint,
            approvalPolicyField: .string("on-request"),
            approvalsReviewerField: .null
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-clear-session-start",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-two",
                turnID: "turn-two",
                promptFingerprint: secondPromptFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "manual"),
                nativeSessionID: "thread-two",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(4)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-clear-session-start",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                permissionMode: "default",
                threadID: "thread-two",
                turnID: "turn-two",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-two",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(5)
        )

        #expect(accepted)
        #expect(
            store.sessionRegistry.activeSession(sessionID: "sess-codex-clear-session-start")?.status?.kind ==
                .needsApproval
        )
    }

    @Test
    func codexHookPermissionRequestDoesNotPublishWhenPromptContextClearsReviewerWithoutPolicy() {
        let store = SessionRuntimeStore(codexHookApprovalDeferralNanoseconds: 1_000_000_000)
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let promptFingerprint = CodexInputFingerprint.fingerprint(for: "manual command")

        store.startSession(
            sessionID: "sess-codex-waits-for-current-prompt-context",
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
            sessionID: "sess-codex-waits-for-current-prompt-context",
            approvalPolicy: "on-request",
            approvalsReviewer: "guardian_subagent"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-waits-for-current-prompt-context",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: promptFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "manual command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let deferred = store.handleCodexHookEvent(
            sessionID: "sess-codex-waits-for-current-prompt-context",
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

        #expect(deferred == false)
        #expect(
            store.sessionRegistry.activeSession(
                sessionID: "sess-codex-waits-for-current-prompt-context"
            )?.status?.kind == .working
        )

        store.recordCodexPendingTurnContext(
            sessionID: "sess-codex-waits-for-current-prompt-context",
            approvalPolicy: nil,
            approvalsReviewer: nil
        )

        #expect(
            store.sessionRegistry.activeSession(
                sessionID: "sess-codex-waits-for-current-prompt-context"
            )?.status?.kind == .working
        )
    }

    @Test
    func codexHookPermissionRequestUsesOverrideContextThatArrivesAfterUserTurnContext() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let promptFingerprint = CodexInputFingerprint.fingerprint(for: "continue")

        store.startSession(
            sessionID: "sess-codex-late-override-context",
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
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-late-override-context",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: promptFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "continue"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-late-override-context",
            fingerprint: promptFingerprint,
            approvalPolicy: "on-request"
        )
        store.recordCodexOverrideTurnContext(
            sessionID: "sess-codex-late-override-context",
            approvalPolicy: .unspecified,
            approvalsReviewer: .string("guardian_subagent")
        )

        let suppressed = store.handleCodexHookEvent(
            sessionID: "sess-codex-late-override-context",
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

        #expect(suppressed == false)
        #expect(
            store.sessionRegistry.activeSession(sessionID: "sess-codex-late-override-context")?.status?.kind ==
                .working
        )
    }

    @Test
    func codexHookPermissionRequestDoesNotUseOverrideContextAfterNullClear() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let promptFingerprint = CodexInputFingerprint.fingerprint(for: "continue")

        store.startSession(
            sessionID: "sess-codex-override-context-clear",
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
            sessionID: "sess-codex-override-context-clear",
            approvalPolicy: "on-request",
            approvalsReviewer: "guardian_subagent"
        )
        store.recordCodexPendingTurnContext(
            sessionID: "sess-codex-override-context-clear",
            approvalPolicy: nil,
            approvalsReviewer: nil
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-override-context-clear",
            fingerprint: promptFingerprint,
            approvalPolicy: "on-request"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-override-context-clear",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: promptFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "continue"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-override-context-clear",
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

        #expect(accepted)
        #expect(
            store.sessionRegistry.activeSession(sessionID: "sess-codex-override-context-clear")?.status?.kind ==
                .needsApproval
        )
    }

    @Test
    func codexHookPermissionRequestSuppressesNullClearWithoutApprovalPolicy() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let promptFingerprint = CodexInputFingerprint.fingerprint(for: "continue")

        store.startSession(
            sessionID: "sess-codex-null-clear-without-fields",
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
            sessionID: "sess-codex-null-clear-without-fields",
            approvalPolicy: "on-request",
            approvalsReviewer: "guardian_subagent"
        )
        store.recordCodexPendingTurnContext(
            sessionID: "sess-codex-null-clear-without-fields",
            approvalPolicy: nil,
            approvalsReviewer: nil
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-null-clear-without-fields",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: promptFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "continue"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-null-clear-without-fields",
            fingerprint: promptFingerprint
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-null-clear-without-fields",
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
        #expect(
            store.sessionRegistry.activeSession(sessionID: "sess-codex-null-clear-without-fields")?.status?.kind ==
                .working
        )
    }

    @Test
    func codexHookPermissionRequestDoesNotUseStaleTurnForUnidentifiedAutoReviewContext() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-stale-auto-review-context",
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
            sessionID: "sess-codex-stale-auto-review-context",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            turnID: "turn-root"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-stale-auto-review-context",
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
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-stale-auto-review-context",
            fingerprint: nil,
            approvalPolicy: "never",
            approvalsReviewer: "reviewer"
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-stale-auto-review-context",
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
            store.sessionRegistry.activeSession(sessionID: "sess-codex-stale-auto-review-context")?.status?.kind ==
                .working
        )
    }

    @Test
    func codexHookPermissionRequestIsSuppressedWhenAutoReviewTurnMismatches() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-auto-review-known-turn-mismatch",
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
            sessionID: "sess-codex-auto-review-known-turn-mismatch",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            turnID: "turn-root",
            approvalPolicy: "never",
            approvalsReviewer: "reviewer"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-auto-review-known-turn-mismatch",
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
            sessionID: "sess-codex-auto-review-known-turn-mismatch",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                threadID: "thread-root",
                turnID: "turn-child",
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
            store.sessionRegistry.activeSession(
                sessionID: "sess-codex-auto-review-known-turn-mismatch"
            )?.status?.kind == .working
        )
    }

    @Test
    func codexHookPermissionRequestIsSuppressedForAwaitingRootWhenActiveAutoReviewTurnMismatches() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let promptFingerprint = CodexInputFingerprint.fingerprint(for: "go ahead")

        store.startSession(
            sessionID: "sess-codex-auto-review-awaiting-turn-mismatch",
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
            sessionID: "sess-codex-auto-review-awaiting-turn-mismatch",
            approvalPolicy: "on-request",
            approvalsReviewer: "guardian_subagent"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-auto-review-awaiting-turn-mismatch",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: promptFingerprint,
                status: SessionStatus(kind: .working, summary: "Working", detail: "go ahead"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(1)
        )

        let accepted = store.handleCodexHookEvent(
            sessionID: "sess-codex-auto-review-awaiting-turn-mismatch",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                threadID: "thread-root",
                turnID: "turn-tool",
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
            store.sessionRegistry.activeSession(
                sessionID: "sess-codex-auto-review-awaiting-turn-mismatch"
            )?.status?.kind == .working
        )
    }

    @Test
    func codexHookPermissionRequestFromDifferentThreadIsIgnoredByRootThreadFilter() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-auto-review-thread-mismatch",
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
            sessionID: "sess-codex-auto-review-thread-mismatch",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            turnID: "turn-root",
            approvalPolicy: "never",
            approvalsReviewer: "reviewer"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-auto-review-thread-mismatch",
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
            sessionID: "sess-codex-auto-review-thread-mismatch",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                threadID: "thread-child",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
                nativeSessionID: "thread-child",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(accepted == false)
        #expect(
            store.sessionRegistry.activeSession(sessionID: "sess-codex-auto-review-thread-mismatch")?.status?.kind ==
                .working
        )
    }

    @Test
    func codexHookPermissionRequestIsSuppressedWhenHookTurnIsMissing() {
        let store = SessionRuntimeStore()
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-auto-review-missing-hook-turn",
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
            sessionID: "sess-codex-auto-review-missing-hook-turn",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            turnID: "turn-root",
            approvalPolicy: "never",
            approvalsReviewer: "reviewer"
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-auto-review-missing-hook-turn",
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
            sessionID: "sess-codex-auto-review-missing-hook-turn",
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                threadID: "thread-root",
                turnID: nil,
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
            store.sessionRegistry.activeSession(sessionID: "sess-codex-auto-review-missing-hook-turn")?.status?.kind ==
                .working
        )
    }

}
