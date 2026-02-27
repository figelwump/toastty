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

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case paneTree
        case panels
        case focusedPanelID
        case auxPanelVisibility
        case unreadNotificationCount
        case recentlyClosedPanels
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        paneTree = try container.decode(PaneNode.self, forKey: .paneTree)
        panels = try container.decode([UUID: PanelState].self, forKey: .panels)
        focusedPanelID = try container.decodeIfPresent(UUID.self, forKey: .focusedPanelID)
        auxPanelVisibility = try container.decodeIfPresent(Set<PanelKind>.self, forKey: .auxPanelVisibility) ?? []
        unreadNotificationCount = try container.decodeIfPresent(Int.self, forKey: .unreadNotificationCount) ?? 0
        recentlyClosedPanels = try container.decodeIfPresent([ClosedPanelRecord].self, forKey: .recentlyClosedPanels) ?? []
        // Focus mode is a transient UI/runtime flag and should never persist across decode boundaries.
        focusedPanelModeActive = false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(paneTree, forKey: .paneTree)
        try container.encode(panels, forKey: .panels)
        try container.encodeIfPresent(focusedPanelID, forKey: .focusedPanelID)
        try container.encode(auxPanelVisibility, forKey: .auxPanelVisibility)
        try container.encode(unreadNotificationCount, forKey: .unreadNotificationCount)
        try container.encode(recentlyClosedPanels, forKey: .recentlyClosedPanels)
    }
}
