import Foundation

public struct ClosedPanelRecord: Codable, Equatable, Sendable {
    public let panelState: PanelState
    public let closedAt: Date
    public let sourceLeafPaneID: UUID

    public init(panelState: PanelState, closedAt: Date, sourceLeafPaneID: UUID) {
        self.panelState = panelState
        self.closedAt = closedAt
        self.sourceLeafPaneID = sourceLeafPaneID
    }
}

public struct WorkspaceState: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var paneTree: PaneNode
    public var panels: [UUID: PanelState]
    public var focusedPanelID: UUID?
    public var auxPanelVisibility: Set<PanelKind>
    public var focusedPanelModeActive: Bool
    public var unreadNotificationCount: Int
    public var recentlyClosedPanels: [ClosedPanelRecord]

    public init(
        id: UUID,
        title: String,
        paneTree: PaneNode,
        panels: [UUID: PanelState],
        focusedPanelID: UUID?,
        auxPanelVisibility: Set<PanelKind> = [],
        focusedPanelModeActive: Bool = false,
        unreadNotificationCount: Int = 0,
        recentlyClosedPanels: [ClosedPanelRecord] = []
    ) {
        self.id = id
        self.title = title
        self.paneTree = paneTree
        self.panels = panels
        self.focusedPanelID = focusedPanelID
        self.auxPanelVisibility = auxPanelVisibility
        self.focusedPanelModeActive = focusedPanelModeActive
        self.unreadNotificationCount = unreadNotificationCount
        self.recentlyClosedPanels = recentlyClosedPanels
    }

    public static func bootstrap(title: String = "Workspace 1") -> WorkspaceState {
        let panelID = UUID()
        let paneID = UUID()
        return WorkspaceState(
            id: UUID(),
            title: title,
            paneTree: .leaf(paneID: paneID, tabPanelIDs: [panelID], selectedIndex: 0),
            panels: [
                panelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: NSHomeDirectory())),
            ],
            focusedPanelID: panelID
        )
    }
}
