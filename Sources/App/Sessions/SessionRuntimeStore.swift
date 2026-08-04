import AppKit
import CodexReconciliation
import CoreState
import Darwin
import Foundation

enum CodexSubagentRolloutObservation: Equatable, Sendable {
    case started(CodexSessionBackgroundActivity)
    case finished(CodexSessionBackgroundActivity)
    case streamReset
}

@MainActor
final class SessionRuntimeStore: ObservableObject {
    typealias SessionStatusNotificationHandler = @Sendable (
        _ title: String,
        _ body: String,
        _ workspaceID: UUID,
        _ panelID: UUID,
        _ context: DesktopNotificationContext
    ) async -> Void
    typealias ApplicationActiveHandler = @MainActor () -> Bool

    @Published private(set) var sessionRegistry = SessionRegistry()

    private weak var store: AppStore?
    private var storeActionObserverToken: UUID?
    private var suppressedCodexVisibleErrorDetailBySessionID: [String: String] = [:]
    private var codexSessionReconciliationBySessionID: [String: CodexSessionReconciliationRuntime] = [:]
    private var codexStatusTrackingSourceBySessionID: [String: CodexStatusTrackingSource] = [:]
    private var pendingCodexHookApprovalBySessionID: [String: PendingCodexHookApproval] = [:]
    private var pendingCodexHookApprovalTaskBySessionID: [String: Task<Void, Never>] = [:]
    private var pendingPanelParentSessionIDs: [UUID: PendingPanelParentSessionID] = [:]
    private let sendSessionStatusNotification: SessionStatusNotificationHandler
    private let isApplicationActive: ApplicationActiveHandler
    private let codexHookApprovalDeferralNanoseconds: UInt64
    private let backgroundActivityReapIntervalNanoseconds: UInt64
    private let maximumBackgroundActivityAge: TimeInterval
    private var backgroundActivityReaperTask: Task<Void, Never>?
    private var resumeGraceRepublishTask: Task<Void, Never>?
    private var resumeGraceRepublishExpiry: Date?
    private var backgroundActivityFinishTombstonesBySessionID: [String: [String: Date]] = [:]
    private var codexSubagentReconcilerBySessionID: [String: CodexSubagentReconciler] = [:]
    private static let backgroundActivityFinishTombstoneTTL: TimeInterval = 120
    private static let pendingPanelParentSessionIDTTL: TimeInterval = 120
    private static let maximumPidlessSubagentBackgroundActivityAge: TimeInterval = 30 * 60

    private struct PendingPanelParentSessionID: Equatable {
        let sessionID: String
        let recordedAt: Date
    }

    private struct WorkspaceStatusDiagnosticRow: Equatable {
        let sessionID: String
        let panelID: UUID
        let agent: AgentKind
        let statusKind: SessionStatusKind
        let projection: SessionStatusProjection
        let isActive: Bool
        let isWorkspaceScoped: Bool

        var summary: String {
            [
                panelID.uuidString,
                sessionID,
                agent.rawValue,
                statusKind.rawValue,
                Self.projectionSummary(projection),
                isActive ? "active" : "stopped",
                isWorkspaceScoped ? "scoped" : "unscoped",
            ].joined(separator: ":")
        }

        private static func projectionSummary(_ projection: SessionStatusProjection) -> String {
            switch projection {
            case .none:
                return "projection_none"
            case .waitingOnChildren(let childCount, let pendingBackgroundTaskCount):
                return "projection_waiting_children_\(childCount)_pending_\(pendingBackgroundTaskCount)"
            case .resuming:
                return "projection_resuming"
            }
        }
    }

    init(
        sendSessionStatusNotification: @escaping SessionStatusNotificationHandler = SessionRuntimeStore.defaultSendSessionStatusNotification,
        isApplicationActive: @escaping ApplicationActiveHandler = SessionRuntimeStore.defaultIsApplicationActive,
        codexHookApprovalDeferralNanoseconds: UInt64 = 1_000_000_000,
        backgroundActivityReapIntervalNanoseconds: UInt64 = 10_000_000_000,
        maximumBackgroundActivityAge: TimeInterval = 8 * 60 * 60
    ) {
        self.sendSessionStatusNotification = sendSessionStatusNotification
        self.isApplicationActive = isApplicationActive
        self.codexHookApprovalDeferralNanoseconds = codexHookApprovalDeferralNanoseconds
        self.backgroundActivityReapIntervalNanoseconds = backgroundActivityReapIntervalNanoseconds
        self.maximumBackgroundActivityAge = maximumBackgroundActivityAge
    }

    func bind(store: AppStore) {
        self.store = store
        synchronize(with: store.state)

        guard storeActionObserverToken == nil else { return }
        storeActionObserverToken = store.addActionAppliedObserver { [weak self] action, previousState, nextState in
            self?.collapseReadyStatusAfterReadIfNeeded(
                action: action,
                previousState: previousState,
                nextState: nextState
            )
            self?.synchronize(with: nextState)
        }
    }

    func unbind() {
        if let storeActionObserverToken,
           let store {
            store.removeActionAppliedObserver(storeActionObserverToken)
        }
        storeActionObserverToken = nil
        store = nil
        resumeGraceRepublishTask?.cancel()
        resumeGraceRepublishTask = nil
        resumeGraceRepublishExpiry = nil
    }

    func reset() {
        sessionRegistry = SessionRegistry()
        suppressedCodexVisibleErrorDetailBySessionID = [:]
        codexSessionReconciliationBySessionID = [:]
        codexStatusTrackingSourceBySessionID = [:]
        backgroundActivityFinishTombstonesBySessionID = [:]
        codexSubagentReconcilerBySessionID = [:]
        pendingPanelParentSessionIDs = [:]
        removeAllPendingCodexHookApprovals()
        backgroundActivityReaperTask?.cancel()
        backgroundActivityReaperTask = nil
        resumeGraceRepublishTask?.cancel()
        resumeGraceRepublishTask = nil
        resumeGraceRepublishExpiry = nil
    }

    var codexReconciliationRuntimeSessionIDsForTesting: Set<String> {
        Set(codexSessionReconciliationBySessionID.keys)
    }

    func codexRootTurnSnapshotForTesting(sessionID: String) -> CodexRootTurnSnapshot? {
        codexSessionReconciliationBySessionID[sessionID]?.rootTurn.snapshot
    }

    func codexAutoReviewedPermissionTurnIDsForTesting(sessionID: String) -> [String] {
        codexSessionReconciliationBySessionID[sessionID]?.approval.snapshot.autoReviewedTurnIDs ?? []
    }

    func hasPendingCodexHookApprovalForTesting(sessionID: String) -> Bool {
        pendingCodexHookApprovalBySessionID[sessionID] != nil
    }

    func startSession(
        sessionID: String,
        agent: AgentKind,
        panelID: UUID,
        windowID: UUID,
        workspaceID: UUID,
        parentSessionID: String? = nil,
        usesSessionStatusNotifications: Bool = false,
        codexStatusTrackingSource: CodexStatusTrackingSource? = nil,
        displayTitleOverride: String? = nil,
        cwd: String?,
        repoRoot: String?,
        scopedWorkspaceIDs: Set<UUID>? = nil,
        at now: Date
    ) {
        suppressedCodexVisibleErrorDetailBySessionID.removeValue(forKey: sessionID)
        codexSessionReconciliationBySessionID.removeValue(forKey: sessionID)
        backgroundActivityFinishTombstonesBySessionID.removeValue(forKey: sessionID)
        codexSubagentReconcilerBySessionID.removeValue(forKey: sessionID)
        removePendingCodexHookApproval(sessionID: sessionID)
        if agent == .codex {
            if let codexStatusTrackingSource {
                codexStatusTrackingSourceBySessionID[sessionID] = codexStatusTrackingSource
            } else {
                codexStatusTrackingSourceBySessionID.removeValue(forKey: sessionID)
            }
            codexSubagentReconcilerBySessionID[sessionID] = CodexSubagentReconciler(
                // Nil source temporarily preserves the legacy permissive path:
                // hooks retain lifecycle authority while rollout events project
                // through the compatibility adapter below.
                authority: codexStatusTrackingSource.map { codexSubagentAuthority(for: $0) } ?? .hooks
            )
        } else {
            codexStatusTrackingSourceBySessionID.removeValue(forKey: sessionID)
            codexSubagentReconcilerBySessionID.removeValue(forKey: sessionID)
        }
        var nextRegistry = sessionRegistry
        nextRegistry.startSession(
            sessionID: sessionID,
            agent: agent,
            panelID: panelID,
            windowID: windowID,
            workspaceID: workspaceID,
            parentSessionID: parentSessionID,
            usesSessionStatusNotifications: usesSessionStatusNotifications,
            displayTitleOverride: displayTitleOverride,
            cwd: cwd,
            repoRoot: repoRoot,
            scopedWorkspaceIDs: scopedWorkspaceIDs,
            at: now
        )
        ToasttyLog.info(
            "Started managed session",
            category: .terminal,
            metadata: sessionStartMetadata(
                sessionID: sessionID,
                agent: agent,
                panelID: panelID,
                windowID: windowID,
                workspaceID: workspaceID,
                parentSessionID: parentSessionID,
                usesSessionStatusNotifications: usesSessionStatusNotifications,
                displayTitleOverride: displayTitleOverride,
                scopedWorkspaceIDs: scopedWorkspaceIDs
            )
        )
        publish(nextRegistry, reason: "start_session", at: now)
        synchronizePersistedResumeRecordScope(sessionID: sessionID, in: nextRegistry)
    }

    func startProcessWatch(
        sessionID: String = UUID().uuidString,
        panelID: UUID,
        windowID: UUID,
        workspaceID: UUID,
        displayTitleOverride: String,
        cwd: String?,
        repoRoot: String?,
        at now: Date
    ) {
        store?.recordSessionStatusSidebarExpansionEligibility()
        startSession(
            sessionID: sessionID,
            agent: .processWatch,
            panelID: panelID,
            windowID: windowID,
            workspaceID: workspaceID,
            usesSessionStatusNotifications: true,
            displayTitleOverride: displayTitleOverride,
            cwd: cwd,
            repoRoot: repoRoot,
            at: now
        )
        updateStatus(
            sessionID: sessionID,
            status: Self.processWatchWorkingStatus,
            at: now
        )
    }

    func updateFiles(
        sessionID: String,
        files: [String],
        cwd: String?,
        repoRoot: String?,
        at now: Date
    ) {
        var nextRegistry = sessionRegistry
        nextRegistry.updateFiles(
            sessionID: sessionID,
            files: files,
            cwd: cwd,
            repoRoot: repoRoot,
            at: now
        )
        publish(nextRegistry, reason: "update_files", at: now)
    }

    func updateStatus(
        sessionID: String,
        status: SessionStatus,
        at now: Date
    ) {
        let previousRecord = sessionRegistry.sessionsByID[sessionID]
        let previousProjectedStatus = previousRecord.flatMap { record in
            sessionRegistry.panelStatus(for: record.panelID, at: now)?.status
        }
        let storedStatus = normalizedStatusForStorage(
            requestedStatus: status,
            previousRecord: previousRecord,
            state: store?.state
        )
        updateSuppressedCodexVisibleErrorDetailIfNeeded(
            previousRecord: previousRecord,
            sessionID: sessionID,
            nextStatus: storedStatus
        )
        var nextRegistry = sessionRegistry
        nextRegistry.updateStatus(sessionID: sessionID, status: storedStatus, at: now)
        clearLaterFlagForMeaningfulSessionAdvanceIfNeeded(
            previousRecord: previousRecord,
            sessionID: sessionID,
            nextStatus: storedStatus,
            registry: &nextRegistry
        )
        if let currentRecord = nextRegistry.sessionsByID[sessionID] {
            ToasttyLog.debug(
                "Updated managed session status",
                category: .terminal,
                metadata: sessionStatusTransitionMetadata(
                    previousRecord: previousRecord,
                    currentRecord: currentRecord,
                    status: storedStatus,
                    now: now
                )
            )
        }
        publish(nextRegistry, reason: "update_status", at: now)
        if shouldSuppressProjectedWaitingSideEffects(
            sessionID: sessionID,
            status: storedStatus,
            registry: nextRegistry
        ) {
            logProjectedWaitingSuppression(
                previousRecord: previousRecord,
                sessionID: sessionID,
                status: storedStatus,
                now: now
            )
        } else {
            clearUnreadForManagedSessionIfNeeded(
                previousRecord: previousRecord,
                sessionID: sessionID,
                status: storedStatus
            )
            handleActionableStatusTransitionIfNeeded(
                previousRecord: previousRecord,
                previousProjectedStatus: previousProjectedStatus,
                sessionID: sessionID,
                status: storedStatus
            )
        }
    }

    @discardableResult
    func updateBackgroundActivity(
        sessionID: String,
        activity: SessionBackgroundActivity,
        at now: Date
    ) -> Bool {
        pruneBackgroundActivityFinishTombstones(at: now)
        guard isBackgroundActivityFinishTombstoned(
            sessionID: sessionID,
            activityID: activity.id,
            at: now
        ) == false else {
            return false
        }
        var nextRegistry = sessionRegistry
        guard nextRegistry.updateBackgroundActivity(sessionID: sessionID, activity: activity, at: now) else {
            return false
        }
        ToasttyLog.debug(
            "Updated managed session background activity",
            category: .terminal,
            metadata: backgroundActivityMetadata(
                sessionID: sessionID,
                activity: activity,
                phase: .start
            )
        )
        publish(nextRegistry, reason: "update_background_activity", at: now)
        return true
    }

    @discardableResult
    func reopenBackgroundActivity(
        sessionID: String,
        activity: SessionBackgroundActivity,
        at now: Date
    ) -> Bool {
        // An authoritative lifecycle start can represent a new turn for an
        // activity ID that completed moments earlier.
        clearBackgroundActivityFinishTombstone(
            sessionID: sessionID,
            activityID: activity.id
        )
        return updateBackgroundActivity(
            sessionID: sessionID,
            activity: activity,
            at: now
        )
    }

    @discardableResult
    func syncBackgroundActivities(
        sessionID: String,
        kind: SessionBackgroundActivityKind,
        entries: [SessionBackgroundActivity],
        pendingBackgroundTaskCount: Int,
        preserveUnlistedActivities: Bool = false,
        at now: Date
    ) -> Bool {
        pruneBackgroundActivityFinishTombstones(at: now)
        let filteredEntries = entries.filter { entry in
            isBackgroundActivityFinishTombstoned(
                sessionID: sessionID,
                activityID: entry.id,
                at: now
            ) == false
        }
        var nextRegistry = sessionRegistry
        guard nextRegistry.syncBackgroundActivities(
            sessionID: sessionID,
            kind: kind,
            entries: filteredEntries,
            pendingBackgroundTaskCount: pendingBackgroundTaskCount,
            preserveUnlistedActivities: preserveUnlistedActivities,
            at: now
        ) else {
            return false
        }
        ToasttyLog.debug(
            "Synced managed session background activities",
            category: .terminal,
            metadata: [
                "session_id": sessionID,
                "activity_kind": kind.rawValue,
                "entry_count": String(filteredEntries.count),
                "skipped_tombstoned_entry_count": String(entries.count - filteredEntries.count),
                "pending_background_task_count": String(max(0, pendingBackgroundTaskCount)),
            ]
        )
        publish(nextRegistry, reason: "sync_background_activities", at: now)
        return true
    }

    @discardableResult
    func finishBackgroundActivity(
        sessionID: String,
        activityID: String,
        at now: Date
    ) -> Bool {
        recordBackgroundActivityFinishTombstone(
            sessionID: sessionID,
            activityID: activityID,
            at: now
        )
        let activity = sessionRegistry.sessionsByID[sessionID]?.backgroundActivitiesByID[activityID]
        var nextRegistry = sessionRegistry
        guard nextRegistry.finishBackgroundActivity(sessionID: sessionID, activityID: activityID, at: now) else {
            return false
        }
        ToasttyLog.debug(
            "Finished managed session background activity",
            category: .terminal,
            metadata: backgroundActivityMetadata(
                sessionID: sessionID,
                activityID: activityID,
                activity: activity,
                phase: .finish
            )
        )
        publish(nextRegistry, reason: "finish_background_activity", at: now)
        return true
    }

    @discardableResult
    func pruneStaleBackgroundActivities(at now: Date = Date()) -> Bool {
        var nextRegistry = sessionRegistry
        let didMutate = nextRegistry.pruneBackgroundActivities(at: now) { sessionID, activity in
            shouldPruneBackgroundActivity(sessionID: sessionID, activity, at: now)
        }
        guard didMutate else {
            updateBackgroundActivityReaperState()
            return false
        }

        for (sessionID, record) in sessionRegistry.sessionsByID {
            let nextActivities = nextRegistry.sessionsByID[sessionID]?.backgroundActivitiesByID ?? [:]
            for (activityID, activity) in record.backgroundActivitiesByID
                where nextActivities[activityID] == nil {
                ToasttyLog.info(
                    "Pruned stale managed session background activity",
                    category: .terminal,
                    metadata: backgroundActivityMetadata(
                        sessionID: sessionID,
                        activityID: activityID,
                        activity: activity,
                        phase: .finish
                    )
                )
            }
        }
        publish(nextRegistry, reason: "prune_background_activity", at: now)
        return true
    }

    func recordCodexRootTurnInput(
        sessionID: String,
        fingerprint: String?,
        threadID: String? = nil,
        turnID: String? = nil,
        approvalPolicy: String? = nil,
        approvalsReviewer: String? = nil,
        approvalPolicyField: CodexSessionLogContextField? = nil,
        approvalsReviewerField: CodexSessionLogContextField? = nil
    ) {
        guard let record = sessionRegistry.sessionsByID[sessionID],
              record.agent == .codex,
              record.usesSessionStatusNotifications else {
            return
        }

        let resolvedApprovalPolicyField = approvalPolicyField
            ?? approvalPolicy.map(CodexSessionLogContextField.string)
            ?? .unspecified
        let resolvedApprovalsReviewerField = approvalsReviewerField
            ?? approvalsReviewer.map(CodexSessionLogContextField.string)
            ?? .unspecified
        let reduction = reduceCodexRootTurnObservation(
            sessionID: sessionID,
            observation: .launchLogRootInput(
                fingerprint: fingerprint,
                threadID: threadID,
                turnID: turnID,
                context: CodexRootTurnApprovalContext(
                    approvalPolicy: resolvedApprovalPolicyField.rootTurnContextField,
                    approvalsReviewer: resolvedApprovalsReviewerField.rootTurnContextField
                )
            )
        )
        let state = codexLegacyPolicySnapshot(
            root: reduction.snapshot,
            sessionID: sessionID
        )

        ToasttyLog.debug(
            "Recorded Codex root turn input fingerprint",
            category: .terminal,
            metadata: codexNotifyMetadata(
                sessionID: sessionID,
                record: record,
                state: state,
                additional: [
                    "input_fingerprint": truncatedFingerprint(fingerprint),
                    "thread_id": threadID ?? "none",
                    "turn_id": turnID ?? "none",
                    "approval_policy": resolvedApprovalPolicyField.metadataValue,
                    "approvals_reviewer": resolvedApprovalsReviewerField.metadataValue,
                ]
            )
        )
        resolvePendingCodexHookApprovalIfPossible(
            sessionID: sessionID,
            record: record,
            state: state,
            reasonPrefix: "context_update"
        )
    }

    func recordCodexOverrideTurnContext(
        sessionID: String,
        approvalPolicy: CodexSessionLogContextField,
        approvalsReviewer: CodexSessionLogContextField
    ) {
        guard approvalPolicy.isSpecified || approvalsReviewer.isSpecified else {
            return
        }
        guard let record = sessionRegistry.sessionsByID[sessionID],
              record.agent == .codex,
              record.usesSessionStatusNotifications else {
            return
        }

        let reduction = reduceCodexRootTurnObservation(
            sessionID: sessionID,
            observation: .launchLogOverrideContext(
                CodexRootTurnApprovalContext(
                    approvalPolicy: approvalPolicy.rootTurnContextField,
                    approvalsReviewer: approvalsReviewer.rootTurnContextField
                )
            )
        )
        let state = codexLegacyPolicySnapshot(
            root: reduction.snapshot,
            sessionID: sessionID
        )

        ToasttyLog.debug(
            "Recorded Codex override turn context",
            category: .terminal,
            metadata: codexNotifyMetadata(
                sessionID: sessionID,
                record: record,
                state: state,
                additional: [
                    "approval_policy": approvalPolicy.metadataValue,
                    "approvals_reviewer": approvalsReviewer.metadataValue,
                ]
            )
        )
        resolvePendingCodexHookApprovalIfPossible(
            sessionID: sessionID,
            record: record,
            state: state,
            reasonPrefix: "context_update"
        )
    }

    func recordCodexPendingTurnContext(
        sessionID: String,
        approvalPolicy: String?,
        approvalsReviewer: String?
    ) {
        recordCodexOverrideTurnContext(
            sessionID: sessionID,
            approvalPolicy: approvalPolicy.map(CodexSessionLogContextField.string) ?? .null,
            approvalsReviewer: approvalsReviewer.map(CodexSessionLogContextField.string) ?? .null
        )
    }

    @discardableResult
    func handleCodexNotifyCompletion(
        sessionID: String,
        completion: CodexNotifyCompletion,
        at now: Date
    ) -> Bool {
        guard let record = sessionRegistry.sessionsByID[sessionID] else {
            logCodexNotifyCompletionDecision(
                sessionID: sessionID,
                record: nil,
                state: .empty,
                completion: completion,
                decision: "accepted",
                reason: "missing_session_record"
            )
            updateStatus(
                sessionID: sessionID,
                status: SessionStatus(kind: .ready, summary: "Ready", detail: completion.detail),
                at: now
            )
            return true
        }
        guard record.agent == .codex else {
            logCodexNotifyCompletionDecision(
                sessionID: sessionID,
                record: record,
                state: .empty,
                completion: completion,
                decision: "accepted",
                reason: "non_codex_session"
            )
            updateStatus(
                sessionID: sessionID,
                status: SessionStatus(kind: .ready, summary: "Ready", detail: completion.detail),
                at: now
            )
            return true
        }
        guard record.usesSessionStatusNotifications else {
            logCodexNotifyCompletionDecision(
                sessionID: sessionID,
                record: record,
                state: .empty,
                completion: completion,
                decision: "accepted",
                reason: "status_notifications_disabled"
            )
            updateStatus(
                sessionID: sessionID,
                status: SessionStatus(kind: .ready, summary: "Ready", detail: completion.detail),
                at: now
            )
            return true
        }

        var state = codexLegacyPolicySnapshot(sessionID: sessionID)
        guard codexStatusTrackingSourceAllowsFallbackEvents(sessionID: sessionID) else {
            logCodexNotifyCompletionDecision(
                sessionID: sessionID,
                record: record,
                state: state,
                completion: completion,
                decision: "ignored",
                reason: "status_source_hooks"
            )
            return false
        }

        var acceptedReason = "unknown"
        if let threadID = completion.threadID {
            let reduction = reduceCodexRootTurnObservation(
                sessionID: sessionID,
                observation: .fallbackNotifyThreadCandidate(
                    threadID: threadID,
                    inputFingerprint: completion.lastInputMessageFingerprint
                )
            )
            state = codexLegacyPolicySnapshot(
                root: reduction.snapshot,
                sessionID: sessionID
            )
            switch reduction.qualification {
            case .proceed:
                if reduction.reason == .fallbackNotifyThreadLatched {
                    acceptedReason = "latched_root_thread_from_input_fingerprint"
                    ToasttyLog.debug(
                        "Latched Codex root notify thread",
                        category: .terminal,
                        metadata: codexNotifyMetadata(
                            sessionID: sessionID,
                            record: record,
                            state: state,
                            completion: completion
                        )
                    )
                } else {
                    acceptedReason = "thread_match"
                }

            case .rejectEvent:
                let reason = codexNotifyRejectionReason(reduction.reason)
                logCodexNotifyCompletionDecision(
                    sessionID: sessionID,
                    record: record,
                    state: state,
                    completion: completion,
                    decision: "ignored",
                    reason: reason
                )
                return false
            }
        } else {
            acceptedReason = "unthreaded_completion"
        }

        logCodexNotifyCompletionDecision(
            sessionID: sessionID,
            record: record,
            state: state,
            completion: completion,
            decision: "accepted",
            reason: acceptedReason
        )
        updateStatus(
            sessionID: sessionID,
            status: SessionStatus(kind: .ready, summary: "Ready", detail: completion.detail),
            at: now
        )
        return true
    }

    @discardableResult
    func handleCodexSessionLogCompletion(
        sessionID: String,
        detail: String,
        threadID: String?,
        turnID: String?,
        at now: Date
    ) -> Bool {
        guard let record = sessionRegistry.sessionsByID[sessionID],
              record.agent == .codex,
              record.usesSessionStatusNotifications else {
            logCodexSessionLogCompletionDecision(
                sessionID: sessionID,
                record: sessionRegistry.sessionsByID[sessionID],
                state: codexLegacyPolicySnapshot(sessionID: sessionID),
                threadID: threadID,
                turnID: turnID,
                decision: "ignored",
                reason: "session_not_tracking_codex_status"
            )
            return false
        }

        let state = codexLegacyPolicySnapshot(sessionID: sessionID)
        guard codexStatusTrackingSourceAllowsFallbackEvents(sessionID: sessionID) else {
            logCodexSessionLogCompletionDecision(
                sessionID: sessionID,
                record: record,
                state: state,
                threadID: threadID,
                turnID: turnID,
                decision: "ignored",
                reason: "status_source_hooks"
            )
            return false
        }

        let acceptedReason: String
        if let turnID {
            guard let rootTurnID = state.rootTurnID else {
                logCodexSessionLogCompletionDecision(
                    sessionID: sessionID,
                    record: record,
                    state: state,
                    threadID: threadID,
                    turnID: turnID,
                    decision: "ignored",
                    reason: "missing_root_turn"
                )
                return false
            }
            guard turnID == rootTurnID else {
                logCodexSessionLogCompletionDecision(
                    sessionID: sessionID,
                    record: record,
                    state: state,
                    threadID: threadID,
                    turnID: turnID,
                    decision: "ignored",
                    reason: "turn_mismatch"
                )
                return false
            }
        }

        if let threadID {
            if let rootThreadID = state.rootThreadID {
                guard threadID == rootThreadID else {
                    logCodexSessionLogCompletionDecision(
                        sessionID: sessionID,
                        record: record,
                        state: state,
                        threadID: threadID,
                        turnID: turnID,
                        decision: "ignored",
                        reason: "thread_mismatch"
                    )
                    return false
                }
                acceptedReason = "thread_match"
            } else if let turnID,
                      let rootTurnID = state.rootTurnID,
                      turnID == rootTurnID {
                acceptedReason = "turn_match_without_root_thread"
            } else {
                logCodexSessionLogCompletionDecision(
                    sessionID: sessionID,
                    record: record,
                    state: state,
                    threadID: threadID,
                    turnID: turnID,
                    decision: "ignored",
                    reason: "missing_root_thread"
                )
                return false
            }
        } else if let turnID,
                  let rootTurnID = state.rootTurnID {
            guard turnID == rootTurnID else {
                logCodexSessionLogCompletionDecision(
                    sessionID: sessionID,
                    record: record,
                    state: state,
                    threadID: threadID,
                    turnID: turnID,
                    decision: "ignored",
                    reason: "turn_mismatch"
                )
                return false
            }
            acceptedReason = "turn_match"
        } else {
            acceptedReason = "unidentified_legacy_completion"
        }

        logCodexSessionLogCompletionDecision(
            sessionID: sessionID,
            record: record,
            state: state,
            threadID: threadID,
            turnID: turnID,
            decision: "accepted",
            reason: acceptedReason
        )
        updateStatus(
            sessionID: sessionID,
            status: SessionStatus(kind: .ready, summary: "Ready", detail: detail),
            at: now
        )
        return true
    }

    @discardableResult
    func handleCodexSessionLogApproval(
        sessionID: String,
        detail: String,
        threadID: String?,
        turnID: String?,
        callID: String?,
        approvalID: String?,
        at now: Date
    ) -> Bool {
        guard let record = sessionRegistry.sessionsByID[sessionID],
              record.agent == .codex,
              record.usesSessionStatusNotifications else {
            logCodexSessionLogApprovalDecision(
                sessionID: sessionID,
                record: sessionRegistry.sessionsByID[sessionID],
                state: codexLegacyPolicySnapshot(sessionID: sessionID),
                threadID: threadID,
                turnID: turnID,
                callID: callID,
                approvalID: approvalID,
                decision: "ignored",
                reason: "session_not_tracking_codex_status"
            )
            return false
        }

        var state = codexLegacyPolicySnapshot(sessionID: sessionID)
        let status = SessionStatus(kind: .needsApproval, summary: "Needs approval", detail: detail)
        let event = CodexHookEvent(
            hookEventName: "PermissionRequest",
            callID: callID,
            approvalID: approvalID,
            threadID: threadID ?? state.rootThreadID,
            turnID: turnID ?? state.rootTurnID,
            promptFingerprint: nil,
            status: status,
            nativeSessionID: threadID ?? state.rootThreadID,
            sessionFilePath: nil,
            cwd: nil
        )
        let reduction = reduceCodexApproval(
            sessionID: sessionID,
            request: CodexApprovalRequest(
                source: .sessionLog,
                threadID: event.threadID,
                turnID: event.turnID,
                turnProvenance: turnID == nil ? .rootFallback : .sourceObserved
            ),
            root: state.root
        )
        state = codexLegacyPolicySnapshot(root: state.root, sessionID: sessionID)

        switch reduction.decision {
        case .accept(let reason):
            logCodexSessionLogApprovalDecision(
                sessionID: sessionID,
                record: record,
                state: state,
                threadID: threadID,
                turnID: turnID,
                callID: callID,
                approvalID: approvalID,
                decision: "accepted",
                reason: codexApprovalReason(reason, source: .sessionLog)
            )
            updateStatus(sessionID: sessionID, status: status, at: now)
            return true

        case .suppress(let reason):
            logCodexSessionLogApprovalDecision(
                sessionID: sessionID,
                record: record,
                state: state,
                threadID: threadID,
                turnID: turnID,
                callID: callID,
                approvalID: approvalID,
                decision: "suppressed",
                reason: codexApprovalReason(reason, source: .sessionLog)
            )
            return false

        case .ignore(let reason), .deferForContext(let reason):
            logCodexSessionLogApprovalDecision(
                sessionID: sessionID,
                record: record,
                state: state,
                threadID: threadID,
                turnID: turnID,
                callID: callID,
                approvalID: approvalID,
                decision: "ignored",
                reason: codexApprovalReason(reason, source: .sessionLog)
            )
            return false
        }
    }

    @discardableResult
    func handleCodexHookEvent(
        sessionID: String,
        event: CodexHookEvent,
        at now: Date
    ) -> Bool {
        guard let record = sessionRegistry.sessionsByID[sessionID] else {
            logIgnoredCodexHookCompletionIfNeeded(
                sessionID: sessionID,
                record: nil,
                state: .empty,
                event: event,
                reason: "missing_session_record"
            )
            return false
        }
        guard record.agent == .codex else {
            logIgnoredCodexHookCompletionIfNeeded(
                sessionID: sessionID,
                record: record,
                state: .empty,
                event: event,
                reason: "non_codex_session"
            )
            return false
        }
        guard record.usesSessionStatusNotifications else {
            logIgnoredCodexHookCompletionIfNeeded(
                sessionID: sessionID,
                record: record,
                state: .empty,
                event: event,
                reason: "status_notifications_disabled"
            )
            return false
        }

        let previousState = codexLegacyPolicySnapshot(sessionID: sessionID)
        let reduction = reduceCodexRootTurnObservation(
            sessionID: sessionID,
            observation: .hook(
                kind: codexRootTurnHookKind(event),
                threadID: event.threadID,
                turnID: event.turnID,
                promptFingerprint: event.promptFingerprint
            )
        )
        var state = codexLegacyPolicySnapshot(
            root: reduction.snapshot,
            sessionID: sessionID
        )
        var stateChanged = previousState != state

        guard reduction.qualification == .proceed else {
            logCodexHookEventDecision(
                sessionID: sessionID,
                record: record,
                state: state,
                event: event,
                decision: "ignored",
                reason: codexHookRejectionReason(reduction.reason)
            )
            return false
        }

        if previousState.rootThreadID == nil,
           state.rootThreadID != nil,
           event.canLatchRootHookThread {
            ToasttyLog.debug(
                "Latched Codex root hook thread",
                category: .terminal,
                metadata: codexHookMetadata(
                    sessionID: sessionID,
                    record: record,
                    state: state,
                    event: event
                )
            )
        } else if event.isClearSessionStart,
                  previousState.rootThreadID != state.rootThreadID,
                  previousState.rootThreadID != nil {
            ToasttyLog.debug(
                "Reset Codex root hook thread after clear",
                category: .terminal,
                metadata: codexHookMetadata(
                    sessionID: sessionID,
                    record: record,
                    state: state,
                    event: event
                )
            )
        }

        if let spawnMetadata = event.spawnMetadata,
           let spawnObservation = codexSubagentHookSpawnObservation(spawnMetadata) {
            stateChanged = reduceCodexSubagentObservation(
                sessionID: sessionID,
                observation: spawnObservation,
                at: now
            ) || stateChanged
        }

        if event.isSubagentStart,
           let rawSubagentID = event.subagentID,
           let subagentID = ProviderAgentID(rawSubagentID) {
            let didMutate = reduceCodexSubagentObservation(
                sessionID: sessionID,
                observation: .hookStart(
                    agentID: subagentID,
                    subagentType: event.meaningfulSubagentType
                ),
                at: now
            )
            return stateChanged || didMutate
        }

        if event.isSubagentStop,
           let rawSubagentID = event.subagentID,
           let subagentID = ProviderAgentID(rawSubagentID) {
            let didMutate = reduceCodexSubagentObservation(
                sessionID: sessionID,
                observation: .hookFinish(agentID: subagentID),
                at: now
            )
            return stateChanged || didMutate
        }

        guard let status = event.status else {
            return stateChanged
        }

        if event.isPermissionRequest,
           status.kind == .needsApproval {
            let approvalReduction = reduceCodexApproval(
                sessionID: sessionID,
                request: codexHookApprovalRequest(event),
                root: state.root
            )
            state = codexLegacyPolicySnapshot(root: state.root, sessionID: sessionID)
            switch approvalReduction.decision {
            case .suppress(let reason):
                removePendingCodexHookApproval(sessionID: sessionID)
                logCodexHookEventDecision(
                    sessionID: sessionID,
                    record: record,
                    state: state,
                    event: event,
                    decision: "suppressed",
                    reason: codexApprovalReason(reason, source: .hook)
                )
                return stateChanged

            case .deferForContext(let reason):
                deferCodexHookApproval(
                    sessionID: sessionID,
                    record: record,
                    state: state,
                    event: event,
                    reason: codexApprovalReason(reason, source: .hook)
                )
                return stateChanged

            case .ignore(let reason):
                removePendingCodexHookApproval(sessionID: sessionID)
                logCodexHookEventDecision(
                    sessionID: sessionID,
                    record: record,
                    state: state,
                    event: event,
                    decision: "ignored",
                    reason: codexApprovalReason(reason, source: .hook)
                )
                return stateChanged

            case .accept(let reason):
                removePendingCodexHookApproval(sessionID: sessionID)
                logCodexHookEventDecision(
                    sessionID: sessionID,
                    record: record,
                    state: state,
                    event: event,
                    decision: "accepted",
                    reason: codexApprovalReason(reason, source: .hook)
                )
            }
        } else if status.kind != .needsApproval {
            removePendingCodexHookApprovalIfSuperseded(
                sessionID: sessionID,
                record: record,
                state: state,
                event: event,
                status: status
            )
        }

        if event.isStop {
            logCodexHookEventDecision(
                sessionID: sessionID,
                record: record,
                state: state,
                event: event,
                decision: "accepted",
                reason: codexHookCompletionAcceptedReason(
                    event: event,
                    state: state
                )
            )
        }

        if event.isRootProgressWorking,
           status.kind == .working {
            guard record.isActive else {
                return stateChanged
            }
            if codexStatusTrackingSourceBySessionID[sessionID] != nil {
                let didProject = applyCodexRootProgressObservation(
                    sessionID: sessionID,
                    observation: .hookWorking(summary: status.summary, detail: status.detail),
                    at: now
                )
                return stateChanged || didProject
            }
        }

        updateStatus(sessionID: sessionID, status: status, at: now)
        return true
    }

    @discardableResult
    func handleCodexSubagentRolloutObservation(
        sessionID: String,
        observation: CodexSubagentRolloutObservation,
        at now: Date
    ) -> Bool {
        guard let record = sessionRegistry.activeSession(sessionID: sessionID),
              record.agent == .codex,
              record.usesSessionStatusNotifications,
              codexSubagentReconcilerBySessionID[sessionID] != nil else {
            return false
        }

        if codexStatusTrackingSourceBySessionID[sessionID] == nil {
            return applyLegacyNilSourceCodexSubagentRolloutObservation(
                sessionID: sessionID,
                observation: observation,
                at: now
            )
        }

        let reducerObservation: CodexSubagentObservation
        switch observation {
        case .started(let activity):
            guard activity.kind == .subagent,
                  let activityID = ActivityID(activity.activityID) else {
                return false
            }
            switch activity.turnTransition {
            case .activated:
                reducerObservation = .rolloutTurnActivated(
                    activityID: activityID,
                    providerAgentID: activity.hookActivityID.flatMap { ProviderAgentID($0) },
                    displayName: activity.displayName
                )
            case .deactivated:
                return false
            case nil:
                reducerObservation = .rolloutStart(
                    activityID: activityID,
                    spawnCallID: activity.spawnToolUseID.flatMap { SpawnCallID($0) },
                    providerAgentID: activity.hookActivityID.flatMap { ProviderAgentID($0) },
                    displayName: activity.displayName,
                    command: activity.command
                )
            }

        case .finished(let activity):
            guard activity.kind == .subagent,
                  let activityID = ActivityID(activity.activityID) else {
                return false
            }
            switch activity.turnTransition {
            case .deactivated:
                reducerObservation = .rolloutTurnDeactivated(
                    activityID: activityID,
                    providerAgentID: activity.hookActivityID.flatMap { ProviderAgentID($0) }
                )
            case .activated:
                return false
            case nil:
                reducerObservation = .rolloutFinish(activityID: activityID)
            }

        case .streamReset:
            reducerObservation = .streamReset
        }

        return reduceCodexSubagentObservation(
            sessionID: sessionID,
            observation: reducerObservation,
            at: now
        )
    }

    @discardableResult
    func handleCodexSessionLogRootProgressObservation(
        sessionID: String,
        observation: CodexRootProgressObservation,
        at now: Date
    ) -> Bool {
        applyCodexRootProgressObservation(
            sessionID: sessionID,
            observation: observation,
            at: now
        )
    }

    /// Temporary compatibility for callers that predate fixed Codex status
    /// authority. Historically nil source admitted hooks in the Store while the
    /// planner also projected rollout activity through its fallback path.
    private func applyLegacyNilSourceCodexSubagentRolloutObservation(
        sessionID: String,
        observation: CodexSubagentRolloutObservation,
        at now: Date
    ) -> Bool {
        switch observation {
        case .started(let activity):
            guard activity.kind == .subagent else {
                return false
            }
            return updateBackgroundActivity(
                sessionID: sessionID,
                activity: SessionBackgroundActivity(
                    id: activity.activityID,
                    kind: .subagent,
                    displayName: activity.displayName,
                    command: activity.command,
                    startedAt: now,
                    lastUpdatedAt: now
                ),
                at: now
            )

        case .finished(let activity):
            guard activity.kind == .subagent else {
                return false
            }
            return finishBackgroundActivity(
                sessionID: sessionID,
                activityID: activity.activityID,
                at: now
            )

        case .streamReset:
            return syncBackgroundActivities(
                sessionID: sessionID,
                kind: .subagent,
                entries: [],
                pendingBackgroundTaskCount: 0,
                at: now
            )
        }
    }

    func stopSession(
        sessionID: String,
        reason: ManagedSessionStopReason = .explicit,
        at now: Date
    ) {
        let activeRecord = sessionRegistry.sessionsByID[sessionID].flatMap { $0.isActive ? $0 : nil }
        if let record = activeRecord {
            logSessionStop(record, reason: reason, at: now)
        }
        suppressedCodexVisibleErrorDetailBySessionID.removeValue(forKey: sessionID)
        codexSessionReconciliationBySessionID.removeValue(forKey: sessionID)
        codexStatusTrackingSourceBySessionID.removeValue(forKey: sessionID)
        backgroundActivityFinishTombstonesBySessionID.removeValue(forKey: sessionID)
        codexSubagentReconcilerBySessionID.removeValue(forKey: sessionID)
        removePendingCodexHookApproval(sessionID: sessionID)
        removePendingPanelParentSessionIDs(parentSessionID: sessionID)
        var nextRegistry = sessionRegistry
        if sessionRegistry.sessionsByID[sessionID]?.agent == .processWatch {
            nextRegistry.removeSession(sessionID: sessionID)
        } else {
            nextRegistry.stopSession(sessionID: sessionID, at: now)
        }
        publish(nextRegistry, reason: "stop_session", at: now)
        if let activeRecord {
            clearPersistedResumeRecord(panelID: activeRecord.panelID)
        }
    }

    func stopSessionForPanel(
        panelID: UUID,
        reason: ManagedSessionStopReason = .explicit,
        at now: Date
    ) {
        let activeRecord = sessionRegistry.activeSession(for: panelID)
        if let record = activeRecord {
            logSessionStop(record, reason: reason, at: now)
            suppressedCodexVisibleErrorDetailBySessionID.removeValue(forKey: record.sessionID)
            codexSessionReconciliationBySessionID.removeValue(forKey: record.sessionID)
            codexStatusTrackingSourceBySessionID.removeValue(forKey: record.sessionID)
            backgroundActivityFinishTombstonesBySessionID.removeValue(forKey: record.sessionID)
            codexSubagentReconcilerBySessionID.removeValue(forKey: record.sessionID)
            removePendingCodexHookApproval(sessionID: record.sessionID)
            removePendingPanelParentSessionIDs(parentSessionID: record.sessionID)
        }
        var nextRegistry = sessionRegistry
        if let record = sessionRegistry.activeSession(for: panelID),
           record.agent == .processWatch {
            nextRegistry.removeSession(sessionID: record.sessionID)
        } else {
            nextRegistry.stopSessionForPanel(panelID: panelID, at: now)
        }
        publish(nextRegistry, reason: "stop_session_for_panel", at: now)
        if activeRecord != nil {
            clearPersistedResumeRecord(panelID: panelID)
        }
    }

    func workspaceStatuses(for workspaceID: UUID, at now: Date = Date()) -> [WorkspaceSessionStatus] {
        sessionRegistry.workspaceStatuses(for: workspaceID, at: now)
    }

    func panelStatus(for panelID: UUID, at now: Date = Date()) -> WorkspaceSessionStatus? {
        sessionRegistry.panelStatus(for: panelID, at: now)
    }

    func isLaterFlagged(sessionID: String) -> Bool {
        sessionRegistry.isLaterFlagged(sessionID: sessionID)
    }

    func scope(ofSessionID sessionID: String) -> Set<UUID>? {
        sessionRegistry.scope(ofSessionID: sessionID)
    }

    func effectiveWorkspaceScope(sessionID: String) -> Set<UUID>? {
        sessionRegistry.effectiveWorkspaceScope(sessionID: sessionID)
    }

    func isWorkspaceScoped(sessionID: String) -> Bool {
        sessionRegistry.isWorkspaceScoped(sessionID: sessionID)
    }

    func allowsWorkspaceAutomation(callerSessionID: String?, of workspaceID: UUID) -> Bool {
        sessionRegistry.allowsWorkspaceAutomation(callerSessionID: callerSessionID, of: workspaceID)
    }

    @discardableResult
    func recordPendingPanelParentSessionID(
        parentSessionID: String,
        forPanelID panelID: UUID,
        at now: Date = Date()
    ) -> Bool {
        prunePendingPanelParentSessionIDs(at: now)
        guard let parent = sessionRegistry.activeSession(sessionID: parentSessionID),
              parent.agent != .processWatch,
              parent.panelID != panelID else {
            return false
        }
        pendingPanelParentSessionIDs[panelID] = PendingPanelParentSessionID(
            sessionID: parent.sessionID,
            recordedAt: now
        )
        return true
    }

    func consumePendingPanelParentSessionID(
        forPanelID panelID: UUID,
        at now: Date = Date()
    ) -> String? {
        prunePendingPanelParentSessionIDs(at: now)
        guard let claim = pendingPanelParentSessionIDs[panelID] else {
            return nil
        }
        guard let parent = sessionRegistry.activeSession(sessionID: claim.sessionID),
              parent.agent != .processWatch,
              parent.panelID != panelID else {
            pendingPanelParentSessionIDs.removeValue(forKey: panelID)
            return nil
        }
        pendingPanelParentSessionIDs.removeValue(forKey: panelID)
        return parent.sessionID
    }

    func discardPendingPanelParentSessionID(forPanelID panelID: UUID) {
        pendingPanelParentSessionIDs.removeValue(forKey: panelID)
    }

    @discardableResult
    func setScope(sessionID: String, workspaceIDs: Set<UUID>) -> Bool {
        mutateScope(sessionID: sessionID, reason: "set_scope") { registry in
            registry.setScope(sessionID: sessionID, workspaceIDs: workspaceIDs)
        }
    }

    @discardableResult
    func addScope(sessionID: String, workspaceIDs: Set<UUID>) -> Bool {
        mutateScope(sessionID: sessionID, reason: "add_scope") { registry in
            registry.addScope(sessionID: sessionID, workspaceIDs: workspaceIDs)
        }
    }

    @discardableResult
    func clearScope(sessionID: String) -> Bool {
        mutateScope(sessionID: sessionID, reason: "clear_scope") { registry in
            registry.clearScope(sessionID: sessionID)
        }
    }

    func setLaterFlag(sessionID: String, isFlagged: Bool) {
        var nextRegistry = sessionRegistry
        nextRegistry.setLaterFlag(sessionID: sessionID, isFlagged: isFlagged)
        publish(nextRegistry, reason: "set_later_flag")
    }

    func toggleLaterFlag(sessionID: String) {
        var nextRegistry = sessionRegistry
        nextRegistry.toggleLaterFlag(sessionID: sessionID)
        publish(nextRegistry, reason: "toggle_later_flag")
    }

    @discardableResult
    func toggleLaterFlagForPanel(panelID: UUID) -> Bool {
        guard let sessionID = sessionRegistry.activeSession(for: panelID)?.sessionID else {
            return false
        }
        toggleLaterFlag(sessionID: sessionID)
        return true
    }

    func activePanelIDs(matching kinds: Set<SessionStatusKind>) -> Set<UUID> {
        Set(
            sessionRegistry.activeSessionIDByPanelID.compactMap { panelID, sessionID in
                guard let record = sessionRegistry.sessionsByID[sessionID],
                      record.isActive,
                      let status = sessionRegistry.panelStatus(for: panelID)?.status,
                      kinds.contains(status.kind) else {
                    return nil
                }
                return panelID
            }
        )
    }

    func activeLaterPanelIDs() -> Set<UUID> {
        Set(
            sessionRegistry.activeSessionIDByPanelID.compactMap { panelID, sessionID in
                guard let record = sessionRegistry.sessionsByID[sessionID],
                      record.isActive,
                      record.isFlaggedForLater else {
                    return nil
                }
                return panelID
            }
        )
    }

    func preferredUnreadStatusPanelID(in workspace: WorkspaceState) -> UUID? {
        guard workspace.unreadPanelIDs.isEmpty == false else {
            return nil
        }

        let visiblePanelIDs = Set(workspace.layoutTree.allSlotInfos.map(\.panelID))
        return sessionRegistry.workspaceStatuses(for: workspace.id)
            .filter { status in
                workspace.unreadPanelIDs.contains(status.panelID) &&
                visiblePanelIDs.contains(status.panelID)
            }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.sessionID < rhs.sessionID
            }
            .first?.panelID
    }

    private func synchronize(with state: AppState, now: Date = Date()) {
        var nextRegistry = sessionRegistry

        for record in Array(nextRegistry.sessionsByID.values) where record.isActive {
            guard let location = state.workspaceSelection(containingPanelID: record.panelID) else {
                logSessionStop(record, reason: .panelRemovedFromAppState, at: now)
                suppressedCodexVisibleErrorDetailBySessionID.removeValue(forKey: record.sessionID)
                codexSessionReconciliationBySessionID.removeValue(forKey: record.sessionID)
                codexStatusTrackingSourceBySessionID.removeValue(forKey: record.sessionID)
                backgroundActivityFinishTombstonesBySessionID.removeValue(forKey: record.sessionID)
                codexSubagentReconcilerBySessionID.removeValue(forKey: record.sessionID)
                removePendingCodexHookApproval(sessionID: record.sessionID)
                if record.agent == .processWatch {
                    nextRegistry.removeSession(sessionID: record.sessionID)
                } else {
                    nextRegistry.stopSession(sessionID: record.sessionID, at: now)
                }
                continue
            }
            if record.windowID != location.windowID || record.workspaceID != location.workspaceID {
                nextRegistry.updatePanelLocation(
                    panelID: record.panelID,
                    windowID: location.windowID,
                    workspaceID: location.workspaceID,
                    at: now
                )
            }
        }

        publish(nextRegistry, reason: "synchronize_app_state", at: now)
    }

    private func publish(
        _ nextRegistry: SessionRegistry,
        reason: String,
        at now: Date = Date(),
        force: Bool = false
    ) {
        guard force || nextRegistry != sessionRegistry else { return }
        logWorkspaceStatusSnapshotChanges(
            previousRegistry: sessionRegistry,
            nextRegistry: nextRegistry,
            reason: reason,
            at: now
        )
        sessionRegistry = nextRegistry
        updateBackgroundActivityReaperState()
        updateResumeGraceRepublishState(at: now)
    }

    private func shouldSuppressProjectedWaitingSideEffects(
        sessionID: String,
        status: SessionStatus,
        registry: SessionRegistry
    ) -> Bool {
        guard status.kind == .ready || status.kind == .idle,
              let currentRecord = registry.sessionsByID[sessionID],
              currentRecord.isActive else {
            return false
        }
        return currentRecord.backgroundActivitiesByID.isEmpty == false ||
            currentRecord.pendingBackgroundTaskCount > 0
    }

    private func logProjectedWaitingSuppression(
        previousRecord: SessionRecord?,
        sessionID: String,
        status: SessionStatus,
        now: Date
    ) {
        guard let currentRecord = sessionRegistry.sessionsByID[sessionID] else { return }
        var metadata = sessionStatusTransitionMetadata(
            previousRecord: previousRecord,
            currentRecord: currentRecord,
            status: status,
            now: now
        )
        metadata["reason"] = "projected_waiting_suppression"
        metadata["background_activity_count"] = String(currentRecord.backgroundActivitiesByID.count)
        metadata["pending_background_task_count"] = String(currentRecord.pendingBackgroundTaskCount)
        ToasttyLog.debug(
            "Suppressed managed session actionable status transition",
            category: .terminal,
            metadata: metadata
        )
    }

    private func codexSubagentHookSpawnObservation(
        _ spawnMetadata: CodexSpawnHookMetadata
    ) -> CodexSubagentObservation? {
        guard let rawCallID = normalizedNonEmpty(spawnMetadata.toolUseID),
              let callID = SpawnCallID(rawCallID) else {
            return nil
        }
        let taskName = meaningfulCodexSubagentMetadataText(spawnMetadata.taskName, limit: 80)
        let command = normalizedCodexSubagentMetadataText(spawnMetadata.message, limit: 512)
        guard taskName != nil || command != nil else {
            return nil
        }
        return .hookSpawn(callID: callID, taskName: taskName, command: command)
    }

    private func codexSubagentAuthority(
        for source: CodexStatusTrackingSource
    ) -> CodexSubagentAuthority {
        switch source {
        case .hooks:
            return .hooks
        case .sessionLogFallback:
            return .rolloutFallback
        }
    }

    @discardableResult
    private func reduceCodexSubagentObservation(
        sessionID: String,
        observation: CodexSubagentObservation,
        at now: Date
    ) -> Bool {
        guard var reconciler = codexSubagentReconcilerBySessionID[sessionID] else {
            return false
        }

        let previousReconciler = reconciler
        let reduction = reconciler.reduce(
            observation,
            projection: codexSubagentProjectionSnapshot(sessionID: sessionID),
            now: now
        )
        codexSubagentReconcilerBySessionID[sessionID] = reconciler
        logCodexSubagentDiagnostics(
            reduction.diagnostics,
            sessionID: sessionID,
            authority: reconciler.authority
        )

        var didMutateProjection = false
        for decision in reduction.decisions {
            didMutateProjection = applyCodexSubagentProjectionDecision(
                decision,
                sessionID: sessionID,
                at: now
            ) || didMutateProjection
        }
        return reconciler != previousReconciler || didMutateProjection
    }

    private func codexSubagentProjectionSnapshot(
        sessionID: String
    ) -> CodexSubagentProjectionSnapshot {
        let activeProviderAgentIDs = sessionRegistry
            .activeSession(sessionID: sessionID)?
            .backgroundActivitiesByID
            .values
            .compactMap { activity -> ProviderAgentID? in
                guard activity.kind == .subagent else { return nil }
                return ProviderAgentID(activity.id)
            } ?? []
        return CodexSubagentProjectionSnapshot(
            activeProviderAgentIDs: Set(activeProviderAgentIDs)
        )
    }

    private func applyCodexSubagentProjectionDecision(
        _ decision: CodexSubagentProjectionDecision,
        sessionID: String,
        at now: Date
    ) -> Bool {
        switch decision {
        case .fallbackUpsert(let activityID, let metadata):
            return updateBackgroundActivity(
                sessionID: sessionID,
                activity: SessionBackgroundActivity(
                    id: activityID.rawValue,
                    kind: .subagent,
                    displayName: metadata.displayName,
                    command: metadata.command,
                    startedAt: now,
                    lastUpdatedAt: now
                ),
                at: now
            )

        case .fallbackReopen(let activityID, let metadata):
            return reopenBackgroundActivity(
                sessionID: sessionID,
                activity: SessionBackgroundActivity(
                    id: activityID.rawValue,
                    kind: .subagent,
                    displayName: metadata.displayName,
                    command: metadata.command,
                    startedAt: now,
                    lastUpdatedAt: now
                ),
                at: now
            )

        case .authoritativeHookReopen(let providerAgentID, let display):
            let existingActivity = sessionRegistry
                .activeSession(sessionID: sessionID)?
                .backgroundActivitiesByID[providerAgentID.rawValue]
            let displayName: String
            switch display {
            case .replace(let replacement):
                displayName = replacement
            case .preserveExisting(let defaultValue):
                displayName = existingActivity?.displayName ?? defaultValue
            }
            return reopenBackgroundActivity(
                sessionID: sessionID,
                activity: SessionBackgroundActivity(
                    id: providerAgentID.rawValue,
                    kind: .subagent,
                    displayName: displayName,
                    command: existingActivity?.command,
                    processID: existingActivity?.processID,
                    preserveWhenUnlisted: existingActivity?.preserveWhenUnlisted ?? false,
                    startedAt: existingActivity?.startedAt ?? now,
                    lastUpdatedAt: now
                ),
                at: now
            )

        case .enrichExisting(let providerAgentID, let metadata):
            guard let existingActivity = sessionRegistry
                .activeSession(sessionID: sessionID)?
                .backgroundActivitiesByID[providerAgentID.rawValue],
                  existingActivity.kind == .subagent else {
                return false
            }
            return updateBackgroundActivity(
                sessionID: sessionID,
                activity: SessionBackgroundActivity(
                    id: existingActivity.id,
                    kind: existingActivity.kind,
                    displayName: metadata.displayName,
                    command: metadata.command,
                    processID: existingActivity.processID,
                    preserveWhenUnlisted: existingActivity.preserveWhenUnlisted,
                    startedAt: existingActivity.startedAt,
                    lastUpdatedAt: now
                ),
                at: now
            )

        case .finish(let activityID):
            let rawActivityID: String
            switch activityID {
            case .providerAgent(let providerAgentID):
                rawActivityID = providerAgentID.rawValue
            case .rolloutActivity(let rolloutActivityID):
                rawActivityID = rolloutActivityID.rawValue
            }
            return finishBackgroundActivity(
                sessionID: sessionID,
                activityID: rawActivityID,
                at: now
            )

        case .clearRolloutProjectedActivities:
            return syncBackgroundActivities(
                sessionID: sessionID,
                kind: .subagent,
                entries: [],
                pendingBackgroundTaskCount: 0,
                at: now
            )
        }
    }

    private func logCodexSubagentDiagnostics(
        _ diagnostics: [CodexSubagentDiagnostic],
        sessionID: String,
        authority: CodexSubagentAuthority
    ) {
        for diagnostic in diagnostics {
            var metadata = [
                "session_id": sessionID,
                "authority": codexSubagentAuthorityCode(authority),
            ]
            switch diagnostic {
            case .ignored(let observation, let reason):
                metadata["diagnostic"] = "ignored"
                metadata["observation"] = codexSubagentObservationCode(observation)
                metadata["reason"] = codexSubagentIgnoredReasonCode(reason)
            case .evictedPendingCorrelation(let callID):
                metadata["diagnostic"] = "evicted_pending_correlation"
                metadata["call_id"] = callID.rawValue
            case .evictedResolvedMetadata(let providerAgentID):
                metadata["diagnostic"] = "evicted_resolved_metadata"
                metadata["provider_agent_id"] = providerAgentID.rawValue
            }
            ToasttyLog.debug(
                "Codex subagent reconciliation diagnostic",
                category: .terminal,
                metadata: metadata
            )
        }
    }

    private func codexSubagentAuthorityCode(_ authority: CodexSubagentAuthority) -> String {
        switch authority {
        case .hooks: "hooks"
        case .rolloutFallback: "rollout_fallback"
        }
    }

    private func codexSubagentObservationCode(_ observation: CodexSubagentObservationKind) -> String {
        switch observation {
        case .hookSpawn: "hook_spawn"
        case .hookStart: "hook_start"
        case .hookFinish: "hook_finish"
        case .rolloutStart: "rollout_start"
        case .rolloutFinish: "rollout_finish"
        case .rolloutTurnActivated: "rollout_turn_activated"
        case .rolloutTurnDeactivated: "rollout_turn_deactivated"
        case .streamReset: "stream_reset"
        case .stop: "stop"
        }
    }

    private func codexSubagentIgnoredReasonCode(_ reason: CodexSubagentIgnoredReason) -> String {
        switch reason {
        case .incompatibleWithAuthority: "incompatible_with_authority"
        case .missingExactCorrelationIdentifiers: "missing_exact_correlation_identifiers"
        case .activeFinishTombstone: "active_finish_tombstone"
        }
    }

    private func normalizedCodexSubagentMetadataText(
        _ value: String?,
        limit: Int
    ) -> String? {
        guard let normalized = normalizedNonEmpty(value),
              isLikelyEncryptedCodexAgentPayload(normalized) == false else {
            return nil
        }
        return String(normalized.prefix(limit))
    }

    private func meaningfulCodexSubagentMetadataText(
        _ value: String?,
        limit: Int = 80
    ) -> String? {
        guard let normalized = normalizedCodexSubagentMetadataText(value, limit: limit),
              normalized.caseInsensitiveCompare("default") != .orderedSame else {
            return nil
        }
        return normalized
    }

    private func recordBackgroundActivityFinishTombstone(
        sessionID: String,
        activityID: String,
        at now: Date
    ) {
        pruneBackgroundActivityFinishTombstones(at: now)
        backgroundActivityFinishTombstonesBySessionID[sessionID, default: [:]][activityID] = now
    }

    private func clearBackgroundActivityFinishTombstone(
        sessionID: String,
        activityID: String
    ) {
        backgroundActivityFinishTombstonesBySessionID[sessionID]?.removeValue(forKey: activityID)
        if backgroundActivityFinishTombstonesBySessionID[sessionID]?.isEmpty == true {
            backgroundActivityFinishTombstonesBySessionID.removeValue(forKey: sessionID)
        }
    }

    private func isBackgroundActivityFinishTombstoned(
        sessionID: String,
        activityID: String,
        at now: Date
    ) -> Bool {
        pruneBackgroundActivityFinishTombstones(at: now)
        guard let tombstonedAt = backgroundActivityFinishTombstonesBySessionID[sessionID]?[activityID] else {
            return false
        }
        return now.timeIntervalSince(tombstonedAt) < Self.backgroundActivityFinishTombstoneTTL
    }

    private func pruneBackgroundActivityFinishTombstones(at now: Date) {
        for sessionID in Array(backgroundActivityFinishTombstonesBySessionID.keys) {
            let activeTombstones = backgroundActivityFinishTombstonesBySessionID[sessionID]?.filter { _, tombstonedAt in
                now.timeIntervalSince(tombstonedAt) < Self.backgroundActivityFinishTombstoneTTL
            } ?? [:]
            if activeTombstones.isEmpty {
                backgroundActivityFinishTombstonesBySessionID.removeValue(forKey: sessionID)
            } else {
                backgroundActivityFinishTombstonesBySessionID[sessionID] = activeTombstones
            }
        }
    }

    private func prunePendingPanelParentSessionIDs(at now: Date) {
        pendingPanelParentSessionIDs = pendingPanelParentSessionIDs.filter { _, claim in
            now.timeIntervalSince(claim.recordedAt) < Self.pendingPanelParentSessionIDTTL
        }
    }

    private func removePendingPanelParentSessionIDs(parentSessionID: String) {
        pendingPanelParentSessionIDs = pendingPanelParentSessionIDs.filter { _, claim in
            claim.sessionID != parentSessionID
        }
    }

    private func updateBackgroundActivityReaperState() {
        let hasOutstandingActivity = sessionRegistry.sessionsByID.values.contains { record in
            record.isActive && record.backgroundActivitiesByID.isEmpty == false
        }
        if hasOutstandingActivity {
            scheduleBackgroundActivityReaperIfNeeded()
        } else {
            backgroundActivityReaperTask?.cancel()
            backgroundActivityReaperTask = nil
        }
    }

    private func scheduleBackgroundActivityReaperIfNeeded() {
        guard backgroundActivityReaperTask == nil else { return }
        let interval = backgroundActivityReapIntervalNanoseconds
        backgroundActivityReaperTask = Task { [weak self] in
            while Task.isCancelled == false {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }

                let shouldContinue = await MainActor.run { () -> Bool in
                    guard let self else { return false }
                    self.pruneStaleBackgroundActivities(at: Date())
                    if self.sessionRegistry.sessionsByID.values.contains(where: {
                        $0.isActive && $0.backgroundActivitiesByID.isEmpty == false
                    }) {
                        return true
                    }
                    self.backgroundActivityReaperTask = nil
                    return false
                }
                guard shouldContinue else { return }
            }
        }
    }

    private func updateResumeGraceRepublishState(at now: Date) {
        guard let expiry = earliestResumeGraceExpiry(in: sessionRegistry, at: now) else {
            resumeGraceRepublishTask?.cancel()
            resumeGraceRepublishTask = nil
            resumeGraceRepublishExpiry = nil
            return
        }

        guard resumeGraceRepublishExpiry != expiry else { return }

        resumeGraceRepublishTask?.cancel()
        resumeGraceRepublishExpiry = expiry
        let delay = max(0, expiry.timeIntervalSince(Date()))
        let delayNanoseconds = UInt64(delay * 1_000_000_000)
        resumeGraceRepublishTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }

            await MainActor.run { [weak self] in
                guard let self,
                      self.resumeGraceRepublishExpiry == expiry else {
                    return
                }
                self.resumeGraceRepublishTask = nil
                self.resumeGraceRepublishExpiry = nil
                self.publish(
                    self.sessionRegistry,
                    reason: "resume_grace_expired",
                    at: Date(),
                    force: true
                )
            }
        }
    }

    private func earliestResumeGraceExpiry(
        in registry: SessionRegistry,
        at now: Date
    ) -> Date? {
        registry.sessionsByID.values
            .filter { record in
                guard record.isActive,
                      let lastActivityFinishedAt = record.lastActivityFinishedAt else {
                    return false
                }
                let expiry = lastActivityFinishedAt.addingTimeInterval(SessionRegistry.resumeProjectionGraceInterval)
                return now < expiry && registry.panelStatus(for: record.panelID, at: now)?.projection == .resuming
            }
            .map { record in
                record.lastActivityFinishedAt!.addingTimeInterval(SessionRegistry.resumeProjectionGraceInterval)
            }
            .min()
    }

    private func shouldPruneBackgroundActivity(
        sessionID: String,
        _ activity: SessionBackgroundActivity,
        at now: Date
    ) -> Bool {
        if activity.kind == .subagent,
           activity.processID == nil,
           codexStatusTrackingSourceBySessionID[sessionID] == .hooks {
            // Hook lifecycle is source-authoritative. A long-running subagent
            // may be quiet for hours, so only SubagentStop or session teardown
            // should remove it.
            return false
        }
        let maximumAge = activity.kind == .subagent && activity.processID == nil
            ? Self.maximumPidlessSubagentBackgroundActivityAge
            : maximumBackgroundActivityAge
        guard now.timeIntervalSince(activity.lastUpdatedAt) < maximumAge else {
            return true
        }
        if let processID = activity.processID {
            return Self.processIsRunning(processID) == false
        }
        return false
    }

    private static func processIsRunning(_ processID: Int32) -> Bool {
        guard processID > 0 else { return false }
        let result = Darwin.kill(pid_t(processID), 0)
        if result == 0 {
            return true
        }
        return errno != ESRCH
    }

    private func logWorkspaceStatusSnapshotChanges(
        previousRegistry: SessionRegistry,
        nextRegistry: SessionRegistry,
        reason: String,
        at now: Date
    ) {
        let workspaceIDs = Set(
            previousRegistry.sessionsByID.values.map(\.workspaceID) +
                nextRegistry.sessionsByID.values.map(\.workspaceID)
        )

        for workspaceID in workspaceIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            let previousRows = workspaceStatusDiagnosticRows(
                previousRegistry.workspaceStatuses(for: workspaceID, at: now)
            )
            let nextRows = workspaceStatusDiagnosticRows(
                nextRegistry.workspaceStatuses(for: workspaceID, at: now)
            )
            guard previousRows != nextRows else { continue }

            ToasttyLog.debug(
                "Workspace sidebar session status snapshot changed",
                category: .state,
                metadata: [
                    "source": "session_runtime_store",
                    "reason": reason,
                    "workspace_id": workspaceID.uuidString,
                    "previous_count": String(previousRows.count),
                    "next_count": String(nextRows.count),
                    "previous_rows": workspaceStatusDiagnosticSummary(previousRows),
                    "next_rows": workspaceStatusDiagnosticSummary(nextRows),
                ]
            )
        }
    }

    private func workspaceStatusDiagnosticRows(
        _ statuses: [WorkspaceSessionStatus]
    ) -> [WorkspaceStatusDiagnosticRow] {
        statuses.map { status in
            WorkspaceStatusDiagnosticRow(
                sessionID: status.sessionID,
                panelID: status.panelID,
                agent: status.agent,
                statusKind: status.status.kind,
                projection: status.projection,
                isActive: status.isActive,
                isWorkspaceScoped: status.isWorkspaceScoped
            )
        }
    }

    private func workspaceStatusDiagnosticSummary(
        _ rows: [WorkspaceStatusDiagnosticRow],
        limit: Int = 12
    ) -> String {
        guard rows.isEmpty == false else { return "none" }

        let visibleRows = rows.prefix(limit).map(\.summary)
        let suffix = rows.count > limit ? ["+\(rows.count - limit)"] : []
        return (visibleRows + suffix).joined(separator: ",")
    }

    @discardableResult
    private func mutateScope(
        sessionID: String,
        reason: String,
        _ mutation: (inout SessionRegistry) -> Bool
    ) -> Bool {
        let previousScope = sessionRegistry.scope(ofSessionID: sessionID)
        var nextRegistry = sessionRegistry
        guard mutation(&nextRegistry) else {
            return false
        }
        let nextScope = nextRegistry.scope(ofSessionID: sessionID)
        ToasttyLog.info(
            "Updated managed session workspace scope",
            category: .terminal,
            metadata: [
                "session_id": sessionID,
                "reason": reason,
                "previous_scope": scopeMetadata(previousScope),
                "next_scope": scopeMetadata(nextScope),
            ]
        )
        publish(nextRegistry, reason: reason)
        synchronizePersistedResumeRecordScope(sessionID: sessionID, in: nextRegistry)
        return true
    }

    private func synchronizePersistedResumeRecordScope(sessionID: String, in registry: SessionRegistry) {
        guard let record = registry.activeSession(sessionID: sessionID) else { return }
        updatePersistedResumeRecordScope(
            panelID: record.panelID,
            scopedWorkspaceIDs: record.scopedWorkspaceIDs
        )
    }

    private func updatePersistedResumeRecordScope(
        panelID: UUID,
        scopedWorkspaceIDs: Set<UUID>?
    ) {
        guard let store,
              let selection = store.state.workspaceSelection(containingPanelID: panelID),
              case .terminal(let terminalState)? = selection.workspace.panelState(for: panelID),
              var resumeRecord = terminalState.resumeRecord,
              resumeRecord.scopedWorkspaceIDs != scopedWorkspaceIDs else {
            return
        }

        resumeRecord.scopedWorkspaceIDs = scopedWorkspaceIDs
        _ = store.send(.updateTerminalPanelResumeRecord(panelID: panelID, resumeRecord: resumeRecord))
    }

    private func clearPersistedResumeRecord(panelID: UUID) {
        guard let store,
              let selection = store.state.workspaceSelection(containingPanelID: panelID),
              case .terminal(let terminalState)? = selection.workspace.panelState(for: panelID),
              terminalState.resumeRecord != nil else {
            return
        }

        _ = store.send(.updateTerminalPanelResumeRecord(panelID: panelID, resumeRecord: nil))
    }

    private func scopeMetadata(_ scope: Set<UUID>?) -> String {
        guard let scope else { return "unrestricted" }
        if scope.isEmpty { return "own_workspace_only" }
        return scope
            .map(\.uuidString)
            .sorted()
            .joined(separator: ",")
    }

    private func updateSuppressedCodexVisibleErrorDetailIfNeeded(
        previousRecord: SessionRecord?,
        sessionID: String,
        nextStatus: SessionStatus
    ) {
        guard previousRecord?.agent == .codex else {
            suppressedCodexVisibleErrorDetailBySessionID.removeValue(forKey: sessionID)
            return
        }

        guard let previousStatus = previousRecord?.status else {
            suppressedCodexVisibleErrorDetailBySessionID.removeValue(forKey: sessionID)
            return
        }

        if nextStatus.kind == .error {
            suppressedCodexVisibleErrorDetailBySessionID.removeValue(forKey: sessionID)
            return
        }

        guard previousStatus.kind == .error,
              let previousDetail = normalizedNonEmpty(previousStatus.detail) else {
            return
        }

        suppressedCodexVisibleErrorDetailBySessionID[sessionID] = previousDetail
    }

    private func clearSuppressedCodexVisibleErrorDetail(sessionID: String) {
        suppressedCodexVisibleErrorDetailBySessionID.removeValue(forKey: sessionID)
    }

    private func isSuppressedCodexVisibleError(_ status: SessionStatus, sessionID: String) -> Bool {
        guard let detail = normalizedNonEmpty(status.detail),
              let suppressedDetail = suppressedCodexVisibleErrorDetailBySessionID[sessionID] else {
            return false
        }
        return detail == suppressedDetail
    }

    private func logSessionStop(
        _ record: SessionRecord,
        reason: ManagedSessionStopReason,
        at now: Date
    ) {
        let metadata = sessionStopMetadata(record: record, reason: reason, now: now)
        if reason.isAutomatic {
            ToasttyLog.info(
                "Stopped managed session",
                category: .terminal,
                metadata: metadata
            )
        } else {
            ToasttyLog.debug(
                "Stopped managed session",
                category: .terminal,
                metadata: metadata
            )
        }
    }

    private func sessionStopMetadata(
        record: SessionRecord,
        reason: ManagedSessionStopReason,
        now: Date
    ) -> [String: String] {
        var metadata: [String: String] = [
            "session_id": record.sessionID,
            "agent": record.agent.rawValue,
            "panel_id": record.panelID.uuidString,
            "window_id": record.windowID.uuidString,
            "workspace_id": record.workspaceID.uuidString,
            "status_kind": record.status?.kind.rawValue ?? "none",
            "reason": reason.code,
            "runtime_seconds": String(format: "%.3f", now.timeIntervalSince(record.startedAt)),
        ]

        if let status = record.status {
            if let summary = truncatedLogMetadataValue(status.summary, limit: 80) {
                metadata["last_status_summary"] = summary
            }
            if let detail = truncatedLogMetadataValue(status.detail, limit: 160) {
                metadata["last_status_detail"] = detail
            }
        }

        switch reason {
        case .explicit, .panelRemovedFromAppState:
            break
        case .ghosttyCommandFinished(let exitCode):
            metadata["exit_code"] = exitCode.map(String.init) ?? "none"
        case .idleAtPrompt:
            break
        }

        return metadata
    }

    private func sessionStatusTransitionMetadata(
        previousRecord: SessionRecord?,
        currentRecord: SessionRecord,
        status: SessionStatus,
        now: Date
    ) -> [String: String] {
        var metadata: [String: String] = [
            "session_id": currentRecord.sessionID,
            "agent": currentRecord.agent.rawValue,
            "panel_id": currentRecord.panelID.uuidString,
            "window_id": currentRecord.windowID.uuidString,
            "workspace_id": currentRecord.workspaceID.uuidString,
            "previous_status_kind": previousRecord?.status?.kind.rawValue ?? "none",
            "next_status_kind": status.kind.rawValue,
            "uses_status_notifications": currentRecord.usesSessionStatusNotifications ? "true" : "false",
            "updated_at_epoch_ms": String(Int(now.timeIntervalSince1970 * 1000)),
        ]

        if let summary = truncatedLogMetadataValue(status.summary, limit: 80) {
            metadata["next_status_summary"] = summary
        }
        if let detail = truncatedLogMetadataValue(status.detail, limit: 160) {
            metadata["next_status_detail"] = detail
        }

        return metadata
    }

    private func logCodexNotifyCompletionDecision(
        sessionID: String,
        record: SessionRecord?,
        state: CodexLegacyPolicySnapshot,
        completion: CodexNotifyCompletion,
        decision: String,
        reason: String
    ) {
        ToasttyLog.info(
            "Codex notify completion decision",
            category: .terminal,
            metadata: codexNotifyMetadata(
                sessionID: sessionID,
                record: record,
                state: state,
                completion: completion,
                additional: codexCompletionDecisionMetadata(
                    decision: decision,
                    reason: reason,
                    hasThreadID: completion.threadID != nil,
                    hasTurnID: completion.turnID != nil,
                    rootThreadKnown: state.rootThreadID != nil,
                    rootTurnKnown: state.rootTurnID != nil
                )
            )
        )
    }

    private func logIgnoredCodexHookCompletionIfNeeded(
        sessionID: String,
        record: SessionRecord?,
        state: CodexLegacyPolicySnapshot,
        event: CodexHookEvent,
        reason: String
    ) {
        guard event.isStop else {
            return
        }
        logCodexHookEventDecision(
            sessionID: sessionID,
            record: record,
            state: state,
            event: event,
            decision: "ignored",
            reason: reason
        )
    }

    private func logCodexHookEventDecision(
        sessionID: String,
        record: SessionRecord?,
        state: CodexLegacyPolicySnapshot,
        event: CodexHookEvent,
        decision: String,
        reason: String
    ) {
        ToasttyLog.info(
            event.isStop ? "Codex hook completion decision" : "Codex hook event decision",
            category: .terminal,
            metadata: codexHookMetadata(
                sessionID: sessionID,
                record: record,
                state: state,
                event: event,
                additional: codexCompletionDecisionMetadata(
                    decision: decision,
                    reason: reason,
                    hasThreadID: event.threadID != nil,
                    hasTurnID: event.turnID != nil,
                    rootThreadKnown: state.rootThreadID != nil,
                    rootTurnKnown: state.rootTurnID != nil
                )
            )
        )
    }

    private func logCodexSessionLogCompletionDecision(
        sessionID: String,
        record: SessionRecord?,
        state: CodexLegacyPolicySnapshot,
        threadID: String?,
        turnID: String?,
        decision: String,
        reason: String
    ) {
        ToasttyLog.info(
            "Codex session log completion decision",
            category: .terminal,
            metadata: codexSessionLogCompletionMetadata(
                sessionID: sessionID,
                record: record,
                state: state,
                threadID: threadID,
                turnID: turnID,
                additional: codexCompletionDecisionMetadata(
                    decision: decision,
                    reason: reason,
                    hasThreadID: threadID != nil,
                    hasTurnID: turnID != nil,
                    rootThreadKnown: state.rootThreadID != nil,
                    rootTurnKnown: state.rootTurnID != nil
                )
            )
        )
    }

    private func logCodexSessionLogApprovalDecision(
        sessionID: String,
        record: SessionRecord?,
        state: CodexLegacyPolicySnapshot,
        threadID: String?,
        turnID: String?,
        callID: String?,
        approvalID: String?,
        decision: String,
        reason: String
    ) {
        let event = CodexHookEvent(
            hookEventName: "PermissionRequest",
            callID: callID,
            approvalID: approvalID,
            threadID: threadID,
            turnID: turnID,
            promptFingerprint: nil,
            status: SessionStatus(kind: .needsApproval, summary: "Needs approval"),
            nativeSessionID: threadID,
            sessionFilePath: nil,
            cwd: nil
        )
        ToasttyLog.info(
            "Codex session log approval decision",
            category: .terminal,
            metadata: codexHookMetadata(
                sessionID: sessionID,
                record: record,
                state: state,
                event: event,
                additional: codexCompletionDecisionMetadata(
                    decision: decision,
                    reason: reason,
                    hasThreadID: threadID != nil,
                    hasTurnID: turnID != nil,
                    rootThreadKnown: state.rootThreadID != nil,
                    rootTurnKnown: state.rootTurnID != nil
                )
            )
        )
    }

    private func codexStatusTrackingSourceAllowsFallbackEvents(sessionID: String) -> Bool {
        guard let source = codexStatusTrackingSourceBySessionID[sessionID] else {
            return true
        }
        switch source {
        case .hooks:
            return false
        case .sessionLogFallback:
            return true
        }
    }

    private func codexStatusTrackingSourceMetadata(sessionID: String) -> String {
        codexStatusTrackingSourceBySessionID[sessionID]?.code ?? "unspecified"
    }

    @discardableResult
    private func applyCodexRootProgressObservation(
        sessionID: String,
        observation: CodexRootProgressObservation,
        at now: Date
    ) -> Bool {
        guard let source = codexStatusTrackingSourceBySessionID[sessionID],
              let record = sessionRegistry.activeSession(sessionID: sessionID),
              record.agent == .codex,
              record.usesSessionStatusNotifications else {
            return false
        }

        let decision = CodexRootProgressEvaluator.evaluate(
            authority: codexRootProgressAuthority(for: source),
            currentRegistryKind: codexRootProgressRegistryKind(for: record.status?.kind),
            observation: observation
        )
        switch decision {
        case .projectWorking(let summary, let detail):
            updateStatus(
                sessionID: sessionID,
                status: SessionStatus(kind: .working, summary: summary, detail: detail),
                at: now
            )
            return true

        case .projectIdle(let detail):
            updateStatus(
                sessionID: sessionID,
                status: SessionStatus(kind: .idle, summary: "Waiting", detail: detail),
                at: now
            )
            return true

        case .ignored:
            return false
        }
    }

    private func codexRootProgressAuthority(
        for source: CodexStatusTrackingSource
    ) -> CodexRootProgressAuthority {
        switch source {
        case .hooks:
            return .hooks
        case .sessionLogFallback:
            return .sessionLogFallback
        }
    }

    private func codexRootProgressRegistryKind(
        for kind: SessionStatusKind?
    ) -> CodexRootProgressRegistryKind {
        switch kind {
        case nil:
            return .none
        case .idle:
            return .idle
        case .working:
            return .working
        case .needsApproval:
            return .needsApproval
        case .ready:
            return .ready
        case .error:
            return .error
        }
    }

    private func codexSessionReconciliationRuntime(
        sessionID: String
    ) -> CodexSessionReconciliationRuntime {
        if let runtime = codexSessionReconciliationBySessionID[sessionID] {
            return runtime
        }
        let rootTurnAuthority: CodexRootTurnAuthority
        let approvalAuthority: CodexApprovalAuthority
        switch codexStatusTrackingSourceBySessionID[sessionID] {
        case .hooks:
            rootTurnAuthority = .hooks
            approvalAuthority = .hooks
        case .sessionLogFallback:
            rootTurnAuthority = .sessionLogFallback
            approvalAuthority = .sessionLogFallback
        case nil:
            rootTurnAuthority = .legacyPermissive
            approvalAuthority = .legacyPermissive
        }
        return CodexSessionReconciliationRuntime(
            rootTurn: CodexRootTurnReconciler(authority: rootTurnAuthority),
            approval: CodexApprovalReconciler(authority: approvalAuthority)
        )
    }

    private func codexLegacyPolicySnapshot(
        sessionID: String
    ) -> CodexLegacyPolicySnapshot {
        guard let runtime = codexSessionReconciliationBySessionID[sessionID] else {
            return .empty
        }
        return runtime.legacyPolicySnapshot
    }

    private func codexLegacyPolicySnapshot(
        root: CodexRootTurnSnapshot,
        sessionID: String
    ) -> CodexLegacyPolicySnapshot {
        CodexLegacyPolicySnapshot(
            root: root,
            autoReviewedPermissionTurnIDs: codexSessionReconciliationBySessionID[sessionID]?
                .approval.snapshot.autoReviewedTurnIDs ?? []
        )
    }

    private func reduceCodexRootTurnObservation(
        sessionID: String,
        observation: CodexRootTurnObservation
    ) -> CodexRootTurnReduction {
        var runtime = codexSessionReconciliationRuntime(sessionID: sessionID)
        let reduction = runtime.rootTurn.reduce(observation)
        guard reduction.qualification == .proceed else {
            return reduction
        }
        if reduction.shouldResetApprovalHistory {
            runtime.approval.resetTurnHistory()
        }
        codexSessionReconciliationBySessionID[sessionID] = runtime
        return reduction
    }

    private func reduceCodexApproval(
        sessionID: String,
        request: CodexApprovalRequest,
        root: CodexRootTurnSnapshot
    ) -> CodexApprovalReduction {
        var runtime = codexSessionReconciliationRuntime(sessionID: sessionID)
        let reduction = runtime.approval.reduce(request, root: root)
        if reduction.didMutateHistory {
            codexSessionReconciliationBySessionID[sessionID] = runtime
        }
        return reduction
    }

    private func codexHookApprovalRequest(
        _ event: CodexHookEvent
    ) -> CodexApprovalRequest {
        CodexApprovalRequest(
            source: .hook,
            threadID: event.threadID,
            turnID: event.turnID,
            turnProvenance: .sourceObserved
        )
    }

    private func codexRootTurnHookKind(
        _ event: CodexHookEvent
    ) -> CodexRootTurnHookKind {
        if event.hookEventName == "SessionStart" {
            return .sessionStart(isClear: event.isClearSessionStart)
        }
        if event.isUserPromptSubmit {
            return .userPromptSubmit
        }
        if event.isStop {
            return .stop
        }
        return .other
    }

    private func codexHookRejectionReason(
        _ reason: CodexRootTurnReductionReason
    ) -> String {
        switch reason {
        case .incompatibleWithAuthority:
            return "status_source_session_log_fallback"
        case .threadMismatch:
            return "thread_mismatch"
        case .missingRootThread:
            return "missing_root_thread"
        case .turnMismatch:
            return "turn_mismatch"
        default:
            return "root_turn_\(String(describing: reason))"
        }
    }

    private func codexNotifyRejectionReason(
        _ reason: CodexRootTurnReductionReason
    ) -> String {
        switch reason {
        case .threadMismatch:
            return "thread_mismatch"
        case .missingRootInputFingerprint:
            return "missing_root_input_fingerprint"
        case .missingNotifyInputFingerprint:
            return "missing_notify_input_fingerprint"
        case .inputFingerprintMismatch:
            return "input_fingerprint_mismatch"
        case .incompatibleWithAuthority:
            return "status_source_hooks"
        default:
            return "root_turn_\(String(describing: reason))"
        }
    }

    private func codexApprovalReason(
        _ reason: CodexApprovalReason,
        source: CodexApprovalSource
    ) -> String {
        switch reason {
        case .incompatibleWithAuthority:
            switch source {
            case .hook:
                return "status_source_session_log_fallback"
            case .sessionLog:
                return "status_source_hooks"
            }
        case .missingRequestThread:
            return "missing_hook_thread"
        case .missingRootThread:
            return "missing_root_thread"
        case .threadMismatch:
            return "thread_mismatch"
        case .missingRequestTurn:
            return "missing_hook_turn"
        case .missingRootTurn:
            return "missing_root_turn"
        case .autoReviewedStaleTurn:
            return "auto_reviewed_stale_turn"
        case .autoReviewContextTurnMismatch:
            return "auto_review_context_turn_mismatch"
        case .turnMismatch:
            return "turn_mismatch"
        case .awaitingRootTurnContext:
            return "awaiting_root_turn_context"
        case .missingApprovalContext:
            return "missing_approval_context"
        case .unknownApprovalsReviewer:
            return "unknown_approvals_reviewer"
        case .missingHumanApprovalPolicy:
            return "missing_human_approval_policy"
        case .missingApprovalsReviewer:
            return "missing_approvals_reviewer"
        case .autoReviewApproval:
            return "auto_review_approval"
        }
    }

    private func deferCodexHookApproval(
        sessionID: String,
        record: SessionRecord,
        state: CodexLegacyPolicySnapshot,
        event: CodexHookEvent,
        reason: String
    ) {
        let token = UUID()
        removePendingCodexHookApproval(sessionID: sessionID)
        pendingCodexHookApprovalBySessionID[sessionID] = PendingCodexHookApproval(
            event: event,
            token: token
        )
        logCodexHookEventDecision(
            sessionID: sessionID,
            record: record,
            state: state,
            event: event,
            decision: "deferred",
            reason: reason
        )

        let delay = codexHookApprovalDeferralNanoseconds
        pendingCodexHookApprovalTaskBySessionID[sessionID] = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            await self?.expirePendingCodexHookApproval(sessionID: sessionID, token: token)
        }
    }

    private func expirePendingCodexHookApproval(sessionID: String, token: UUID) {
        guard let pending = pendingCodexHookApprovalBySessionID[sessionID],
              pending.token == token else {
            return
        }
        guard let record = sessionRegistry.sessionsByID[sessionID],
              let status = pending.event.status else {
            removePendingCodexHookApproval(sessionID: sessionID)
            return
        }

        var state = codexLegacyPolicySnapshot(sessionID: sessionID)
        let reduction = reduceCodexApproval(
            sessionID: sessionID,
            request: codexHookApprovalRequest(pending.event),
            root: state.root
        )
        state = codexLegacyPolicySnapshot(root: state.root, sessionID: sessionID)
        switch reduction.decision {
        case .suppress(let reason):
            removePendingCodexHookApproval(sessionID: sessionID)
            logCodexHookEventDecision(
                sessionID: sessionID,
                record: record,
                state: state,
                event: pending.event,
                decision: "suppressed",
                reason: codexApprovalReason(reason, source: .hook)
            )

        case .ignore(let reason):
            removePendingCodexHookApproval(sessionID: sessionID)
            logCodexHookEventDecision(
                sessionID: sessionID,
                record: record,
                state: state,
                event: pending.event,
                decision: "ignored",
                reason: codexApprovalReason(reason, source: .hook)
            )

        case .accept(let reason):
            removePendingCodexHookApproval(sessionID: sessionID)
            logCodexHookEventDecision(
                sessionID: sessionID,
                record: record,
                state: state,
                event: pending.event,
                decision: "accepted",
                reason: codexApprovalReason(reason, source: .hook)
            )
            updateStatus(sessionID: sessionID, status: status, at: Date())

        case .deferForContext(let reason):
            removePendingCodexHookApproval(sessionID: sessionID)
            logCodexHookEventDecision(
                sessionID: sessionID,
                record: record,
                state: state,
                event: pending.event,
                decision: "ignored",
                reason: "context_timeout_\(codexApprovalReason(reason, source: .hook))"
            )
        }
    }

    private func resolvePendingCodexHookApprovalIfPossible(
        sessionID: String,
        record: SessionRecord,
        state: CodexLegacyPolicySnapshot,
        reasonPrefix: String
    ) {
        guard let pending = pendingCodexHookApprovalBySessionID[sessionID],
              let status = pending.event.status else {
            return
        }

        var state = state
        let reduction = reduceCodexApproval(
            sessionID: sessionID,
            request: codexHookApprovalRequest(pending.event),
            root: state.root
        )
        state = codexLegacyPolicySnapshot(root: state.root, sessionID: sessionID)
        switch reduction.decision {
        case .deferForContext:
            return

        case .suppress(let reason):
            removePendingCodexHookApproval(sessionID: sessionID)
            logCodexHookEventDecision(
                sessionID: sessionID,
                record: record,
                state: state,
                event: pending.event,
                decision: "suppressed",
                reason: codexApprovalReason(reason, source: .hook)
            )

        case .ignore(let reason):
            removePendingCodexHookApproval(sessionID: sessionID)
            logCodexHookEventDecision(
                sessionID: sessionID,
                record: record,
                state: state,
                event: pending.event,
                decision: "ignored",
                reason: "\(reasonPrefix)_\(codexApprovalReason(reason, source: .hook))"
            )

        case .accept(let reason):
            removePendingCodexHookApproval(sessionID: sessionID)
            logCodexHookEventDecision(
                sessionID: sessionID,
                record: record,
                state: state,
                event: pending.event,
                decision: "accepted",
                reason: "\(reasonPrefix)_\(codexApprovalReason(reason, source: .hook))"
            )
            updateStatus(sessionID: sessionID, status: status, at: Date())
        }
    }

    private func removePendingCodexHookApprovalIfSuperseded(
        sessionID: String,
        record: SessionRecord,
        state: CodexLegacyPolicySnapshot,
        event: CodexHookEvent,
        status: SessionStatus
    ) {
        guard let pending = pendingCodexHookApprovalBySessionID[sessionID],
              CodexApprovalSupersession.shouldSupersede(
                  pending: CodexApprovalCorrelation(
                      threadID: pending.event.threadID,
                      turnID: pending.event.turnID
                  ),
                  incoming: CodexApprovalCorrelation(
                      threadID: event.threadID,
                      turnID: event.turnID
                  )
              ) else {
            return
        }
        removePendingCodexHookApproval(sessionID: sessionID)
        logCodexHookEventDecision(
            sessionID: sessionID,
            record: record,
            state: state,
            event: pending.event,
            decision: "ignored",
            reason: "superseded_by_\(status.kind.rawValue)"
        )
    }

    private func removePendingCodexHookApproval(sessionID: String) {
        pendingCodexHookApprovalBySessionID.removeValue(forKey: sessionID)
        pendingCodexHookApprovalTaskBySessionID.removeValue(forKey: sessionID)?.cancel()
    }

    private func removeAllPendingCodexHookApprovals() {
        pendingCodexHookApprovalBySessionID.removeAll()
        for task in pendingCodexHookApprovalTaskBySessionID.values {
            task.cancel()
        }
        pendingCodexHookApprovalTaskBySessionID.removeAll()
    }

    private func codexHookCompletionAcceptedReason(
        event: CodexHookEvent,
        state: CodexLegacyPolicySnapshot
    ) -> String {
        if let threadID = event.threadID,
           let rootThreadID = state.rootThreadID,
           threadID == rootThreadID {
            return "thread_match"
        }
        if event.threadID == nil,
           let turnID = event.turnID,
           let rootTurnID = state.rootTurnID,
           turnID == rootTurnID {
            return "turn_match"
        }
        if event.threadID == nil,
           event.turnID == nil {
            return "unidentified_legacy_stop"
        }
        if event.threadID != nil,
           state.rootThreadID == nil,
           event.canLatchRootHookThread == false {
            return "matching_root_turn_without_latched_thread"
        }
        return "status_accepted"
    }

    private func codexCompletionDecisionMetadata(
        decision: String,
        reason: String,
        hasThreadID: Bool,
        hasTurnID: Bool,
        rootThreadKnown: Bool,
        rootTurnKnown: Bool
    ) -> [String: String] {
        [
            "decision": decision,
            "decision_reason": reason,
            "reason": reason,
            "has_thread_id": boolMetadata(hasThreadID),
            "has_turn_id": boolMetadata(hasTurnID),
            "root_thread_known": boolMetadata(rootThreadKnown),
            "root_turn_known": boolMetadata(rootTurnKnown),
        ]
    }

    private func codexHookMetadata(
        sessionID: String,
        record: SessionRecord?,
        state: CodexLegacyPolicySnapshot,
        event: CodexHookEvent,
        additional: [String: String] = [:]
    ) -> [String: String] {
        var metadata: [String: String] = [
            "session_id": sessionID,
            "agent": record?.agent.rawValue ?? "none",
            "panel_id": record?.panelID.uuidString ?? "none",
            "window_id": record?.windowID.uuidString ?? "none",
            "workspace_id": record?.workspaceID.uuidString ?? "none",
            "completion_source": "codex-hooks",
            "status_tracking_source": codexStatusTrackingSourceMetadata(sessionID: sessionID),
            "event_name": event.hookEventName,
            "hook_event_name": event.hookEventName,
            "hook_source": event.source ?? "none",
            "previous_status_kind": record?.status?.kind.rawValue ?? "none",
            "root_thread_id": state.rootThreadID ?? "none",
            "root_turn_id": state.rootTurnID ?? "none",
            "root_turn_input_fingerprint": truncatedFingerprint(state.rootTurnInputFingerprint),
            "root_turn_awaiting_session_log_context": boolMetadata(state.rootTurnAwaitingSessionLogContext),
            "auto_reviewed_permission_turn_count": "\(state.autoReviewedPermissionTurnIDs.count)",
            "hook_turn_was_auto_reviewed": boolMetadata(event.turnID.map {
                state.autoReviewedPermissionTurnIDs.contains($0)
            } ?? false),
            "approval_context_known": boolMetadata(state.approvalContextKnown),
            "approval_policy": state.approvalPolicy.metadataValue,
            "approvals_reviewer": state.approvalsReviewer.metadataValue,
            "hook_thread_id": event.threadID ?? "none",
            "hook_turn_id": event.turnID ?? "none",
            "hook_permission_mode": event.permissionMode ?? "none",
            "hook_tool_use_id": event.toolUseID ?? "none",
            "hook_call_id": event.callID ?? "none",
            "hook_approval_id": event.approvalID ?? "none",
            "has_thread_id": boolMetadata(event.threadID != nil),
            "has_turn_id": boolMetadata(event.turnID != nil),
            "root_thread_known": boolMetadata(state.rootThreadID != nil),
            "root_turn_known": boolMetadata(state.rootTurnID != nil),
            "pending_input_fingerprint": truncatedFingerprint(state.pendingRootInputFingerprint),
            "pending_root_approval_context_known": boolMetadata(state.pendingRootApprovalContext != nil),
            "pending_root_approval_policy": state.pendingRootApprovalContext?.approvalPolicy.metadataValue ?? "none",
            "pending_root_approvals_reviewer": state.pendingRootApprovalContext?.approvalsReviewer.metadataValue ?? "none",
            "active_turn_approval_context_known": boolMetadata(state.activeTurnApprovalContext != nil),
            "active_turn_approval_policy": state.activeTurnApprovalContext?.approvalPolicy.metadataValue ?? "none",
            "active_turn_approvals_reviewer": state.activeTurnApprovalContext?.approvalsReviewer.metadataValue ?? "none",
            "hook_input_fingerprint": truncatedFingerprint(event.promptFingerprint),
        ]

        if let status = event.status {
            metadata["hook_status_kind"] = status.kind.rawValue
        }

        for (key, value) in additional {
            metadata[key] = value
        }

        return metadata
    }

    private func codexSessionLogCompletionMetadata(
        sessionID: String,
        record: SessionRecord?,
        state: CodexLegacyPolicySnapshot,
        threadID: String?,
        turnID: String?,
        additional: [String: String] = [:]
    ) -> [String: String] {
        var metadata: [String: String] = [
            "session_id": sessionID,
            "agent": record?.agent.rawValue ?? "none",
            "panel_id": record?.panelID.uuidString ?? "none",
            "window_id": record?.windowID.uuidString ?? "none",
            "workspace_id": record?.workspaceID.uuidString ?? "none",
            "completion_source": "codex-session-log",
            "status_tracking_source": codexStatusTrackingSourceMetadata(sessionID: sessionID),
            "event_name": "task_complete",
            "previous_status_kind": record?.status?.kind.rawValue ?? "none",
            "root_thread_id": state.rootThreadID ?? "none",
            "root_turn_id": state.rootTurnID ?? "none",
            "root_turn_input_fingerprint": truncatedFingerprint(state.rootTurnInputFingerprint),
            "root_turn_awaiting_session_log_context": boolMetadata(state.rootTurnAwaitingSessionLogContext),
            "approval_context_known": boolMetadata(state.approvalContextKnown),
            "approval_policy": state.approvalPolicy.metadataValue,
            "approvals_reviewer": state.approvalsReviewer.metadataValue,
            "session_log_thread_id": threadID ?? "none",
            "session_log_turn_id": turnID ?? "none",
            "has_thread_id": boolMetadata(threadID != nil),
            "has_turn_id": boolMetadata(turnID != nil),
            "root_thread_known": boolMetadata(state.rootThreadID != nil),
            "root_turn_known": boolMetadata(state.rootTurnID != nil),
            "pending_input_fingerprint": truncatedFingerprint(state.pendingRootInputFingerprint),
            "pending_root_approval_context_known": boolMetadata(state.pendingRootApprovalContext != nil),
            "pending_root_approval_policy": state.pendingRootApprovalContext?.approvalPolicy.metadataValue ?? "none",
            "pending_root_approvals_reviewer": state.pendingRootApprovalContext?.approvalsReviewer.metadataValue ?? "none",
            "active_turn_approval_context_known": boolMetadata(state.activeTurnApprovalContext != nil),
            "active_turn_approval_policy": state.activeTurnApprovalContext?.approvalPolicy.metadataValue ?? "none",
            "active_turn_approvals_reviewer": state.activeTurnApprovalContext?.approvalsReviewer.metadataValue ?? "none",
        ]

        for (key, value) in additional {
            metadata[key] = value
        }

        return metadata
    }

    private func codexNotifyMetadata(
        sessionID: String,
        record: SessionRecord?,
        state: CodexLegacyPolicySnapshot,
        completion: CodexNotifyCompletion? = nil,
        additional: [String: String] = [:]
    ) -> [String: String] {
        var metadata: [String: String] = [
            "session_id": sessionID,
            "agent": record?.agent.rawValue ?? "none",
            "panel_id": record?.panelID.uuidString ?? "none",
            "window_id": record?.windowID.uuidString ?? "none",
            "workspace_id": record?.workspaceID.uuidString ?? "none",
            "completion_source": "codex-notify",
            "status_tracking_source": codexStatusTrackingSourceMetadata(sessionID: sessionID),
            "event_name": "notify_completion",
            "previous_status_kind": record?.status?.kind.rawValue ?? "none",
            "root_thread_id": state.rootThreadID ?? "none",
            "root_turn_id": state.rootTurnID ?? "none",
            "root_turn_input_fingerprint": truncatedFingerprint(state.rootTurnInputFingerprint),
            "root_turn_awaiting_session_log_context": boolMetadata(state.rootTurnAwaitingSessionLogContext),
            "approval_context_known": boolMetadata(state.approvalContextKnown),
            "approval_policy": state.approvalPolicy.metadataValue,
            "approvals_reviewer": state.approvalsReviewer.metadataValue,
            "root_thread_known": boolMetadata(state.rootThreadID != nil),
            "root_turn_known": boolMetadata(state.rootTurnID != nil),
            "pending_input_fingerprint": truncatedFingerprint(state.pendingRootInputFingerprint),
            "pending_root_approval_context_known": boolMetadata(state.pendingRootApprovalContext != nil),
            "pending_root_approval_policy": state.pendingRootApprovalContext?.approvalPolicy.metadataValue ?? "none",
            "pending_root_approvals_reviewer": state.pendingRootApprovalContext?.approvalsReviewer.metadataValue ?? "none",
            "active_turn_approval_context_known": boolMetadata(state.activeTurnApprovalContext != nil),
            "active_turn_approval_policy": state.activeTurnApprovalContext?.approvalPolicy.metadataValue ?? "none",
            "active_turn_approvals_reviewer": state.activeTurnApprovalContext?.approvalsReviewer.metadataValue ?? "none",
        ]

        if let completion {
            metadata["notify_type"] = completion.notificationType
            metadata["notify_thread_id"] = completion.threadID ?? "none"
            metadata["notify_turn_id"] = completion.turnID ?? "none"
            metadata["has_thread_id"] = boolMetadata(completion.threadID != nil)
            metadata["has_turn_id"] = boolMetadata(completion.turnID != nil)
            metadata["notify_input_fingerprint"] = truncatedFingerprint(completion.lastInputMessageFingerprint)
            metadata["notify_input_message_count"] = String(completion.inputMessageCount)
        }

        for (key, value) in additional {
            metadata[key] = value
        }

        return metadata
    }

    private func boolMetadata(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    private func truncatedFingerprint(_ fingerprint: String?) -> String {
        guard let fingerprint, fingerprint.isEmpty == false else {
            return "none"
        }
        return String(fingerprint.prefix(16))
    }

    private func backgroundActivityMetadata(
        sessionID: String,
        activityID: String? = nil,
        activity: SessionBackgroundActivity?,
        phase: SessionBackgroundActivityPhase
    ) -> [String: String] {
        let record = sessionRegistry.sessionsByID[sessionID]
        return [
            "session_id": sessionID,
            "agent": record?.agent.rawValue ?? "none",
            "panel_id": record?.panelID.uuidString ?? "none",
            "workspace_id": record?.workspaceID.uuidString ?? "none",
            "phase": phase.rawValue,
            "activity_id": activity?.id ?? activityID ?? "none",
            "activity_kind": activity?.kind.rawValue ?? "none",
            "display_name": activity?.displayName ?? "none",
            "has_command": boolMetadata(activity?.command != nil),
            "process_id": activity?.processID.map(String.init) ?? "none",
        ]
    }

    private func sessionStartMetadata(
        sessionID: String,
        agent: AgentKind,
        panelID: UUID,
        windowID: UUID,
        workspaceID: UUID,
        parentSessionID: String?,
        usesSessionStatusNotifications: Bool,
        displayTitleOverride: String?,
        scopedWorkspaceIDs: Set<UUID>?
    ) -> [String: String] {
        var metadata = [
            "session_id": sessionID,
            "agent": agent.rawValue,
            "panel_id": panelID.uuidString,
            "window_id": windowID.uuidString,
            "workspace_id": workspaceID.uuidString,
            "parent_session_id": parentSessionID ?? "none",
            "uses_status_notifications": usesSessionStatusNotifications ? "true" : "false",
            "workspace_scope": scopeMetadata(scopedWorkspaceIDs),
        ]
        if let displayTitleOverride = truncatedLogMetadataValue(displayTitleOverride, limit: 80) {
            metadata["display_title_override"] = displayTitleOverride
        }
        return metadata
    }

    private func clearLaterFlagForMeaningfulSessionAdvanceIfNeeded(
        previousRecord: SessionRecord?,
        sessionID: String,
        nextStatus: SessionStatus,
        registry: inout SessionRegistry
    ) {
        guard previousRecord?.isFlaggedForLater == true else {
            return
        }
        guard shouldClearLaterFlag(
            previousKind: previousRecord?.status?.kind,
            nextKind: nextStatus.kind
        ) else {
            return
        }
        registry.setLaterFlag(sessionID: sessionID, isFlagged: false)
    }

    private func handleActionableStatusTransitionIfNeeded(
        previousRecord: SessionRecord?,
        previousProjectedStatus: SessionStatus?,
        sessionID: String,
        status: SessionStatus
    ) {
        guard let store else { return }
        guard isActionableStatusKind(status.kind) else {
            return
        }
        let previousEffectiveKind = previousProjectedStatus?.kind ?? previousRecord?.status?.kind
        guard previousEffectiveKind != status.kind else {
            return
        }
        guard let currentRecord = sessionRegistry.sessionsByID[sessionID],
              currentRecord.isActive else {
            return
        }
        guard !isActionableStatusTransitionSuppressed(for: currentRecord, state: store.state) else {
            return
        }

        _ = store.send(
            .recordDesktopNotification(
                workspaceID: currentRecord.workspaceID,
                panelID: currentRecord.panelID
            )
        )

        guard currentRecord.usesSessionStatusNotifications else {
            return
        }

        let notificationContext = desktopNotificationContext(for: currentRecord, state: store.state)
        let title = notificationTitle(for: currentRecord, status: status)
        let body = notificationBody(for: currentRecord, status: status)
        let workspaceID = currentRecord.workspaceID
        let panelID = currentRecord.panelID
        Task {
            await sendSessionStatusNotification(
                title,
                body,
                workspaceID,
                panelID,
                notificationContext
            )
        }
    }

    private func collapseReadyStatusAfterReadIfNeeded(
        action: AppAction,
        previousState: AppState,
        nextState: AppState,
        now: Date = Date()
    ) {
        guard let readContext = readTransitionContext(
            for: action,
            previousState: previousState,
            nextState: nextState
        ),
        let record = sessionRegistry.activeSession(for: readContext.panelID),
        record.workspaceID == readContext.workspaceID,
        let status = record.status else {
            return
        }

        if record.agent == .processWatch,
           status.kind == .ready || status.kind == .error {
            stopSession(sessionID: record.sessionID, at: now)
            return
        }

        guard status.kind == .ready else {
            return
        }

        updateStatus(
            sessionID: record.sessionID,
            status: collapsedReadyStatus(from: status),
            at: now
        )
    }

    private func readTransitionContext(
        for action: AppAction,
        previousState: AppState,
        nextState: AppState
    ) -> (workspaceID: UUID, panelID: UUID)? {
        let workspaceID: UUID
        let panelID: UUID
        switch action {
        case .focusPanel(let readWorkspaceID, let readPanelID):
            workspaceID = readWorkspaceID
            panelID = readPanelID
        case .markPanelNotificationsRead(let readWorkspaceID, let readPanelID):
            workspaceID = readWorkspaceID
            panelID = readPanelID
        default:
            return nil
        }

        guard panelIsUnread(
            panelID: panelID,
            in: previousState.workspacesByID[workspaceID]
        ),
        !panelIsUnread(
            panelID: panelID,
            in: nextState.workspacesByID[workspaceID]
        ) else {
            return nil
        }

        return (workspaceID, panelID)
    }

    private func clearUnreadForManagedSessionIfNeeded(
        previousRecord: SessionRecord?,
        sessionID: String,
        status: SessionStatus
    ) {
        guard status.kind == .working else {
            return
        }
        guard let previousKind = previousRecord?.status?.kind,
              isActionableStatusKind(previousKind) else {
            return
        }
        guard let store,
              let currentRecord = sessionRegistry.sessionsByID[sessionID],
              currentRecord.isActive,
              currentRecord.usesSessionStatusNotifications else {
            return
        }
        guard isApplicationActive() || !isPanelCurrentlyFocused(currentRecord.panelID, state: store.state) else {
            return
        }
        guard store.state.workspacesByID[currentRecord.workspaceID]?.unreadPanelIDs.contains(currentRecord.panelID) == true else {
            return
        }

        // `unreadPanelIDs` currently coalesces session-status and generic
        // terminal notification unread. Only auto-clear the managed-session
        // path, where session status is already the authoritative signal.
        _ = store.send(
            .markPanelNotificationsRead(
                workspaceID: currentRecord.workspaceID,
                panelID: currentRecord.panelID
            )
        )
    }

    private func isPanelCurrentlyFocused(_ panelID: UUID, state: AppState) -> Bool {
        guard let selection = state.selectedWorkspaceSelection() else {
            return false
        }
        guard selection.workspace.focusedPanelID == panelID else {
            return false
        }
        return selection.workspace.layoutTree.slotContaining(panelID: panelID) != nil
    }

    private func isActionableStatusTransitionSuppressed(
        for record: SessionRecord,
        state: AppState
    ) -> Bool {
        isApplicationActive() && isPanelCurrentlyFocused(record.panelID, state: state)
    }

    private func normalizedStatusForStorage(
        requestedStatus: SessionStatus,
        previousRecord: SessionRecord?,
        state: AppState?
    ) -> SessionStatus {
        guard requestedStatus.kind == .ready,
              let previousRecord,
              let state,
              isActionableStatusTransitionSuppressed(for: previousRecord, state: state) else {
            return requestedStatus
        }

        return collapsedReadyStatus(from: requestedStatus)
    }

    private func isActionableStatusKind(_ kind: SessionStatusKind) -> Bool {
        kind == .needsApproval || kind == .ready || kind == .error
    }

    private func shouldClearLaterFlag(
        previousKind: SessionStatusKind?,
        nextKind: SessionStatusKind
    ) -> Bool {
        if previousKind != .working && nextKind == .working {
            return true
        }
        if previousKind != nextKind && isActionableStatusKind(nextKind) {
            return true
        }
        return false
    }

    private func panelIsUnread(panelID: UUID, in workspace: WorkspaceState?) -> Bool {
        guard let workspace,
              let tabID = workspace.tabID(containingPanelID: panelID) else {
            return false
        }
        return workspace.tab(id: tabID)?.unreadPanelIDs.contains(panelID) == true
    }

    private func collapsedReadyStatus(from status: SessionStatus) -> SessionStatus {
        SessionStatus(
            kind: .idle,
            summary: Self.readyCollapsedIdleStatus.summary,
            detail: normalizedNonEmpty(status.detail)
        )
    }

    private static let readyCollapsedIdleStatus = SessionStatus(
        kind: .idle,
        summary: "Waiting",
        detail: nil
    )

    private static let interruptedIdleStatus = SessionStatus(
        kind: .idle,
        summary: "Waiting",
        detail: "Ready for prompt"
    )

    private static let processWatchWorkingStatus = SessionStatus(
        kind: .working,
        summary: "Working",
        detail: "Running"
    )

    private func notificationTitle(for record: SessionRecord, status: SessionStatus) -> String {
        if record.agent == .processWatch {
            switch status.kind {
            case .ready:
                return "Command finished"
            case .error:
                return "Command failed"
            case .needsApproval:
                return "Command needs approval"
            case .idle, .working:
                return record.displayTitleOverride ?? record.agent.displayName
            }
        }

        switch status.kind {
        case .needsApproval:
            return "\(record.agent.displayName) needs approval"
        case .ready:
            return "\(record.agent.displayName) is ready"
        case .error:
            return "\(record.agent.displayName) hit an error"
        case .idle, .working:
            return record.agent.displayName
        }
    }

    private func notificationBody(for record: SessionRecord, status: SessionStatus) -> String {
        if record.agent == .processWatch,
           let displayTitle = normalizedNonEmpty(record.displayTitleOverride) {
            if status.kind == .error,
               let detail = normalizedNonEmpty(status.detail) {
                return "\(displayTitle) (\(detail))"
            }
            return displayTitle
        }

        if let detail = normalizedNonEmpty(status.detail) {
            return detail
        }
        if let summary = normalizedNonEmpty(status.summary) {
            return summary
        }
        return status.summary
    }

    private func processWatchCompletionStatus(exitCode: Int?) -> SessionStatus {
        if let exitCode, exitCode != 0 {
            return SessionStatus(
                kind: .error,
                summary: "Error",
                detail: "Exit \(exitCode)"
            )
        }

        return SessionStatus(
            kind: .ready,
            summary: "Ready",
            detail: "Completed"
        )
    }

    private func desktopNotificationContext(
        for record: SessionRecord,
        state: AppState
    ) -> DesktopNotificationContext {
        guard let workspace = state.workspacesByID[record.workspaceID] else {
            return DesktopNotificationContext()
        }
        return DesktopNotificationContext(
            workspaceTitle: workspace.title,
            panelLabel: workspace.panelState(for: record.panelID)?.notificationLabel
        )
    }

    nonisolated private static func defaultSendSessionStatusNotification(
        title: String,
        body: String,
        workspaceID: UUID,
        panelID: UUID,
        context: DesktopNotificationContext
    ) async {
        await SystemNotificationSender.send(
            title: title,
            body: body,
            workspaceID: workspaceID,
            panelID: panelID,
            context: context
        )
    }

    @MainActor
    private static func defaultIsApplicationActive() -> Bool {
        NSApplication.shared.isActive
    }
}

private struct CodexSessionReconciliationRuntime {
    var rootTurn: CodexRootTurnReconciler
    var approval: CodexApprovalReconciler

    var legacyPolicySnapshot: CodexLegacyPolicySnapshot {
        CodexLegacyPolicySnapshot(
            root: rootTurn.snapshot,
            autoReviewedPermissionTurnIDs: approval.snapshot.autoReviewedTurnIDs
        )
    }
}

private struct CodexLegacyPolicySnapshot: Equatable {
    let root: CodexRootTurnSnapshot
    let autoReviewedPermissionTurnIDs: [String]

    static let empty = CodexLegacyPolicySnapshot(
        root: .empty,
        autoReviewedPermissionTurnIDs: []
    )

    var rootThreadID: String? { root.rootThreadID }
    var rootTurnID: String? { root.rootTurnID }
    var rootTurnInputFingerprint: String? { root.rootTurnInputFingerprint }
    var rootTurnAwaitingSessionLogContext: Bool { root.isAwaitingSessionLogContext }
    var pendingRootInputFingerprint: String? { root.pendingRootInputFingerprint }
    var pendingRootApprovalContext: CodexRootTurnApprovalContext? { root.pendingApprovalContext }
    var activeTurnApprovalContext: CodexRootTurnApprovalContext? { root.activeApprovalContext }
    var approvalContextKnown: Bool { root.currentApprovalContext != nil }
    var approvalPolicy: CodexSessionLogContextField {
        root.currentApprovalContext?.approvalPolicy.sessionLogContextField ?? .unspecified
    }
    var approvalsReviewer: CodexSessionLogContextField {
        root.currentApprovalContext?.approvalsReviewer.sessionLogContextField ?? .unspecified
    }
}

private extension CodexSessionLogContextField {
    var rootTurnContextField: CodexRootTurnContextField {
        switch self {
        case .unspecified:
            return .unspecified
        case .null:
            return .null
        case .string(let value):
            return .string(value)
        }
    }
}

private extension CodexRootTurnContextField {
    var sessionLogContextField: CodexSessionLogContextField {
        switch self {
        case .unspecified:
            return .unspecified
        case .null:
            return .null
        case .string(let value):
            return .string(value)
        }
    }

    var metadataValue: String {
        switch self {
        case .unspecified:
            return "unknown"
        case .null:
            return "none"
        case .string(let value):
            return value
        }
    }
}

private struct PendingCodexHookApproval {
    let event: CodexHookEvent
    let token: UUID
}

extension SessionRuntimeStore: TerminalSessionLifecycleTracking {
    func activeSessionUsesStatusNotifications(panelID: UUID) -> Bool {
        sessionRegistry.activeSession(for: panelID)?.usesSessionStatusNotifications == true
    }

    @discardableResult
    func refreshManagedSessionStatusFromVisibleTextIfNeeded(
        panelID: UUID,
        visibleText: String,
        promptState: TerminalPromptState,
        at now: Date
    ) -> Bool {
        guard let record = sessionRegistry.activeSession(for: panelID),
              record.agent == .codex,
              record.usesSessionStatusNotifications,
              let currentStatus = record.status else {
            return false
        }

        if let nextStatus = CodexVisibleTextStatusParser.fatalErrorStatus(from: visibleText) {
            guard currentStatus.kind == .working || currentStatus.kind == .error,
                  isSuppressedCodexVisibleError(nextStatus, sessionID: record.sessionID) == false,
                  nextStatus != currentStatus else {
                return false
            }

            updateStatus(sessionID: record.sessionID, status: nextStatus, at: now)
            return true
        }

        guard let nextStatus = refreshedWorkingCodexStatus(
            currentStatus: currentStatus,
            visibleText: visibleText,
            promptState: promptState
        ) else {
            return false
        }

        // Keep suppressing a recovered fatal banner until Codex surfaces a
        // recognizable working detail again. Generic non-error text can be a
        // transient scroll or render gap, not evidence that the stale banner
        // is truly gone.
        clearSuppressedCodexVisibleErrorDetail(sessionID: record.sessionID)

        guard nextStatus != currentStatus else {
            return false
        }

        if codexStatusTrackingSourceBySessionID[record.sessionID] != nil {
            guard let detail = nextStatus.detail else {
                return false
            }
            return applyCodexRootProgressObservation(
                sessionID: record.sessionID,
                observation: .visibleTextWorking(detail: detail),
                at: now
            )
        }

        updateStatus(sessionID: record.sessionID, status: nextStatus, at: now)
        return true
    }

    private func refreshedWorkingCodexStatus(
        currentStatus: SessionStatus,
        visibleText: String,
        promptState _: TerminalPromptState
    ) -> SessionStatus? {
        switch currentStatus.kind {
        case .working:
            return CodexVisibleTextStatusParser.workingStatus(from: visibleText)
        case .idle, .ready, .needsApproval:
            // Safe containment: do not resurrect non-working Codex rows from
            // visible text until we can distinguish Codex's own ready prompt
            // from a truly active turn.
            return nil
        case .error:
            return nil
        }
    }

    func handleLocalInterruptForPanelIfActive(
        panelID: UUID,
        kind: TerminalLocalInterruptKind,
        at now: Date
    ) -> Bool {
        guard let record = sessionRegistry.activeSession(for: panelID),
              let currentStatus = record.status,
              currentStatus.kind == .working || currentStatus.kind == .needsApproval else {
            return false
        }

        if record.agent == .codex,
           codexStatusTrackingSourceBySessionID[record.sessionID] != nil {
            let interrupt: CodexRootProgressInterrupt = switch kind {
            case .escape:
                .escape
            case .controlC:
                .controlC
            }
            return applyCodexRootProgressObservation(
                sessionID: record.sessionID,
                observation: .localInterrupt(interrupt),
                at: now
            )
        }

        if kind == .escape,
           record.agent == .codex,
           codexStatusTrackingSourceAllowsFallbackEvents(sessionID: record.sessionID) {
            // Codex logs explicit interrupt events for Esc and other turn
            // cancellations when session-log fallback is active. Let that
            // watcher-driven signal drive idle transitions to avoid clearing
            // the spinner on every in-TUI Escape press.
            return false
        }

        updateStatus(
            sessionID: record.sessionID,
            status: Self.interruptedIdleStatus,
            at: now
        )
        return true
    }

    func stopSessionForPanelIfActive(
        panelID: UUID,
        reason: ManagedSessionStopReason,
        at now: Date
    ) -> Bool {
        guard sessionRegistry.activeSession(for: panelID) != nil else {
            return false
        }
        stopSessionForPanel(panelID: panelID, reason: reason, at: now)
        return true
    }

    func handleCommandFinished(panelID: UUID, exitCode: Int?, at now: Date) -> Bool {
        guard let record = sessionRegistry.activeSession(for: panelID) else {
            return false
        }

        guard record.agent == .processWatch else {
            stopSessionForPanel(
                panelID: panelID,
                reason: .ghosttyCommandFinished(exitCode: exitCode),
                at: now
            )
            return true
        }

        guard record.status?.kind == .working else {
            return true
        }

        updateStatus(
            sessionID: record.sessionID,
            status: processWatchCompletionStatus(exitCode: exitCode),
            at: now
        )
        return true
    }

    func stopSessionForPanelIfOlderThan(
        panelID: UUID,
        minimumRuntime: TimeInterval,
        reason: ManagedSessionStopReason,
        at now: Date
    ) -> Bool {
        guard let record = sessionRegistry.activeSession(for: panelID),
              now.timeIntervalSince(record.startedAt) >= minimumRuntime else {
            return false
        }

        if record.agent == .processWatch,
           let status = record.status {
            if status.kind == .ready || status.kind == .error {
                return false
            }

            if reason == .idleAtPrompt,
               status.kind == .working {
                updateStatus(
                    sessionID: record.sessionID,
                    status: processWatchCompletionStatus(exitCode: nil),
                    at: now
                )
                return true
            }
        }

        stopSessionForPanel(panelID: panelID, reason: reason, at: now)
        return true
    }
}

private extension CodexHookEvent {
    var isClearSessionStart: Bool {
        hookEventName == "SessionStart" && source == "clear"
    }

    var isStop: Bool {
        hookEventName == "Stop"
    }

    var isUserPromptSubmit: Bool {
        hookEventName == "UserPromptSubmit"
    }

    var isRootProgressWorking: Bool {
        hookEventName == "UserPromptSubmit" || hookEventName == "PreToolUse"
    }

    var isPermissionRequest: Bool {
        hookEventName == "PermissionRequest"
    }

    var isSubagentStart: Bool {
        hookEventName == "SubagentStart"
    }

    var isSubagentStop: Bool {
        hookEventName == "SubagentStop"
    }

    var meaningfulSubagentType: String? {
        guard let normalizedType = normalizedNonEmpty(subagentType),
              normalizedType.caseInsensitiveCompare("default") != .orderedSame else {
            return nil
        }
        return normalizedType
    }

    var canLatchRootHookThread: Bool {
        hookEventName == "SessionStart" || hookEventName == "UserPromptSubmit"
    }
}

private func normalizedNonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          trimmed.isEmpty == false else {
        return nil
    }
    return trimmed
}

private func truncatedLogMetadataValue(_ value: String?, limit: Int) -> String? {
    guard let normalized = normalizedNonEmpty(value) else { return nil }
    guard normalized.count > limit else { return normalized }
    let endIndex = normalized.index(normalized.startIndex, offsetBy: limit - 3)
    return String(normalized[..<endIndex]) + "..."
}
