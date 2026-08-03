import CoreState
import Foundation
import Testing
@testable import ToasttyApp

extension SessionRuntimeStoreTests {
    @Test
    func codexExactRootTurnContextMergesWhenLaunchInputPrecedesHookPrompt() {
        let sessionID = "sess-codex-root-context-launch-first"
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let fingerprint = CodexInputFingerprint.fingerprint(for: "Run the checks")
        let store = startedCodexRootContextStore(sessionID: sessionID, at: startedAt)

        store.recordCodexPendingTurnContext(
            sessionID: sessionID,
            approvalPolicy: "on-request",
            approvalsReviewer: "guardian_subagent"
        )
        store.recordCodexRootTurnInput(
            sessionID: sessionID,
            fingerprint: fingerprint,
            threadID: "thread-root",
            turnID: "turn-root",
            approvalPolicyField: .string("on-request"),
            approvalsReviewerField: .unspecified
        )

        let promptAccepted = store.handleCodexHookEvent(
            sessionID: sessionID,
            event: codexRootContextPromptEvent(
                threadID: "thread-root",
                turnID: "turn-root",
                fingerprint: fingerprint,
                detail: "Run the checks"
            ),
            at: startedAt.addingTimeInterval(1)
        )
        let permissionAccepted = store.handleCodexHookEvent(
            sessionID: sessionID,
            event: codexRootContextPermissionEvent(threadID: "thread-root", turnID: "turn-root"),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(promptAccepted)
        #expect(permissionAccepted == false)
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind == .working)
    }

    @Test
    func codexExactRootTurnContextMergesWhenLaunchInputAndOverrideFollowHookPrompt() {
        let sessionID = "sess-codex-root-context-hook-first"
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let fingerprint = CodexInputFingerprint.fingerprint(for: "Run the checks")
        let store = startedCodexRootContextStore(sessionID: sessionID, at: startedAt)

        let promptAccepted = store.handleCodexHookEvent(
            sessionID: sessionID,
            event: codexRootContextPromptEvent(
                threadID: "thread-root",
                turnID: "turn-root",
                fingerprint: fingerprint,
                detail: "Run the checks"
            ),
            at: startedAt.addingTimeInterval(1)
        )
        store.recordCodexRootTurnInput(
            sessionID: sessionID,
            fingerprint: fingerprint,
            threadID: "thread-root",
            turnID: "turn-root",
            approvalPolicyField: .string("on-request"),
            approvalsReviewerField: .unspecified
        )
        store.recordCodexOverrideTurnContext(
            sessionID: sessionID,
            approvalPolicy: .unspecified,
            approvalsReviewer: .string("guardian_subagent")
        )

        let permissionAccepted = store.handleCodexHookEvent(
            sessionID: sessionID,
            event: codexRootContextPermissionEvent(threadID: "thread-root", turnID: "turn-root"),
            at: startedAt.addingTimeInterval(2)
        )

        #expect(promptAccepted)
        #expect(permissionAccepted == false)
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind == .working)
    }

    @Test
    func codexMismatchedLaunchThreadMakesTheFormerHookThreadIneligible() {
        let sessionID = "sess-codex-root-context-thread-replacement"
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let hookFingerprint = CodexInputFingerprint.fingerprint(for: "Hook prompt")
        let launchFingerprint = CodexInputFingerprint.fingerprint(for: "Launch prompt")
        let store = startedCodexRootContextStore(sessionID: sessionID, at: startedAt)

        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: codexRootContextPromptEvent(
                threadID: "thread-hook",
                turnID: "turn-hook",
                fingerprint: hookFingerprint,
                detail: "Hook prompt"
            ),
            at: startedAt.addingTimeInterval(1)
        ))
        store.recordCodexRootTurnInput(
            sessionID: sessionID,
            fingerprint: launchFingerprint,
            threadID: "thread-launch",
            turnID: "turn-launch",
            approvalPolicyField: .string("on-request"),
            approvalsReviewerField: .null
        )

        let formerHookPermissionAccepted = store.handleCodexHookEvent(
            sessionID: sessionID,
            event: codexRootContextPermissionEvent(threadID: "thread-hook", turnID: "turn-hook"),
            at: startedAt.addingTimeInterval(2)
        )
        let replacementPermissionAccepted = store.handleCodexHookEvent(
            sessionID: sessionID,
            event: codexRootContextPermissionEvent(threadID: "thread-launch", turnID: "turn-launch"),
            at: startedAt.addingTimeInterval(3)
        )

        #expect(formerHookPermissionAccepted == false)
        #expect(replacementPermissionAccepted)
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind == .needsApproval)
    }

    @Test
    func codexClearSessionStartReplacesRootIdentityAndDropsInheritedApprovalContext() {
        let sessionID = "sess-codex-root-context-clear"
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let oldFingerprint = CodexInputFingerprint.fingerprint(for: "Old prompt")
        let pendingOldFingerprint = CodexInputFingerprint.fingerprint(for: "Pending old prompt")
        let newFingerprint = CodexInputFingerprint.fingerprint(for: "New prompt")
        let store = startedCodexRootContextStore(sessionID: sessionID, at: startedAt)

        store.recordCodexPendingTurnContext(
            sessionID: sessionID,
            approvalPolicy: "on-request",
            approvalsReviewer: "guardian_subagent"
        )
        store.recordCodexRootTurnInput(
            sessionID: sessionID,
            fingerprint: oldFingerprint,
            threadID: "thread-old",
            turnID: "turn-old",
            approvalPolicyField: .string("on-request"),
            approvalsReviewerField: .unspecified
        )
        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: codexRootContextPromptEvent(
                threadID: "thread-old",
                turnID: "turn-old",
                fingerprint: oldFingerprint,
                detail: "Old prompt"
            ),
            at: startedAt.addingTimeInterval(1)
        ))
        store.recordCodexRootTurnInput(
            sessionID: sessionID,
            fingerprint: pendingOldFingerprint,
            threadID: "thread-old",
            approvalPolicyField: .string("on-request"),
            approvalsReviewerField: .unspecified
        )

        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: codexRootContextClearEvent(threadID: "thread-new"),
            at: startedAt.addingTimeInterval(2)
        ))
        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: codexRootContextPromptEvent(
                threadID: "thread-new",
                turnID: "turn-new",
                fingerprint: newFingerprint,
                detail: "New prompt"
            ),
            at: startedAt.addingTimeInterval(3)
        ))
        store.recordCodexRootTurnInput(
            sessionID: sessionID,
            fingerprint: newFingerprint,
            threadID: "thread-new",
            turnID: "turn-new",
            approvalPolicyField: .string("on-request"),
            approvalsReviewerField: .unspecified
        )

        let deferred = store.handleCodexHookEvent(
            sessionID: sessionID,
            event: codexRootContextPermissionEvent(threadID: "thread-new", turnID: "turn-new"),
            at: startedAt.addingTimeInterval(4)
        )
        #expect(deferred == false)
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind == .working)

        store.recordCodexOverrideTurnContext(
            sessionID: sessionID,
            approvalPolicy: .unspecified,
            approvalsReviewer: .null
        )

        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind == .needsApproval)
    }

    @Test
    func codexDistinctExactTurnIDsKeepSeparateContextsForIdenticalPromptFingerprints() {
        let sessionID = "sess-codex-root-context-identical-prompts"
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let fingerprint = CodexInputFingerprint.fingerprint(for: "continue")
        let store = startedCodexRootContextStore(sessionID: sessionID, at: startedAt)

        store.recordCodexRootTurnInput(
            sessionID: sessionID,
            fingerprint: fingerprint,
            threadID: "thread-root",
            turnID: "turn-one",
            approvalPolicyField: .string("on-request"),
            approvalsReviewerField: .string("guardian_subagent")
        )
        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: codexRootContextPromptEvent(
                threadID: "thread-root",
                turnID: "turn-one",
                fingerprint: fingerprint,
                detail: "continue"
            ),
            at: startedAt.addingTimeInterval(1)
        ))
        let firstPermissionAccepted = store.handleCodexHookEvent(
            sessionID: sessionID,
            event: codexRootContextPermissionEvent(threadID: "thread-root", turnID: "turn-one"),
            at: startedAt.addingTimeInterval(2)
        )

        store.recordCodexRootTurnInput(
            sessionID: sessionID,
            fingerprint: fingerprint,
            threadID: "thread-root",
            turnID: "turn-two",
            approvalPolicyField: .string("on-request"),
            approvalsReviewerField: .null
        )
        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: codexRootContextPromptEvent(
                threadID: "thread-root",
                turnID: "turn-two",
                fingerprint: fingerprint,
                detail: "continue again"
            ),
            at: startedAt.addingTimeInterval(3)
        ))
        let secondPermissionAccepted = store.handleCodexHookEvent(
            sessionID: sessionID,
            event: codexRootContextPermissionEvent(threadID: "thread-root", turnID: "turn-two"),
            at: startedAt.addingTimeInterval(4)
        )

        #expect(firstPermissionAccepted == false)
        #expect(secondPermissionAccepted)
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind == .needsApproval)
    }

    @Test
    func codexApprovalContextFieldsDistinguishOmittedNullAndValuedUpdates() {
        let inherited = codexRootContextDecision(
            suffix: "inherited",
            approvalPolicyField: .unspecified,
            approvalsReviewerField: .unspecified
        )
        let fullyCleared = codexRootContextDecision(
            suffix: "fully-cleared",
            approvalPolicyField: .null,
            approvalsReviewerField: .null
        )
        let manual = codexRootContextDecision(
            suffix: "manual",
            approvalPolicyField: .string("on-request"),
            approvalsReviewerField: .null
        )
        let reviewed = codexRootContextDecision(
            suffix: "reviewed",
            approvalPolicyField: .string("on-request"),
            approvalsReviewerField: .string("guardian_subagent")
        )

        #expect(inherited.accepted == false)
        #expect(inherited.statusKind == .working)
        #expect(fullyCleared.accepted == false)
        #expect(fullyCleared.statusKind == .working)
        #expect(manual.accepted)
        #expect(manual.statusKind == .needsApproval)
        #expect(reviewed.accepted == false)
        #expect(reviewed.statusKind == .working)
    }

    @Test
    func codexRootTurnContextDoesNotSurviveStopOrResetWithSessionIDReuse() {
        assertCodexRootContextIsolationAfterLifecycleTransition(.stop)
        assertCodexRootContextIsolationAfterLifecycleTransition(.reset)
    }
}

private enum CodexRootContextLifecycleTransition {
    case stop
    case reset
}

@MainActor
private func startedCodexRootContextStore(
    sessionID: String,
    at startedAt: Date,
    deferralNanoseconds: UInt64 = 10_000_000_000
) -> SessionRuntimeStore {
    let store = SessionRuntimeStore(codexHookApprovalDeferralNanoseconds: deferralNanoseconds)
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
    return store
}

private func codexRootContextPromptEvent(
    threadID: String,
    turnID: String,
    fingerprint: String?,
    detail: String
) -> CodexHookEvent {
    CodexHookEvent(
        hookEventName: "UserPromptSubmit",
        threadID: threadID,
        turnID: turnID,
        promptFingerprint: fingerprint,
        status: SessionStatus(kind: .working, summary: "Working", detail: detail),
        nativeSessionID: threadID,
        sessionFilePath: nil,
        cwd: nil
    )
}

private func codexRootContextPermissionEvent(threadID: String, turnID: String) -> CodexHookEvent {
    CodexHookEvent(
        hookEventName: "PermissionRequest",
        permissionMode: "default",
        threadID: threadID,
        turnID: turnID,
        promptFingerprint: nil,
        status: SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: "Approve command"),
        nativeSessionID: threadID,
        sessionFilePath: nil,
        cwd: nil
    )
}

private func codexRootContextClearEvent(threadID: String) -> CodexHookEvent {
    CodexHookEvent(
        hookEventName: "SessionStart",
        source: "clear",
        threadID: threadID,
        turnID: nil,
        promptFingerprint: nil,
        status: nil,
        nativeSessionID: threadID,
        sessionFilePath: nil,
        cwd: nil
    )
}

@MainActor
private func codexRootContextDecision(
    suffix: String,
    approvalPolicyField: CodexSessionLogContextField,
    approvalsReviewerField: CodexSessionLogContextField
) -> (accepted: Bool, statusKind: SessionStatusKind?) {
    let sessionID = "sess-codex-root-context-fields-\(suffix)"
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let fingerprint = CodexInputFingerprint.fingerprint(for: "Inspect context \(suffix)")
    let store = startedCodexRootContextStore(sessionID: sessionID, at: startedAt)

    store.recordCodexPendingTurnContext(
        sessionID: sessionID,
        approvalPolicy: "never",
        approvalsReviewer: "guardian_subagent"
    )
    store.recordCodexRootTurnInput(
        sessionID: sessionID,
        fingerprint: fingerprint,
        threadID: "thread-root",
        turnID: "turn-root",
        approvalPolicyField: approvalPolicyField,
        approvalsReviewerField: approvalsReviewerField
    )
    _ = store.handleCodexHookEvent(
        sessionID: sessionID,
        event: codexRootContextPromptEvent(
            threadID: "thread-root",
            turnID: "turn-root",
            fingerprint: fingerprint,
            detail: "Inspect context"
        ),
        at: startedAt.addingTimeInterval(1)
    )
    let accepted = store.handleCodexHookEvent(
        sessionID: sessionID,
        event: codexRootContextPermissionEvent(threadID: "thread-root", turnID: "turn-root"),
        at: startedAt.addingTimeInterval(2)
    )
    return (accepted, store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind)
}

@MainActor
private func assertCodexRootContextIsolationAfterLifecycleTransition(
    _ transition: CodexRootContextLifecycleTransition
) {
    let suffix: String
    switch transition {
    case .stop:
        suffix = "stop"
    case .reset:
        suffix = "reset"
    }
    let sessionID = "sess-codex-root-context-reuse-\(suffix)"
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let oldFingerprint = CodexInputFingerprint.fingerprint(for: "Old reviewed prompt")
    let newFingerprint = CodexInputFingerprint.fingerprint(for: "New manual prompt")
    let store = startedCodexRootContextStore(sessionID: sessionID, at: startedAt)

    store.recordCodexPendingTurnContext(
        sessionID: sessionID,
        approvalPolicy: "on-request",
        approvalsReviewer: "guardian_subagent"
    )
    store.recordCodexRootTurnInput(
        sessionID: sessionID,
        fingerprint: oldFingerprint,
        threadID: "thread-old",
        turnID: "turn-old",
        approvalPolicyField: .string("on-request"),
        approvalsReviewerField: .unspecified
    )
    _ = store.handleCodexHookEvent(
        sessionID: sessionID,
        event: codexRootContextPromptEvent(
            threadID: "thread-old",
            turnID: "turn-old",
            fingerprint: oldFingerprint,
            detail: "Old reviewed prompt"
        ),
        at: startedAt.addingTimeInterval(1)
    )

    switch transition {
    case .stop:
        store.stopSession(sessionID: sessionID, at: startedAt.addingTimeInterval(2))
    case .reset:
        store.reset()
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
        at: startedAt.addingTimeInterval(3)
    )
    _ = store.handleCodexHookEvent(
        sessionID: sessionID,
        event: codexRootContextPromptEvent(
            threadID: "thread-new",
            turnID: "turn-new",
            fingerprint: newFingerprint,
            detail: "New manual prompt"
        ),
        at: startedAt.addingTimeInterval(4)
    )
    store.recordCodexRootTurnInput(
        sessionID: sessionID,
        fingerprint: newFingerprint,
        threadID: "thread-new",
        turnID: "turn-new",
        approvalPolicyField: .string("on-request"),
        approvalsReviewerField: .unspecified
    )
    let deferred = store.handleCodexHookEvent(
        sessionID: sessionID,
        event: codexRootContextPermissionEvent(threadID: "thread-new", turnID: "turn-new"),
        at: startedAt.addingTimeInterval(5)
    )

    #expect(deferred == false)
    #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind == .working)

    store.recordCodexOverrideTurnContext(
        sessionID: sessionID,
        approvalPolicy: .unspecified,
        approvalsReviewer: .null
    )

    #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind == .needsApproval)
}
