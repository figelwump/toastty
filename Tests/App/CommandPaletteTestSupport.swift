import CoreState
import Foundation
@testable import ToasttyApp

@MainActor
class CommandPaletteActionSpy: CommandPaletteActionHandling {
    var commandSelectionValue: WindowCommandSelection?
    var workspaceSwitchOptionsValue: [PaletteWorkspaceSwitchOption] = []

    var canCreateWindowValue = true
    var canCreateWorkspaceValue = true
    var canCreateWorkspaceTabValue = true
    var canSplitValue = true
    var canFocusSplitValue = true
    var canEqualizeSplitsValue = true
    var canResizeSplitValue = true
    var canCreateBrowserValue = true
    var canOpenLocalDocumentValue = true
    var canToggleSidebarValue = true
    var canToggleFocusedPanelModeValue = true
    var canWatchRunningCommandValue = true
    var canClosePanelValue = true
    var canRenameWorkspaceValue = true
    var canCloseWorkspaceValue = true
    var canRenameTabValue = true
    var canSelectAdjacentTabValue = true
    var canJumpToNextActiveValue = true
    var canLaunchAgentValue = true
    var allowedAgentProfileIDs: Set<String>?
    var canSplitWithTerminalProfileValue = true
    var canReloadValue = true

    var createWindowResult = true
    var createWorkspaceResult = true
    var createWorkspaceTabResult = true
    var splitResult = true
    var focusSplitResult = true
    var equalizeSplitsResult = true
    var resizeSplitResult = true
    var createBrowserResult = true
    var openLocalDocumentResult = true
    var toggleSidebarResult = true
    var toggleFocusedPanelModeResult = true
    var watchRunningCommandResult = true
    var closePanelResult = true
    var renameWorkspaceResult = true
    var closeWorkspaceResult = true
    var renameTabResult = true
    var selectAdjacentTabResult = true
    var jumpToNextActiveResult = true
    var launchAgentResult = true
    var splitWithTerminalProfileResult = true
    var reloadConfigurationResult = true

    var sidebarTitleValue = ToasttyBuiltInCommand.toggleSidebar.title
    var focusedPanelModeTitleValue = ToasttyBuiltInCommand.toggleFocusedPanelMode.title

    var createdWindowIDs: [UUID] = []
    var createdWorkspaceWindowIDs: [UUID] = []
    var createdWorkspaceTabWindowIDs: [UUID] = []
    var splitCalls: [RecordedPaletteSplitCall] = []
    var focusSplitCalls: [RecordedPaletteFocusSplitCall] = []
    var equalizedSplitWindowIDs: [UUID] = []
    var resizeSplitCalls: [RecordedPaletteResizeSplitCall] = []
    var browserCalls: [RecordedPaletteBrowserCall] = []
    var localDocumentCalls: [RecordedPaletteLocalDocumentCall] = []
    var toggledSidebarWindowIDs: [UUID] = []
    var toggledFocusedPanelModeWindowIDs: [UUID] = []
    var watchedRunningCommandWindowIDs: [UUID] = []
    var closedPanelWindowIDs: [UUID] = []
    var renamedWorkspaceWindowIDs: [UUID] = []
    var closedWorkspaceWindowIDs: [UUID] = []
    var renamedTabWindowIDs: [UUID] = []
    var tabSelectionCalls: [RecordedPaletteTabSelectionCall] = []
    var jumpToNextActiveWindowIDs: [UUID] = []
    var workspaceSwitchCalls: [RecordedPaletteWorkspaceSwitchCall] = []
    var launchedAgentCalls: [RecordedPaletteAgentLaunchCall] = []
    var terminalProfileSplitCalls: [RecordedPaletteTerminalProfileSplitCall] = []
    var reloadConfigurationCount = 0

    func commandSelection(originWindowID: UUID) -> WindowCommandSelection? {
        _ = originWindowID
        return commandSelectionValue
    }

    func workspaceSwitchOptions(originWindowID: UUID) -> [PaletteWorkspaceSwitchOption] {
        _ = originWindowID
        return workspaceSwitchOptionsValue
    }

    func canCreateWindow(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canCreateWindowValue
    }

    func createWindow(originWindowID: UUID) -> Bool {
        createdWindowIDs.append(originWindowID)
        return createWindowResult
    }

    func canCreateWorkspace(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canCreateWorkspaceValue
    }

    func createWorkspace(originWindowID: UUID) -> Bool {
        createdWorkspaceWindowIDs.append(originWindowID)
        return createWorkspaceResult
    }

    func canCreateWorkspaceTab(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canCreateWorkspaceTabValue
    }

    func createWorkspaceTab(originWindowID: UUID) -> Bool {
        createdWorkspaceTabWindowIDs.append(originWindowID)
        return createWorkspaceTabResult
    }

    func canSplit(direction: SlotSplitDirection, originWindowID: UUID) -> Bool {
        _ = direction
        _ = originWindowID
        return canSplitValue
    }

    func split(direction: SlotSplitDirection, originWindowID: UUID) -> Bool {
        splitCalls.append(
            RecordedPaletteSplitCall(direction: direction, originWindowID: originWindowID)
        )
        return splitResult
    }

    func canFocusSplit(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canFocusSplitValue
    }

    func focusSplit(direction: SlotFocusDirection, originWindowID: UUID) -> Bool {
        focusSplitCalls.append(
            RecordedPaletteFocusSplitCall(direction: direction, originWindowID: originWindowID)
        )
        return focusSplitResult
    }

    func canEqualizeSplits(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canEqualizeSplitsValue
    }

    func equalizeSplits(originWindowID: UUID) -> Bool {
        equalizedSplitWindowIDs.append(originWindowID)
        return equalizeSplitsResult
    }

    func canResizeSplit(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canResizeSplitValue
    }

    func resizeSplit(direction: SplitResizeDirection, originWindowID: UUID) -> Bool {
        resizeSplitCalls.append(
            RecordedPaletteResizeSplitCall(direction: direction, originWindowID: originWindowID)
        )
        return resizeSplitResult
    }

    func canCreateBrowser(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canCreateBrowserValue
    }

    func createBrowser(placement: WebPanelPlacement, originWindowID: UUID) -> Bool {
        browserCalls.append(
            RecordedPaletteBrowserCall(placement: placement, originWindowID: originWindowID)
        )
        return createBrowserResult
    }

    func canOpenLocalDocument(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canOpenLocalDocumentValue
    }

    func openLocalDocument(placement: WebPanelPlacement, originWindowID: UUID) -> Bool {
        localDocumentCalls.append(
            RecordedPaletteLocalDocumentCall(placement: placement, originWindowID: originWindowID)
        )
        return openLocalDocumentResult
    }

    func canToggleSidebar(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canToggleSidebarValue
    }

    func toggleSidebar(originWindowID: UUID) -> Bool {
        toggledSidebarWindowIDs.append(originWindowID)
        return toggleSidebarResult
    }

    func sidebarTitle(originWindowID: UUID) -> String {
        _ = originWindowID
        return sidebarTitleValue
    }

    func canToggleFocusedPanelMode(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canToggleFocusedPanelModeValue
    }

    func toggleFocusedPanelMode(originWindowID: UUID) -> Bool {
        toggledFocusedPanelModeWindowIDs.append(originWindowID)
        return toggleFocusedPanelModeResult
    }

    func toggleFocusedPanelModeTitle(originWindowID: UUID) -> String {
        _ = originWindowID
        return focusedPanelModeTitleValue
    }

    func canWatchRunningCommand(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canWatchRunningCommandValue
    }

    func watchRunningCommand(originWindowID: UUID) -> Bool {
        watchedRunningCommandWindowIDs.append(originWindowID)
        return watchRunningCommandResult
    }

    func canClosePanel(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canClosePanelValue
    }

    func closePanel(originWindowID: UUID) -> Bool {
        closedPanelWindowIDs.append(originWindowID)
        return closePanelResult
    }

    func canRenameWorkspace(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canRenameWorkspaceValue
    }

    func renameWorkspace(originWindowID: UUID) -> Bool {
        renamedWorkspaceWindowIDs.append(originWindowID)
        return renameWorkspaceResult
    }

    func canCloseWorkspace(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canCloseWorkspaceValue
    }

    func closeWorkspace(originWindowID: UUID) -> Bool {
        closedWorkspaceWindowIDs.append(originWindowID)
        return closeWorkspaceResult
    }

    func canRenameTab(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canRenameTabValue
    }

    func renameTab(originWindowID: UUID) -> Bool {
        renamedTabWindowIDs.append(originWindowID)
        return renameTabResult
    }

    func canSelectAdjacentTab(
        direction: TabNavigationDirection,
        originWindowID: UUID
    ) -> Bool {
        _ = direction
        _ = originWindowID
        return canSelectAdjacentTabValue
    }

    func selectAdjacentTab(
        direction: TabNavigationDirection,
        originWindowID: UUID
    ) -> Bool {
        tabSelectionCalls.append(
            RecordedPaletteTabSelectionCall(direction: direction, originWindowID: originWindowID)
        )
        return selectAdjacentTabResult
    }

    func canJumpToNextActive(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canJumpToNextActiveValue
    }

    func jumpToNextActive(originWindowID: UUID) -> Bool {
        jumpToNextActiveWindowIDs.append(originWindowID)
        return jumpToNextActiveResult
    }

    func canLaunchAgent(profileID: String, originWindowID: UUID) -> Bool {
        _ = originWindowID
        guard canLaunchAgentValue else {
            return false
        }
        return allowedAgentProfileIDs?.contains(profileID) ?? true
    }

    func launchAgent(profileID: String, originWindowID: UUID) -> Bool {
        launchedAgentCalls.append(
            RecordedPaletteAgentLaunchCall(profileID: profileID, originWindowID: originWindowID)
        )
        return launchAgentResult
    }

    func canSplitWithTerminalProfile(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canSplitWithTerminalProfileValue
    }

    func splitWithTerminalProfile(
        profileID: String,
        direction: SlotSplitDirection,
        originWindowID: UUID
    ) -> Bool {
        terminalProfileSplitCalls.append(
            RecordedPaletteTerminalProfileSplitCall(
                profileID: profileID,
                direction: direction,
                originWindowID: originWindowID
            )
        )
        return splitWithTerminalProfileResult
    }

    func canReloadConfiguration() -> Bool {
        canReloadValue
    }

    func reloadConfiguration() -> Bool {
        reloadConfigurationCount += 1
        return reloadConfigurationResult
    }

    func execute(_ invocation: PaletteCommandInvocation, originWindowID: UUID) -> Bool {
        switch invocation {
        case .builtIn(let command):
            switch command {
            case .splitRight:
                return split(direction: .right, originWindowID: originWindowID)
            case .splitLeft:
                return split(direction: .left, originWindowID: originWindowID)
            case .splitDown:
                return split(direction: .down, originWindowID: originWindowID)
            case .splitUp:
                return split(direction: .up, originWindowID: originWindowID)
            case .selectPreviousSplit:
                return focusSplit(direction: .previous, originWindowID: originWindowID)
            case .selectNextSplit:
                return focusSplit(direction: .next, originWindowID: originWindowID)
            case .navigateSplitUp:
                return focusSplit(direction: .up, originWindowID: originWindowID)
            case .navigateSplitDown:
                return focusSplit(direction: .down, originWindowID: originWindowID)
            case .navigateSplitLeft:
                return focusSplit(direction: .left, originWindowID: originWindowID)
            case .navigateSplitRight:
                return focusSplit(direction: .right, originWindowID: originWindowID)
            case .equalizeSplits:
                return equalizeSplits(originWindowID: originWindowID)
            case .resizeSplitLeft:
                return resizeSplit(direction: .left, originWindowID: originWindowID)
            case .resizeSplitRight:
                return resizeSplit(direction: .right, originWindowID: originWindowID)
            case .resizeSplitUp:
                return resizeSplit(direction: .up, originWindowID: originWindowID)
            case .resizeSplitDown:
                return resizeSplit(direction: .down, originWindowID: originWindowID)
            case .newWindow:
                return createWindow(originWindowID: originWindowID)
            case .newWorkspace:
                return createWorkspace(originWindowID: originWindowID)
            case .newTab:
                return createWorkspaceTab(originWindowID: originWindowID)
            case .newBrowser:
                return createBrowser(placement: .rootRight, originWindowID: originWindowID)
            case .newBrowserTab:
                return createBrowser(placement: .newTab, originWindowID: originWindowID)
            case .newBrowserSplit:
                return createBrowser(placement: .splitRight, originWindowID: originWindowID)
            case .openLocalFile:
                return openLocalDocument(placement: .rootRight, originWindowID: originWindowID)
            case .openLocalFileInTab:
                return openLocalDocument(placement: .newTab, originWindowID: originWindowID)
            case .openLocalFileInSplit:
                return openLocalDocument(placement: .splitRight, originWindowID: originWindowID)
            case .toggleSidebar:
                return toggleSidebar(originWindowID: originWindowID)
            case .toggleFocusedPanelMode:
                return toggleFocusedPanelMode(originWindowID: originWindowID)
            case .watchRunningCommand:
                return watchRunningCommand(originWindowID: originWindowID)
            case .closePanel:
                return closePanel(originWindowID: originWindowID)
            case .renameWorkspace:
                return renameWorkspace(originWindowID: originWindowID)
            case .closeWorkspace:
                return closeWorkspace(originWindowID: originWindowID)
            case .renameTab:
                return renameTab(originWindowID: originWindowID)
            case .selectPreviousTab:
                return selectAdjacentTab(direction: .previous, originWindowID: originWindowID)
            case .selectNextTab:
                return selectAdjacentTab(direction: .next, originWindowID: originWindowID)
            case .jumpToNextActive:
                return jumpToNextActive(originWindowID: originWindowID)
            case .reloadConfiguration:
                return reloadConfiguration()
            }
        case .workspaceSwitch(let workspaceID):
            workspaceSwitchCalls.append(
                RecordedPaletteWorkspaceSwitchCall(
                    workspaceID: workspaceID,
                    originWindowID: originWindowID
                )
            )
            return true
        case .agentProfileLaunch(let profileID):
            return launchAgent(profileID: profileID, originWindowID: originWindowID)
        case .terminalProfileSplit(let profileID, let direction):
            return splitWithTerminalProfile(
                profileID: profileID,
                direction: direction,
                originWindowID: originWindowID
            )
        }
    }
}

struct RecordedPaletteSplitCall: Equatable {
    let direction: SlotSplitDirection
    let originWindowID: UUID
}

struct RecordedPaletteFocusSplitCall: Equatable {
    let direction: SlotFocusDirection
    let originWindowID: UUID
}

struct RecordedPaletteResizeSplitCall: Equatable {
    let direction: SplitResizeDirection
    let originWindowID: UUID
}

struct RecordedPaletteBrowserCall: Equatable {
    let placement: WebPanelPlacement
    let originWindowID: UUID
}

struct RecordedPaletteLocalDocumentCall: Equatable {
    let placement: WebPanelPlacement
    let originWindowID: UUID
}

struct RecordedPaletteTabSelectionCall: Equatable {
    let direction: TabNavigationDirection
    let originWindowID: UUID
}

struct RecordedPaletteWorkspaceSwitchCall: Equatable {
    let workspaceID: UUID
    let originWindowID: UUID
}

struct RecordedPaletteAgentLaunchCall: Equatable {
    let profileID: String
    let originWindowID: UUID
}

struct RecordedPaletteTerminalProfileSplitCall: Equatable {
    let profileID: String
    let direction: SlotSplitDirection
    let originWindowID: UUID
}

func makeProfileShortcutRegistry(
    terminalProfiles: TerminalProfileCatalog = .empty,
    terminalProfilesFilePath: String = "/tmp/terminal-profiles.toml",
    agentProfiles: AgentCatalog = .empty,
    agentProfilesFilePath: String = "/tmp/agents.toml"
) -> ProfileShortcutRegistry {
    ProfileShortcutRegistry(
        terminalProfiles: terminalProfiles,
        terminalProfilesFilePath: terminalProfilesFilePath,
        agentProfiles: agentProfiles,
        agentProfilesFilePath: agentProfilesFilePath
    )
}
