import Foundation

public enum AppAction: Equatable, Sendable {
    case selectWindow(windowID: UUID)
    case selectWorkspace(windowID: UUID, workspaceID: UUID)
    case focusPanel(workspaceID: UUID, panelID: UUID)
    case splitFocusedPane(workspaceID: UUID, orientation: SplitOrientation)
    case createTerminalPanel(workspaceID: UUID, paneID: UUID)
}
