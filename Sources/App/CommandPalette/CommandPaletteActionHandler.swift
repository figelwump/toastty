import CoreState
import Foundation

@MainActor
protocol CommandPaletteActionHandling: AnyObject {
    func commandSelection(originWindowID: UUID) -> WindowCommandSelection?
    func workspaceSwitchOptions(originWindowID: UUID) -> [PaletteWorkspaceSwitchOption]
    func fileSearchScope(originWindowID: UUID) -> PaletteFileSearchScope?
    func canCreateWindow(originWindowID: UUID) -> Bool
    func createWindow(originWindowID: UUID) -> Bool
    func canCreateWorkspace(originWindowID: UUID) -> Bool
    func createWorkspace(originWindowID: UUID) -> Bool
    func canCreateWorkspaceTab(originWindowID: UUID) -> Bool
    func createWorkspaceTab(originWindowID: UUID) -> Bool
    func canSplit(direction: SlotSplitDirection, originWindowID: UUID) -> Bool
    func split(direction: SlotSplitDirection, originWindowID: UUID) -> Bool
    func canFocusSplit(originWindowID: UUID) -> Bool
    func focusSplit(direction: SlotFocusDirection, originWindowID: UUID) -> Bool
    func canEqualizeSplits(originWindowID: UUID) -> Bool
    func equalizeSplits(originWindowID: UUID) -> Bool
    func canResizeSplit(originWindowID: UUID) -> Bool
    func resizeSplit(direction: SplitResizeDirection, originWindowID: UUID) -> Bool
    func canCreateBrowser(originWindowID: UUID) -> Bool
    func createBrowser(placement: WebPanelPlacement, originWindowID: UUID) -> Bool
    func canOpenLocalDocument(originWindowID: UUID) -> Bool
    func openLocalDocument(placement: WebPanelPlacement, originWindowID: UUID) -> Bool
    func canShowScratchpadForCurrentSession(originWindowID: UUID) -> Bool
    func showScratchpadForCurrentSession(originWindowID: UUID) -> Bool
    func canToggleSidebar(originWindowID: UUID) -> Bool
    func toggleSidebar(originWindowID: UUID) -> Bool
    func sidebarTitle(originWindowID: UUID) -> String
    func canToggleFocusedPanelMode(originWindowID: UUID) -> Bool
    func toggleFocusedPanelMode(originWindowID: UUID) -> Bool
    func toggleFocusedPanelModeTitle(originWindowID: UUID) -> String
    func canWatchRunningCommand(originWindowID: UUID) -> Bool
    func watchRunningCommand(originWindowID: UUID) -> Bool
    func canClosePanel(originWindowID: UUID) -> Bool
    func closePanel(originWindowID: UUID) -> Bool
    func canRenameWorkspace(originWindowID: UUID) -> Bool
    func renameWorkspace(originWindowID: UUID) -> Bool
    func canCloseWorkspace(originWindowID: UUID) -> Bool
    func closeWorkspace(originWindowID: UUID) -> Bool
    func canRenameTab(originWindowID: UUID) -> Bool
    func renameTab(originWindowID: UUID) -> Bool
    func canSelectAdjacentTab(direction: TabNavigationDirection, originWindowID: UUID) -> Bool
    func selectAdjacentTab(direction: TabNavigationDirection, originWindowID: UUID) -> Bool
    func canJumpToNextActive(originWindowID: UUID) -> Bool
    func jumpToNextActive(originWindowID: UUID) -> Bool
    func canLaunchAgent(profileID: String, originWindowID: UUID) -> Bool
    func launchAgent(profileID: String, originWindowID: UUID) -> Bool
    func canSplitWithTerminalProfile(originWindowID: UUID) -> Bool
    func splitWithTerminalProfile(profileID: String, direction: SlotSplitDirection, originWindowID: UUID) -> Bool
    func canManageConfig(originWindowID: UUID) -> Bool
    func manageConfig(originWindowID: UUID) -> Bool
    func canManageTerminalProfiles(originWindowID: UUID) -> Bool
    func manageTerminalProfiles(originWindowID: UUID) -> Bool
    func canManageAgents(originWindowID: UUID) -> Bool
    func manageAgents(originWindowID: UUID) -> Bool
    func canReloadConfiguration() -> Bool
    func reloadConfiguration() -> Bool
    func openFileResult(
        _ destination: PaletteFileOpenDestination,
        placement: PaletteFileOpenPlacement,
        originWindowID: UUID
    ) -> Bool
    func execute(_ invocation: PaletteCommandInvocation, originWindowID: UUID) -> Bool
}

@MainActor
final class CommandPaletteActionHandler: CommandPaletteActionHandling {
    private weak var store: AppStore?
    private let fileManager: FileManager
    private let splitLayoutCommandController: SplitLayoutCommandController
    private let focusedPanelCommandController: FocusedPanelCommandController
    private let terminalRuntimeRegistry: TerminalRuntimeRegistry
    private let sessionRuntimeStore: SessionRuntimeStore
    private let processWatchCommandController: ProcessWatchCommandController
    private let agentLaunchService: AgentLaunchService
    private let terminalProfilesMenuController: TerminalProfilesMenuController
    private let supportsConfigurationReload: @MainActor () -> Bool
    private let reloadConfigurationAction: @MainActor () -> Void
    private let openLocalDocumentAction: @MainActor (UUID?, WebPanelPlacement) -> Bool
    private let showScratchpadForCurrentSessionAction: @MainActor (UUID?) -> Bool
    private let openManageConfigAction: @MainActor (UUID) -> Bool
    private let openTerminalProfilesConfigurationAction: @MainActor (UUID) -> Bool
    private let openAgentProfilesConfigurationAction: @MainActor (UUID) -> Bool

    init(
        store: AppStore,
        fileManager: FileManager = .default,
        splitLayoutCommandController: SplitLayoutCommandController,
        focusedPanelCommandController: FocusedPanelCommandController,
        terminalRuntimeRegistry: TerminalRuntimeRegistry,
        sessionRuntimeStore: SessionRuntimeStore,
        agentLaunchService: AgentLaunchService,
        terminalProfilesMenuController: TerminalProfilesMenuController,
        supportsConfigurationReload: @escaping @MainActor () -> Bool,
        reloadConfigurationAction: @escaping @MainActor () -> Void,
        openLocalDocumentAction: @escaping @MainActor (UUID?, WebPanelPlacement) -> Bool,
        showScratchpadForCurrentSessionAction: @escaping @MainActor (UUID?) -> Bool = { _ in false },
        openManageConfigAction: @escaping @MainActor (UUID) -> Bool = { _ in false },
        openTerminalProfilesConfigurationAction: @escaping @MainActor (UUID) -> Bool = { _ in false },
        openAgentProfilesConfigurationAction: @escaping @MainActor (UUID) -> Bool = { _ in false },
        processWatchCommandController: ProcessWatchCommandController? = nil
    ) {
        self.store = store
        self.fileManager = fileManager
        self.splitLayoutCommandController = splitLayoutCommandController
        self.focusedPanelCommandController = focusedPanelCommandController
        self.terminalRuntimeRegistry = terminalRuntimeRegistry
        self.sessionRuntimeStore = sessionRuntimeStore
        self.processWatchCommandController = processWatchCommandController ?? ProcessWatchCommandController(
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore
        )
        self.agentLaunchService = agentLaunchService
        self.terminalProfilesMenuController = terminalProfilesMenuController
        self.supportsConfigurationReload = supportsConfigurationReload
        self.reloadConfigurationAction = reloadConfigurationAction
        self.openLocalDocumentAction = openLocalDocumentAction
        self.showScratchpadForCurrentSessionAction = showScratchpadForCurrentSessionAction
        self.openManageConfigAction = openManageConfigAction
        self.openTerminalProfilesConfigurationAction = openTerminalProfilesConfigurationAction
        self.openAgentProfilesConfigurationAction = openAgentProfilesConfigurationAction
    }

    func commandSelection(originWindowID: UUID) -> WindowCommandSelection? {
        store?.commandSelection(preferredWindowID: originWindowID)
    }

    func workspaceSwitchOptions(originWindowID: UUID) -> [PaletteWorkspaceSwitchOption] {
        guard let selection = store?.commandSelection(preferredWindowID: originWindowID) else {
            return []
        }

        return selection.window.workspaceIDs.enumerated().compactMap { index, workspaceID in
            guard let workspace = store?.state.workspacesByID[workspaceID] else {
                return nil
            }
            let shortcut = index < DisplayShortcutConfig.maxWorkspaceShortcutCount
                ? PaletteShortcut(symbolLabel: "\u{2325}\(index + 1)")
                : nil
            return PaletteWorkspaceSwitchOption(
                workspaceID: workspaceID,
                title: workspace.title,
                shortcut: shortcut
            )
        }
    }

    func fileSearchScope(originWindowID: UUID) -> PaletteFileSearchScope? {
        guard let workspace = store?.commandSelection(preferredWindowID: originWindowID)?.workspace else {
            return nil
        }

        if let focusedPanelID = workspace.focusedPanelID,
           let scope = paletteFileSearchScope(for: focusedPanelID, in: workspace) {
            return scope
        }

        for panelID in workspace.terminalPanelIDsInDisplayOrder {
            guard let scope = paletteFileSearchScope(for: panelID, in: workspace) else {
                continue
            }
            return scope
        }

        return nil
    }

    func canCreateWindow(originWindowID: UUID) -> Bool {
        store?.window(id: originWindowID) != nil
    }

    func createWindow(originWindowID: UUID) -> Bool {
        // Keep the palette anchored to its origin window instead of silently
        // retargeting another window if the origin disappears mid-session.
        guard let store, store.window(id: originWindowID) != nil else {
            return false
        }
        return store.createWindowFromCommand(preferredWindowID: originWindowID)
    }

    func canCreateWorkspace(originWindowID: UUID) -> Bool {
        guard let store, store.window(id: originWindowID) != nil else {
            return false
        }
        return store.canCreateWorkspaceFromCommand(preferredWindowID: originWindowID)
    }

    func createWorkspace(originWindowID: UUID) -> Bool {
        guard let store, store.window(id: originWindowID) != nil else {
            return false
        }
        return store.createWorkspaceFromCommand(preferredWindowID: originWindowID)
    }

    func canCreateWorkspaceTab(originWindowID: UUID) -> Bool {
        store?.commandSelection(preferredWindowID: originWindowID) != nil
    }

    func createWorkspaceTab(originWindowID: UUID) -> Bool {
        store?.createWorkspaceTabFromCommand(preferredWindowID: originWindowID) ?? false
    }

    func canSplit(direction: SlotSplitDirection, originWindowID: UUID) -> Bool {
        _ = direction
        return splitLayoutCommandController.canSplit(preferredWindowID: originWindowID)
    }

    func split(direction: SlotSplitDirection, originWindowID: UUID) -> Bool {
        splitLayoutCommandController.split(direction: direction, preferredWindowID: originWindowID)
    }

    func canFocusSplit(originWindowID: UUID) -> Bool {
        splitLayoutCommandController.canFocusSplit(preferredWindowID: originWindowID)
    }

    func focusSplit(direction: SlotFocusDirection, originWindowID: UUID) -> Bool {
        splitLayoutCommandController.focusSplit(direction: direction, preferredWindowID: originWindowID)
    }

    func canEqualizeSplits(originWindowID: UUID) -> Bool {
        splitLayoutCommandController.canAdjustSplitLayout(preferredWindowID: originWindowID)
    }

    func equalizeSplits(originWindowID: UUID) -> Bool {
        splitLayoutCommandController.equalizeSplits(preferredWindowID: originWindowID)
    }

    func canResizeSplit(originWindowID: UUID) -> Bool {
        splitLayoutCommandController.canAdjustSplitLayout(preferredWindowID: originWindowID)
    }

    func resizeSplit(direction: SplitResizeDirection, originWindowID: UUID) -> Bool {
        splitLayoutCommandController.resizeSplit(direction: direction, preferredWindowID: originWindowID)
    }

    func canCreateBrowser(originWindowID: UUID) -> Bool {
        store?.commandSelection(preferredWindowID: originWindowID) != nil
    }

    func createBrowser(placement: WebPanelPlacement, originWindowID: UUID) -> Bool {
        store?.createBrowserPanelFromCommand(
            preferredWindowID: originWindowID,
            request: BrowserPanelCreateRequest(placementOverride: placement)
        ) ?? false
    }

    func canOpenLocalDocument(originWindowID: UUID) -> Bool {
        store?.commandSelection(preferredWindowID: originWindowID) != nil
    }

    func openLocalDocument(placement: WebPanelPlacement, originWindowID: UUID) -> Bool {
        openLocalDocumentAction(originWindowID, placement)
    }

    func canShowScratchpadForCurrentSession(originWindowID: UUID) -> Bool {
        guard let selection = store?.commandSelection(preferredWindowID: originWindowID),
              let focusedPanelID = selection.workspace.focusedPanelID,
              selection.workspace.layoutTree.slotContaining(panelID: focusedPanelID) != nil,
              case .terminal = selection.workspace.panelState(for: focusedPanelID) else {
            return false
        }

        return sessionRuntimeStore.sessionRegistry.activeSession(for: focusedPanelID) != nil
    }

    func showScratchpadForCurrentSession(originWindowID: UUID) -> Bool {
        guard canShowScratchpadForCurrentSession(originWindowID: originWindowID) else {
            return false
        }
        return showScratchpadForCurrentSessionAction(originWindowID)
    }

    func canToggleSidebar(originWindowID: UUID) -> Bool {
        store?.window(id: originWindowID) != nil
    }

    func toggleSidebar(originWindowID: UUID) -> Bool {
        guard let store, store.window(id: originWindowID) != nil else {
            return false
        }
        return store.send(.toggleSidebar(windowID: originWindowID))
    }

    func sidebarTitle(originWindowID: UUID) -> String {
        guard let window = store?.window(id: originWindowID) else {
            return ToasttyBuiltInCommand.toggleSidebar.title
        }
        return ToasttyBuiltInCommand.toggleSidebarTitle(sidebarVisible: window.sidebarVisible)
    }

    func canToggleFocusedPanelMode(originWindowID: UUID) -> Bool {
        store?.commandSelection(preferredWindowID: originWindowID) != nil
    }

    func toggleFocusedPanelMode(originWindowID: UUID) -> Bool {
        guard let workspaceID = store?.commandSelection(preferredWindowID: originWindowID)?.workspace.id else {
            return false
        }
        return terminalRuntimeRegistry.toggleFocusedPanelMode(workspaceID: workspaceID)
    }

    func toggleFocusedPanelModeTitle(originWindowID: UUID) -> String {
        let focusedPanelModeActive = store?.commandSelection(preferredWindowID: originWindowID)?.workspace.focusedPanelModeActive ?? false
        return ToasttyBuiltInCommand.toggleFocusedPanelModeTitle(
            focusedPanelModeActive: focusedPanelModeActive
        )
    }

    func canWatchRunningCommand(originWindowID: UUID) -> Bool {
        processWatchCommandController.canWatchFocusedProcess(preferredWindowID: originWindowID)
    }

    func watchRunningCommand(originWindowID: UUID) -> Bool {
        processWatchCommandController.watchFocusedProcess(preferredWindowID: originWindowID)
    }

    func canClosePanel(originWindowID: UUID) -> Bool {
        guard let workspaceID = store?.commandSelection(preferredWindowID: originWindowID)?.workspace.id else {
            return false
        }
        return focusedPanelCommandController.canCloseFocusedPanel(in: workspaceID)
    }

    func closePanel(originWindowID: UUID) -> Bool {
        guard let workspaceID = store?.commandSelection(preferredWindowID: originWindowID)?.workspace.id else {
            return false
        }
        return focusedPanelCommandController.closeFocusedPanel(in: workspaceID).didMutateState
    }

    // The menu controllers wrap these same AppStore command helpers, but the
    // palette must pass its explicit origin window instead of following the
    // live key-window providers those controllers use.
    func canRenameWorkspace(originWindowID: UUID) -> Bool {
        store?.commandSelection(preferredWindowID: originWindowID) != nil
    }

    func renameWorkspace(originWindowID: UUID) -> Bool {
        store?.renameSelectedWorkspaceFromCommand(preferredWindowID: originWindowID) ?? false
    }

    func canCloseWorkspace(originWindowID: UUID) -> Bool {
        store?.commandSelection(preferredWindowID: originWindowID) != nil
    }

    func closeWorkspace(originWindowID: UUID) -> Bool {
        store?.closeSelectedWorkspaceFromCommand(preferredWindowID: originWindowID) ?? false
    }

    func canRenameTab(originWindowID: UUID) -> Bool {
        store?.canRenameSelectedWorkspaceTabFromCommand(preferredWindowID: originWindowID) ?? false
    }

    func renameTab(originWindowID: UUID) -> Bool {
        store?.renameSelectedWorkspaceTabFromCommand(preferredWindowID: originWindowID) ?? false
    }

    func canSelectAdjacentTab(direction: TabNavigationDirection, originWindowID: UUID) -> Bool {
        _ = direction
        guard let workspace = store?.commandSelection(preferredWindowID: originWindowID)?.workspace else {
            return false
        }
        let tabs = workspace.orderedTabs
        guard tabs.count > 1, let selectedTabID = workspace.resolvedSelectedTabID else {
            return false
        }
        return tabs.contains(where: { $0.id == selectedTabID })
    }

    func selectAdjacentTab(direction: TabNavigationDirection, originWindowID: UUID) -> Bool {
        store?.selectAdjacentWorkspaceTab(
            preferredWindowID: originWindowID,
            direction: direction
        ) ?? false
    }

    func canJumpToNextActive(originWindowID: UUID) -> Bool {
        store?.canFocusNextUnreadOrActivePanelFromCommand(
            preferredWindowID: originWindowID,
            sessionRuntimeStore: sessionRuntimeStore
        ) ?? false
    }

    func jumpToNextActive(originWindowID: UUID) -> Bool {
        store?.focusNextUnreadOrActivePanelFromCommand(
            preferredWindowID: originWindowID,
            sessionRuntimeStore: sessionRuntimeStore
        ) ?? false
    }

    func canLaunchAgent(profileID: String, originWindowID: UUID) -> Bool {
        agentLaunchService.canLaunchAgent(
            profileID: profileID,
            workspaceID: store?.commandSelection(preferredWindowID: originWindowID)?.workspace.id
        )
    }

    func launchAgent(profileID: String, originWindowID: UUID) -> Bool {
        AgentLaunchUI.launch(
            profileID: profileID,
            workspaceID: store?.commandSelection(preferredWindowID: originWindowID)?.workspace.id,
            agentLaunchService: agentLaunchService
        )
    }

    func canSplitWithTerminalProfile(originWindowID: UUID) -> Bool {
        terminalProfilesMenuController.canSplitFocusedSlotWithTerminalProfile(
            preferredWindowID: originWindowID
        )
    }

    func splitWithTerminalProfile(
        profileID: String,
        direction: SlotSplitDirection,
        originWindowID: UUID
    ) -> Bool {
        terminalProfilesMenuController.splitFocusedSlot(
            profileID: profileID,
            direction: direction,
            preferredWindowID: originWindowID
        )
    }

    func canManageConfig(originWindowID: UUID) -> Bool {
        canOpenManagedConfiguration(originWindowID: originWindowID)
    }

    func manageConfig(originWindowID: UUID) -> Bool {
        guard canManageConfig(originWindowID: originWindowID) else {
            return false
        }
        return openManageConfigAction(originWindowID)
    }

    func canManageTerminalProfiles(originWindowID: UUID) -> Bool {
        canOpenManagedConfiguration(originWindowID: originWindowID)
    }

    func manageTerminalProfiles(originWindowID: UUID) -> Bool {
        guard canManageTerminalProfiles(originWindowID: originWindowID) else {
            return false
        }
        return openTerminalProfilesConfigurationAction(originWindowID)
    }

    func canManageAgents(originWindowID: UUID) -> Bool {
        canOpenManagedConfiguration(originWindowID: originWindowID)
    }

    func manageAgents(originWindowID: UUID) -> Bool {
        guard canManageAgents(originWindowID: originWindowID) else {
            return false
        }
        return openAgentProfilesConfigurationAction(originWindowID)
    }

    func canReloadConfiguration() -> Bool {
        supportsConfigurationReload()
    }

    func reloadConfiguration() -> Bool {
        guard supportsConfigurationReload() else {
            return false
        }
        reloadConfigurationAction()
        return true
    }

    func openFileResult(
        _ destination: PaletteFileOpenDestination,
        placement: PaletteFileOpenPlacement,
        originWindowID: UUID
    ) -> Bool {
        let placementOverride = paletteFilePlacementOverride(for: placement)

        switch destination {
        case .localDocument(let filePath):
            return store?.createLocalDocumentPanelFromCommand(
                preferredWindowID: originWindowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: filePath,
                    placementOverride: placementOverride
                )
            ) ?? false
        case .browser(let fileURLString):
            return store?.createBrowserPanelFromCommand(
                preferredWindowID: originWindowID,
                request: BrowserPanelCreateRequest(
                    initialURL: fileURLString,
                    placementOverride: placementOverride
                )
            ) ?? false
        }
    }

    func execute(_ invocation: PaletteCommandInvocation, originWindowID: UUID) -> Bool {
        switch invocation {
        case .builtIn(let command):
            return executeBuiltIn(command, originWindowID: originWindowID)
        case .workspaceSwitch(let workspaceID):
            return selectWorkspace(workspaceID: workspaceID, originWindowID: originWindowID)
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

    private func executeBuiltIn(_ command: ToasttyBuiltInCommand, originWindowID: UUID) -> Bool {
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
        case .showScratchpadForCurrentSession:
            return showScratchpadForCurrentSession(originWindowID: originWindowID)
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
        case .manageConfig:
            return manageConfig(originWindowID: originWindowID)
        case .manageTerminalProfiles:
            return manageTerminalProfiles(originWindowID: originWindowID)
        case .manageAgents:
            return manageAgents(originWindowID: originWindowID)
        case .reloadConfiguration:
            return reloadConfiguration()
        }
    }

    private func selectWorkspace(workspaceID: UUID, originWindowID: UUID) -> Bool {
        guard let store,
              let selection = store.commandSelection(preferredWindowID: originWindowID),
              selection.window.workspaceIDs.contains(workspaceID),
              store.state.workspacesByID[workspaceID] != nil else {
            return false
        }

        store.selectWorkspace(
            windowID: selection.windowID,
            workspaceID: workspaceID,
            preferringUnreadSessionPanelIn: sessionRuntimeStore
        )
        return true
    }

    private func canOpenManagedConfiguration(originWindowID: UUID) -> Bool {
        store?.commandSelection(preferredWindowID: originWindowID) != nil
    }

    private func paletteFilePlacementOverride(
        for placement: PaletteFileOpenPlacement
    ) -> WebPanelPlacement? {
        switch placement {
        case .default:
            return nil
        case .alternate:
            return .newTab
        }
    }

    private func paletteFileSearchScope(
        for panelID: UUID,
        in workspace: WorkspaceState
    ) -> PaletteFileSearchScope? {
        guard case .terminal(let terminalState)? = workspace.panels[panelID],
              let scopePath = resolvedScopePath(from: terminalState.workingDirectorySeed) else {
            return nil
        }

        let repoRoot = RepositoryRootLocator.inferRepoRoot(from: scopePath)
        return PaletteFileSearchScope(
            rootPath: repoRoot ?? scopePath,
            kind: repoRoot == nil ? .workingDirectory : .repositoryRoot
        )
    }

    private func resolvedScopePath(from candidatePath: String?) -> String? {
        guard let candidatePath else {
            return nil
        }

        let normalizedPath = URL(fileURLWithPath: candidatePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: normalizedPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        return normalizedPath
    }
}
