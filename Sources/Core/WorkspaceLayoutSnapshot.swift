import Foundation

public struct WorkspaceLayoutSnapshot: Codable, Equatable, Sendable {
    public var windows: [WindowState]
    public var selectedWindowID: UUID?
    public var workspacesByID: [UUID: WorkspaceLayoutWorkspaceSnapshot]

    public init(
        windows: [WindowState],
        selectedWindowID: UUID?,
        workspacesByID: [UUID: WorkspaceLayoutWorkspaceSnapshot]
    ) {
        self.windows = windows
        self.selectedWindowID = selectedWindowID
        self.workspacesByID = workspacesByID
    }

    public init(state: AppState) {
        windows = state.windows
        selectedWindowID = state.selectedWindowID
        workspacesByID = state.workspacesByID.reduce(into: [:]) { partialResult, entry in
            partialResult[entry.key] = WorkspaceLayoutWorkspaceSnapshot(workspace: entry.value)
        }
    }

    public func makeAppState() -> AppState {
        let restoredWorkspaces = workspacesByID.reduce(into: [UUID: WorkspaceState]()) { partialResult, entry in
            partialResult[entry.key] = entry.value.makeWorkspaceState()
        }

        return AppState(
            windows: windows,
            workspacesByID: restoredWorkspaces,
            selectedWindowID: selectedWindowID,
            configuredTerminalFontPoints: nil,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
    }
}

public struct WorkspaceLayoutTerminalPanelSnapshot: Codable, Equatable, Sendable {
    public var shell: String
    public var launchWorkingDirectory: String
    public var profileBinding: TerminalProfileBinding?

    public init(
        shell: String,
        launchWorkingDirectory: String,
        profileBinding: TerminalProfileBinding? = nil
    ) {
        self.shell = shell
        self.launchWorkingDirectory = launchWorkingDirectory
        self.profileBinding = profileBinding
    }

    init(terminalState: TerminalPanelState) {
        shell = terminalState.shell
        launchWorkingDirectory = terminalState.workingDirectorySeed
        profileBinding = terminalState.profileBinding
    }
}

extension WorkspaceLayoutTerminalPanelSnapshot {
    private enum CodingKeys: String, CodingKey {
        case shell
        case launchWorkingDirectory
        case profileBinding
        case cwd
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shell = try container.decode(String.self, forKey: .shell)
        if let launchWorkingDirectory = try container.decodeIfPresent(String.self, forKey: .launchWorkingDirectory) {
            self.launchWorkingDirectory = launchWorkingDirectory
        } else {
            self.launchWorkingDirectory = try container.decode(String.self, forKey: .cwd)
        }
        profileBinding = try container.decodeIfPresent(TerminalProfileBinding.self, forKey: .profileBinding)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shell, forKey: .shell)
        try container.encode(launchWorkingDirectory, forKey: .launchWorkingDirectory)
        try container.encodeIfPresent(profileBinding, forKey: .profileBinding)
        // Preserve downgrade compatibility while older builds still decode the
        // legacy terminal snapshot schema from `cwd`.
        try container.encode(launchWorkingDirectory, forKey: .cwd)
    }
}

public enum WorkspaceLayoutPanelSnapshot: Equatable, Sendable {
    case terminal(WorkspaceLayoutTerminalPanelSnapshot)
    case diff(DiffPanelState)
    case markdown(MarkdownPanelState)
    case scratchpad(ScratchpadPanelState)

    init(panelState: PanelState) {
        switch panelState {
        case .terminal(let terminalState):
            self = .terminal(WorkspaceLayoutTerminalPanelSnapshot(terminalState: terminalState))
        case .diff(let diffState):
            self = .diff(diffState)
        case .markdown(let markdownState):
            self = .markdown(markdownState)
        case .scratchpad(let scratchpadState):
            self = .scratchpad(scratchpadState)
        }
    }
}

extension WorkspaceLayoutPanelSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case terminal
        case diff
        case markdown
        case scratchpad
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(PanelKind.self, forKey: .kind)
        switch kind {
        case .terminal:
            self = .terminal(try container.decode(WorkspaceLayoutTerminalPanelSnapshot.self, forKey: .terminal))
        case .diff:
            self = .diff(try container.decode(DiffPanelState.self, forKey: .diff))
        case .markdown:
            self = .markdown(try container.decode(MarkdownPanelState.self, forKey: .markdown))
        case .scratchpad:
            self = .scratchpad(try container.decode(ScratchpadPanelState.self, forKey: .scratchpad))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .terminal(let value):
            try container.encode(PanelKind.terminal, forKey: .kind)
            try container.encode(value, forKey: .terminal)
        case .diff(let value):
            try container.encode(PanelKind.diff, forKey: .kind)
            try container.encode(value, forKey: .diff)
        case .markdown(let value):
            try container.encode(PanelKind.markdown, forKey: .kind)
            try container.encode(value, forKey: .markdown)
        case .scratchpad(let value):
            try container.encode(PanelKind.scratchpad, forKey: .kind)
            try container.encode(value, forKey: .scratchpad)
        }
    }
}

public struct WorkspaceLayoutWorkspaceSnapshot: Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var selectedTabID: UUID?
    public var tabIDs: [UUID]
    public var tabsByID: [UUID: WorkspaceLayoutTabSnapshot]

    public init(
        id: UUID,
        title: String,
        selectedTabID: UUID?,
        tabIDs: [UUID],
        tabsByID: [UUID: WorkspaceLayoutTabSnapshot]
    ) {
        self.id = id
        self.title = title
        self.selectedTabID = selectedTabID
        self.tabIDs = tabIDs
        self.tabsByID = tabsByID
    }

    init(workspace: WorkspaceState) {
        id = workspace.id
        title = workspace.title
        selectedTabID = workspace.resolvedSelectedTabID
        tabIDs = workspace.tabIDs
        tabsByID = workspace.tabsByID.reduce(into: [:]) { partialResult, entry in
            partialResult[entry.key] = WorkspaceLayoutTabSnapshot(tab: entry.value)
        }
    }

    public var orderedTabs: [WorkspaceLayoutTabSnapshot] {
        tabIDs.compactMap { tabsByID[$0] }
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

    public var selectedTab: WorkspaceLayoutTabSnapshot? {
        guard let resolvedSelectedTabID else { return nil }
        return tabsByID[resolvedSelectedTabID]
    }

    // Legacy selected-tab mirrors kept for existing layout snapshot callers.
    public var layoutTree: LayoutNode {
        requiredSelectedTab.layoutTree
    }

    public var panels: [UUID: WorkspaceLayoutPanelSnapshot] {
        requiredSelectedTab.panels
    }

    public var focusedPanelID: UUID? {
        requiredSelectedTab.focusedPanelID
    }

    public var auxPanelVisibility: Set<PanelKind> {
        requiredSelectedTab.auxPanelVisibility
    }

    func makeWorkspaceState() -> WorkspaceState {
        return WorkspaceState(
            id: id,
            title: title,
            selectedTabID: selectedTabID,
            tabIDs: tabIDs,
            tabsByID: tabsByID.reduce(into: [UUID: WorkspaceTabState]()) { partialResult, entry in
                partialResult[entry.key] = entry.value.makeWorkspaceTabState()
            },
            unreadWorkspaceNotificationCount: 0
        )
    }
}

extension WorkspaceLayoutWorkspaceSnapshot {
    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case selectedTabID
        case tabIDs
        case tabsByID
        case layoutTree
        case panels
        case focusedPanelID
        case auxPanelVisibility
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)

        let decodedSelectedTabID = try container.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        let decodedTabIDs = try container.decodeIfPresent([UUID].self, forKey: .tabIDs)
        let decodedTabsByID = try container.decodeIfPresent([UUID: WorkspaceLayoutTabSnapshot].self, forKey: .tabsByID)

        if let decodedTabIDs, let decodedTabsByID, decodedTabsByID.isEmpty == false {
            selectedTabID = decodedSelectedTabID
            tabIDs = decodedTabIDs
            tabsByID = decodedTabsByID
        } else {
            let legacyTab = WorkspaceLayoutTabSnapshot(
                id: UUID(),
                layoutTree: try container.decode(LayoutNode.self, forKey: .layoutTree),
                panels: try container.decode([UUID: WorkspaceLayoutPanelSnapshot].self, forKey: .panels),
                focusedPanelID: try container.decodeIfPresent(UUID.self, forKey: .focusedPanelID),
                auxPanelVisibility: try container.decodeIfPresent(Set<PanelKind>.self, forKey: .auxPanelVisibility) ?? []
            )
            selectedTabID = legacyTab.id
            tabIDs = [legacyTab.id]
            tabsByID = [legacyTab.id: legacyTab]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(selectedTabID, forKey: .selectedTabID)
        try container.encode(tabIDs, forKey: .tabIDs)
        try container.encode(tabsByID, forKey: .tabsByID)
        // Preserve a selected-tab legacy mirror while older layout snapshots
        // are still on disk in the field.
        let legacyTab = selectedTabID.flatMap { tabsByID[$0] } ?? tabIDs.first.flatMap { tabsByID[$0] }
        try container.encode(legacyTab?.layoutTree, forKey: .layoutTree)
        try container.encode(legacyTab?.panels ?? [:], forKey: .panels)
        try container.encodeIfPresent(legacyTab?.focusedPanelID, forKey: .focusedPanelID)
        try container.encode(legacyTab?.auxPanelVisibility ?? [], forKey: .auxPanelVisibility)
    }

    private var requiredSelectedTab: WorkspaceLayoutTabSnapshot {
        guard let selectedTab else {
            preconditionFailure("Workspace layout snapshot \(id) must always resolve a selected tab")
        }
        return selectedTab
    }
}

public struct WorkspaceLayoutTabSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var customTitle: String?
    public var layoutTree: LayoutNode
    public var panels: [UUID: WorkspaceLayoutPanelSnapshot]
    public var focusedPanelID: UUID?
    public var auxPanelVisibility: Set<PanelKind>

    public init(
        id: UUID,
        customTitle: String? = nil,
        layoutTree: LayoutNode,
        panels: [UUID: WorkspaceLayoutPanelSnapshot],
        focusedPanelID: UUID?,
        auxPanelVisibility: Set<PanelKind>
    ) {
        self.id = id
        self.customTitle = customTitle
        self.layoutTree = layoutTree
        self.panels = panels
        self.focusedPanelID = focusedPanelID
        self.auxPanelVisibility = auxPanelVisibility
    }

    init(tab: WorkspaceTabState) {
        id = tab.id
        customTitle = tab.customTitle
        layoutTree = tab.layoutTree
        panels = tab.panels.reduce(into: [:]) { partialResult, entry in
            partialResult[entry.key] = WorkspaceLayoutPanelSnapshot(panelState: entry.value)
        }
        focusedPanelID = tab.focusedPanelID
        auxPanelVisibility = tab.auxPanelVisibility
    }

    func makeWorkspaceTabState() -> WorkspaceTabState {
        let restoredPanels = makePanelsWithRestoredTerminalTitles()
        return WorkspaceTabState(
            id: id,
            customTitle: customTitle,
            layoutTree: layoutTree,
            panels: restoredPanels,
            focusedPanelID: focusedPanelID,
            auxPanelVisibility: auxPanelVisibility,
            focusedPanelModeActive: false,
            unreadPanelIDs: [],
            recentlyClosedPanels: []
        )
    }

    private func makePanelsWithRestoredTerminalTitles() -> [UUID: PanelState] {
        let terminalTitleByPanelID = makeRestoredTerminalTitlesByPanelID()

        return panels.reduce(into: [UUID: PanelState]()) { partialResult, entry in
            let panelID = entry.key
            switch entry.value {
            case .terminal(let terminalSnapshot):
                guard let title = terminalTitleByPanelID[panelID] else {
                    preconditionFailure("Missing restored terminal title for panel \(panelID)")
                }
                partialResult[panelID] = .terminal(
                    TerminalPanelState(
                        title: title,
                        shell: terminalSnapshot.shell,
                        // Restored terminal panes should wait for authoritative
                        // runtime metadata instead of treating persisted cwd as
                        // the live shell cwd shown in the UI.
                        cwd: "",
                        launchWorkingDirectory: terminalSnapshot.launchWorkingDirectory,
                        profileBinding: terminalSnapshot.profileBinding
                    )
                )
            case .diff(let diffState):
                partialResult[panelID] = .diff(diffState)
            case .markdown(let markdownState):
                partialResult[panelID] = .markdown(markdownState)
            case .scratchpad(let scratchpadState):
                partialResult[panelID] = .scratchpad(scratchpadState)
            }
        }
    }

    private func makeRestoredTerminalTitlesByPanelID() -> [UUID: String] {
        var titleByPanelID: [UUID: String] = [:]
        var nextTerminalNumber = 1

        func assignTitleIfNeeded(_ panelID: UUID) {
            guard titleByPanelID[panelID] == nil else { return }
            titleByPanelID[panelID] = "\(Self.restoredTerminalTitlePrefix)\(nextTerminalNumber)"
            nextTerminalNumber += 1
        }

        for leaf in layoutTree.allSlotInfos {
            let panelID = leaf.panelID
            guard let panelSnapshot = panels[panelID],
                  case .terminal = panelSnapshot else {
                continue
            }
            assignTitleIfNeeded(panelID)
        }

        let sortedPanelIDs = panels.keys.sorted { $0.uuidString < $1.uuidString }
        for panelID in sortedPanelIDs {
            guard let panelSnapshot = panels[panelID],
                  case .terminal = panelSnapshot else {
                continue
            }
            assignTitleIfNeeded(panelID)
        }

        return titleByPanelID
    }

    private static let restoredTerminalTitlePrefix = "Terminal "
}
