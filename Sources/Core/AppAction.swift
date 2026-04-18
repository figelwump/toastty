import Foundation

public enum SlotSplitDirection: String, Codable, Equatable, Sendable {
    case right
    case down
    case left
    case up
}

public enum SlotFocusDirection: String, Codable, Equatable, Sendable {
    case previous
    case next
    case up
    case down
    case left
    case right
}

public enum SplitResizeDirection: String, Codable, Equatable, Sendable {
    case up
    case down
    case left
    case right
}

public enum AppAction: Equatable, Sendable {
    case selectWindow(windowID: UUID)
    case updateWindowFrame(windowID: UUID, frame: CGRectCodable)
    case selectWorkspace(windowID: UUID, workspaceID: UUID)
    case selectWorkspaceTab(workspaceID: UUID, tabID: UUID)
    case createWorkspace(windowID: UUID, title: String?)
    case createWorkspaceTab(workspaceID: UUID, seed: WindowLaunchSeed?)
    case createWindow(seed: WindowLaunchSeed?, initialFrame: CGRectCodable?)
    case closeWindow(windowID: UUID)
    case renameWorkspace(workspaceID: UUID, title: String)
    case setWorkspaceTabCustomTitle(workspaceID: UUID, tabID: UUID, title: String?)
    case closeWorkspace(workspaceID: UUID)
    case closeWorkspaceTab(workspaceID: UUID, tabID: UUID)
    case focusPanel(workspaceID: UUID, panelID: UUID)
    case movePanelToSlot(panelID: UUID, targetSlotID: UUID)
    case movePanelToWorkspace(panelID: UUID, targetWorkspaceID: UUID, targetSlotID: UUID?)
    case detachPanelToNewWindow(panelID: UUID)
    case closePanel(panelID: UUID)
    case reopenLastClosedPanel(workspaceID: UUID)
    case createWebPanel(workspaceID: UUID, panel: WebPanelState, placement: WebPanelPlacement)
    case toggleFocusedPanelMode(workspaceID: UUID)
    case setConfiguredTerminalFont(points: Double?)
    case setDefaultTerminalProfile(profileID: String?)
    case setWindowTerminalFont(windowID: UUID, points: Double)
    case increaseWindowTerminalFont(windowID: UUID)
    case decreaseWindowTerminalFont(windowID: UUID)
    case resetWindowTerminalFont(windowID: UUID)
    case setWindowMarkdownTextScale(windowID: UUID, scale: Double)
    case increaseWindowMarkdownTextScale(windowID: UUID)
    case decreaseWindowMarkdownTextScale(windowID: UUID)
    case resetWindowMarkdownTextScale(windowID: UUID)
    case setBrowserPanelPageZoom(panelID: UUID, zoom: Double)
    case increaseBrowserPanelPageZoom(panelID: UUID)
    case decreaseBrowserPanelPageZoom(panelID: UUID)
    case resetBrowserPanelPageZoom(panelID: UUID)
    case splitFocusedSlot(workspaceID: UUID, orientation: SplitOrientation)
    case splitFocusedSlotInDirection(workspaceID: UUID, direction: SlotSplitDirection)
    case splitFocusedSlotInDirectionWithWorkingDirectory(
        workspaceID: UUID,
        direction: SlotSplitDirection,
        workingDirectory: String
    )
    case splitFocusedSlotInDirectionWithTerminalProfile(
        workspaceID: UUID,
        direction: SlotSplitDirection,
        profileBinding: TerminalProfileBinding
    )
    case focusSlot(workspaceID: UUID, direction: SlotFocusDirection)
    case resizeFocusedSlotSplit(workspaceID: UUID, direction: SplitResizeDirection, amount: Int)
    case equalizeLayoutSplits(workspaceID: UUID)
    case createTerminalPanel(workspaceID: UUID, slotID: UUID)
    case updateTerminalPanelMetadata(panelID: UUID, title: String?, cwd: String?)
    case updateWebPanelMetadata(panelID: UUID, title: String?, url: String?)
    case recordDesktopNotification(workspaceID: UUID, panelID: UUID?)
    case markPanelNotificationsRead(workspaceID: UUID, panelID: UUID)
    case toggleSidebar(windowID: UUID)
}

public extension AppAction {
    var logName: String {
        switch self {
        case .selectWindow:
            return "selectWindow"
        case .updateWindowFrame:
            return "updateWindowFrame"
        case .selectWorkspace:
            return "selectWorkspace"
        case .selectWorkspaceTab:
            return "selectWorkspaceTab"
        case .createWorkspace:
            return "createWorkspace"
        case .createWorkspaceTab:
            return "createWorkspaceTab"
        case .createWindow:
            return "createWindow"
        case .closeWindow:
            return "closeWindow"
        case .renameWorkspace:
            return "renameWorkspace"
        case .setWorkspaceTabCustomTitle:
            return "setWorkspaceTabCustomTitle"
        case .closeWorkspace:
            return "closeWorkspace"
        case .closeWorkspaceTab:
            return "closeWorkspaceTab"
        case .focusPanel:
            return "focusPanel"
        case .movePanelToSlot:
            return "movePanelToSlot"
        case .movePanelToWorkspace:
            return "movePanelToWorkspace"
        case .detachPanelToNewWindow:
            return "detachPanelToNewWindow"
        case .closePanel:
            return "closePanel"
        case .reopenLastClosedPanel:
            return "reopenLastClosedPanel"
        case .createWebPanel:
            return "createWebPanel"
        case .toggleFocusedPanelMode:
            return "toggleFocusedPanelMode"
        case .setConfiguredTerminalFont:
            return "setConfiguredTerminalFont"
        case .setDefaultTerminalProfile:
            return "setDefaultTerminalProfile"
        case .setWindowTerminalFont:
            return "setWindowTerminalFont"
        case .increaseWindowTerminalFont:
            return "increaseWindowTerminalFont"
        case .decreaseWindowTerminalFont:
            return "decreaseWindowTerminalFont"
        case .resetWindowTerminalFont:
            return "resetWindowTerminalFont"
        case .setWindowMarkdownTextScale:
            return "setWindowMarkdownTextScale"
        case .increaseWindowMarkdownTextScale:
            return "increaseWindowMarkdownTextScale"
        case .decreaseWindowMarkdownTextScale:
            return "decreaseWindowMarkdownTextScale"
        case .resetWindowMarkdownTextScale:
            return "resetWindowMarkdownTextScale"
        case .setBrowserPanelPageZoom:
            return "setBrowserPanelPageZoom"
        case .increaseBrowserPanelPageZoom:
            return "increaseBrowserPanelPageZoom"
        case .decreaseBrowserPanelPageZoom:
            return "decreaseBrowserPanelPageZoom"
        case .resetBrowserPanelPageZoom:
            return "resetBrowserPanelPageZoom"
        case .splitFocusedSlot:
            return "splitFocusedSlot"
        case .splitFocusedSlotInDirection:
            return "splitFocusedSlotInDirection"
        case .splitFocusedSlotInDirectionWithWorkingDirectory:
            return "splitFocusedSlotInDirectionWithWorkingDirectory"
        case .splitFocusedSlotInDirectionWithTerminalProfile:
            return "splitFocusedSlotInDirectionWithTerminalProfile"
        case .focusSlot:
            return "focusSlot"
        case .resizeFocusedSlotSplit:
            return "resizeFocusedSlotSplit"
        case .equalizeLayoutSplits:
            return "equalizeLayoutSplits"
        case .createTerminalPanel:
            return "createTerminalPanel"
        case .updateTerminalPanelMetadata:
            return "updateTerminalPanelMetadata"
        case .updateWebPanelMetadata:
            return "updateWebPanelMetadata"
        case .recordDesktopNotification:
            return "recordDesktopNotification"
        case .markPanelNotificationsRead:
            return "markPanelNotificationsRead"
        case .toggleSidebar:
            return "toggleSidebar"
        }
    }
}
