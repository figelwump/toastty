import CoreState
import SwiftUI

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

    /// The status Toasty carries in the row's left column: steam while the
    /// agent works, a session row's rail dot otherwise.
    static func iconStatus(_ mark: Mark) -> ToastyIcon.Status {
        switch mark {
        case .working: .working
        case .unread: .unread
        case .needsApproval: .needsApproval
        case .error: .error
        case .quiet, .starting, .notRunning: .none
        }
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

    static func accessibilityLabel(_ mark: Mark, isSelected: Bool) -> String {
        var parts = [AppState.coordinatorWorkspaceTitle]
        if let status = statusText(mark) { parts.append(status) }
        if isSelected { parts.append("selected") }
        return parts.joined(separator: ", ")
    }
}

/// The coordinator's row, pinned at the top of the sidebar above the Tasks
/// row. It is not a project card: it shows in both sidebar segments, has no
/// number and does not reorder. It shows the agent's status and unread
/// marks, and says when the agent does not run.
struct SidebarCoordinatorRow: View {
    let workspace: WorkspaceState
    let isSelected: Bool
    let selectedPanelID: UUID?
    @ObservedObject var controller: CoordinatorController
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore
    let select: () -> Void
    let openPolicy: () -> Void
    let restart: () -> Void
    let close: () -> Void

    @State private var isHovered = false

    private var mark: SidebarCoordinatorPresentation.Mark {
        let status = controller.status
        let statusKind = status?.location.panelID
            .flatMap { sessionRuntimeStore.sessionRegistry.panelStatus(for: $0) }
            .flatMap { $0.isActive ? $0.status.kind : nil }
        return SidebarCoordinatorPresentation.mark(
            agentState: status?.agentState ?? .notRunning,
            statusKind: statusKind,
            hasUnread: SidebarCoordinatorPresentation.hasUnread(
                in: workspace,
                selectedWorkspaceID: isSelected ? workspace.id : nil,
                selectedPanelID: selectedPanelID
            )
        )
    }

    var body: some View {
        let mark = mark
        let label = SidebarCoordinatorPresentation.accessibilityLabel(mark, isSelected: isSelected)
        Button(action: select) {
            HStack(spacing: 8) {
                ToastyIcon(
                    style: .outline,
                    size: 14,
                    status: SidebarCoordinatorPresentation.iconStatus(mark),
                    badgeRingColor: rowBackground ?? ToastyTheme.chromeBackground
                )
                .frame(width: 14)
                Text(AppState.coordinatorWorkspaceTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(ToastyTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                markView(mark)
            }
            // As tall as the Tasks row, whatever mark shows.
            .frame(minHeight: 20)
            .padding(.vertical, 5)
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .background(rowBackground ?? Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open Policy", action: openPolicy)
            Button("Restart Coordinator", action: restart)
            Button("Close Coordinator", role: .destructive, action: close)
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("sidebar.coordinator")
        .background {
            SidebarSemanticTextBridge(text: label)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
        .background(ToastyTheme.chromeBackground)
    }

    /// The selected or hovered row's fill. Without one, the row shows the
    /// sidebar's chrome.
    private var rowBackground: Color? {
        if isSelected { return ToastyTheme.sidebarSessionActiveBackground }
        if isHovered { return ToastyTheme.sidebarSessionHoverBackground }
        return nil
    }

    /// The words at the right end, as on a session row's first line.
    @ViewBuilder
    private func markView(_ mark: SidebarCoordinatorPresentation.Mark) -> some View {
        switch mark {
        case .quiet, .working, .unread:
            EmptyView()
        case .needsApproval:
            SessionStatusBadge(kind: .needsApproval)
        case .error:
            SessionStatusBadge(kind: .error)
        case .starting:
            quietText("Starting…")
        case .notRunning:
            quietText("Not running")
        }
    }

    private func quietText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(ToastyTheme.sidebarSessionPathText)
            .lineLimit(1)
    }
}
