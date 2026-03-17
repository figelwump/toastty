import CoreState
import Foundation

@MainActor
final class SessionRuntimeStore: ObservableObject {
    @Published private(set) var sessionRegistry = SessionRegistry()

    private weak var store: AppStore?
    private var storeActionObserverToken: UUID?

    func bind(store: AppStore) {
        self.store = store
        synchronize(with: store.state)

        guard storeActionObserverToken == nil else { return }
        storeActionObserverToken = store.addActionAppliedObserver { [weak self] _, _, nextState in
            self?.synchronize(with: nextState)
        }
    }

    func reset() {
        sessionRegistry = SessionRegistry()
    }

    func startSession(
        sessionID: String,
        agent: AgentKind,
        panelID: UUID,
        windowID: UUID,
        workspaceID: UUID,
        cwd: String?,
        repoRoot: String?,
        at now: Date
    ) {
        var nextRegistry = sessionRegistry
        nextRegistry.startSession(
            sessionID: sessionID,
            agent: agent,
            panelID: panelID,
            windowID: windowID,
            workspaceID: workspaceID,
            cwd: cwd,
            repoRoot: repoRoot,
            at: now
        )
        publish(nextRegistry)
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
        var nextRegistry = sessionRegistry
        nextRegistry.updateStatus(sessionID: sessionID, status: status, at: now)
        publish(nextRegistry)
        recordPanelAttentionIfNeeded(
            previousRecord: previousRecord,
            sessionID: sessionID,
            status: status
        )
    }

    func stopSession(sessionID: String, at now: Date) {
        var nextRegistry = sessionRegistry
        nextRegistry.stopSession(sessionID: sessionID, at: now)
        publish(nextRegistry)
    }

    func stopSessionForPanel(panelID: UUID, at now: Date) {
        var nextRegistry = sessionRegistry
        nextRegistry.stopSessionForPanel(panelID: panelID, at: now)
        publish(nextRegistry)
    }

    func workspaceStatuses(for workspaceID: UUID) -> [WorkspaceSessionStatus] {
        let statuses = sessionRegistry.workspaceStatuses(for: workspaceID)
        guard let workspace = store?.state.workspacesByID[workspaceID] else {
            return statuses
        }

        let displayOrder = Dictionary(
            uniqueKeysWithValues: workspace.terminalPanelIDsInDisplayOrder.enumerated().map { offset, panelID in
                (panelID, offset)
            }
        )

        return statuses.sorted { lhs, rhs in
            let lhsOrder = displayOrder[lhs.panelID] ?? Int.max
            let rhsOrder = displayOrder[rhs.panelID] ?? Int.max
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.sessionID < rhs.sessionID
        }
    }

    func panelStatus(for panelID: UUID) -> WorkspaceSessionStatus? {
        sessionRegistry.panelStatus(for: panelID)
    }

    private func synchronize(with state: AppState, now: Date = Date()) {
        var nextRegistry = sessionRegistry

        for record in Array(nextRegistry.sessionsByID.values) where record.isActive {
            guard let location = Self.locatePanel(record.panelID, in: state) else {
                nextRegistry.stopSession(sessionID: record.sessionID, at: now)
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

    private func recordPanelAttentionIfNeeded(
        previousRecord: SessionRecord?,
        sessionID: String,
        status: SessionStatus
    ) {
        guard let store else { return }
        guard status.kind == .needsApproval || status.kind == .ready || status.kind == .error else {
            return
        }
        guard previousRecord?.status?.kind != status.kind else {
            return
        }
        guard let currentRecord = sessionRegistry.sessionsByID[sessionID],
              currentRecord.isActive,
              isPanelCurrentlyFocused(currentRecord.panelID, state: store.state) == false else {
            return
        }

        _ = store.send(
            .recordDesktopNotification(
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

    private static func locatePanel(
        _ panelID: UUID,
        in state: AppState
    ) -> (windowID: UUID, workspaceID: UUID)? {
        for window in state.windows {
            for workspaceID in window.workspaceIDs {
                guard let workspace = state.workspacesByID[workspaceID] else { continue }
                if workspace.panels[panelID] != nil {
                    return (window.id, workspaceID)
                }
            }
        }
        return nil
    }
}

extension SessionRuntimeStore: TerminalSessionLifecycleTracking {
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
            // Codex emits an explicit turn_aborted watcher event for Esc.
            // Let that authoritative signal drive idle transitions to avoid
            // clearing the spinner on every in-TUI Escape press.
            return false
        }

        updateStatus(
            sessionID: record.sessionID,
            status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt"),
            at: now
        )
        return true
    }

    func stopSessionForPanelIfActive(panelID: UUID, at now: Date) -> Bool {
        guard sessionRegistry.activeSession(for: panelID) != nil else {
            return false
        }
        stopSessionForPanel(panelID: panelID, at: now)
        return true
    }

    func stopSessionForPanelIfOlderThan(
        panelID: UUID,
        minimumRuntime: TimeInterval,
        at now: Date
    ) -> Bool {
        guard let record = sessionRegistry.activeSession(for: panelID),
              now.timeIntervalSince(record.startedAt) >= minimumRuntime else {
            return false
        }

        stopSessionForPanel(panelID: panelID, at: now)
        return true
    }
}
