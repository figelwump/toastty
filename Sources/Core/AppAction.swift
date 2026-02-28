import Foundation

public enum PaneSplitDirection: String, Codable, Equatable, Sendable {
    case right
    case down
    case left
    case up
}

public enum PaneFocusDirection: String, Codable, Equatable, Sendable {
    case previous
    case next
    case up
    case down
    case left
    case right
}

public enum PaneResizeDirection: String, Codable, Equatable, Sendable {
    case up
    case down
    case left
    case right
}

public enum AppAction: Equatable, Sendable {
    case selectWindow(windowID: UUID)
    case selectWorkspace(windowID: UUID, workspaceID: UUID)
    case createWorkspace(windowID: UUID, title: String?)
    case focusPanel(workspaceID: UUID, panelID: UUID)
    case reorderPanel(panelID: UUID, toIndex: Int, inPaneID: UUID)
    case movePanelToPane(panelID: UUID, targetPaneID: UUID, index: Int?)
    case movePanelToWorkspace(panelID: UUID, targetWorkspaceID: UUID, targetPaneID: UUID?)
    case detachPanelToNewWindow(panelID: UUID)
    case closePanel(panelID: UUID)
    case reopenLastClosedPanel(workspaceID: UUID)
    case toggleAuxPanel(workspaceID: UUID, kind: PanelKind)
    case toggleFocusedPanelMode(workspaceID: UUID)
    case increaseGlobalTerminalFont
    case decreaseGlobalTerminalFont
    case resetGlobalTerminalFont
    case splitFocusedPane(workspaceID: UUID, orientation: SplitOrientation)
    case splitFocusedPaneInDirection(workspaceID: UUID, direction: PaneSplitDirection)
    case focusPane(workspaceID: UUID, direction: PaneFocusDirection)
    case resizeFocusedPaneSplit(workspaceID: UUID, direction: PaneResizeDirection, amount: Int)
    case equalizePaneSplits(workspaceID: UUID)
    case createTerminalPanel(workspaceID: UUID, paneID: UUID)
}
