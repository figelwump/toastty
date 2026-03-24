import Foundation

public struct WorkspaceTabState: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var layoutTree: LayoutNode
    public var panels: [UUID: PanelState]
    public var focusedPanelID: UUID?
    public var auxPanelVisibility: Set<PanelKind>
    public var focusedPanelModeActive: Bool
    public var unreadPanelIDs: Set<UUID>
    public var recentlyClosedPanels: [ClosedPanelRecord]

    public init(
        id: UUID,
        layoutTree: LayoutNode,
        panels: [UUID: PanelState],
        focusedPanelID: UUID?,
        auxPanelVisibility: Set<PanelKind> = [],
        focusedPanelModeActive: Bool = false,
        unreadPanelIDs: Set<UUID> = [],
        recentlyClosedPanels: [ClosedPanelRecord] = []
    ) {
        self.id = id
        self.layoutTree = layoutTree
        self.panels = panels
        self.focusedPanelID = focusedPanelID
        self.auxPanelVisibility = auxPanelVisibility
        self.focusedPanelModeActive = focusedPanelModeActive
        self.unreadPanelIDs = unreadPanelIDs.intersection(Set(panels.keys))
        self.recentlyClosedPanels = recentlyClosedPanels
    }

    public static func bootstrap(
        initialTerminalCWD: String? = nil,
        initialTerminalProfileBinding: TerminalProfileBinding? = nil,
        terminalTitle: String = "Terminal 1"
    ) -> WorkspaceTabState {
        let panelID = UUID()
        let slotID = UUID()
        return WorkspaceTabState(
            id: UUID(),
            layoutTree: .slot(slotID: slotID, panelID: panelID),
            panels: [
                panelID: .terminal(
                    TerminalPanelState(
                        title: terminalTitle,
                        shell: "zsh",
                        cwd: normalizedInitialTerminalCWD(initialTerminalCWD) ?? NSHomeDirectory(),
                        profileBinding: initialTerminalProfileBinding
                    )
                ),
            ],
            focusedPanelID: panelID
        )
    }

    public var displayTitle: String {
        if let focusedPanelID = resolvedFocusedPanelID,
           let panelState = panels[focusedPanelID] {
            return panelState.notificationLabel
        }

        for slot in layoutTree.allSlotInfos {
            if let panelState = panels[slot.panelID] {
                return panelState.notificationLabel
            }
        }

        return "Tab"
    }

    public var allPanelIDs: Set<UUID> {
        Set(panels.keys)
    }

    public var resolvedFocusedPanelID: UUID? {
        if let focusedPanelID,
           panels[focusedPanelID] != nil,
           layoutTree.slotContaining(panelID: focusedPanelID) != nil {
            return focusedPanelID
        }

        for slot in layoutTree.allSlotInfos where panels[slot.panelID] != nil {
            return slot.panelID
        }

        return nil
    }

    public func slotID(containingPanelID panelID: UUID) -> UUID? {
        layoutTree.slotContaining(panelID: panelID)?.slotID
    }

    private static func normalizedInitialTerminalCWD(_ cwd: String?) -> String? {
        guard let cwd else { return nil }
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let normalizedPath = (trimmed as NSString).standardizingPath
        guard normalizedPath.isEmpty == false else { return nil }
        return normalizedPath
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case layoutTree
        case panels
        case focusedPanelID
        case auxPanelVisibility
        case unreadPanelIDs
        case recentlyClosedPanels
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        layoutTree = try container.decode(LayoutNode.self, forKey: .layoutTree)
        panels = try container.decode([UUID: PanelState].self, forKey: .panels)
        focusedPanelID = try container.decodeIfPresent(UUID.self, forKey: .focusedPanelID)
        auxPanelVisibility = try container.decodeIfPresent(Set<PanelKind>.self, forKey: .auxPanelVisibility) ?? []
        unreadPanelIDs = (try container.decodeIfPresent(Set<UUID>.self, forKey: .unreadPanelIDs) ?? [])
            .intersection(Set(panels.keys))
        recentlyClosedPanels = try container.decodeIfPresent([ClosedPanelRecord].self, forKey: .recentlyClosedPanels) ?? []
        // Focus mode is a transient UI/runtime flag and should never persist across decode boundaries.
        focusedPanelModeActive = false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(layoutTree, forKey: .layoutTree)
        try container.encode(panels, forKey: .panels)
        try container.encodeIfPresent(focusedPanelID, forKey: .focusedPanelID)
        try container.encode(auxPanelVisibility, forKey: .auxPanelVisibility)
        try container.encode(unreadPanelIDs, forKey: .unreadPanelIDs)
        try container.encode(recentlyClosedPanels, forKey: .recentlyClosedPanels)
    }
}
