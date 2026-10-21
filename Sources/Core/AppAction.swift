import RemoteProtocol
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

public enum PanelTabNavigationDirection: String, Codable, Equatable, Sendable {
    case previous
    case next
}

public enum SplitResizeDirection: String, Codable, Equatable, Sendable {
    case up
    case down
    case left
    case right
}

public enum RightAuxPanelActivation: Equatable, Sendable {
    case reveal
    case focus
}

public enum AppAction: Equatable, Sendable {
    case selectWindow(windowID: UUID)
    case updateWindowFrame(windowID: UUID, frame: CGRectCodable)
    case selectWorkspace(windowID: UUID, workspaceID: UUID)
    case selectWorkspaceTab(workspaceID: UUID, tabID: UUID)
    case moveWorkspace(windowID: UUID, fromIndex: Int, toIndex: Int)
    case moveWorkspaceTab(workspaceID: UUID, fromIndex: Int, toIndex: Int)
    case moveSidebarSession(workspaceID: UUID, panelID: UUID, targetPanelID: UUID, placeAfter: Bool, visiblePanelIDs: [UUID])
    case createWorkspace(windowID: UUID, title: String?, activate: Bool)
    /// Opens a top-level workspace again for a closed project: one terminal
    /// in `rootDirectory`, which it keeps as its root, without selecting it.
    /// The caller chooses the IDs so it can place a task there next.
    case reopenWorkspace(windowID: UUID, workspaceID: UUID, panelID: UUID, title: String, rootDirectory: String)
    case createWorkspaceTab(workspaceID: UUID, seed: WindowLaunchSeed?, activate: Bool = true)
    /// Appends a tab holding one plain terminal, without selecting it. The
    /// caller chooses the IDs so it can address the terminal afterward. The
    /// terminal takes no profile binding: a profile's startup command would
    /// occupy the shell that the caller is about to use.
    case createBackgroundTerminalTab(workspaceID: UUID, tabID: UUID, panelID: UUID, terminalCWD: String)
    /// Creates a task's task space nested under `parentWorkspaceID`'s root,
    /// without selecting it, in one step so no half-made workspace is ever
    /// visible. The caller chooses the IDs and saves them first, so a retry
    /// after a crash finds this workspace. The one terminal starts in
    /// `terminalCWD` with no profile binding, for the same reason as
    /// `createBackgroundTerminalTab`.
    case createTaskSpace(
        windowID: UUID,
        workspaceID: UUID,
        panelID: UUID,
        parentWorkspaceID: UUID,
        spawningSessionID: String?,
        taskID: UUID,
        title: String,
        terminalCWD: String
    )
    case createWindow(seed: WindowLaunchSeed?, initialFrame: CGRectCodable?)
    case closeWindow(windowID: UUID)
    case renameWorkspace(workspaceID: UUID, title: String)
    /// `primary` true makes this the workspace's primary annotation, false
    /// clears that role if this key holds it, and nil leaves it unchanged.
    case setWorkspaceAnnotation(workspaceID: UUID, key: String, annotation: WorkspaceAnnotation, primary: Bool? = nil)
    case clearWorkspaceAnnotation(workspaceID: UUID, key: String)
    /// Nests a workspace under `parentWorkspaceID` as a subspace, or detaches
    /// it when `parentWorkspaceID` is `nil`. `spawningSessionID` records the
    /// managed session that spawned it, when known.
    case setWorkspaceParent(workspaceID: UUID, parentWorkspaceID: UUID?, spawningSessionID: String?)
    /// Marks a workspace done at `doneAt`, or clears the mark when it is `nil`.
    case setWorkspaceDone(workspaceID: UUID, doneAt: Date?)
    /// Sets or clears a top-level workspace's project root directory.
    case setWorkspaceRootDirectory(workspaceID: UUID, rootDirectory: String?)
    /// Links a workspace to the task it is the task space of, or clears the
    /// link.
    case setWorkspaceTaskID(workspaceID: UUID, taskID: UUID?)
    case setWorkspaceTabCustomTitle(workspaceID: UUID, tabID: UUID, title: String?)
    case closeWorkspace(workspaceID: UUID)
    case closeWorkspaceTab(workspaceID: UUID, tabID: UUID)
    case focusPanel(workspaceID: UUID, panelID: UUID)
    case movePanelToSlot(panelID: UUID, targetSlotID: UUID)
    case movePanelToWorkspace(panelID: UUID, targetWorkspaceID: UUID, targetSlotID: UUID?)
    case detachPanelToNewWindow(panelID: UUID)
    /// Closes a panel, and its tab when the panel was the tab's last. The
    /// close normally selects the panel's tab first; a background close
    /// (`preservesTabSelection`) keeps the workspace's selected tab instead.
    case closePanel(panelID: UUID, preservesTabSelection: Bool = false)
    case reopenLastClosedPanel(workspaceID: UUID)
    case createWebPanel(workspaceID: UUID, panel: WebPanelState, placement: WebPanelPlacement)
    case createRightAuxWebPanel(
        workspaceID: UUID,
        tabID: UUID,
        panelID: UUID,
        panel: WebPanelState,
        activation: RightAuxPanelActivation
    )
    case setRightAuxPanelVisibility(workspaceID: UUID, isVisible: Bool)
    case toggleRightAuxPanel(workspaceID: UUID)
    case setRightAuxPanelWidth(workspaceID: UUID, width: Double)
    case selectRightAuxPanelTab(workspaceID: UUID, tabID: UUID, focus: Bool)
    case selectAdjacentRightAuxPanelTab(workspaceID: UUID, direction: PanelTabNavigationDirection)
    case closeRightAuxPanelTab(workspaceID: UUID, tabID: UUID)
    case revealRightAuxPanel(workspaceID: UUID, panelID: UUID)
    case focusRightAuxPanel(workspaceID: UUID, panelID: UUID)
    case clearRightAuxPanelFocus(workspaceID: UUID)
    case toggleFocusedPanelMode(workspaceID: UUID)
    case exitFocusedPanelMode(workspaceID: UUID)
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
    /// Splits a specific main-layout panel without depending on the selected tab.
    case splitPanel(
        workspaceID: UUID,
        tabID: UUID,
        panelID: UUID,
        direction: SlotSplitDirection,
        profileBinding: TerminalProfileBinding?,
        activate: Bool
    )
    case focusSlot(workspaceID: UUID, direction: SlotFocusDirection)
    case resizeFocusedSlotSplit(workspaceID: UUID, direction: SplitResizeDirection, amount: Int)
    case setLayoutSplitRatio(workspaceID: UUID, nodeID: UUID, ratio: Double)
    case equalizeLayoutSplits(workspaceID: UUID)
    case createTerminalPanel(workspaceID: UUID, slotID: UUID)
    case updateTerminalPanelMetadata(panelID: UUID, title: String?, cwd: String?)
    case updateTerminalPanelResumeRecord(panelID: UUID, resumeRecord: ManagedAgentResumeRecord?)
    case updateTerminalPanelRemoteConversationID(panelID: UUID, remoteConversationID: RemoteConversationID?)
    case setTerminalPanelAgentReadPolicy(panelID: UUID, policy: TerminalAgentReadPolicy?)
    case updateWebPanelMetadata(panelID: UUID, title: String?, url: String?)
    case updateScratchpadPanelState(panelID: UUID, scratchpad: ScratchpadState, title: String?)
    // Session provenance is transient; saved unread state remains panel-scoped.
    case recordDesktopNotification(workspaceID: UUID, panelID: UUID?, sessionID: String? = nil)
    case markPanelNotificationsRead(workspaceID: UUID, panelID: UUID)
    case toggleSidebar(windowID: UUID)
    case setSidebarWidth(windowID: UUID, width: Double, defaultWidth: Double)
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
        case .moveWorkspace:
            return "moveWorkspace"
        case .moveSidebarSession:
            return "moveSidebarSession"
        case .moveWorkspaceTab:
            return "moveWorkspaceTab"
        case .createWorkspace:
            return "createWorkspace"
        case .reopenWorkspace:
            return "reopenWorkspace"
        case .createWorkspaceTab:
            return "createWorkspaceTab"
        case .createBackgroundTerminalTab:
            return "createBackgroundTerminalTab"
        case .createTaskSpace:
            return "createTaskSpace"
        case .createWindow:
            return "createWindow"
        case .closeWindow:
            return "closeWindow"
        case .renameWorkspace:
            return "renameWorkspace"
        case .setWorkspaceAnnotation:
            return "setWorkspaceAnnotation"
        case .clearWorkspaceAnnotation:
            return "clearWorkspaceAnnotation"
        case .setWorkspaceParent:
            return "setWorkspaceParent"
        case .setWorkspaceDone:
            return "setWorkspaceDone"
        case .setWorkspaceRootDirectory:
            return "setWorkspaceRootDirectory"
        case .setWorkspaceTaskID:
            return "setWorkspaceTaskID"
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
        case .createRightAuxWebPanel:
            return "createRightAuxWebPanel"
        case .setRightAuxPanelVisibility:
            return "setRightAuxPanelVisibility"
        case .toggleRightAuxPanel:
            return "toggleRightAuxPanel"
        case .setRightAuxPanelWidth:
            return "setRightAuxPanelWidth"
        case .selectRightAuxPanelTab:
            return "selectRightAuxPanelTab"
        case .selectAdjacentRightAuxPanelTab:
            return "selectAdjacentRightAuxPanelTab"
        case .closeRightAuxPanelTab:
            return "closeRightAuxPanelTab"
        case .revealRightAuxPanel:
            return "revealRightAuxPanel"
        case .focusRightAuxPanel:
            return "focusRightAuxPanel"
        case .clearRightAuxPanelFocus:
            return "clearRightAuxPanelFocus"
        case .toggleFocusedPanelMode:
            return "toggleFocusedPanelMode"
        case .exitFocusedPanelMode:
            return "exitFocusedPanelMode"
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
        case .splitPanel:
            return "splitPanel"
        case .focusSlot:
            return "focusSlot"
        case .resizeFocusedSlotSplit:
            return "resizeFocusedSlotSplit"
        case .setLayoutSplitRatio:
            return "setLayoutSplitRatio"
        case .equalizeLayoutSplits:
            return "equalizeLayoutSplits"
        case .createTerminalPanel:
            return "createTerminalPanel"
        case .updateTerminalPanelMetadata:
            return "updateTerminalPanelMetadata"
        case .updateTerminalPanelResumeRecord:
            return "updateTerminalPanelResumeRecord"
        case .updateTerminalPanelRemoteConversationID:
            return "updateTerminalPanelRemoteConversationID"
        case .setTerminalPanelAgentReadPolicy:
            return "setTerminalPanelAgentReadPolicy"
        case .updateWebPanelMetadata:
            return "updateWebPanelMetadata"
        case .updateScratchpadPanelState:
            return "updateScratchpadPanelState"
        case .recordDesktopNotification:
            return "recordDesktopNotification"
        case .markPanelNotificationsRead:
            return "markPanelNotificationsRead"
        case .toggleSidebar:
            return "toggleSidebar"
        case .setSidebarWidth:
            return "setSidebarWidth"
        }
    }
}
