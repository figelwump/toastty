import CoreState
import Foundation
import XCTest
@testable import ToasttyApp

@MainActor
final class CommandPaletteCatalogTests: XCTestCase {
    func testBuiltInCommandMetadataUsesStableIdentifiers() {
        XCTAssertEqual(ToasttyBuiltInCommand.splitRight.id, "layout.split.horizontal")
        XCTAssertEqual(ToasttyBuiltInCommand.splitLeft.id, "layout.split.left")
        XCTAssertEqual(ToasttyBuiltInCommand.splitDown.id, "layout.split.vertical")
        XCTAssertEqual(ToasttyBuiltInCommand.splitUp.id, "layout.split.up")
        XCTAssertEqual(ToasttyBuiltInCommand.selectPreviousSplit.id, "layout.split.select-previous")
        XCTAssertEqual(ToasttyBuiltInCommand.selectNextSplit.id, "layout.split.select-next")
        XCTAssertEqual(ToasttyBuiltInCommand.navigateSplitUp.id, "layout.split.navigate-up")
        XCTAssertEqual(ToasttyBuiltInCommand.navigateSplitDown.id, "layout.split.navigate-down")
        XCTAssertEqual(ToasttyBuiltInCommand.navigateSplitLeft.id, "layout.split.navigate-left")
        XCTAssertEqual(ToasttyBuiltInCommand.navigateSplitRight.id, "layout.split.navigate-right")
        XCTAssertEqual(ToasttyBuiltInCommand.equalizeSplits.id, "layout.split.equalize")
        XCTAssertEqual(ToasttyBuiltInCommand.resizeSplitLeft.id, "layout.split.resize-left")
        XCTAssertEqual(ToasttyBuiltInCommand.resizeSplitRight.id, "layout.split.resize-right")
        XCTAssertEqual(ToasttyBuiltInCommand.resizeSplitUp.id, "layout.split.resize-up")
        XCTAssertEqual(ToasttyBuiltInCommand.resizeSplitDown.id, "layout.split.resize-down")
        XCTAssertEqual(ToasttyBuiltInCommand.newBrowser.id, "browser.create")
        XCTAssertEqual(ToasttyBuiltInCommand.newBrowserTab.id, "browser.tab.create")
        XCTAssertEqual(ToasttyBuiltInCommand.newBrowserSplit.id, "browser.split.create")
        XCTAssertEqual(ToasttyBuiltInCommand.openLocalFile.id, "local-document.open")
        XCTAssertEqual(ToasttyBuiltInCommand.openLocalFileInTab.id, "local-document.open-tab")
        XCTAssertEqual(ToasttyBuiltInCommand.openLocalFileInSplit.id, "local-document.open-split")
        XCTAssertEqual(ToasttyBuiltInCommand.newScratchpad.id, "scratchpad.create")
        XCTAssertEqual(ToasttyBuiltInCommand.showScratchpadForCurrentSession.id, "scratchpad.show-current-session")
        XCTAssertEqual(ToasttyBuiltInCommand.toggleRightPanel.id, "window.toggle-right-panel")
        XCTAssertEqual(ToasttyBuiltInCommand.toggleFocusedPanelMode.id, "panel.focus-mode.toggle")
        XCTAssertEqual(ToasttyBuiltInCommand.watchRunningCommand.id, "panel.process-watch.create")
        XCTAssertEqual(ToasttyBuiltInCommand.manageConfig.id, "app.config.manage")
        XCTAssertEqual(ToasttyBuiltInCommand.manageTerminalProfiles.id, "terminal.profiles.manage")
        XCTAssertEqual(ToasttyBuiltInCommand.manageAgents.id, "agent.profiles.manage")
        XCTAssertEqual(ToasttyBuiltInCommand.selectPreviousRightPanelTab.id, "right-panel.tab.select-previous")
        XCTAssertEqual(ToasttyBuiltInCommand.selectNextRightPanelTab.id, "right-panel.tab.select-next")
        XCTAssertEqual(ToasttyBuiltInCommand.reloadConfiguration.id, "app.reload-configuration")
    }

    func testStaticCatalogExposesExpectedBuiltInsInStableOrder() {
        let commands = makeCommands()

        XCTAssertEqual(
            commands.map(\.id),
            [
                ToasttyBuiltInCommand.splitRight.id,
                ToasttyBuiltInCommand.splitLeft.id,
                ToasttyBuiltInCommand.splitDown.id,
                ToasttyBuiltInCommand.splitUp.id,
                ToasttyBuiltInCommand.selectPreviousSplit.id,
                ToasttyBuiltInCommand.selectNextSplit.id,
                ToasttyBuiltInCommand.navigateSplitUp.id,
                ToasttyBuiltInCommand.navigateSplitDown.id,
                ToasttyBuiltInCommand.navigateSplitLeft.id,
                ToasttyBuiltInCommand.navigateSplitRight.id,
                ToasttyBuiltInCommand.equalizeSplits.id,
                ToasttyBuiltInCommand.resizeSplitLeft.id,
                ToasttyBuiltInCommand.resizeSplitRight.id,
                ToasttyBuiltInCommand.resizeSplitUp.id,
                ToasttyBuiltInCommand.resizeSplitDown.id,
                ToasttyBuiltInCommand.newWorkspace.id,
                ToasttyBuiltInCommand.newTab.id,
                ToasttyBuiltInCommand.newWindow.id,
                ToasttyBuiltInCommand.newBrowser.id,
                ToasttyBuiltInCommand.newBrowserTab.id,
                ToasttyBuiltInCommand.newBrowserSplit.id,
                ToasttyBuiltInCommand.openLocalFile.id,
                ToasttyBuiltInCommand.openLocalFileInTab.id,
                ToasttyBuiltInCommand.openLocalFileInSplit.id,
                ToasttyBuiltInCommand.newScratchpad.id,
                ToasttyBuiltInCommand.showScratchpadForCurrentSession.id,
                ToasttyBuiltInCommand.toggleSidebar.id,
                ToasttyBuiltInCommand.toggleRightPanel.id,
                ToasttyBuiltInCommand.toggleFocusedPanelMode.id,
                ToasttyBuiltInCommand.watchRunningCommand.id,
                ToasttyBuiltInCommand.closePanel.id,
                ToasttyBuiltInCommand.renameWorkspace.id,
                ToasttyBuiltInCommand.closeWorkspace.id,
                ToasttyBuiltInCommand.renameTab.id,
                ToasttyBuiltInCommand.selectPreviousTab.id,
                ToasttyBuiltInCommand.selectNextTab.id,
                ToasttyBuiltInCommand.selectPreviousRightPanelTab.id,
                ToasttyBuiltInCommand.selectNextRightPanelTab.id,
                ToasttyBuiltInCommand.jumpToNextActive.id,
                ToasttyBuiltInCommand.manageConfig.id,
                ToasttyBuiltInCommand.manageTerminalProfiles.id,
                ToasttyBuiltInCommand.manageAgents.id,
                ToasttyBuiltInCommand.reloadConfiguration.id,
            ]
        )
    }

    func testCatalogUsesDynamicTitlesAndLocalFileNaming() throws {
        let actions = CommandPaletteActionSpy()
        actions.sidebarTitleValue = "Hide Sidebar"
        actions.rightPanelTitleValue = "Hide Right Panel"
        actions.focusedPanelModeTitleValue = "Restore Layout"

        let commands = makeCommands(actions: actions)

        XCTAssertEqual(
            try XCTUnwrap(commands.first(where: { $0.id == ToasttyBuiltInCommand.toggleSidebar.id })).title,
            "Hide Sidebar"
        )
        XCTAssertEqual(
            try XCTUnwrap(commands.first(where: { $0.id == ToasttyBuiltInCommand.toggleRightPanel.id })).title,
            "Hide Right Panel"
        )
        XCTAssertEqual(
            try XCTUnwrap(commands.first(where: { $0.id == ToasttyBuiltInCommand.toggleFocusedPanelMode.id })).title,
            "Restore Layout"
        )
        XCTAssertEqual(
            commands.filter { $0.id.hasPrefix("local-document.") }.map(\.title),
            ["Open Local File", "Open Local File in Tab", "Open Local File in Split"]
        )
    }

    func testCatalogFiltersUnavailableCommands() {
        let actions = CommandPaletteActionSpy()
        actions.canEqualizeSplitsValue = false
        actions.canCreateBrowserValue = false
        actions.canOpenLocalDocumentValue = false
        actions.canCreateScratchpadValue = false
        actions.canShowScratchpadForCurrentSessionValue = false
        actions.canToggleRightPanelValue = false
        actions.canWatchRunningCommandValue = false
        actions.canManageConfigValue = false
        actions.canManageTerminalProfilesValue = false
        actions.canManageAgentsValue = false
        actions.canSelectAdjacentRightPanelTabValue = false
        actions.canReloadValue = false

        let commands = makeCommands(actions: actions)

        XCTAssertFalse(commands.contains(where: { $0.id == ToasttyBuiltInCommand.equalizeSplits.id }))
        XCTAssertFalse(commands.contains(where: { $0.id == ToasttyBuiltInCommand.newBrowser.id }))
        XCTAssertFalse(commands.contains(where: { $0.id == ToasttyBuiltInCommand.openLocalFile.id }))
        XCTAssertFalse(commands.contains(where: { $0.id == ToasttyBuiltInCommand.newScratchpad.id }))
        XCTAssertFalse(commands.contains(where: { $0.id == ToasttyBuiltInCommand.showScratchpadForCurrentSession.id }))
        XCTAssertFalse(commands.contains(where: { $0.id == ToasttyBuiltInCommand.toggleRightPanel.id }))
        XCTAssertFalse(commands.contains(where: { $0.id == ToasttyBuiltInCommand.watchRunningCommand.id }))
        XCTAssertFalse(commands.contains(where: { $0.id == ToasttyBuiltInCommand.manageConfig.id }))
        XCTAssertFalse(commands.contains(where: { $0.id == ToasttyBuiltInCommand.manageTerminalProfiles.id }))
        XCTAssertFalse(commands.contains(where: { $0.id == ToasttyBuiltInCommand.manageAgents.id }))
        XCTAssertFalse(commands.contains(where: { $0.id == ToasttyBuiltInCommand.selectPreviousRightPanelTab.id }))
        XCTAssertFalse(commands.contains(where: { $0.id == ToasttyBuiltInCommand.selectNextRightPanelTab.id }))
        XCTAssertFalse(commands.contains(where: { $0.id == ToasttyBuiltInCommand.reloadConfiguration.id }))
    }

    func testCatalogProjectsWorkspaceSwitchCommandsWithoutUsageKeys() throws {
        let actions = CommandPaletteActionSpy()
        let workspaceID = UUID()
        actions.workspaceSwitchOptionsValue = [
            PaletteWorkspaceSwitchOption(
                workspaceID: workspaceID,
                title: "Review",
                shortcut: PaletteShortcut(symbolLabel: "\u{2325}1")
            ),
        ]

        let commands = makeCommands(actions: actions)
        let workspaceCommand = try XCTUnwrap(
            commands.first(where: { $0.id == "workspace.switch.\(workspaceID.uuidString)" })
        )

        XCTAssertEqual(workspaceCommand.title, "Switch to Workspace: Review")
        XCTAssertNil(workspaceCommand.usageKey)
        XCTAssertEqual(workspaceCommand.shortcut?.symbolLabel, "\u{2325}1")
        XCTAssertEqual(workspaceCommand.invocation, .workspaceSwitch(workspaceID: workspaceID))
    }

    func testCatalogProjectsAgentProfileCommandsWithStableIDsAndShortcuts() throws {
        let actions = CommandPaletteActionSpy()
        actions.allowedAgentProfileIDs = ["codex"]
        let agentCatalog = AgentCatalog(
            profiles: [
                AgentProfile(id: "codex", displayName: "Codex", argv: ["codex"], shortcutKey: "c"),
                AgentProfile(id: "claude", displayName: "Claude", argv: ["claude"], shortcutKey: "d"),
            ]
        )

        let commands = makeCommands(
            actions: actions,
            agentCatalog: agentCatalog,
            profileShortcutRegistry: makeProfileShortcutRegistry(agentProfiles: agentCatalog)
        )

        let agentCommand = try XCTUnwrap(commands.first(where: { $0.id == "agent.run.codex" }))
        XCTAssertEqual(agentCommand.title, "Run Agent: Codex")
        XCTAssertEqual(agentCommand.shortcut?.symbolLabel, "\u{2325}\u{2318}C")
        XCTAssertEqual(agentCommand.invocation, .agentProfileLaunch(profileID: "codex"))
        XCTAssertFalse(commands.contains(where: { $0.id == "agent.run.claude" }))
    }

    func testCatalogProjectsTerminalProfileSplitCommandsWithStableIDsAndShortcuts() throws {
        let actions = CommandPaletteActionSpy()
        let terminalProfiles = TerminalProfileCatalog(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach",
                    shortcutKey: "z"
                ),
            ]
        )

        let commands = makeCommands(
            actions: actions,
            terminalProfileCatalog: terminalProfiles,
            profileShortcutRegistry: makeProfileShortcutRegistry(terminalProfiles: terminalProfiles)
        )

        let splitRightCommand = try XCTUnwrap(
            commands.first(where: { $0.id == "terminal-profile.zmx.split-right" })
        )
        let splitDownCommand = try XCTUnwrap(
            commands.first(where: { $0.id == "terminal-profile.zmx.split-down" })
        )

        XCTAssertEqual(splitRightCommand.title, "Split Right With ZMX")
        XCTAssertEqual(splitRightCommand.shortcut?.symbolLabel, "\u{2325}\u{2318}Z")
        XCTAssertEqual(
            splitRightCommand.invocation,
            .terminalProfileSplit(profileID: "zmx", direction: .right)
        )
        XCTAssertEqual(splitDownCommand.shortcut?.symbolLabel, "\u{2325}\u{21E7}\u{2318}Z")
    }

    func testCatalogInvocationsExecuteAgainstOriginWindowID() throws {
        let originWindowID = UUID()
        let workspaceID = UUID()
        let actions = CommandPaletteActionSpy()
        actions.workspaceSwitchOptionsValue = [
            PaletteWorkspaceSwitchOption(workspaceID: workspaceID, title: "Review", shortcut: nil),
        ]
        let agentCatalog = AgentCatalog(
            profiles: [AgentProfile(id: "codex", displayName: "Codex", argv: ["codex"])]
        )
        let terminalProfiles = TerminalProfileCatalog(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach"
                ),
            ]
        )

        let commands = makeCommands(
            originWindowID: originWindowID,
            actions: actions,
            agentCatalog: agentCatalog,
            terminalProfileCatalog: terminalProfiles,
            profileShortcutRegistry: makeProfileShortcutRegistry(
                terminalProfiles: terminalProfiles,
                agentProfiles: agentCatalog
            )
        )

        XCTAssertTrue(actions.execute(try XCTUnwrap(commands.first(where: { $0.id == ToasttyBuiltInCommand.newWindow.id })).invocation, originWindowID: originWindowID))
        XCTAssertTrue(actions.execute(try XCTUnwrap(commands.first(where: { $0.id == ToasttyBuiltInCommand.newScratchpad.id })).invocation, originWindowID: originWindowID))
        XCTAssertTrue(actions.execute(try XCTUnwrap(commands.first(where: { $0.id == ToasttyBuiltInCommand.showScratchpadForCurrentSession.id })).invocation, originWindowID: originWindowID))
        XCTAssertTrue(actions.execute(try XCTUnwrap(commands.first(where: { $0.id == ToasttyBuiltInCommand.watchRunningCommand.id })).invocation, originWindowID: originWindowID))
        XCTAssertTrue(actions.execute(try XCTUnwrap(commands.first(where: { $0.id == ToasttyBuiltInCommand.manageConfig.id })).invocation, originWindowID: originWindowID))
        XCTAssertTrue(actions.execute(try XCTUnwrap(commands.first(where: { $0.id == ToasttyBuiltInCommand.manageTerminalProfiles.id })).invocation, originWindowID: originWindowID))
        XCTAssertTrue(actions.execute(try XCTUnwrap(commands.first(where: { $0.id == ToasttyBuiltInCommand.manageAgents.id })).invocation, originWindowID: originWindowID))
        XCTAssertTrue(actions.execute(try XCTUnwrap(commands.first(where: { $0.id == "workspace.switch.\(workspaceID.uuidString)" })).invocation, originWindowID: originWindowID))
        XCTAssertTrue(actions.execute(try XCTUnwrap(commands.first(where: { $0.id == "agent.run.codex" })).invocation, originWindowID: originWindowID))
        XCTAssertTrue(actions.execute(try XCTUnwrap(commands.first(where: { $0.id == "terminal-profile.zmx.split-right" })).invocation, originWindowID: originWindowID))

        XCTAssertEqual(actions.createdWindowIDs, [originWindowID])
        XCTAssertEqual(actions.createdScratchpadWindowIDs, [originWindowID])
        XCTAssertEqual(actions.shownScratchpadWindowIDs, [originWindowID])
        XCTAssertEqual(actions.watchedRunningCommandWindowIDs, [originWindowID])
        XCTAssertEqual(actions.managedConfigWindowIDs, [originWindowID])
        XCTAssertEqual(actions.managedTerminalProfilesWindowIDs, [originWindowID])
        XCTAssertEqual(actions.managedAgentsWindowIDs, [originWindowID])
        XCTAssertEqual(
            actions.workspaceSwitchCalls,
            [RecordedPaletteWorkspaceSwitchCall(workspaceID: workspaceID, originWindowID: originWindowID)]
        )
        XCTAssertEqual(
            actions.launchedAgentCalls,
            [RecordedPaletteAgentLaunchCall(profileID: "codex", originWindowID: originWindowID)]
        )
        XCTAssertEqual(
            actions.terminalProfileSplitCalls,
            [RecordedPaletteTerminalProfileSplitCall(profileID: "zmx", direction: .right, originWindowID: originWindowID)]
        )
    }

    func testCatalogExecutesManagedConfigurationCommandsThroughActionHandler() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let originWindowID = try XCTUnwrap(store.state.windows.first?.id)
        var managedConfigWindowIDs: [UUID] = []
        var managedTerminalProfilesWindowIDs: [UUID] = []
        var managedAgentsWindowIDs: [UUID] = []
        let actions = try makeLiveActions(
            store: store,
            openManageConfigAction: { windowID in
                managedConfigWindowIDs.append(windowID)
                return true
            },
            openTerminalProfilesConfigurationAction: { windowID in
                managedTerminalProfilesWindowIDs.append(windowID)
                return true
            },
            openAgentProfilesConfigurationAction: { windowID in
                managedAgentsWindowIDs.append(windowID)
                return true
            }
        )
        let commands = makeCommands(originWindowID: originWindowID, actions: actions)

        XCTAssertTrue(actions.execute(try XCTUnwrap(commands.first(where: { $0.id == ToasttyBuiltInCommand.manageConfig.id })).invocation, originWindowID: originWindowID))
        XCTAssertTrue(actions.execute(try XCTUnwrap(commands.first(where: { $0.id == ToasttyBuiltInCommand.manageTerminalProfiles.id })).invocation, originWindowID: originWindowID))
        XCTAssertTrue(actions.execute(try XCTUnwrap(commands.first(where: { $0.id == ToasttyBuiltInCommand.manageAgents.id })).invocation, originWindowID: originWindowID))

        XCTAssertEqual(managedConfigWindowIDs, [originWindowID])
        XCTAssertEqual(managedTerminalProfilesWindowIDs, [originWindowID])
        XCTAssertEqual(managedAgentsWindowIDs, [originWindowID])
    }

    func testCatalogDoesNotExecuteNewWorkspaceAfterOriginWindowCloses() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let originWindowID = try XCTUnwrap(store.state.windows.first?.id)
        let actions = try makeLiveActions(store: store)
        let viewModel = makeViewModel(originWindowID: originWindowID, actions: actions)

        viewModel.query = ToasttyBuiltInCommand.newWorkspace.title.lowercased()
        XCTAssertTrue(store.send(.closeWindow(windowID: originWindowID)))

        viewModel.submitSelection()

        XCTAssertTrue(store.state.windows.isEmpty)
    }

    func testCatalogDoesNotExecuteNavigateSplitAfterOriginWindowCloses() throws {
        let state = try XCTUnwrap(AutomationFixtureLoader.load(named: "split-workspace"))
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let originWindowID = try XCTUnwrap(store.state.windows.first?.id)
        let actions = try makeLiveActions(store: store)
        let viewModel = makeViewModel(originWindowID: originWindowID, actions: actions)

        viewModel.query = ToasttyBuiltInCommand.navigateSplitLeft.title.lowercased()
        XCTAssertTrue(store.send(.closeWindow(windowID: originWindowID)))

        viewModel.submitSelection()

        XCTAssertTrue(store.state.windows.isEmpty)
    }

    func testCatalogDoesNotExecuteEqualizeSplitsAfterOriginWindowCloses() throws {
        let state = try XCTUnwrap(AutomationFixtureLoader.load(named: "split-workspace"))
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let originWindowID = try XCTUnwrap(store.state.windows.first?.id)
        let actions = try makeLiveActions(store: store)
        let viewModel = makeViewModel(originWindowID: originWindowID, actions: actions)

        viewModel.query = ToasttyBuiltInCommand.equalizeSplits.title.lowercased()
        XCTAssertTrue(store.send(.closeWindow(windowID: originWindowID)))

        viewModel.submitSelection()

        XCTAssertTrue(store.state.windows.isEmpty)
    }

    func testCatalogDoesNotExecuteTerminalProfileSplitWhenProfileIsUnavailable() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let originWindowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let initialPanelCount = try XCTUnwrap(store.state.workspacesByID[workspaceID]?.panels.count)

        let runtimeRegistry = TerminalRuntimeRegistry()
        runtimeRegistry.bind(store: store)

        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        runtimeRegistry.bind(sessionLifecycleTracker: sessionRuntimeStore)

        let configHome = try TemporaryPaletteConfigHome()
        let agentCatalogStore = AgentCatalogStore(
            fileManager: .default,
            homeDirectoryPath: configHome.url.path
        )
        let terminalProfileStore = TerminalProfileStore(
            fileManager: .default,
            homeDirectoryPath: configHome.url.path,
            environment: [:]
        )
        let actions = CommandPaletteActionHandler(
            store: store,
            splitLayoutCommandController: SplitLayoutCommandController(store: store),
            focusedPanelCommandController: FocusedPanelCommandController(
                store: store,
                runtimeRegistry: runtimeRegistry,
                slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
            ),
            terminalRuntimeRegistry: runtimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            agentLaunchService: AgentLaunchService(
                store: store,
                terminalCommandRouter: runtimeRegistry,
                sessionRuntimeStore: sessionRuntimeStore,
                agentCatalogProvider: agentCatalogStore
            ),
            terminalProfilesMenuController: TerminalProfilesMenuController(
                store: store,
                terminalRuntimeRegistry: runtimeRegistry,
                terminalProfileProvider: terminalProfileStore,
                installShellIntegrationAction: {},
                openProfilesConfigurationAction: {}
            ),
            supportsConfigurationReload: { true },
            reloadConfigurationAction: {},
            openLocalDocumentAction: { _, _ in false }
        )
        let staleCatalog = TerminalProfileCatalog(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach"
                ),
            ]
        )
        let viewModel = makeViewModel(
            originWindowID: originWindowID,
            actions: actions,
            terminalProfileCatalog: staleCatalog
        )

        viewModel.query = "split right with zmx"
        viewModel.submitSelection()

        XCTAssertEqual(store.state.workspacesByID[workspaceID]?.panels.count, initialPanelCount)
    }

    func testCatalogHidesTabNavigationForSingleTabWorkspace() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let originWindowID = try XCTUnwrap(store.state.windows.first?.id)
        let actions = try makeLiveActions(store: store)

        let commands = makeCommands(originWindowID: originWindowID, actions: actions)

        XCTAssertFalse(commands.contains(where: { $0.id == ToasttyBuiltInCommand.selectPreviousTab.id }))
        XCTAssertFalse(commands.contains(where: { $0.id == ToasttyBuiltInCommand.selectNextTab.id }))
    }

    func testCatalogHidesRightPanelTabNavigationWithoutMultipleRightPanelTabs() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let originWindowID = try XCTUnwrap(store.state.windows.first?.id)
        let actions = try makeLiveActions(store: store)

        let commands = makeCommands(originWindowID: originWindowID, actions: actions)

        XCTAssertFalse(commands.contains(where: { $0.id == ToasttyBuiltInCommand.selectPreviousRightPanelTab.id }))
        XCTAssertFalse(commands.contains(where: { $0.id == ToasttyBuiltInCommand.selectNextRightPanelTab.id }))
    }

    func testCatalogShowsScratchpadOnlyForFocusedManagedSession() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let selection = try XCTUnwrap(store.state.selectedWorkspaceSelection())
        let sourcePanelID = try XCTUnwrap(selection.workspace.focusedPanelID)
        let sessionRuntimeStore = SessionRuntimeStore()
        var shownScratchpadWindowIDs: [UUID] = []
        let actions = try makeLiveActions(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            showScratchpadForCurrentSessionAction: { windowID in
                if let windowID {
                    shownScratchpadWindowIDs.append(windowID)
                }
                return true
            }
        )

        XCTAssertFalse(
            makeCommands(originWindowID: selection.windowID, actions: actions)
                .contains(where: { $0.id == ToasttyBuiltInCommand.showScratchpadForCurrentSession.id })
        )

        sessionRuntimeStore.startSession(
            sessionID: "sess-palette-scratchpad",
            agent: .codex,
            panelID: sourcePanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            displayTitleOverride: "Codex",
            cwd: nil,
            repoRoot: nil,
            at: Date(timeIntervalSince1970: 100)
        )

        let commands = makeCommands(originWindowID: selection.windowID, actions: actions)
        let scratchpadCommand = try XCTUnwrap(
            commands.first(where: { $0.id == ToasttyBuiltInCommand.showScratchpadForCurrentSession.id })
        )

        XCTAssertEqual(scratchpadCommand.title, ToasttyBuiltInCommand.showScratchpadForCurrentSession.title)
        XCTAssertTrue(actions.execute(scratchpadCommand.invocation, originWindowID: selection.windowID))
        XCTAssertEqual(shownScratchpadWindowIDs, [selection.windowID])
    }

    private func makeCommands(
        originWindowID: UUID = UUID(),
        actions: CommandPaletteActionHandling = CommandPaletteActionSpy(),
        agentCatalog: AgentCatalog = .empty,
        terminalProfileCatalog: TerminalProfileCatalog = .empty,
        profileShortcutRegistry: ProfileShortcutRegistry = makeProfileShortcutRegistry()
    ) -> [PaletteCommandDescriptor] {
        CommandPaletteCatalog.commands(
            originWindowID: originWindowID,
            actions: actions,
            agentCatalog: agentCatalog,
            terminalProfileCatalog: terminalProfileCatalog,
            profileShortcutRegistry: profileShortcutRegistry
        )
    }

    private func makeViewModel(
        originWindowID: UUID,
        actions: CommandPaletteActionHandling,
        agentCatalog: AgentCatalog = .empty,
        terminalProfileCatalog: TerminalProfileCatalog = .empty,
        profileShortcutRegistry: ProfileShortcutRegistry = makeProfileShortcutRegistry()
    ) -> CommandPaletteViewModel {
        CommandPaletteViewModel(
            originWindowID: originWindowID,
            projectCommands: {
                CommandPaletteCatalog.commands(
                    originWindowID: originWindowID,
                    actions: actions,
                    agentCatalog: agentCatalog,
                    terminalProfileCatalog: terminalProfileCatalog,
                    profileShortcutRegistry: profileShortcutRegistry
                )
            },
            executeCommand: { invocation, originWindowID in
                actions.execute(invocation, originWindowID: originWindowID)
            },
            onCancel: {},
            onSubmitted: {}
        )
    }

    private func makeLiveActions(
        store: AppStore,
        sessionRuntimeStore providedSessionRuntimeStore: SessionRuntimeStore? = nil,
        showScratchpadForCurrentSessionAction: @escaping @MainActor (UUID?) -> Bool = { _ in false },
        openManageConfigAction: @escaping @MainActor (UUID) -> Bool = { _ in false },
        openTerminalProfilesConfigurationAction: @escaping @MainActor (UUID) -> Bool = { _ in false },
        openAgentProfilesConfigurationAction: @escaping @MainActor (UUID) -> Bool = { _ in false }
    ) throws -> CommandPaletteActionHandler {
        let runtimeRegistry = TerminalRuntimeRegistry()
        runtimeRegistry.bind(store: store)

        let sessionRuntimeStore = providedSessionRuntimeStore ?? SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        runtimeRegistry.bind(sessionLifecycleTracker: sessionRuntimeStore)

        let configHome = try TemporaryPaletteConfigHome()
        let agentCatalogStore = AgentCatalogStore(
            fileManager: .default,
            homeDirectoryPath: configHome.url.path
        )
        let terminalProfileStore = TerminalProfileStore(
            fileManager: .default,
            homeDirectoryPath: configHome.url.path,
            environment: [:]
        )
        let agentLaunchService = AgentLaunchService(
            store: store,
            terminalCommandRouter: runtimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: agentCatalogStore
        )
        let terminalProfilesMenuController = TerminalProfilesMenuController(
            store: store,
            terminalRuntimeRegistry: runtimeRegistry,
            terminalProfileProvider: terminalProfileStore,
            installShellIntegrationAction: {},
            openProfilesConfigurationAction: {}
        )

        return CommandPaletteActionHandler(
            store: store,
            splitLayoutCommandController: SplitLayoutCommandController(store: store),
            focusedPanelCommandController: FocusedPanelCommandController(
                store: store,
                runtimeRegistry: runtimeRegistry,
                slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
            ),
            terminalRuntimeRegistry: runtimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            agentLaunchService: agentLaunchService,
            terminalProfilesMenuController: terminalProfilesMenuController,
            supportsConfigurationReload: { true },
            reloadConfigurationAction: {},
            openLocalDocumentAction: { _, _ in false },
            showScratchpadForCurrentSessionAction: showScratchpadForCurrentSessionAction,
            openManageConfigAction: openManageConfigAction,
            openTerminalProfilesConfigurationAction: openTerminalProfilesConfigurationAction,
            openAgentProfilesConfigurationAction: openAgentProfilesConfigurationAction
        )
    }
}

private struct TemporaryPaletteConfigHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
