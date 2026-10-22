import CoreState
import Foundation
import RemoteProtocol

/// Sidebar presentation, derived from state and session data. A thin port
/// of the macOS `SidebarSessionPresentation` rules that the GTK sidebar
/// needs (status chips, unread accent, "New" badge, pane subtitle), kept
/// pure so it is unit-tested and diffed before touching widgets.
public struct SidebarSessionRowModel: Equatable, Sendable {
    public let sessionID: String
    public let panelID: UUID
    public let name: String
    public let agentLabel: String
    public let statusKind: SessionStatusKind
    /// "approval", "error", "ready" or "waiting"; nil when the dot says enough.
    public let chipLabel: String?
    public let summary: String?
    public let isUnread: Bool
    public let isFocused: Bool
    public let isFlaggedForLater: Bool

    public var attentionClass: String? {
        switch statusKind {
        case .needsApproval: return "attention-approval"
        case .error: return "attention-error"
        case .ready: return isUnread ? "attention-ready" : nil
        case .idle, .working: return nil
        }
    }

    /// The row's status dot (macOS `SidebarSessionPresentation.sessionRailState`):
    /// a ready session shows the ready dot only while its panel is unread;
    /// once the user has seen it the row rests like an idle one, so the
    /// "ready" mark goes away with the unread mark.
    public var dotClass: String {
        statusKind == .ready && isUnread == false ? "idle" : statusClass
    }

    public var statusClass: String {
        switch statusKind {
        case .idle: return "idle"
        case .working: return "working"
        case .needsApproval: return "needs-approval"
        case .ready: return "ready"
        case .error: return "error"
        }
    }
}

public struct SidebarWorkspaceRowModel: Equatable, Sendable {
    public let workspaceID: UUID
    public let index: Int
    public let title: String
    public let subtitle: String
    public let isSelected: Bool
    public let showsNewBadge: Bool
    public let hasUnread: Bool
    /// macOS's `active/running` agent badge: sessions working out of live
    /// agent sessions (process watches excluded).
    public let agentSummary: WorkspaceAgentSummary
    /// Ctrl+Alt+N for the first nine workspaces.
    public let shortcutLabel: String?
    public let isSubspace: Bool
    public let isDone: Bool
    public let sessions: [SidebarSessionRowModel]
}

@MainActor
public enum SidebarModel {
    public static func rows(
        state: AppState,
        windowID: UUID,
        sessions: any LinuxSessionSource,
        shortcutLabel: (Int) -> String? = defaultShortcutLabel
    ) -> [SidebarWorkspaceRowModel] {
        guard let window = state.window(id: windowID) else { return [] }
        let selectedWorkspaceID = window.selectedWorkspaceID
        let selectedPanelID = selectedWorkspaceID.flatMap { state.workspacesByID[$0]?.focusedPanelID }

        return window.workspaceIDs.enumerated().compactMap { index, workspaceID in
            guard let workspace = state.workspacesByID[workspaceID] else { return nil }
            let isSelected = workspaceID == selectedWorkspaceID
            let paneCount = workspace.layoutTree.allSlotInfos.count
            let tabCount = workspace.tabIDs.count
            var subtitle = paneCount == 1 ? "1 pane" : "\(paneCount) panes"
            if tabCount > 1 { subtitle = "\(tabCount) tabs · " + subtitle }

            let statuses = sessions.sessions(workspaceID: workspaceID)
            let sessionRows = statuses.map { session in
                sessionRow(
                    session,
                    workspace: workspace,
                    isFocused: isSelected && selectedPanelID == session.panelID,
                    isFlagged: sessions.isFlaggedForLater(sessionID: session.sessionID)
                )
            }
            return SidebarWorkspaceRowModel(
                workspaceID: workspaceID,
                index: index,
                title: workspace.title,
                subtitle: subtitle,
                isSelected: isSelected,
                showsNewBadge: isSelected == false && workspace.hasBeenVisited == false,
                hasUnread: workspace.unreadNotificationCount > 0,
                agentSummary: WorkspaceAgentSummary.make(from: statuses, workspaceID: workspaceID),
                shortcutLabel: shortcutLabel(index),
                isSubspace: workspace.parentWorkspaceID != nil,
                isDone: workspace.doneAt != nil,
                sessions: sessionRows
            )
        }
    }

    nonisolated public static func defaultShortcutLabel(_ index: Int) -> String? {
        guard index < 9 else { return nil }
        return ShortcutLabels.label(forCommand: "workspace.select-\(index + 1)")
    }

    static func sessionRow(
        _ session: WorkspaceSessionStatus,
        workspace: WorkspaceState,
        isFocused: Bool,
        isFlagged: Bool
    ) -> SidebarSessionRowModel {
        let isUnread: Bool = {
            guard let tabID = workspace.tabID(containingPanelID: session.panelID),
                  workspace.tab(id: tabID)?.unreadPanelIDs.contains(session.panelID) == true else { return false }
            return isFocused == false
        }()
        let chip: String? = {
            if case .waitingOnChildren = session.projection { return "waiting" }
            switch session.status.kind {
            case .needsApproval: return "approval"
            case .error: return "error"
            case .ready: return isUnread ? "ready" : nil
            case .idle, .working: return nil
            }
        }()
        let summary = session.status.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = session.displayTitleOverride ?? session.providerSessionName ?? session.agent.displayName
        return SidebarSessionRowModel(
            sessionID: session.sessionID,
            panelID: session.panelID,
            name: name,
            agentLabel: session.agent.rawValue,
            statusKind: session.status.kind,
            chipLabel: chip,
            summary: summary.isEmpty ? nil : summary,
            isUnread: isUnread,
            isFocused: isFocused,
            isFlaggedForLater: isFlagged
        )
    }
}
