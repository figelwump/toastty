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
    public var selectedTabID: UUID?
    public var tabIDs: [UUID]
    public var tabsByID: [UUID: WorkspaceTabState]
    public var unreadWorkspaceNotificationCount: Int
    public var unreadNotificationCount: Int {
        tabsByID.values.reduce(unreadWorkspaceNotificationCount) { partialResult, tab in
            partialResult + tab.unreadPanelIDs.count
        }
    }
    public var unreadPanelCount: Int {
        tabsByID.values.reduce(0) { partialResult, tab in
            partialResult + tab.unreadPanelIDs.count
        }
    }

    public init(
        id: UUID,
        title: String,
        selectedTabID: UUID?,
        tabIDs: [UUID],
        tabsByID: [UUID: WorkspaceTabState],
        unreadWorkspaceNotificationCount: Int = 0
    ) {
        let sanitizedTabs = Self.sanitizedTabs(
            preferredSelectedTabID: selectedTabID,
            tabIDs: tabIDs,
            tabsByID: tabsByID
        )
        self.id = id
        self.title = title
        self.selectedTabID = sanitizedTabs.selectedTabID
        self.tabIDs = sanitizedTabs.tabIDs
        self.tabsByID = sanitizedTabs.tabsByID
        self.unreadWorkspaceNotificationCount = max(0, unreadWorkspaceNotificationCount)
    }

    public init(
        id: UUID,
        title: String,
        layoutTree: LayoutNode,
        panels: [UUID: PanelState],
        focusedPanelID: UUID?,
        focusedPanelModeActive: Bool = false,
        focusModeRootNodeID: UUID? = nil,
        selectedPanelIDs: Set<UUID> = [],
        unreadPanelIDs: Set<UUID> = [],
        unreadWorkspaceNotificationCount: Int = 0,
        recentlyClosedPanels: [ClosedPanelRecord] = []
    ) {
        let tab = WorkspaceTabState(
            id: UUID(),
            layoutTree: layoutTree,
            panels: panels,
            focusedPanelID: focusedPanelID,
            focusedPanelModeActive: focusedPanelModeActive,
            focusModeRootNodeID: focusModeRootNodeID,
            selectedPanelIDs: selectedPanelIDs,
            unreadPanelIDs: unreadPanelIDs,
            recentlyClosedPanels: recentlyClosedPanels
        )
        self.init(
            id: id,
            title: title,
            selectedTabID: tab.id,
            tabIDs: [tab.id],
            tabsByID: [tab.id: tab],
            unreadWorkspaceNotificationCount: unreadWorkspaceNotificationCount
        )
    }

    public static func bootstrap(
        title: String = "Workspace 1",
        initialTerminalCWD: String? = nil,
        initialTerminalProfileBinding: TerminalProfileBinding? = nil
    ) -> WorkspaceState {
        let tab = WorkspaceTabState.bootstrap(
            initialTerminalCWD: initialTerminalCWD,
            initialTerminalProfileBinding: initialTerminalProfileBinding
        )
        return WorkspaceState(
            id: UUID(),
            title: title,
            selectedTabID: tab.id,
            tabIDs: [tab.id],
            tabsByID: [tab.id: tab]
        )
    }

    public var orderedTabs: [WorkspaceTabState] {
        tabIDs.compactMap { tabsByID[$0] }
    }

    public var selectedTab: WorkspaceTabState? {
        guard let resolvedSelectedTabID else { return nil }
        return tabsByID[resolvedSelectedTabID]
    }

    public var resolvedSelectedTabID: UUID? {
        if let selectedTabID,
           tabsByID[selectedTabID] != nil,
           tabIDs.contains(selectedTabID) {
            return selectedTabID
        }

        for tabID in tabIDs where tabsByID[tabID] != nil {
            return tabID
        }

        return tabsByID.keys.sorted { $0.uuidString < $1.uuidString }.first
    }

    public var layoutTree: LayoutNode {
        get { requiredSelectedTab.layoutTree }
        set { updateSelectedTab { $0.layoutTree = newValue } }
    }

    public var panels: [UUID: PanelState] {
        get { requiredSelectedTab.panels }
        set { updateSelectedTab { $0.panels = newValue } }
    }

    public var focusedPanelID: UUID? {
        get { requiredSelectedTab.focusedPanelID }
        set { updateSelectedTab { $0.focusedPanelID = newValue } }
    }

    public var focusedPanelModeActive: Bool {
        get { requiredSelectedTab.focusedPanelModeActive }
        set { updateSelectedTab { $0.focusedPanelModeActive = newValue } }
    }

    public var focusModeRootNodeID: UUID? {
        get { requiredSelectedTab.focusModeRootNodeID }
        set { updateSelectedTab { $0.focusModeRootNodeID = newValue } }
    }

    public var selectedPanelIDs: Set<UUID> {
        get { requiredSelectedTab.selectedPanelIDs }
        set { updateSelectedTab { $0.selectedPanelIDs = newValue } }
    }

    public var unreadPanelIDs: Set<UUID> {
        get { requiredSelectedTab.unreadPanelIDs }
        set { updateSelectedTab { $0.unreadPanelIDs = newValue } }
    }

    public var recentlyClosedPanels: [ClosedPanelRecord] {
        get { requiredSelectedTab.recentlyClosedPanels }
        set { updateSelectedTab { $0.recentlyClosedPanels = newValue } }
    }

    public var selectedTabDisplayTitle: String {
        selectedTab?.displayTitle ?? "Tab"
    }

    public var allPanelsByID: [UUID: PanelState] {
        orderedTabs.reduce(into: [UUID: PanelState]()) { partialResult, tab in
            for (panelID, panelState) in tab.panels {
                partialResult[panelID] = panelState
            }
        }
    }

    public var allTerminalPanelIDs: Set<UUID> {
        orderedTabs.reduce(into: Set<UUID>()) { partialResult, tab in
            for (panelID, panelState) in tab.panels {
                guard case .terminal = panelState else { continue }
                partialResult.insert(panelID)
            }
        }
    }

    public func tab(id tabID: UUID) -> WorkspaceTabState? {
        tabsByID[tabID]
    }

    public func panelState(for panelID: UUID) -> PanelState? {
        if let panelState = selectedTab?.panels[panelID] {
            return panelState
        }

        for tab in orderedTabs where tab.id != resolvedSelectedTabID {
            if let panelState = tab.panels[panelID] {
                return panelState
            }
        }

        return nil
    }

    public func tabID(containingPanelID panelID: UUID) -> UUID? {
        for tab in orderedTabs where tab.layoutTree.slotContaining(panelID: panelID) != nil {
            return tab.id
        }
        return nil
    }

    public func tabID(containingSlotID slotID: UUID) -> UUID? {
        for tab in orderedTabs where tab.layoutTree.allSlotInfos.contains(where: { $0.slotID == slotID }) {
            return tab.id
        }
        return nil
    }

    public func slotID(containingPanelID panelID: UUID) -> UUID? {
        for tab in orderedTabs {
            if let slotID = tab.slotID(containingPanelID: panelID) {
                return slotID
            }
        }
        return nil
    }

    @discardableResult
    public mutating func updateTab(
        id tabID: UUID,
        _ update: (inout WorkspaceTabState) -> Void
    ) -> Bool {
        guard var tab = tabsByID[tabID] else { return false }
        update(&tab)
        tabsByID[tabID] = tab
        if selectedTabID == nil {
            selectedTabID = tabID
        }
        return true
    }

    @discardableResult
    public mutating func updateSelectedTab(_ update: (inout WorkspaceTabState) -> Void) -> Bool {
        guard let resolvedSelectedTabID else { return false }
        return updateTab(id: resolvedSelectedTabID, update)
    }

    public mutating func appendTab(_ tab: WorkspaceTabState, select: Bool) {
        tabsByID[tab.id] = tab
        if tabIDs.contains(tab.id) == false {
            tabIDs.append(tab.id)
        }
        if select || selectedTabID == nil {
            selectedTabID = tab.id
        }
    }

    @discardableResult
    public mutating func removeTab(id tabID: UUID) -> WorkspaceTabState? {
        guard let removedTab = tabsByID.removeValue(forKey: tabID),
              let tabIndex = tabIDs.firstIndex(of: tabID) else {
            return nil
        }

        tabIDs.remove(at: tabIndex)
        if selectedTabID == tabID {
            if tabIDs.indices.contains(tabIndex) {
                selectedTabID = tabIDs[tabIndex]
            } else {
                selectedTabID = tabIDs.last
            }
        } else if selectedTabID == nil {
            selectedTabID = tabIDs.first
        }
        return removedTab
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case selectedTabID
        case tabIDs
        case tabsByID
        case layoutTree
        case panels
        case focusedPanelID
        case unreadPanelIDs
        case unreadWorkspaceNotificationCount
        case unreadNotificationCount
        case recentlyClosedPanels
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        let decodedSelectedTabID = try container.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        let decodedTabIDs = try container.decodeIfPresent([UUID].self, forKey: .tabIDs)
        let decodedTabsByID = try container.decodeIfPresent([UUID: WorkspaceTabState].self, forKey: .tabsByID)

        if let decodedTabIDs, let decodedTabsByID, decodedTabsByID.isEmpty == false {
            let sanitizedTabs = Self.sanitizedTabs(
                preferredSelectedTabID: decodedSelectedTabID,
                tabIDs: decodedTabIDs,
                tabsByID: decodedTabsByID
            )
            selectedTabID = sanitizedTabs.selectedTabID
            tabIDs = sanitizedTabs.tabIDs
            tabsByID = sanitizedTabs.tabsByID
        } else {
            let layoutTree = try container.decode(LayoutNode.self, forKey: .layoutTree)
            let panels = try container.decode([UUID: PanelState].self, forKey: .panels)
            let focusedPanelID = try container.decodeIfPresent(UUID.self, forKey: .focusedPanelID)
            let unreadPanelIDs = (try container.decodeIfPresent(Set<UUID>.self, forKey: .unreadPanelIDs) ?? [])
                .intersection(Set(panels.keys))
            let recentlyClosedPanels = try container.decodeIfPresent([ClosedPanelRecord].self, forKey: .recentlyClosedPanels) ?? []
            let legacyTab = WorkspaceTabState(
                id: UUID(),
                layoutTree: layoutTree,
                panels: panels,
                focusedPanelID: focusedPanelID,
                focusedPanelModeActive: false,
                unreadPanelIDs: unreadPanelIDs,
                recentlyClosedPanels: recentlyClosedPanels
            )
            selectedTabID = legacyTab.id
            tabIDs = [legacyTab.id]
            tabsByID = [legacyTab.id: legacyTab]
        }
        let decodedWorkspaceUnread = try container.decodeIfPresent(Int.self, forKey: .unreadWorkspaceNotificationCount)
        let legacyUnreadCount = try container.decodeIfPresent(Int.self, forKey: .unreadNotificationCount)
        unreadWorkspaceNotificationCount = max(0, decodedWorkspaceUnread ?? legacyUnreadCount ?? 0)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(resolvedSelectedTabID, forKey: .selectedTabID)
        try container.encode(tabIDs, forKey: .tabIDs)
        try container.encode(tabsByID, forKey: .tabsByID)
        // Preserve a best-effort legacy mirror of the selected tab for older
        // persisted-state readers while the multi-tab shape rolls out.
        try container.encode(layoutTree, forKey: .layoutTree)
        try container.encode(panels, forKey: .panels)
        try container.encodeIfPresent(focusedPanelID, forKey: .focusedPanelID)
        try container.encode(unreadPanelIDs, forKey: .unreadPanelIDs)
        try container.encode(unreadWorkspaceNotificationCount, forKey: .unreadWorkspaceNotificationCount)
        // Backwards compatibility with older persisted state shape.
        try container.encode(unreadNotificationCount, forKey: .unreadNotificationCount)
        try container.encode(recentlyClosedPanels, forKey: .recentlyClosedPanels)
    }

    private static func sanitizedTabs(
        preferredSelectedTabID: UUID?,
        tabIDs: [UUID],
        tabsByID: [UUID: WorkspaceTabState]
    ) -> (selectedTabID: UUID, tabIDs: [UUID], tabsByID: [UUID: WorkspaceTabState]) {
        var orderedIDs: [UUID] = []
        var seenIDs: Set<UUID> = []

        for tabID in tabIDs where seenIDs.contains(tabID) == false && tabsByID[tabID] != nil {
            orderedIDs.append(tabID)
            seenIDs.insert(tabID)
        }

        for tabID in tabsByID.keys.sorted(by: { $0.uuidString < $1.uuidString }) where seenIDs.contains(tabID) == false {
            orderedIDs.append(tabID)
            seenIDs.insert(tabID)
        }

        var sanitizedTabsByID = tabsByID
        if orderedIDs.isEmpty {
            let fallbackTab = WorkspaceTabState.bootstrap()
            orderedIDs = [fallbackTab.id]
            sanitizedTabsByID = [fallbackTab.id: fallbackTab]
        }

        let selectedTabID: UUID
        if let preferredSelectedTabID,
           orderedIDs.contains(preferredSelectedTabID) {
            selectedTabID = preferredSelectedTabID
        } else {
            selectedTabID = orderedIDs[0]
        }

        return (selectedTabID, orderedIDs, sanitizedTabsByID)
    }

    private var requiredSelectedTab: WorkspaceTabState {
        guard let selectedTab = selectedTab else {
            preconditionFailure("Workspace \(id) must always resolve a selected tab")
        }
        return selectedTab
    }
}
