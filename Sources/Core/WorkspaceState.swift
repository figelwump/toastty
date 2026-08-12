import Foundation

/// One structured `key -> (text, url?)` chip shown under a workspace name.
/// Keys are canonicalized identifiers; text and URL pass the shared
/// validation helpers below so CLI writes and persisted-file decodes cannot
/// diverge.
public struct WorkspaceAnnotation: Codable, Equatable, Sendable {
    public var text: String
    public var url: String?

    public init(text: String, url: String? = nil) {
        self.text = text
        self.url = url
    }
}

public extension WorkspaceAnnotation {
    static let maximumKeyLength = 32
    static let maximumTextCharacterCount = 80
    static let maximumAnnotationsPerWorkspace = 12

    /// Trims and lowercases a raw key. Returns nil unless the result is 1-32
    /// characters drawn from ASCII letters, digits, `.`, `_`, and `-`.
    /// Overlong or invalid keys are rejected, never truncated.
    static func canonicalKey(_ rawKey: String) -> String? {
        let candidate = rawKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard candidate.isEmpty == false,
              candidate.count <= maximumKeyLength else {
            return nil
        }
        let allowedScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        guard candidate.unicodeScalars.allSatisfy(allowedScalars.contains) else {
            return nil
        }
        return candidate
    }

    /// Trims and NFC-normalizes chip text. Returns nil when the result is
    /// empty, longer than 80 user-perceived characters, or contains control,
    /// line/paragraph separator, or bidi override/isolate scalars. Valid
    /// emoji, including zero-width-joiner sequences, remain allowed.
    static func normalizedText(_ rawText: String) -> String? {
        let normalized = rawText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard normalized.isEmpty == false,
              normalized.count <= maximumTextCharacterCount else {
            return nil
        }
        guard normalized.unicodeScalars.allSatisfy({ isAllowedTextScalar($0) }) else {
            return nil
        }
        return normalized
    }

    /// Accepts only absolute `http` / `https` URLs with a host.
    static func validatedURLString(_ rawURL: String) -> String? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, host.isEmpty == false else {
            return nil
        }
        return trimmed
    }

    /// Whole-value validation shared by the reducer and defensive decoding.
    static func validated(text: String, url: String?) -> WorkspaceAnnotation? {
        guard let normalizedText = normalizedText(text) else { return nil }
        if let url {
            guard let validatedURL = validatedURLString(url) else { return nil }
            return WorkspaceAnnotation(text: normalizedText, url: validatedURL)
        }
        return WorkspaceAnnotation(text: normalizedText, url: nil)
    }

    /// Retains only entries whose stored key is already canonical and whose
    /// value passes validation. Persisted files are user-editable, so invalid
    /// entries are dropped and logged individually instead of failing the
    /// whole decode. Valid values are normalized and the public per-workspace
    /// count limit is enforced deterministically.
    static func sanitizedAnnotations(
        _ rawAnnotations: [String: WorkspaceAnnotation],
        workspaceID: UUID
    ) -> [String: WorkspaceAnnotation] {
        rawAnnotations.sorted { $0.key < $1.key }.reduce(into: [:]) { partialResult, entry in
            guard canonicalKey(entry.key) == entry.key,
                  let validated = validated(text: entry.value.text, url: entry.value.url) else {
                ToasttyLog.warning(
                    "Dropped invalid persisted workspace annotation",
                    category: .state,
                    metadata: [
                        "workspace_id": workspaceID.uuidString,
                        "key_length": String(entry.key.count),
                    ]
                )
                return
            }
            guard partialResult.count < maximumAnnotationsPerWorkspace else {
                ToasttyLog.warning(
                    "Dropped persisted workspace annotation above count limit",
                    category: .state,
                    metadata: [
                        "workspace_id": workspaceID.uuidString,
                        "key_length": String(entry.key.count),
                        "maximum_count": String(maximumAnnotationsPerWorkspace),
                    ]
                )
                return
            }
            partialResult[entry.key] = validated
        }
    }

    private static func isAllowedTextScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.generalCategory == .control {
            return false
        }
        switch scalar.value {
        case 0x2028, 0x2029, // line / paragraph separators
             0x202A...0x202E, // bidi embedding and override controls
             0x2066...0x2069: // bidi isolate controls
            return false
        default:
            return true
        }
    }
}

extension WorkspaceAnnotation {
    /// Decodes a user-editable annotations object one value at a time. A
    /// structurally malformed entry must not make the surrounding workspace,
    /// profile, or complete persistence document undecodable.
    static func decodeSanitizedAnnotations<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key,
        workspaceID: UUID
    ) -> [String: WorkspaceAnnotation] {
        guard container.contains(key) else { return [:] }
        if (try? container.decodeNil(forKey: key)) == true { return [:] }

        let annotationsContainer: KeyedDecodingContainer<WorkspaceAnnotationCodingKey>
        do {
            annotationsContainer = try container.nestedContainer(
                keyedBy: WorkspaceAnnotationCodingKey.self,
                forKey: key
            )
        } catch {
            ToasttyLog.warning(
                "Ignored malformed persisted workspace annotations object",
                category: .state,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "error": error.localizedDescription,
                ]
            )
            return [:]
        }

        var decoded: [String: WorkspaceAnnotation] = [:]
        for annotationKey in annotationsContainer.allKeys {
            do {
                decoded[annotationKey.stringValue] = try annotationsContainer.decode(
                    WorkspaceAnnotation.self,
                    forKey: annotationKey
                )
            } catch {
                ToasttyLog.warning(
                    "Dropped malformed persisted workspace annotation",
                    category: .state,
                    metadata: [
                        "workspace_id": workspaceID.uuidString,
                        "key_length": String(annotationKey.stringValue.count),
                        "error": error.localizedDescription,
                    ]
                )
            }
        }
        return sanitizedAnnotations(decoded, workspaceID: workspaceID)
    }
}

private struct WorkspaceAnnotationCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

public struct ClosedPanelRecord: Codable, Equatable, Sendable {
    public let panelState: PanelState
    public let closedAt: Date
    public let sourceSlotID: UUID
    public let sourceTabID: UUID?
    public let sourceTabIndex: Int?
    public let sourceTabPredecessorID: UUID?
    public let sourceTabSuccessorID: UUID?
    public let sourceTabCustomTitle: String?

    public init(
        panelState: PanelState,
        closedAt: Date,
        sourceSlotID: UUID,
        sourceTabID: UUID? = nil,
        sourceTabIndex: Int? = nil,
        sourceTabPredecessorID: UUID? = nil,
        sourceTabSuccessorID: UUID? = nil,
        sourceTabCustomTitle: String? = nil
    ) {
        self.panelState = panelState
        self.closedAt = closedAt
        self.sourceSlotID = sourceSlotID
        self.sourceTabID = sourceTabID
        self.sourceTabIndex = sourceTabIndex
        self.sourceTabPredecessorID = sourceTabPredecessorID
        self.sourceTabSuccessorID = sourceTabSuccessorID
        if let sourceTabCustomTitle {
            let trimmed = sourceTabCustomTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            self.sourceTabCustomTitle = trimmed.isEmpty ? nil : trimmed
        } else {
            self.sourceTabCustomTitle = nil
        }
    }
}

public struct WorkspaceState: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var hasBeenVisited: Bool
    public var selectedTabID: UUID?
    public var tabIDs: [UUID]
    public var tabsByID: [UUID: WorkspaceTabState]
    public var annotations: [String: WorkspaceAnnotation]
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
        hasBeenVisited: Bool = true,
        selectedTabID: UUID?,
        tabIDs: [UUID],
        tabsByID: [UUID: WorkspaceTabState],
        rightAuxPanel: RightAuxPanelState? = nil,
        annotations: [String: WorkspaceAnnotation] = [:],
        unreadWorkspaceNotificationCount: Int = 0
    ) {
        let sanitizedTabs = Self.sanitizedTabs(
            preferredSelectedTabID: selectedTabID,
            tabIDs: tabIDs,
            tabsByID: tabsByID
        )
        var seededTabsByID = sanitizedTabs.tabsByID
        if let rightAuxPanel,
           var selectedTab = seededTabsByID[sanitizedTabs.selectedTabID] {
            selectedTab.rightAuxPanel = rightAuxPanel
            seededTabsByID[sanitizedTabs.selectedTabID] = selectedTab
        }
        self.id = id
        self.title = title
        self.hasBeenVisited = hasBeenVisited
        self.selectedTabID = sanitizedTabs.selectedTabID
        self.tabIDs = sanitizedTabs.tabIDs
        self.tabsByID = seededTabsByID
        self.annotations = annotations
        self.unreadWorkspaceNotificationCount = max(0, unreadWorkspaceNotificationCount)
    }

    public init(
        id: UUID,
        title: String,
        hasBeenVisited: Bool = true,
        layoutTree: LayoutNode,
        panels: [UUID: PanelState],
        focusedPanelID: UUID?,
        focusedPanelModeActive: Bool = false,
        focusModeRootNodeID: UUID? = nil,
        selectedPanelIDs: Set<UUID> = [],
        unreadPanelIDs: Set<UUID> = [],
        unreadWorkspaceNotificationCount: Int = 0,
        recentlyClosedPanels: [ClosedPanelRecord] = [],
        rightAuxPanel: RightAuxPanelState? = nil,
        annotations: [String: WorkspaceAnnotation] = [:]
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
            recentlyClosedPanels: recentlyClosedPanels,
            rightAuxPanel: rightAuxPanel ?? RightAuxPanelState()
        )
        self.init(
            id: id,
            title: title,
            hasBeenVisited: hasBeenVisited,
            selectedTabID: tab.id,
            tabIDs: [tab.id],
            tabsByID: [tab.id: tab],
            annotations: annotations,
            unreadWorkspaceNotificationCount: unreadWorkspaceNotificationCount
        )
    }

    public static func bootstrap(
        title: String = "Workspace 1",
        initialTerminalCWD: String? = nil,
        initialTerminalProfileBinding: TerminalProfileBinding? = nil,
        hasBeenVisited: Bool = true
    ) -> WorkspaceState {
        let tab = WorkspaceTabState.bootstrap(
            initialTerminalCWD: initialTerminalCWD,
            initialTerminalProfileBinding: initialTerminalProfileBinding
        )
        return WorkspaceState(
            id: UUID(),
            title: title,
            hasBeenVisited: hasBeenVisited,
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

    public var rightAuxPanel: RightAuxPanelState {
        get { selectedTab?.rightAuxPanel ?? RightAuxPanelState() }
        set { updateSelectedTab { $0.rightAuxPanel = newValue } }
    }

    public var selectedTabDisplayTitle: String {
        selectedTab?.displayTitle ?? "Tab"
    }

    public var allPanelsByID: [UUID: PanelState] {
        let panelsByID = orderedTabs.reduce(into: [UUID: PanelState]()) { partialResult, tab in
            for (panelID, panelState) in tab.panels {
                partialResult[panelID] = panelState
            }
            for rightAuxTab in tab.rightAuxPanel.orderedTabs {
                partialResult[rightAuxTab.panelID] = rightAuxTab.panelState
            }
        }
        return panelsByID
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

        if let panelState = selectedTab?.rightAuxPanel.panelState(for: panelID) {
            return panelState
        }

        for tab in orderedTabs where tab.id != resolvedSelectedTabID {
            if let panelState = tab.panels[panelID] {
                return panelState
            }
            if let panelState = tab.rightAuxPanel.panelState(for: panelID) {
                return panelState
            }
        }

        return nil
    }

    public func rightAuxPanelTabID(containingPanelID panelID: UUID) -> UUID? {
        rightAuxPanelTabLocation(containingPanelID: panelID)?.rightAuxTabID
    }

    public func rightAuxPanelTabLocation(containingRightAuxTabID rightAuxTabID: UUID) -> (
        mainTabID: UUID,
        rightAuxTabID: UUID
    )? {
        for tab in orderedTabs where tab.rightAuxPanel.tabsByID[rightAuxTabID] != nil {
            return (tab.id, rightAuxTabID)
        }
        return nil
    }

    public func rightAuxPanelTabLocation(containingPanelID panelID: UUID) -> (
        mainTabID: UUID,
        rightAuxTabID: UUID
    )? {
        for tab in orderedTabs {
            if let rightAuxTabID = tab.rightAuxPanel.tabID(containingPanelID: panelID) {
                return (tab.id, rightAuxTabID)
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
        insertTab(tab, at: tabIDs.count, select: select)
    }

    public mutating func insertTab(_ tab: WorkspaceTabState, at preferredIndex: Int, select: Bool) {
        tabsByID[tab.id] = tab
        if let existingIndex = tabIDs.firstIndex(of: tab.id) {
            tabIDs.remove(at: existingIndex)
        }

        let insertionIndex = min(max(0, preferredIndex), tabIDs.count)
        tabIDs.insert(tab.id, at: insertionIndex)
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
        case hasBeenVisited
        case selectedTabID
        case tabIDs
        case tabsByID
        case annotations
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
        hasBeenVisited = try container.decodeIfPresent(Bool.self, forKey: .hasBeenVisited) ?? true
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
        annotations = WorkspaceAnnotation.decodeSanitizedAnnotations(
            from: container,
            forKey: .annotations,
            workspaceID: id
        )
        let decodedWorkspaceUnread = try container.decodeIfPresent(Int.self, forKey: .unreadWorkspaceNotificationCount)
        let legacyUnreadCount = try container.decodeIfPresent(Int.self, forKey: .unreadNotificationCount)
        unreadWorkspaceNotificationCount = max(0, decodedWorkspaceUnread ?? legacyUnreadCount ?? 0)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(hasBeenVisited, forKey: .hasBeenVisited)
        try container.encodeIfPresent(resolvedSelectedTabID, forKey: .selectedTabID)
        try container.encode(tabIDs, forKey: .tabIDs)
        try container.encode(tabsByID, forKey: .tabsByID)
        try container.encode(annotations, forKey: .annotations)
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
