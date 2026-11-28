import CoreState
import Foundation

/// What the coordinator's sidebar row shows beside its name.
@MainActor
enum SidebarCoordinatorPresentation {
    enum Mark: Equatable {
        /// The agent is at rest and nothing is unread.
        case quiet
        case working
        case unread
        case needsApproval
        case error
        case starting
        case notRunning
    }

    static func mark(
        agentState: CoordinatorController.AgentState,
        statusKind: SessionStatusKind?,
        hasUnread: Bool
    ) -> Mark {
        switch agentState {
        case .notRunning: return .notRunning
        case .starting: return .starting
        case .running: break
        }
        switch statusKind {
        case .needsApproval?: return .needsApproval
        case .error?: return .error
        case .working?: return .working
        case .idle?, .ready?, nil: return hasUnread ? .unread : .quiet
        }
    }

    /// Unread marks in the coordinator's workspace, as its session rows
    /// would count them: the panel the user looks at is read.
    static func hasUnread(
        in workspace: WorkspaceState,
        selectedWorkspaceID: UUID?,
        selectedPanelID: UUID?
    ) -> Bool {
        if workspace.unreadWorkspaceNotificationCount > 0 { return true }
        return workspace.tabsByID.values.contains { tab in
            tab.unreadPanelIDs.contains { panelID in
                SidebarSessionPresentation.showsUnreadSessionAccent(
                    for: panelID,
                    in: workspace,
                    selectedWorkspaceID: selectedWorkspaceID,
                    selectedPanelID: selectedPanelID
                )
            }
        }
    }

    /// The coordinator's mark now. `readPanelID` is the panel whose output
    /// the user sees: the full view's focused panel, or the coordinator's
    /// terminal while the dock shows its chat. `nil` when neither shows.
    static func currentMark(
        controller: CoordinatorController,
        sessionRuntimeStore: SessionRuntimeStore,
        workspace: WorkspaceState,
        readPanelID: UUID?
    ) -> Mark {
        let status = controller.status
        let statusKind = status?.location.panelID
            .flatMap { sessionRuntimeStore.sessionRegistry.panelStatus(for: $0) }
            .flatMap { $0.isActive ? $0.status.kind : nil }
        return mark(
            agentState: status?.agentState ?? .notRunning,
            statusKind: statusKind,
            hasUnread: hasUnread(
                in: workspace,
                selectedWorkspaceID: readPanelID == nil ? nil : workspace.id,
                selectedPanelID: readPanelID
            )
        )
    }

    static func statusText(_ mark: Mark) -> String? {
        switch mark {
        case .quiet: nil
        case .working: "working"
        case .unread: "unread"
        case .needsApproval: "needs approval"
        case .error: "error"
        case .starting: "starting"
        case .notRunning: "not running"
        }
    }

    static func accessibilityLabel(_ mark: Mark, isSelected: Bool, dockShows: Bool = false) -> String {
        var parts = [AppState.coordinatorWorkspaceTitle]
        if let status = statusText(mark) { parts.append(status) }
        if isSelected { parts.append("selected") }
        if dockShows { parts.append("dock open") }
        return parts.joined(separator: ", ")
    }
}
