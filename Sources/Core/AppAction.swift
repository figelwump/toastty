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
    case createWorkspace(windowID: UUID, title: String?)
    case createWindow(initialWorkspaceTitle: String?, initialFrame: CGRectCodable?)
    case closeWindow(windowID: UUID)
    case renameWorkspace(workspaceID: UUID, title: String)
    case closeWorkspace(workspaceID: UUID)
    case focusPanel(workspaceID: UUID, panelID: UUID)
    case movePanelToSlot(panelID: UUID, targetSlotID: UUID)
    case movePanelToWorkspace(panelID: UUID, targetWorkspaceID: UUID, targetSlotID: UUID?)
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
    case splitFocusedSlot(workspaceID: UUID, orientation: SplitOrientation)
    case splitFocusedSlotInDirection(workspaceID: UUID, direction: SlotSplitDirection)
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
        case .createWorkspace:
            return "createWorkspace"
        case .createWindow:
            return "createWindow"
        case .closeWindow:
            return "closeWindow"
        case .renameWorkspace:
            return "renameWorkspace"
        case .closeWorkspace:
            return "closeWorkspace"
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
        case .splitFocusedSlot:
            return "splitFocusedSlot"
        case .splitFocusedSlotInDirection:
            return "splitFocusedSlotInDirection"
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
        case .recordDesktopNotification:
            return "recordDesktopNotification"
        case .markPanelNotificationsRead:
            return "markPanelNotificationsRead"
        case .toggleSidebar:
            return "toggleSidebar"
        }
    }
}
