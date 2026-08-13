import Combine
import CoreState
import Foundation
import Testing
@testable import ToasttyApp

extension SessionRuntimeStoreTests {
    @Test
    func codexHookPermissionRequestWithOmittedReviewerSurfacesAfterContextTimeout() async {
        let store = SessionRuntimeStore(codexHookApprovalDeferralNanoseconds: 20_000_000)
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-unknown-reviewer",
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
            sessionID: "sess-codex-unknown-reviewer",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            turnID: "turn-root",
            approvalPolicyField: .string("on-request"),
            approvalsReviewerField: .unspecified
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-unknown-reviewer",
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
            sessionID: "sess-codex-unknown-reviewer",
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
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-unknown-reviewer")?.status?.kind == .working)

        try? await Task.sleep(nanoseconds: 80_000_000)

        #expect(
            store.sessionRegistry.activeSession(
                sessionID: "sess-codex-unknown-reviewer"
            )?.status?.kind == .needsApproval
        )

        store.recordCodexCanonicalTurnContext(
            sessionID: "sess-codex-unknown-reviewer",
            turnID: "turn-root",
            approvalPolicy: .string("on-request"),
            approvalsReviewer: .string("auto_review")
        )

        #expect(
            store.sessionRegistry.activeSession(
                sessionID: "sess-codex-unknown-reviewer"
            )?.status?.kind == .working
        )
    }

    @Test
    func codexCanonicalReviewerTransitionsPreserveHumanAndAutoApprovalBehavior() {
        let store = SessionRuntimeStore()
        let sessionID = "sess-codex-canonical-reviewer-transitions"
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

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

        func submitPrompt(turnID: String) {
            _ = store.handleCodexHookEvent(
                sessionID: sessionID,
                event: CodexHookEvent(
                    hookEventName: "UserPromptSubmit",
                    threadID: "thread-root",
                    turnID: turnID,
                    promptFingerprint: CodexInputFingerprint.fingerprint(for: turnID),
                    status: SessionStatus(kind: .working, summary: "Working", detail: turnID),
                    nativeSessionID: "thread-root",
                    sessionFilePath: nil,
                    cwd: nil
                ),
                at: startedAt
            )
        }

        func recordContext(turnID: String, reviewer: String) {
            store.recordCodexCanonicalTurnContext(
                sessionID: sessionID,
                turnID: turnID,
                approvalPolicy: .string("on-request"),
                approvalsReviewer: .string(reviewer)
            )
        }

        func requestApproval(turnID: String) -> Bool {
            store.handleCodexHookEvent(
                sessionID: sessionID,
                event: CodexHookEvent(
                    hookEventName: "PermissionRequest",
                    threadID: "thread-root",
                    turnID: turnID,
                    promptFingerprint: nil,
                    status: SessionStatus(
                        kind: .needsApproval,
                        summary: "Needs approval",
                        detail: turnID
                    ),
                    nativeSessionID: "thread-root",
                    sessionFilePath: nil,
                    cwd: nil
                ),
                at: startedAt
            )
        }

        submitPrompt(turnID: "turn-auto-one")
        recordContext(turnID: "turn-auto-one", reviewer: "auto_review")
        #expect(requestApproval(turnID: "turn-auto-one") == false)
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind == .working)

        submitPrompt(turnID: "turn-human")
        recordContext(turnID: "turn-human", reviewer: "user")
        #expect(requestApproval(turnID: "turn-human"))
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind == .needsApproval)

        submitPrompt(turnID: "turn-auto-two")
        recordContext(turnID: "turn-auto-two", reviewer: "guardian_subagent")
        #expect(requestApproval(turnID: "turn-auto-two") == false)
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind == .working)
    }

    @Test
    func codexHookPermissionRequestWithOmittedReviewerSurfacesAfterExplicitNullContextArrives() {
        let store = SessionRuntimeStore(codexHookApprovalDeferralNanoseconds: 1_000_000_000)
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-unknown-reviewer-later-null",
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
            sessionID: "sess-codex-unknown-reviewer-later-null",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            turnID: "turn-root",
            approvalPolicyField: .string("on-request"),
            approvalsReviewerField: .unspecified
        )
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-unknown-reviewer-later-null",
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
        let deferred = store.handleCodexHookEvent(
            sessionID: "sess-codex-unknown-reviewer-later-null",
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
                sessionID: "sess-codex-unknown-reviewer-later-null"
            )?.status?.kind == .working
        )

        store.recordCodexOverrideTurnContext(
            sessionID: "sess-codex-unknown-reviewer-later-null",
            approvalPolicy: .unspecified,
            approvalsReviewer: .null
        )

        #expect(
            store.sessionRegistry.activeSession(
                sessionID: "sess-codex-unknown-reviewer-later-null"
            )?.status?.kind == .needsApproval
        )
    }

    @Test
    func codexHookPermissionRequestDefersUntilAutoReviewContextArrives() async {
        let store = SessionRuntimeStore(codexHookApprovalDeferralNanoseconds: 1_000_000_000)
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-deferred-auto-review",
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
            sessionID: "sess-codex-deferred-auto-review",
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
            sessionID: "sess-codex-deferred-auto-review",
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
        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-deferred-auto-review")?.status?.kind == .working)

        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-deferred-auto-review",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Run checks"),
            turnID: "turn-root",
            approvalPolicy: "never",
            approvalsReviewer: "reviewer"
        )
        await settleNotificationTasks()

        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-deferred-auto-review")?.status?.kind == .working)
    }

    @Test
    func codexHookPermissionRequestStaysWorkingWhenContextDoesNotArrive() async {
        let store = SessionRuntimeStore(codexHookApprovalDeferralNanoseconds: 20_000_000)
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-deferred-timeout",
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
            sessionID: "sess-codex-deferred-timeout",
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
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-deferred-timeout",
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

        await SessionRuntimeStoreTestSupport.waitUntil {
            store.sessionRegistry.activeSession(sessionID: "sess-codex-deferred-timeout")?.status?.kind ==
                .working
        }

        #expect(store.sessionRegistry.activeSession(sessionID: "sess-codex-deferred-timeout")?.status?.kind == .working)
    }

    @Test
    func codexHookPermissionRequestDoesNotBecomeStaleNeedsApprovalAfterWorkContinues() async {
        let store = SessionRuntimeStore(codexHookApprovalDeferralNanoseconds: 20_000_000)
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-deferred-superseded",
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
            sessionID: "sess-codex-deferred-superseded",
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
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-deferred-superseded",
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
        _ = store.handleCodexHookEvent(
            sessionID: "sess-codex-deferred-superseded",
            event: CodexHookEvent(
                hookEventName: "PreToolUse",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(kind: .working, summary: "Working", detail: "Running command"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(3)
        )
        try? await Task.sleep(nanoseconds: 80_000_000)

        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-deferred-superseded")?.status
        #expect(status?.kind == .working)
        #expect(status?.detail == "Running command")
    }

    @Test
    func codexHookPermissionRequestDoesNotBecomeStaleNeedsApprovalAfterRootTurnAdvances() async {
        let store = SessionRuntimeStore(codexHookApprovalDeferralNanoseconds: 20_000_000)
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-deferred-context-superseded",
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
            sessionID: "sess-codex-deferred-context-superseded",
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
            sessionID: "sess-codex-deferred-context-superseded",
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
        store.recordCodexRootTurnInput(
            sessionID: "sess-codex-deferred-context-superseded",
            fingerprint: CodexInputFingerprint.fingerprint(for: "Next task"),
            turnID: "turn-new",
            approvalPolicy: "never",
            approvalsReviewer: "reviewer"
        )
        try? await Task.sleep(nanoseconds: 80_000_000)

        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-deferred-context-superseded")?.status
        #expect(status?.kind == .working)
        #expect(status?.detail == "Run checks")
    }

    @Test
    func codexHookPermissionRequestIsSupersededByNewTurnHook() async {
        let store = SessionRuntimeStore(codexHookApprovalDeferralNanoseconds: 20_000_000)
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.startSession(
            sessionID: "sess-codex-deferred-new-turn-superseded",
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
            sessionID: "sess-codex-deferred-new-turn-superseded",
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
            sessionID: "sess-codex-deferred-new-turn-superseded",
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
            sessionID: "sess-codex-deferred-new-turn-superseded",
            event: CodexHookEvent(
                hookEventName: "UserPromptSubmit",
                permissionMode: "default",
                threadID: "thread-root",
                turnID: "turn-new",
                promptFingerprint: CodexInputFingerprint.fingerprint(for: "Next task"),
                status: SessionStatus(kind: .working, summary: "Working", detail: "Next task"),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(3)
        )
        try? await Task.sleep(nanoseconds: 80_000_000)

        let status = store.sessionRegistry.activeSession(sessionID: "sess-codex-deferred-new-turn-superseded")?.status
        #expect(status?.kind == .working)
        #expect(status?.detail == "Next task")
    }

    @Test
    func codexReplacementPendingApprovalSurvivesStaleExpiryTask() async {
        let store = SessionRuntimeStore(codexHookApprovalDeferralNanoseconds: 10_000_000_000)
        let sessionID = "sess-codex-replaced-pending-token"
        let startedAt = Date(timeIntervalSince1970: 1_700_000_100)

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

        for detail in ["Approve first request", "Approve replacement request"] {
            #expect(store.handleCodexHookEvent(
                sessionID: sessionID,
                event: CodexHookEvent(
                    hookEventName: "PermissionRequest",
                    permissionMode: "default",
                    threadID: "thread-root",
                    turnID: "turn-root",
                    promptFingerprint: nil,
                    status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: detail),
                    nativeSessionID: "thread-root",
                    sessionFilePath: nil,
                    cwd: nil
                ),
                at: startedAt.addingTimeInterval(2)
            ) == false)
        }

        await settleNotificationTasks()
        #expect(store.hasPendingCodexHookApprovalForTesting(sessionID: sessionID))

        store.recordCodexOverrideTurnContext(
            sessionID: sessionID,
            approvalPolicy: .string("on-request"),
            approvalsReviewer: .null
        )

        let status = store.sessionRegistry.activeSession(sessionID: sessionID)?.status
        #expect(status?.kind == .needsApproval)
        #expect(status?.detail == "Approve replacement request")
        #expect(store.hasPendingCodexHookApprovalForTesting(sessionID: sessionID) == false)
    }

    @Test
    func codexIncompatibleLogApprovalDoesNotRemovePendingHookApproval() {
        let store = SessionRuntimeStore(codexHookApprovalDeferralNanoseconds: 10_000_000_000)
        let sessionID = "sess-codex-incompatible-log-keeps-pending"
        let startedAt = Date(timeIntervalSince1970: 1_700_000_200)

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
        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: CodexHookEvent(
                hookEventName: "PermissionRequest",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: SessionStatus(
                    kind: .needsApproval,
                    summary: "Needs approval",
                    detail: "Hook approval"
                ),
                nativeSessionID: "thread-root",
                sessionFilePath: nil,
                cwd: nil
            ),
            at: startedAt.addingTimeInterval(2)
        ) == false)
        #expect(store.hasPendingCodexHookApprovalForTesting(sessionID: sessionID))

        #expect(store.handleCodexSessionLogApproval(
            sessionID: sessionID,
            detail: "Incompatible log approval",
            threadID: "thread-root",
            turnID: "turn-root",
            callID: nil,
            approvalID: nil,
            at: startedAt.addingTimeInterval(3)
        ) == false)

        #expect(store.hasPendingCodexHookApprovalForTesting(sessionID: sessionID))
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind == .working)
    }

}
