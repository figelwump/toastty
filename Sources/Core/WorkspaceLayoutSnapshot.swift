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

public struct WorkspaceLayoutWorkspaceSnapshot: Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var paneTree: PaneNode
    public var panels: [UUID: PanelState]
    public var focusedPanelID: UUID?
    public var auxPanelVisibility: Set<PanelKind>

    public init(
        id: UUID,
        title: String,
        paneTree: PaneNode,
        panels: [UUID: PanelState],
        focusedPanelID: UUID?,
        auxPanelVisibility: Set<PanelKind>
    ) {
        self.id = id
        self.title = title
        self.paneTree = paneTree
        self.panels = panels
        self.focusedPanelID = focusedPanelID
        self.auxPanelVisibility = auxPanelVisibility
    }

    init(workspace: WorkspaceState) {
        id = workspace.id
        title = workspace.title
        paneTree = workspace.paneTree
        panels = workspace.panels
        focusedPanelID = workspace.focusedPanelID
        auxPanelVisibility = workspace.auxPanelVisibility
    }

    func makeWorkspaceState() -> WorkspaceState {
        WorkspaceState(
            id: id,
            title: title,
            paneTree: paneTree,
            panels: panels,
            focusedPanelID: focusedPanelID,
            auxPanelVisibility: auxPanelVisibility,
            focusedPanelModeActive: false,
            unreadPanelIDs: [],
            unreadWorkspaceNotificationCount: 0,
            recentlyClosedPanels: []
        )
    }
}
