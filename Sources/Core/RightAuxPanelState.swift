import Foundation

public struct RightAuxPanelState: Codable, Equatable, Sendable {
    public static let defaultWidth: Double = 360
    public static let minWidth: Double = 260
    public static let maxWidth: Double = 640

    public var isVisible: Bool
    public var width: Double
    public var activeTabID: UUID?
    public var tabIDs: [UUID]
    public var tabsByID: [UUID: RightAuxPanelTabState]

    // Transient UI focus signal. This intentionally does not persist.
    public var focusedPanelID: UUID?

    public init(
        isVisible: Bool = false,
        width: Double = Self.defaultWidth,
        activeTabID: UUID? = nil,
        tabIDs: [UUID] = [],
        tabsByID: [UUID: RightAuxPanelTabState] = [:],
        focusedPanelID: UUID? = nil
    ) {
        self.isVisible = isVisible
        self.width = Self.clampedWidth(width)
        self.activeTabID = activeTabID
        self.tabIDs = tabIDs
        self.tabsByID = tabsByID
        self.focusedPanelID = focusedPanelID
        repairTransientState()
    }

    public var orderedTabs: [RightAuxPanelTabState] {
        tabIDs.compactMap { tabsByID[$0] }
    }

    public var activeTab: RightAuxPanelTabState? {
        guard let activeTabID else { return nil }
        return tabsByID[activeTabID]
    }

    public var activePanelID: UUID? {
        activeTab?.panelID
    }

    public var panelIDs: Set<UUID> {
        Set(tabsByID.values.map(\.panelID))
    }

    public static func clampedWidth(_ width: Double) -> Double {
        min(max(width, minWidth), maxWidth)
    }

    public func tabID(containingPanelID panelID: UUID) -> UUID? {
        orderedTabs.first(where: { $0.panelID == panelID })?.id
    }

    public func tabID(matching identity: RightAuxPanelTabIdentity) -> UUID? {
        orderedTabs.first(where: { $0.identity == identity })?.id
    }

    public func panelState(for panelID: UUID) -> PanelState? {
        guard let tabID = tabID(containingPanelID: panelID) else { return nil }
        return tabsByID[tabID]?.panelState
    }

    public mutating func appendTab(_ tab: RightAuxPanelTabState, activate: Bool = true) {
        tabsByID[tab.id] = tab
        if tabIDs.contains(tab.id) == false {
            tabIDs.append(tab.id)
        }
        if activate || activeTabID == nil {
            activeTabID = tab.id
        }
        isVisible = true
        repairTransientState()
    }

    @discardableResult
    public mutating func removeTab(id tabID: UUID) -> RightAuxPanelTabState? {
        guard let removedTab = tabsByID.removeValue(forKey: tabID),
              let tabIndex = tabIDs.firstIndex(of: tabID) else {
            return nil
        }

        tabIDs.remove(at: tabIndex)
        if activeTabID == tabID {
            if tabIDs.indices.contains(tabIndex) {
                activeTabID = tabIDs[tabIndex]
            } else {
                activeTabID = tabIDs.last
            }
        }
        if focusedPanelID == removedTab.panelID {
            focusedPanelID = nil
        }
        if tabIDs.isEmpty {
            activeTabID = nil
            focusedPanelID = nil
            isVisible = false
        }
        return removedTab
    }

    public mutating func repairTransientState() {
        width = Self.clampedWidth(width)

        var orderedIDs: [UUID] = []
        var seenIDs: Set<UUID> = []
        var repairedTabsByID: [UUID: RightAuxPanelTabState] = [:]

        for tabID in tabIDs where seenIDs.contains(tabID) == false {
            guard let tab = tabsByID[tabID],
                  tab.id == tabID else {
                continue
            }
            orderedIDs.append(tabID)
            seenIDs.insert(tabID)
            repairedTabsByID[tabID] = tab
        }

        for tabID in tabsByID.keys.sorted(by: { $0.uuidString < $1.uuidString }) where seenIDs.contains(tabID) == false {
            guard let tab = tabsByID[tabID],
                  tab.id == tabID else {
                continue
            }
            orderedIDs.append(tabID)
            repairedTabsByID[tabID] = tab
        }

        tabIDs = orderedIDs
        tabsByID = repairedTabsByID

        if tabIDs.isEmpty {
            isVisible = false
            activeTabID = nil
            focusedPanelID = nil
            return
        }

        if let activeTabID,
           tabIDs.contains(activeTabID) == false {
            self.activeTabID = tabIDs.first
        } else if activeTabID == nil {
            activeTabID = tabIDs.first
        }

        if let focusedPanelID,
           panelIDs.contains(focusedPanelID) == false {
            self.focusedPanelID = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case isVisible
        case width
        case activeTabID
        case tabIDs
        case tabsByID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? false
        width = try container.decodeIfPresent(Double.self, forKey: .width) ?? Self.defaultWidth
        activeTabID = try container.decodeIfPresent(UUID.self, forKey: .activeTabID)
        tabIDs = try container.decodeIfPresent([UUID].self, forKey: .tabIDs) ?? []
        tabsByID = try container.decodeIfPresent([UUID: RightAuxPanelTabState].self, forKey: .tabsByID) ?? [:]
        focusedPanelID = nil
        repairTransientState()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isVisible, forKey: .isVisible)
        try container.encode(width, forKey: .width)
        try container.encodeIfPresent(activeTabID, forKey: .activeTabID)
        try container.encode(tabIDs, forKey: .tabIDs)
        try container.encode(tabsByID, forKey: .tabsByID)
    }
}

public struct RightAuxPanelTabState: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var identity: RightAuxPanelTabIdentity
    public var panelID: UUID
    public var panelState: PanelState

    public init(
        id: UUID,
        identity: RightAuxPanelTabIdentity,
        panelID: UUID,
        panelState: PanelState
    ) {
        self.id = id
        self.identity = identity
        self.panelID = panelID
        self.panelState = panelState
    }
}

public enum RightAuxPanelTabIdentity: Codable, Equatable, Hashable, Sendable {
    case localDocument(path: String)
    case scratchpad(id: UUID)
    case diff(id: UUID)
    case browserSession(UUID)

    public static func identity(for webState: WebPanelState, panelID: UUID) -> RightAuxPanelTabIdentity {
        switch webState.definition {
        case .localDocument:
            if let filePath = WebPanelState.normalizedFilePath(webState.filePath) {
                return .localDocument(path: (filePath as NSString).standardizingPath)
            }
            return .browserSession(panelID)
        case .scratchpad:
            return .scratchpad(id: panelID)
        case .diff:
            return .diff(id: panelID)
        case .browser:
            return .browserSession(panelID)
        }
    }
}
