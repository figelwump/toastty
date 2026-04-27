import Foundation

public struct WorkspaceTabState: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var customTitle: String?
    public var layoutTree: LayoutNode
    public var panels: [UUID: PanelState]
    public var focusedPanelID: UUID?
    public var focusedPanelModeActive: Bool
    public var focusModeRootNodeID: UUID?
    public var selectedPanelIDs: Set<UUID>
    public var unreadPanelIDs: Set<UUID>
    public var recentlyClosedPanels: [ClosedPanelRecord]
    public var rightAuxPanel: RightAuxPanelState

    public init(
        id: UUID,
        customTitle: String? = nil,
        layoutTree: LayoutNode,
        panels: [UUID: PanelState],
        focusedPanelID: UUID?,
        focusedPanelModeActive: Bool = false,
        focusModeRootNodeID: UUID? = nil,
        selectedPanelIDs: Set<UUID> = [],
        unreadPanelIDs: Set<UUID> = [],
        recentlyClosedPanels: [ClosedPanelRecord] = [],
        rightAuxPanel: RightAuxPanelState = RightAuxPanelState()
    ) {
        self.id = id
        self.customTitle = Self.normalizedCustomTitle(customTitle)
        self.layoutTree = layoutTree
        self.panels = panels
        self.focusedPanelID = focusedPanelID
        self.focusedPanelModeActive = focusedPanelModeActive
        self.focusModeRootNodeID = focusModeRootNodeID
        self.selectedPanelIDs = selectedPanelIDs.intersection(Set(panels.keys))
        self.unreadPanelIDs = unreadPanelIDs.intersection(
            Self.validUnreadPanelIDs(panels: panels, rightAuxPanel: rightAuxPanel)
        )
        self.recentlyClosedPanels = recentlyClosedPanels
        self.rightAuxPanel = rightAuxPanel
        self.rightAuxPanel.repairTransientState()
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
        if let customTitle {
            return customTitle
        }

        return derivedDisplayTitle
    }

    private var derivedDisplayTitle: String {
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
        Self.validUnreadPanelIDs(panels: panels, rightAuxPanel: rightAuxPanel)
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
        case customTitle
        case layoutTree
        case panels
        case focusedPanelID
        case unreadPanelIDs
        case recentlyClosedPanels
        case rightAuxPanel
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        customTitle = Self.normalizedCustomTitle(try container.decodeIfPresent(String.self, forKey: .customTitle))
        layoutTree = try container.decode(LayoutNode.self, forKey: .layoutTree)
        panels = try container.decode([UUID: PanelState].self, forKey: .panels)
        focusedPanelID = try container.decodeIfPresent(UUID.self, forKey: .focusedPanelID)
        recentlyClosedPanels = try container.decodeIfPresent([ClosedPanelRecord].self, forKey: .recentlyClosedPanels) ?? []
        rightAuxPanel = try container.decodeIfPresent(RightAuxPanelState.self, forKey: .rightAuxPanel) ?? RightAuxPanelState()
        unreadPanelIDs = (try container.decodeIfPresent(Set<UUID>.self, forKey: .unreadPanelIDs) ?? [])
            .intersection(Self.validUnreadPanelIDs(panels: panels, rightAuxPanel: rightAuxPanel))
        // Focus mode is a transient UI/runtime flag and should never persist across decode boundaries.
        focusedPanelModeActive = false
        focusModeRootNodeID = nil
        selectedPanelIDs = []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(customTitle, forKey: .customTitle)
        try container.encode(layoutTree, forKey: .layoutTree)
        try container.encode(panels, forKey: .panels)
        try container.encodeIfPresent(focusedPanelID, forKey: .focusedPanelID)
        try container.encode(unreadPanelIDs, forKey: .unreadPanelIDs)
        try container.encode(recentlyClosedPanels, forKey: .recentlyClosedPanels)
        try container.encode(rightAuxPanel, forKey: .rightAuxPanel)
    }

    private static func validUnreadPanelIDs(
        panels: [UUID: PanelState],
        rightAuxPanel: RightAuxPanelState
    ) -> Set<UUID> {
        Set(panels.keys).union(rightAuxPanel.panelIDs)
    }

    private static func normalizedCustomTitle(_ customTitle: String?) -> String? {
        guard let customTitle else { return nil }
        let trimmed = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return trimmed
    }
}
