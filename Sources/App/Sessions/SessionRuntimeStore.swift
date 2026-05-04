import AppKit
import CoreState
import Foundation

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
    private var codexNotifyStateBySessionID: [String: CodexNotifySessionState] = [:]
    private let sendSessionStatusNotification: SessionStatusNotificationHandler
    private let isApplicationActive: ApplicationActiveHandler

    init(
        sendSessionStatusNotification: @escaping SessionStatusNotificationHandler = SessionRuntimeStore.defaultSendSessionStatusNotification,
        isApplicationActive: @escaping ApplicationActiveHandler = SessionRuntimeStore.defaultIsApplicationActive
    ) {
        self.sendSessionStatusNotification = sendSessionStatusNotification
        self.isApplicationActive = isApplicationActive
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

    func reset() {
        sessionRegistry = SessionRegistry()
        suppressedCodexVisibleErrorDetailBySessionID = [:]
        codexNotifyStateBySessionID = [:]
    }

    func startSession(
        sessionID: String,
        agent: AgentKind,
        panelID: UUID,
        windowID: UUID,
        workspaceID: UUID,
        usesSessionStatusNotifications: Bool = false,
        displayTitleOverride: String? = nil,
        cwd: String?,
        repoRoot: String?,
        at now: Date
    ) {
        suppressedCodexVisibleErrorDetailBySessionID.removeValue(forKey: sessionID)
        codexNotifyStateBySessionID.removeValue(forKey: sessionID)
        var nextRegistry = sessionRegistry
        nextRegistry.startSession(
            sessionID: sessionID,
            agent: agent,
            panelID: panelID,
            windowID: windowID,
            workspaceID: workspaceID,
            usesSessionStatusNotifications: usesSessionStatusNotifications,
            displayTitleOverride: displayTitleOverride,
            cwd: cwd,
            repoRoot: repoRoot,
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
                usesSessionStatusNotifications: usesSessionStatusNotifications,
                displayTitleOverride: displayTitleOverride
            )
        )
        publish(nextRegistry)
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
        publish(nextRegistry)
    }

    func updateStatus(
        sessionID: String,
        status: SessionStatus,
        at now: Date
    ) {
        let previousRecord = sessionRegistry.sessionsByID[sessionID]
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
        publish(nextRegistry)
        clearUnreadForManagedSessionIfNeeded(
            previousRecord: previousRecord,
            sessionID: sessionID,
            status: storedStatus
        )
        handleActionableStatusTransitionIfNeeded(
            previousRecord: previousRecord,
            sessionID: sessionID,
            status: storedStatus
        )
    }

    func recordCodexRootTurnInput(
        sessionID: String,
        fingerprint: String?
    ) {
        guard let record = sessionRegistry.sessionsByID[sessionID],
              record.agent == .codex,
              record.usesSessionStatusNotifications else {
            return
        }

        var state = codexNotifyStateBySessionID[sessionID] ?? CodexNotifySessionState()
        state.pendingRootInputFingerprint = fingerprint
        codexNotifyStateBySessionID[sessionID] = state

        ToasttyLog.debug(
            "Recorded Codex root turn input fingerprint",
            category: .terminal,
            metadata: codexNotifyMetadata(
                sessionID: sessionID,
                record: record,
                state: state,
                additional: [
                    "input_fingerprint": truncatedFingerprint(fingerprint),
                ]
            )
        )
    }

    @discardableResult
    func handleCodexNotifyCompletion(
        sessionID: String,
        completion: CodexNotifyCompletion,
        at now: Date
    ) -> Bool {
        guard let record = sessionRegistry.sessionsByID[sessionID],
              record.agent == .codex,
              record.usesSessionStatusNotifications else {
            updateStatus(
                sessionID: sessionID,
                status: SessionStatus(kind: .ready, summary: "Ready", detail: completion.detail),
                at: now
            )
            return true
        }

        var state = codexNotifyStateBySessionID[sessionID] ?? CodexNotifySessionState()
        if let threadID = completion.threadID {
            if let rootThreadID = state.rootThreadID {
                guard threadID == rootThreadID else {
                    codexNotifyStateBySessionID[sessionID] = state
                    logIgnoredCodexNotifyCompletion(
                        sessionID: sessionID,
                        record: record,
                        state: state,
                        completion: completion,
                        reason: "thread_mismatch"
                    )
                    return false
                }
            } else if let notifyFingerprint = completion.lastInputMessageFingerprint,
                      let pendingFingerprint = state.pendingRootInputFingerprint,
                      notifyFingerprint == pendingFingerprint {
                state.rootThreadID = threadID
                codexNotifyStateBySessionID[sessionID] = state
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
            } else if state.pendingRootInputFingerprint == nil {
                codexNotifyStateBySessionID[sessionID] = state
                logIgnoredCodexNotifyCompletion(
                    sessionID: sessionID,
                    record: record,
                    state: state,
                    completion: completion,
                    reason: "missing_root_input_fingerprint"
                )
                return false
            } else {
                codexNotifyStateBySessionID[sessionID] = state
                let reason = completion.lastInputMessageFingerprint == nil
                    ? "missing_notify_input_fingerprint"
                    : "input_fingerprint_mismatch"
                logIgnoredCodexNotifyCompletion(
                    sessionID: sessionID,
                    record: record,
                    state: state,
                    completion: completion,
                    reason: reason
                )
                return false
            }
        } else {
            codexNotifyStateBySessionID[sessionID] = state
            ToasttyLog.debug(
                "Accepted unthreaded Codex notify completion",
                category: .terminal,
                metadata: codexNotifyMetadata(
                    sessionID: sessionID,
                    record: record,
                    state: state,
                    completion: completion
                )
            )
        }

        updateStatus(
            sessionID: sessionID,
            status: SessionStatus(kind: .ready, summary: "Ready", detail: completion.detail),
            at: now
        )
        return true
    }

    func stopSession(
        sessionID: String,
        reason: ManagedSessionStopReason = .explicit,
        at now: Date
    ) {
        if let record = sessionRegistry.sessionsByID[sessionID], record.isActive {
            logSessionStop(record, reason: reason, at: now)
        }
        suppressedCodexVisibleErrorDetailBySessionID.removeValue(forKey: sessionID)
        codexNotifyStateBySessionID.removeValue(forKey: sessionID)
        var nextRegistry = sessionRegistry
        if sessionRegistry.sessionsByID[sessionID]?.agent == .processWatch {
            nextRegistry.removeSession(sessionID: sessionID)
        } else {
            nextRegistry.stopSession(sessionID: sessionID, at: now)
        }
        publish(nextRegistry)
    }

    func stopSessionForPanel(
        panelID: UUID,
        reason: ManagedSessionStopReason = .explicit,
        at now: Date
    ) {
        if let record = sessionRegistry.activeSession(for: panelID) {
            logSessionStop(record, reason: reason, at: now)
            suppressedCodexVisibleErrorDetailBySessionID.removeValue(forKey: record.sessionID)
            codexNotifyStateBySessionID.removeValue(forKey: record.sessionID)
        }
        var nextRegistry = sessionRegistry
        if let record = sessionRegistry.activeSession(for: panelID),
           record.agent == .processWatch {
            nextRegistry.removeSession(sessionID: record.sessionID)
        } else {
            nextRegistry.stopSessionForPanel(panelID: panelID, at: now)
        }
        publish(nextRegistry)
    }

    func workspaceStatuses(for workspaceID: UUID) -> [WorkspaceSessionStatus] {
        sessionRegistry.workspaceStatuses(for: workspaceID)
    }

    func panelStatus(for panelID: UUID) -> WorkspaceSessionStatus? {
        sessionRegistry.panelStatus(for: panelID)
    }

    func isLaterFlagged(sessionID: String) -> Bool {
        sessionRegistry.isLaterFlagged(sessionID: sessionID)
    }

    func setLaterFlag(sessionID: String, isFlagged: Bool) {
        var nextRegistry = sessionRegistry
        nextRegistry.setLaterFlag(sessionID: sessionID, isFlagged: isFlagged)
        publish(nextRegistry)
    }

    func toggleLaterFlag(sessionID: String) {
        var nextRegistry = sessionRegistry
        nextRegistry.toggleLaterFlag(sessionID: sessionID)
        publish(nextRegistry)
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
                      let status = record.status,
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

        publish(nextRegistry)
    }

    private func publish(_ nextRegistry: SessionRegistry) {
        guard nextRegistry != sessionRegistry else { return }
        sessionRegistry = nextRegistry
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

    private func logIgnoredCodexNotifyCompletion(
        sessionID: String,
        record: SessionRecord,
        state: CodexNotifySessionState,
        completion: CodexNotifyCompletion,
        reason: String
    ) {
        ToasttyLog.debug(
            "Ignored Codex notify completion",
            category: .terminal,
            metadata: codexNotifyMetadata(
                sessionID: sessionID,
                record: record,
                state: state,
                completion: completion,
                additional: [
                    "reason": reason,
                ]
            )
        )
    }

    private func codexNotifyMetadata(
        sessionID: String,
        record: SessionRecord,
        state: CodexNotifySessionState,
        completion: CodexNotifyCompletion? = nil,
        additional: [String: String] = [:]
    ) -> [String: String] {
        var metadata: [String: String] = [
            "session_id": sessionID,
            "panel_id": record.panelID.uuidString,
            "root_thread_id": state.rootThreadID ?? "none",
            "pending_input_fingerprint": truncatedFingerprint(state.pendingRootInputFingerprint),
        ]

        if let completion {
            metadata["notify_type"] = completion.notificationType
            metadata["notify_thread_id"] = completion.threadID ?? "none"
            metadata["notify_turn_id"] = completion.turnID ?? "none"
            metadata["notify_input_fingerprint"] = truncatedFingerprint(completion.lastInputMessageFingerprint)
            metadata["notify_input_message_count"] = String(completion.inputMessageCount)
        }

        for (key, value) in additional {
            metadata[key] = value
        }

        return metadata
    }

    private func truncatedFingerprint(_ fingerprint: String?) -> String {
        guard let fingerprint, fingerprint.isEmpty == false else {
            return "none"
        }
        return String(fingerprint.prefix(16))
    }

    private func sessionStartMetadata(
        sessionID: String,
        agent: AgentKind,
        panelID: UUID,
        windowID: UUID,
        workspaceID: UUID,
        usesSessionStatusNotifications: Bool,
        displayTitleOverride: String?
    ) -> [String: String] {
        var metadata = [
            "session_id": sessionID,
            "agent": agent.rawValue,
            "panel_id": panelID.uuidString,
            "window_id": windowID.uuidString,
            "workspace_id": workspaceID.uuidString,
            "uses_status_notifications": usesSessionStatusNotifications ? "true" : "false",
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
        sessionID: String,
        status: SessionStatus
    ) {
        guard let store else { return }
        guard isActionableStatusKind(status.kind) else {
            return
        }
        guard previousRecord?.status?.kind != status.kind else {
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

private struct CodexNotifySessionState {
    var rootThreadID: String?
    var pendingRootInputFingerprint: String?
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

        if kind == .escape, record.agent == .codex {
            // Codex logs explicit interrupt events for Esc and other turn
            // cancellations. Let that watcher-driven signal drive idle
            // transitions to avoid clearing the spinner on every in-TUI
            // Escape press.
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
