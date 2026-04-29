import CoreState
import Foundation
@testable import ToasttyApp

@MainActor
class CommandPaletteActionSpy: CommandPaletteActionHandling {
    var commandSelectionValue: WindowCommandSelection?
    var workspaceSwitchOptionsValue: [PaletteWorkspaceSwitchOption] = []
    var fileSearchScopeValue: PaletteFileSearchScope?

    var canCreateWindowValue = true
    var canCreateWorkspaceValue = true
    var canCreateWorkspaceTabValue = true
    var canSplitValue = true
    var canFocusSplitValue = true
    var canEqualizeSplitsValue = true
    var canResizeSplitValue = true
    var canCreateBrowserValue = true
    var canOpenLocalDocumentValue = true
    var canCreateScratchpadValue = true
    var canShowScratchpadForCurrentSessionValue = true
    var canToggleSidebarValue = true
    var canToggleRightPanelValue = true
    var canToggleFocusedPanelModeValue = true
    var canWatchRunningCommandValue = true
    var canClosePanelValue = true
    var canRenameWorkspaceValue = true
    var canCloseWorkspaceValue = true
    var canRenameTabValue = true
    var canSelectAdjacentTabValue = true
    var canSelectAdjacentRightPanelTabValue = true
    var canJumpToNextActiveValue = true
    var canLaunchAgentValue = true
    var allowedAgentProfileIDs: Set<String>?
    var canSplitWithTerminalProfileValue = true
    var canManageConfigValue = true
    var canManageTerminalProfilesValue = true
    var canManageAgentsValue = true
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
    var createScratchpadResult = true
    var showScratchpadForCurrentSessionResult = true
    var toggleSidebarResult = true
    var toggleRightPanelResult = true
    var toggleFocusedPanelModeResult = true
    var watchRunningCommandResult = true
    var closePanelResult = true
    var renameWorkspaceResult = true
    var closeWorkspaceResult = true
    var renameTabResult = true
    var selectAdjacentTabResult = true
    var selectAdjacentRightPanelTabResult = true
    var jumpToNextActiveResult = true
    var launchAgentResult = true
    var splitWithTerminalProfileResult = true
    var manageConfigResult = true
    var manageTerminalProfilesResult = true
    var manageAgentsResult = true
    var reloadConfigurationResult = true

    var sidebarTitleValue = ToasttyBuiltInCommand.toggleSidebar.title
    var rightPanelTitleValue = ToasttyBuiltInCommand.toggleRightPanel.title
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
    var createdScratchpadWindowIDs: [UUID] = []
    var shownScratchpadWindowIDs: [UUID] = []
    var toggledSidebarWindowIDs: [UUID] = []
    var toggledRightPanelWindowIDs: [UUID] = []
    var toggledFocusedPanelModeWindowIDs: [UUID] = []
    var watchedRunningCommandWindowIDs: [UUID] = []
    var closedPanelWindowIDs: [UUID] = []
    var renamedWorkspaceWindowIDs: [UUID] = []
    var closedWorkspaceWindowIDs: [UUID] = []
    var renamedTabWindowIDs: [UUID] = []
    var tabSelectionCalls: [RecordedPaletteTabSelectionCall] = []
    var rightPanelTabSelectionCalls: [RecordedPaletteRightPanelTabSelectionCall] = []
    var jumpToNextActiveWindowIDs: [UUID] = []
    var workspaceSwitchCalls: [RecordedPaletteWorkspaceSwitchCall] = []
    var launchedAgentCalls: [RecordedPaletteAgentLaunchCall] = []
    var terminalProfileSplitCalls: [RecordedPaletteTerminalProfileSplitCall] = []
    var openedFileResults: [RecordedPaletteFileOpenCall] = []
    var managedConfigWindowIDs: [UUID] = []
    var managedTerminalProfilesWindowIDs: [UUID] = []
    var managedAgentsWindowIDs: [UUID] = []
    var reloadConfigurationCount = 0

    func commandSelection(originWindowID: UUID) -> WindowCommandSelection? {
        _ = originWindowID
        return commandSelectionValue
    }

    func workspaceSwitchOptions(originWindowID: UUID) -> [PaletteWorkspaceSwitchOption] {
        _ = originWindowID
        return workspaceSwitchOptionsValue
    }

    func fileSearchScope(originWindowID: UUID) -> PaletteFileSearchScope? {
        _ = originWindowID
        return fileSearchScopeValue
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

    func canCreateScratchpad(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canCreateScratchpadValue
    }

    func createScratchpad(originWindowID: UUID) -> Bool {
        createdScratchpadWindowIDs.append(originWindowID)
        return createScratchpadResult
    }

    func canShowScratchpadForCurrentSession(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canShowScratchpadForCurrentSessionValue
    }

    func showScratchpadForCurrentSession(originWindowID: UUID) -> Bool {
        shownScratchpadWindowIDs.append(originWindowID)
        return showScratchpadForCurrentSessionResult
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

    func canToggleRightPanel(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canToggleRightPanelValue
    }

    func toggleRightPanel(originWindowID: UUID) -> Bool {
        toggledRightPanelWindowIDs.append(originWindowID)
        return toggleRightPanelResult
    }

    func rightPanelTitle(originWindowID: UUID) -> String {
        _ = originWindowID
        return rightPanelTitleValue
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

    func canSelectAdjacentRightPanelTab(
        direction: PanelTabNavigationDirection,
        originWindowID: UUID
    ) -> Bool {
        _ = direction
        _ = originWindowID
        return canSelectAdjacentRightPanelTabValue
    }

    func selectAdjacentRightPanelTab(
        direction: PanelTabNavigationDirection,
        originWindowID: UUID
    ) -> Bool {
        rightPanelTabSelectionCalls.append(
            RecordedPaletteRightPanelTabSelectionCall(direction: direction, originWindowID: originWindowID)
        )
        return selectAdjacentRightPanelTabResult
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

    func canManageConfig(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canManageConfigValue
    }

    func manageConfig(originWindowID: UUID) -> Bool {
        managedConfigWindowIDs.append(originWindowID)
        return manageConfigResult
    }

    func canManageTerminalProfiles(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canManageTerminalProfilesValue
    }

    func manageTerminalProfiles(originWindowID: UUID) -> Bool {
        managedTerminalProfilesWindowIDs.append(originWindowID)
        return manageTerminalProfilesResult
    }

    func canManageAgents(originWindowID: UUID) -> Bool {
        _ = originWindowID
        return canManageAgentsValue
    }

    func manageAgents(originWindowID: UUID) -> Bool {
        managedAgentsWindowIDs.append(originWindowID)
        return manageAgentsResult
    }

    func canReloadConfiguration() -> Bool {
        canReloadValue
    }

    func reloadConfiguration() -> Bool {
        reloadConfigurationCount += 1
        return reloadConfigurationResult
    }

    func openFileResult(
        _ destination: PaletteFileOpenDestination,
        placement: PaletteFileOpenPlacement,
        originWindowID: UUID
    ) -> Bool {
        openedFileResults.append(
            RecordedPaletteFileOpenCall(
                destination: destination,
                placement: placement,
                originWindowID: originWindowID
            )
        )
        return true
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
                return createBrowser(placement: .rightPanel, originWindowID: originWindowID)
            case .newBrowserTab:
                return createBrowser(placement: .newTab, originWindowID: originWindowID)
            case .newBrowserSplit:
                return createBrowser(placement: .splitRight, originWindowID: originWindowID)
            case .openLocalFile:
                return openLocalDocument(placement: .rightPanel, originWindowID: originWindowID)
            case .openLocalFileInTab:
                return openLocalDocument(placement: .newTab, originWindowID: originWindowID)
            case .openLocalFileInSplit:
                return openLocalDocument(placement: .splitRight, originWindowID: originWindowID)
            case .newScratchpad:
                return createScratchpad(originWindowID: originWindowID)
            case .showScratchpadForCurrentSession:
                return showScratchpadForCurrentSession(originWindowID: originWindowID)
            case .toggleSidebar:
                return toggleSidebar(originWindowID: originWindowID)
            case .toggleRightPanel:
                return toggleRightPanel(originWindowID: originWindowID)
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
            case .selectPreviousRightPanelTab:
                return selectAdjacentRightPanelTab(direction: .previous, originWindowID: originWindowID)
            case .selectNextRightPanelTab:
                return selectAdjacentRightPanelTab(direction: .next, originWindowID: originWindowID)
            case .jumpToNextActive:
                return jumpToNextActive(originWindowID: originWindowID)
            case .manageConfig:
                return manageConfig(originWindowID: originWindowID)
            case .manageTerminalProfiles:
                return manageTerminalProfiles(originWindowID: originWindowID)
            case .manageAgents:
                return manageAgents(originWindowID: originWindowID)
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

struct RecordedPaletteRightPanelTabSelectionCall: Equatable {
    let direction: PanelTabNavigationDirection
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

struct RecordedPaletteFileOpenCall: Equatable {
    let destination: PaletteFileOpenDestination
    let placement: PaletteFileOpenPlacement
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
