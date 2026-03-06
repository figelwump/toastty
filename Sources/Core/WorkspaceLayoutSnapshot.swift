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
    public var cwd: String

    public init(shell: String, cwd: String) {
        self.shell = shell
        self.cwd = cwd
    }

    init(terminalState: TerminalPanelState) {
        shell = terminalState.shell
        cwd = terminalState.cwd
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
    public var layoutTree: LayoutNode
    public var panels: [UUID: WorkspaceLayoutPanelSnapshot]
    public var focusedPanelID: UUID?
    public var auxPanelVisibility: Set<PanelKind>

    public init(
        id: UUID,
        title: String,
        layoutTree: LayoutNode,
        panels: [UUID: WorkspaceLayoutPanelSnapshot],
        focusedPanelID: UUID?,
        auxPanelVisibility: Set<PanelKind>
    ) {
        self.id = id
        self.title = title
        self.layoutTree = layoutTree
        self.panels = panels
        self.focusedPanelID = focusedPanelID
        self.auxPanelVisibility = auxPanelVisibility
    }

    init(workspace: WorkspaceState) {
        id = workspace.id
        title = workspace.title
        layoutTree = workspace.layoutTree
        panels = workspace.panels.reduce(into: [:]) { partialResult, entry in
            partialResult[entry.key] = WorkspaceLayoutPanelSnapshot(panelState: entry.value)
        }
        focusedPanelID = workspace.focusedPanelID
        auxPanelVisibility = workspace.auxPanelVisibility
    }

    func makeWorkspaceState() -> WorkspaceState {
        let restoredPanels = makePanelsWithRestoredTerminalTitles()
        return WorkspaceState(
            id: id,
            title: title,
            layoutTree: layoutTree,
            panels: restoredPanels,
            focusedPanelID: focusedPanelID,
            auxPanelVisibility: auxPanelVisibility,
            focusedPanelModeActive: false,
            unreadPanelIDs: [],
            unreadWorkspaceNotificationCount: 0,
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
                    TerminalPanelState(title: title, shell: terminalSnapshot.shell, cwd: terminalSnapshot.cwd)
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
