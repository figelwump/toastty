import Foundation

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
    case splitFocusedPane(workspaceID: UUID, orientation: SplitOrientation)
    case createTerminalPanel(workspaceID: UUID, paneID: UUID)
}
