import Foundation

public struct ClosedPanelRecord: Codable, Equatable, Sendable {
    public let panelState: PanelState
    public let closedAt: Date
    public let sourceSlotID: UUID

    public init(panelState: PanelState, closedAt: Date, sourceSlotID: UUID) {
        self.panelState = panelState
        self.closedAt = closedAt
        self.sourceSlotID = sourceSlotID
    }
}

public struct WorkspaceState: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var layoutTree: LayoutNode
    public var panels: [UUID: PanelState]
    public var focusedPanelID: UUID?
    public var auxPanelVisibility: Set<PanelKind>
    public var focusedPanelModeActive: Bool
    public var unreadPanelIDs: Set<UUID>
    public var unreadWorkspaceNotificationCount: Int
    public var unreadNotificationCount: Int {
        unreadPanelIDs.count + unreadWorkspaceNotificationCount
    }
    public var livePanelIDs: Set<UUID> {
        Set(panels.keys)
    }
    public var splitTree: WorkspaceSplitTree {
        WorkspaceSplitTree(root: layoutTree)
    }
    public var resolvedFocusedPanel: WorkspaceSplitTree.FocusedPanelResolution? {
        splitTree.resolveFocusedPanel(
            preferredFocusedPanelID: focusedPanelID,
            livePanelIDs: livePanelIDs
        )
    }
    public var renderedLayout: WorkspaceRenderedLayout {
        splitTree.renderedLayout(
            workspaceID: id,
            focusedPanelModeActive: focusedPanelModeActive,
            focusedPanelID: focusedPanelID
        )
    }
    public var recentlyClosedPanels: [ClosedPanelRecord]

    public init(
        id: UUID,
        title: String,
        layoutTree: LayoutNode,
        panels: [UUID: PanelState],
        focusedPanelID: UUID?,
        auxPanelVisibility: Set<PanelKind> = [],
        focusedPanelModeActive: Bool = false,
        unreadPanelIDs: Set<UUID> = [],
        unreadWorkspaceNotificationCount: Int = 0,
        recentlyClosedPanels: [ClosedPanelRecord] = []
    ) {
        self.id = id
        self.title = title
        self.layoutTree = layoutTree
        self.panels = panels
        self.focusedPanelID = focusedPanelID
        self.auxPanelVisibility = auxPanelVisibility
        self.focusedPanelModeActive = focusedPanelModeActive
        self.unreadPanelIDs = unreadPanelIDs.intersection(Set(panels.keys))
        self.unreadWorkspaceNotificationCount = max(0, unreadWorkspaceNotificationCount)
        self.recentlyClosedPanels = recentlyClosedPanels
    }

    public static func bootstrap(title: String = "Workspace 1") -> WorkspaceState {
        let panelID = UUID()
        let slotID = UUID()
        return WorkspaceState(
            id: UUID(),
            title: title,
            layoutTree: .slot(slotID: slotID, panelID: panelID),
            panels: [
                panelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: NSHomeDirectory())),
            ],
            focusedPanelID: panelID
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case layoutTree
        case panels
        case focusedPanelID
        case auxPanelVisibility
        case unreadPanelIDs
        case unreadWorkspaceNotificationCount
        case unreadNotificationCount
        case recentlyClosedPanels
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        layoutTree = try container.decode(LayoutNode.self, forKey: .layoutTree)
        panels = try container.decode([UUID: PanelState].self, forKey: .panels)
        focusedPanelID = try container.decodeIfPresent(UUID.self, forKey: .focusedPanelID)
        auxPanelVisibility = try container.decodeIfPresent(Set<PanelKind>.self, forKey: .auxPanelVisibility) ?? []
        unreadPanelIDs = (try container.decodeIfPresent(Set<UUID>.self, forKey: .unreadPanelIDs) ?? [])
            .intersection(Set(panels.keys))
        let decodedWorkspaceUnread = try container.decodeIfPresent(Int.self, forKey: .unreadWorkspaceNotificationCount)
        let legacyUnreadCount = try container.decodeIfPresent(Int.self, forKey: .unreadNotificationCount)
        unreadWorkspaceNotificationCount = max(0, decodedWorkspaceUnread ?? legacyUnreadCount ?? 0)
        recentlyClosedPanels = try container.decodeIfPresent([ClosedPanelRecord].self, forKey: .recentlyClosedPanels) ?? []
        // Focus mode is a transient UI/runtime flag and should never persist across decode boundaries.
        focusedPanelModeActive = false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(layoutTree, forKey: .layoutTree)
        try container.encode(panels, forKey: .panels)
        try container.encodeIfPresent(focusedPanelID, forKey: .focusedPanelID)
        try container.encode(auxPanelVisibility, forKey: .auxPanelVisibility)
        try container.encode(unreadPanelIDs, forKey: .unreadPanelIDs)
        try container.encode(unreadWorkspaceNotificationCount, forKey: .unreadWorkspaceNotificationCount)
        // Backwards compatibility with older persisted state shape.
        try container.encode(unreadNotificationCount, forKey: .unreadNotificationCount)
        try container.encode(recentlyClosedPanels, forKey: .recentlyClosedPanels)
    }
}
