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
    case renameWorkspace(workspaceID: UUID, title: String)
    case closeWorkspace(workspaceID: UUID)
    case focusPanel(workspaceID: UUID, panelID: UUID)
    case reorderPanel(panelID: UUID, toIndex: Int, inPaneID: UUID)
    case movePanelToPane(panelID: UUID, targetPaneID: UUID, index: Int?)
    case movePanelToWorkspace(panelID: UUID, targetWorkspaceID: UUID, targetPaneID: UUID?)
    case detachPanelToNewWindow(panelID: UUID)
    case closePanel(panelID: UUID)
    case reopenLastClosedPanel(workspaceID: UUID)
    case toggleAuxPanel(workspaceID: UUID, kind: PanelKind)
    case toggleFocusedPanelMode(workspaceID: UUID)
    case setConfiguredTerminalFont(points: Double?)
    case setGlobalTerminalFont(points: Double)
    case increaseGlobalTerminalFont
    case decreaseGlobalTerminalFont
    case resetGlobalTerminalFont
    case splitFocusedPane(workspaceID: UUID, orientation: SplitOrientation)
    case splitFocusedPaneInDirection(workspaceID: UUID, direction: PaneSplitDirection)
    case focusPane(workspaceID: UUID, direction: PaneFocusDirection)
    case resizeFocusedPaneSplit(workspaceID: UUID, direction: PaneResizeDirection, amount: Int)
    case equalizePaneSplits(workspaceID: UUID)
    case createTerminalPanel(workspaceID: UUID, paneID: UUID)
    case updateTerminalPanelMetadata(panelID: UUID, title: String?, cwd: String?)
    case recordDesktopNotification(workspaceID: UUID)
}

public extension AppAction {
    var logName: String {
        switch self {
        case .selectWindow:
            return "selectWindow"
        case .selectWorkspace:
            return "selectWorkspace"
        case .createWorkspace:
            return "createWorkspace"
        case .renameWorkspace:
            return "renameWorkspace"
        case .closeWorkspace:
            return "closeWorkspace"
        case .focusPanel:
            return "focusPanel"
        case .reorderPanel:
            return "reorderPanel"
        case .movePanelToPane:
            return "movePanelToPane"
        case .movePanelToWorkspace:
            return "movePanelToWorkspace"
        case .detachPanelToNewWindow:
            return "detachPanelToNewWindow"
        case .closePanel:
            return "closePanel"
        case .reopenLastClosedPanel:
            return "reopenLastClosedPanel"
        case .toggleAuxPanel:
            return "toggleAuxPanel"
        case .toggleFocusedPanelMode:
            return "toggleFocusedPanelMode"
        case .setConfiguredTerminalFont:
            return "setConfiguredTerminalFont"
        case .setGlobalTerminalFont:
            return "setGlobalTerminalFont"
        case .increaseGlobalTerminalFont:
            return "increaseGlobalTerminalFont"
        case .decreaseGlobalTerminalFont:
            return "decreaseGlobalTerminalFont"
        case .resetGlobalTerminalFont:
            return "resetGlobalTerminalFont"
        case .splitFocusedPane:
            return "splitFocusedPane"
        case .splitFocusedPaneInDirection:
            return "splitFocusedPaneInDirection"
        case .focusPane:
            return "focusPane"
        case .resizeFocusedPaneSplit:
            return "resizeFocusedPaneSplit"
        case .equalizePaneSplits:
            return "equalizePaneSplits"
        case .createTerminalPanel:
            return "createTerminalPanel"
        case .updateTerminalPanelMetadata:
            return "updateTerminalPanelMetadata"
        case .recordDesktopNotification:
            return "recordDesktopNotification"
        }
    }
}
