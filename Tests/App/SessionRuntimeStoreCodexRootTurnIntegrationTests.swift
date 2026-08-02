import CoreState
import Foundation
import Testing
@testable import ToasttyApp

extension SessionRuntimeStoreTests {
    @Test
    func codexReconciliationRuntimeIsLazyAndClearedByExplicitLifecyclePaths() {
        let sessionID = "sess-codex-reconciliation-lazy"
        let panelID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_002_000)
        let store = SessionRuntimeStore()

        startCodexReconciliationSession(
            store,
            sessionID: sessionID,
            panelID: panelID,
            source: .sessionLogFallback(reason: "test"),
            at: startedAt
        )
        #expect(store.codexReconciliationRuntimeSessionIDsForTesting.contains(sessionID) == false)

        #expect(store.handleCodexNotifyCompletion(
            sessionID: sessionID,
            completion: CodexNotifyCompletion(
                notificationType: "agent-turn-complete",
                threadID: nil,
                turnID: nil,
                lastInputMessageFingerprint: nil,
                inputMessageCount: 0,
                detail: "Finished"
            ),
            at: startedAt.addingTimeInterval(1)
        ))
        #expect(store.codexReconciliationRuntimeSessionIDsForTesting.contains(sessionID) == false)

        store.recordCodexRootTurnInput(
            sessionID: sessionID,
            fingerprint: CodexInputFingerprint.fingerprint(for: "First turn")
        )
        #expect(store.codexReconciliationRuntimeSessionIDsForTesting.contains(sessionID))

        store.stopSession(sessionID: sessionID, at: startedAt.addingTimeInterval(2))
        #expect(store.codexReconciliationRuntimeSessionIDsForTesting.contains(sessionID) == false)

        startCodexReconciliationSession(
            store,
            sessionID: sessionID,
            panelID: panelID,
            source: .hooks,
            at: startedAt.addingTimeInterval(3)
        )
        #expect(store.codexReconciliationRuntimeSessionIDsForTesting.contains(sessionID) == false)
        store.recordCodexOverrideTurnContext(
            sessionID: sessionID,
            approvalPolicy: .string("on-request"),
            approvalsReviewer: .null
        )
        #expect(store.codexReconciliationRuntimeSessionIDsForTesting.contains(sessionID))

        store.stopSessionForPanel(panelID: panelID, at: startedAt.addingTimeInterval(4))
        #expect(store.codexReconciliationRuntimeSessionIDsForTesting.contains(sessionID) == false)

        startCodexReconciliationSession(
            store,
            sessionID: sessionID,
            panelID: panelID,
            source: .hooks,
            at: startedAt.addingTimeInterval(5)
        )
        store.recordCodexRootTurnInput(sessionID: sessionID, fingerprint: nil)
        #expect(store.codexReconciliationRuntimeSessionIDsForTesting.contains(sessionID))

        store.reset()
        #expect(store.codexReconciliationRuntimeSessionIDsForTesting.isEmpty)
    }

    @Test
    func codexReconciliationRuntimeIsClearedWhenOwningPanelDisappears() throws {
        let appStore = AppStore(persistTerminalFontPreference: false)
        let store = SessionRuntimeStore()
        store.bind(store: appStore)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let panelID = try #require(selection.workspace.focusedPanelID)
        let sessionID = "sess-codex-reconciliation-panel-removal"
        let startedAt = Date(timeIntervalSince1970: 1_700_002_100)

        store.startSession(
            sessionID: sessionID,
            agent: .codex,
            panelID: panelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            codexStatusTrackingSource: .hooks,
            cwd: "/repo",
            repoRoot: "/repo",
            at: startedAt
        )
        store.recordCodexRootTurnInput(
            sessionID: sessionID,
            fingerprint: CodexInputFingerprint.fingerprint(for: "Panel-owned turn")
        )
        #expect(store.codexReconciliationRuntimeSessionIDsForTesting.contains(sessionID))

        #expect(appStore.send(.closePanel(panelID: panelID)))

        #expect(store.codexReconciliationRuntimeSessionIDsForTesting.contains(sessionID) == false)
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID) == nil)
    }

    @Test
    func codexFallbackAuthorityRejectsRootMutatingHookBeforeProjection() {
        let sessionID = "sess-codex-fallback-rejects-prompt"
        let startedAt = Date(timeIntervalSince1970: 1_700_002_200)
        let store = SessionRuntimeStore()
        startCodexReconciliationSession(
            store,
            sessionID: sessionID,
            source: .sessionLogFallback(reason: "test"),
            at: startedAt
        )
        store.recordCodexRootTurnInput(
            sessionID: sessionID,
            fingerprint: CodexInputFingerprint.fingerprint(for: "Root turn"),
            threadID: "thread-root",
            turnID: "turn-root"
        )
        store.updateStatus(
            sessionID: sessionID,
            status: SessionStatus(kind: .working, summary: "Working", detail: "Fallback is authoritative"),
            at: startedAt
        )
        let snapshotBefore = store.codexRootTurnSnapshotForTesting(sessionID: sessionID)

        let accepted = store.handleCodexHookEvent(
            sessionID: sessionID,
            event: codexReconciliationPromptEvent(
                threadID: "thread-hook",
                turnID: "turn-hook",
                detail: "Hook must not project"
            ),
            at: startedAt.addingTimeInterval(1)
        )

        #expect(accepted == false)
        #expect(store.codexRootTurnSnapshotForTesting(sessionID: sessionID) == snapshotBefore)
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.detail == "Fallback is authoritative")
    }

    @Test
    func codexFallbackAuthorityRejectsClearHookWithoutMutatingReconciliationRuntime() {
        let sessionID = "sess-codex-fallback-rejects-clear"
        let pristineSessionID = "sess-codex-fallback-rejects-clear-pristine"
        let startedAt = Date(timeIntervalSince1970: 1_700_002_250)
        let store = SessionRuntimeStore()
        startCodexReconciliationSession(
            store,
            sessionID: sessionID,
            source: .sessionLogFallback(reason: "test"),
            at: startedAt
        )
        store.recordCodexRootTurnInput(
            sessionID: sessionID,
            fingerprint: CodexInputFingerprint.fingerprint(for: "Fallback root turn"),
            threadID: "thread-root",
            turnID: "turn-root",
            approvalPolicyField: .string("on-request"),
            approvalsReviewerField: .string("guardian_subagent")
        )
        #expect(store.handleCodexSessionLogApproval(
            sessionID: sessionID,
            detail: "Auto-reviewed command",
            threadID: "thread-root",
            turnID: "turn-root",
            callID: nil,
            approvalID: nil,
            at: startedAt.addingTimeInterval(1)
        ) == false)
        let snapshotBefore = store.codexRootTurnSnapshotForTesting(sessionID: sessionID)
        let reviewedBefore = store.codexAutoReviewedPermissionTurnIDsForTesting(sessionID: sessionID)
        let runtimeSessionIDsBefore = store.codexReconciliationRuntimeSessionIDsForTesting
        #expect(reviewedBefore == ["turn-root"])

        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: codexReconciliationClearEvent(threadID: "thread-replacement"),
            at: startedAt.addingTimeInterval(2)
        ) == false)

        #expect(store.codexRootTurnSnapshotForTesting(sessionID: sessionID) == snapshotBefore)
        #expect(store.codexAutoReviewedPermissionTurnIDsForTesting(sessionID: sessionID) == reviewedBefore)
        #expect(store.codexReconciliationRuntimeSessionIDsForTesting == runtimeSessionIDsBefore)

        startCodexReconciliationSession(
            store,
            sessionID: pristineSessionID,
            source: .sessionLogFallback(reason: "test"),
            at: startedAt.addingTimeInterval(3)
        )
        #expect(store.codexReconciliationRuntimeSessionIDsForTesting.contains(pristineSessionID) == false)
        #expect(store.handleCodexHookEvent(
            sessionID: pristineSessionID,
            event: codexReconciliationClearEvent(threadID: "thread-pristine"),
            at: startedAt.addingTimeInterval(4)
        ) == false)
        #expect(store.codexReconciliationRuntimeSessionIDsForTesting.contains(pristineSessionID) == false)
    }

    @Test
    func codexProceedingNoOpHooksStillProjectSubagentAndApprovalEvents() throws {
        let sessionID = "sess-codex-proceeding-no-op"
        let startedAt = Date(timeIntervalSince1970: 1_700_002_300)
        let store = SessionRuntimeStore()
        startCodexReconciliationSession(store, sessionID: sessionID, source: .hooks, at: startedAt)
        let fingerprint = CodexInputFingerprint.fingerprint(for: "Root turn")
        store.recordCodexRootTurnInput(
            sessionID: sessionID,
            fingerprint: fingerprint,
            threadID: "thread-root",
            turnID: "turn-root",
            approvalPolicyField: .string("on-request"),
            approvalsReviewerField: .null
        )
        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: codexReconciliationPromptEvent(
                threadID: "thread-root",
                turnID: "turn-root",
                fingerprint: fingerprint,
                detail: "Root turn"
            ),
            at: startedAt.addingTimeInterval(1)
        ))
        let snapshotBefore = store.codexRootTurnSnapshotForTesting(sessionID: sessionID)

        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: CodexHookEvent(
                hookEventName: "SubagentStart",
                threadID: "thread-root",
                turnID: "turn-root",
                promptFingerprint: nil,
                status: nil,
                nativeSessionID: nil,
                sessionFilePath: nil,
                cwd: nil,
                subagentID: "agent-child",
                subagentType: "reviewer"
            ),
            at: startedAt.addingTimeInterval(2)
        ))
        #expect(store.codexRootTurnSnapshotForTesting(sessionID: sessionID) == snapshotBefore)
        _ = try #require(store.sessionRegistry.activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID["agent-child"])

        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: codexReconciliationPermissionEvent(
                threadID: "thread-root",
                turnID: "turn-root"
            ),
            at: startedAt.addingTimeInterval(3)
        ))
        #expect(store.codexRootTurnSnapshotForTesting(sessionID: sessionID) == snapshotBefore)
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status?.kind == .needsApproval)
    }

    @Test
    func codexClearSessionStartClearsLegacyReviewHistoryBeforeQualification() {
        let sessionID = "sess-codex-clear-review-history"
        let startedAt = Date(timeIntervalSince1970: 1_700_002_400)
        let store = SessionRuntimeStore()
        startCodexReconciliationSession(store, sessionID: sessionID, source: .hooks, at: startedAt)
        recordAutoReviewedCodexTurn(
            store,
            sessionID: sessionID,
            threadID: "thread-root",
            turnID: "turn-root",
            at: startedAt
        )
        let snapshotBeforeSameThreadClear = store.codexRootTurnSnapshotForTesting(sessionID: sessionID)
        #expect(store.codexAutoReviewedPermissionTurnIDsForTesting(sessionID: sessionID) == ["turn-root"])

        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: codexReconciliationClearEvent(threadID: "thread-root"),
            at: startedAt.addingTimeInterval(3)
        ))
        #expect(store.codexRootTurnSnapshotForTesting(sessionID: sessionID) == snapshotBeforeSameThreadClear)
        #expect(store.codexAutoReviewedPermissionTurnIDsForTesting(sessionID: sessionID).isEmpty)

        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: codexReconciliationPermissionEvent(
                threadID: "thread-root",
                turnID: "turn-root"
            ),
            at: startedAt.addingTimeInterval(4)
        ) == false)
        #expect(store.codexAutoReviewedPermissionTurnIDsForTesting(sessionID: sessionID) == ["turn-root"])

        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: codexReconciliationClearEvent(threadID: "thread-replacement"),
            at: startedAt.addingTimeInterval(5)
        ))
        let replaced = store.codexRootTurnSnapshotForTesting(sessionID: sessionID)
        #expect(replaced?.rootThreadID == "thread-replacement")
        #expect(replaced?.rootTurnID == nil)
        #expect(replaced?.currentApprovalContext == nil)
        #expect(store.codexAutoReviewedPermissionTurnIDsForTesting(sessionID: sessionID).isEmpty)
    }

    @Test
    func codexAutoReviewedTurnHistoryIsDeduplicatedAndBoundedFIFO() {
        let sessionID = "sess-codex-auto-review-fifo"
        let startedAt = Date(timeIntervalSince1970: 1_700_002_500)
        let store = SessionRuntimeStore()
        startCodexReconciliationSession(store, sessionID: sessionID, source: .hooks, at: startedAt)

        for index in 1 ... 17 {
            recordAutoReviewedCodexTurn(
                store,
                sessionID: sessionID,
                threadID: "thread-root",
                turnID: "turn-\(index)",
                at: startedAt.addingTimeInterval(Double(index * 3))
            )
        }
        #expect(
            store.codexAutoReviewedPermissionTurnIDsForTesting(sessionID: sessionID) ==
                (2 ... 17).map { "turn-\($0)" }
        )

        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: codexReconciliationPermissionEvent(
                threadID: "thread-root",
                turnID: "turn-17"
            ),
            at: startedAt.addingTimeInterval(100)
        ) == false)
        #expect(
            store.codexAutoReviewedPermissionTurnIDsForTesting(sessionID: sessionID) ==
                (2 ... 17).map { "turn-\($0)" }
        )
    }

    @Test
    func codexDuplicateRootInputDoesNotResolvePendingApprovalTwice() {
        let sessionID = "sess-codex-duplicate-root-resolution"
        let startedAt = Date(timeIntervalSince1970: 1_700_002_600)
        let fingerprint = CodexInputFingerprint.fingerprint(for: "Resolve pending approval")
        let store = SessionRuntimeStore(codexHookApprovalDeferralNanoseconds: 10_000_000_000)
        startCodexReconciliationSession(store, sessionID: sessionID, source: .hooks, at: startedAt)

        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: codexReconciliationPromptEvent(
                threadID: "thread-root",
                turnID: "turn-root",
                fingerprint: fingerprint,
                detail: "Resolve pending approval"
            ),
            at: startedAt.addingTimeInterval(1)
        ))
        #expect(store.handleCodexHookEvent(
            sessionID: sessionID,
            event: codexReconciliationPermissionEvent(
                threadID: "thread-root",
                turnID: "turn-root"
            ),
            at: startedAt.addingTimeInterval(2)
        ) == false)
        #expect(store.hasPendingCodexHookApprovalForTesting(sessionID: sessionID))

        store.recordCodexRootTurnInput(
            sessionID: sessionID,
            fingerprint: fingerprint,
            threadID: "thread-root",
            turnID: "turn-root",
            approvalPolicyField: .string("on-request"),
            approvalsReviewerField: .string("guardian_subagent")
        )
        #expect(store.hasPendingCodexHookApprovalForTesting(sessionID: sessionID) == false)
        let snapshotAfterResolution = store.codexRootTurnSnapshotForTesting(sessionID: sessionID)
        let reviewedAfterResolution = store.codexAutoReviewedPermissionTurnIDsForTesting(sessionID: sessionID)
        let statusAfterResolution = store.sessionRegistry.activeSession(sessionID: sessionID)?.status

        store.recordCodexRootTurnInput(
            sessionID: sessionID,
            fingerprint: fingerprint,
            threadID: "thread-root",
            turnID: "turn-root",
            approvalPolicyField: .string("on-request"),
            approvalsReviewerField: .string("guardian_subagent")
        )

        #expect(store.hasPendingCodexHookApprovalForTesting(sessionID: sessionID) == false)
        #expect(store.codexRootTurnSnapshotForTesting(sessionID: sessionID) == snapshotAfterResolution)
        #expect(store.codexAutoReviewedPermissionTurnIDsForTesting(sessionID: sessionID) == reviewedAfterResolution)
        #expect(store.sessionRegistry.activeSession(sessionID: sessionID)?.status == statusAfterResolution)
    }
}

@MainActor
private func startCodexReconciliationSession(
    _ store: SessionRuntimeStore,
    sessionID: String,
    panelID: UUID = UUID(),
    source: CodexStatusTrackingSource,
    at startedAt: Date
) {
    store.startSession(
        sessionID: sessionID,
        agent: .codex,
        panelID: panelID,
        windowID: UUID(),
        workspaceID: UUID(),
        usesSessionStatusNotifications: true,
        codexStatusTrackingSource: source,
        cwd: "/repo",
        repoRoot: "/repo",
        at: startedAt
    )
}

private func codexReconciliationPromptEvent(
    threadID: String,
    turnID: String,
    fingerprint: String? = nil,
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

private func codexReconciliationPermissionEvent(
    threadID: String,
    turnID: String
) -> CodexHookEvent {
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

private func codexReconciliationClearEvent(threadID: String) -> CodexHookEvent {
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
private func recordAutoReviewedCodexTurn(
    _ store: SessionRuntimeStore,
    sessionID: String,
    threadID: String,
    turnID: String,
    at startedAt: Date
) {
    let fingerprint = CodexInputFingerprint.fingerprint(for: turnID)
    store.recordCodexRootTurnInput(
        sessionID: sessionID,
        fingerprint: fingerprint,
        threadID: threadID,
        turnID: turnID,
        approvalPolicyField: .string("on-request"),
        approvalsReviewerField: .string("guardian_subagent")
    )
    #expect(store.handleCodexHookEvent(
        sessionID: sessionID,
        event: codexReconciliationPromptEvent(
            threadID: threadID,
            turnID: turnID,
            fingerprint: fingerprint,
            detail: turnID
        ),
        at: startedAt.addingTimeInterval(1)
    ))
    #expect(store.handleCodexHookEvent(
        sessionID: sessionID,
        event: codexReconciliationPermissionEvent(threadID: threadID, turnID: turnID),
        at: startedAt.addingTimeInterval(2)
    ) == false)
}
