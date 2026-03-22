@testable import ToasttyApp
import AppKit
import CoreState
import XCTest

@MainActor
final class WindowCommandControllerTests: XCTestCase {
    func testCloseWindowClosesFocusedPanelInsteadOfRemovingWindow() throws {
        let fixture = try makeSplitWorkspaceFixture()
        let store = fixture.store
        let controller = fixture.controller

        XCTAssertTrue(controller.canCloseWindow())
        XCTAssertTrue(controller.closeWindow())

        let window = try XCTUnwrap(store.window(id: fixture.windowID))
        XCTAssertEqual(store.state.windows.count, 1)
        XCTAssertEqual(window.workspaceIDs, [fixture.workspaceID])
        let workspace = try XCTUnwrap(store.state.workspacesByID[fixture.workspaceID])
        XCTAssertEqual(workspace.panels.count, 1)
        XCTAssertNil(workspace.panels[fixture.closedPanelID])
        XCTAssertNotNil(workspace.focusedPanelID)
        XCTAssertEqual(store.state.selectedWindowID, fixture.windowID)
    }

    func testCloseWindowIsUnavailableWithoutAFocusedPanel() {
        let state = AppState(
            windows: [],
            workspacesByID: [:],
            selectedWindowID: nil,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let controller = WindowCommandController(
            focusedPanelCommandController: makeFocusedPanelCommandController(store: store)
        )

        XCTAssertFalse(controller.canCloseWindow())
        XCTAssertFalse(controller.closeWindow())
    }

    func testCloseWindowRemovesWindowWhenClosingLastPanel() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        XCTAssertTrue(store.send(.selectWindow(windowID: windowID)))

        let controller = WindowCommandController(
            focusedPanelCommandController: makeFocusedPanelCommandController(store: store)
        )

        XCTAssertTrue(controller.canCloseWindow())
        XCTAssertTrue(controller.closeWindow())
        XCTAssertTrue(store.state.windows.isEmpty)
        XCTAssertNil(store.window(id: windowID))
        XCTAssertNil(store.state.selectedWindowID)
    }

    func testMenuBridgeRetargetsDefaultCloseItemAndClosesFocusedPanel() throws {
        let fixture = try makeSplitWorkspaceFixture()
        let store = fixture.store
        let controller = fixture.controller
        let bridge = CloseWindowMenuBridge(windowCommandController: controller)

        let mainMenu = NSMenu(title: "Main")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let closeItem = NSMenuItem(
            title: "Fermer la fenetre",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        closeItem.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(closeItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        XCTAssertEqual(closeItem.title, "Close Panel")
        XCTAssertTrue(closeItem.target === bridge)
        XCTAssertEqual(closeItem.action, #selector(CloseWindowMenuBridge.performCloseWindow(_:)))
        XCTAssertTrue(bridge.validateMenuItem(closeItem))

        bridge.installIfNeeded()
        XCTAssertEqual(closeItem.title, "Close Panel")
        XCTAssertTrue(closeItem.target === bridge)
        XCTAssertEqual(closeItem.action, #selector(CloseWindowMenuBridge.performCloseWindow(_:)))

        bridge.performCloseWindow(nil)

        let window = try XCTUnwrap(store.window(id: fixture.windowID))
        XCTAssertEqual(store.state.windows.count, 1)
        XCTAssertEqual(window.workspaceIDs, [fixture.workspaceID])
        let workspace = try XCTUnwrap(store.state.workspacesByID[fixture.workspaceID])
        XCTAssertEqual(workspace.panels.count, 1)
        XCTAssertNil(workspace.panels[fixture.closedPanelID])
        XCTAssertNotNil(workspace.focusedPanelID)
        XCTAssertEqual(store.state.selectedWindowID, fixture.windowID)
        XCTAssertTrue(bridge.validateMenuItem(closeItem))
    }

    func testCloseWorkspaceMenuBridgeRetargetsDefaultCloseAllItemAndRequestsSelectedWorkspaceClose() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let firstWindowID = try XCTUnwrap(store.state.windows.first?.id)
        let firstWorkspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        XCTAssertTrue(store.send(.createWorkspace(windowID: firstWindowID, title: "Second")))
        let secondWorkspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        XCTAssertNotEqual(firstWorkspaceID, secondWorkspaceID)

        let controller = CloseWorkspaceCommandController(store: store)
        let bridge = CloseWorkspaceMenuBridge(closeWorkspaceCommandController: controller)

        let mainMenu = NSMenu(title: "Main")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let closeAllItem = NSMenuItem(title: "Close All", action: nil, keyEquivalent: "w")
        closeAllItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(closeAllItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        XCTAssertEqual(closeAllItem.title, "Close Workspace")
        XCTAssertEqual(closeAllItem.keyEquivalent, "")
        XCTAssertEqual(closeAllItem.keyEquivalentModifierMask, [])
        XCTAssertTrue(closeAllItem.target === bridge)
        XCTAssertEqual(closeAllItem.action, #selector(CloseWorkspaceMenuBridge.performCloseWorkspace(_:)))
        XCTAssertTrue(bridge.validateMenuItem(closeAllItem))

        bridge.performCloseWorkspace(nil)

        let window = try XCTUnwrap(store.window(id: firstWindowID))
        XCTAssertEqual(window.workspaceIDs, [firstWorkspaceID, secondWorkspaceID])
        XCTAssertEqual(window.selectedWorkspaceID, secondWorkspaceID)
        XCTAssertEqual(
            store.pendingCloseWorkspaceRequest,
            PendingWorkspaceCloseRequest(windowID: firstWindowID, workspaceID: secondWorkspaceID)
        )
        XCTAssertNotNil(store.state.workspacesByID[secondWorkspaceID])
        XCTAssertTrue(bridge.validateMenuItem(closeAllItem))
    }

    func testCloseWorkspaceMenuBridgeMatchesSystemCloseAllMaskWithoutExplicitCommandBit() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let controller = CloseWorkspaceCommandController(store: store)
        let bridge = CloseWorkspaceMenuBridge(closeWorkspaceCommandController: controller)

        let mainMenu = NSMenu(title: "Main")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let closeAllItem = NSMenuItem(title: "Close All", action: nil, keyEquivalent: "w")
        closeAllItem.keyEquivalentModifierMask = [.shift]
        fileMenu.addItem(closeAllItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        XCTAssertEqual(closeAllItem.title, "Close Workspace")
        XCTAssertEqual(closeAllItem.keyEquivalent, "")
        XCTAssertEqual(closeAllItem.keyEquivalentModifierMask, [])
        XCTAssertTrue(closeAllItem.target === bridge)
        XCTAssertEqual(closeAllItem.action, #selector(CloseWorkspaceMenuBridge.performCloseWorkspace(_:)))
    }

    func testCloseWorkspaceMenuBridgeDoesNotRetargetNonFileShiftWItem() {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let controller = CloseWorkspaceCommandController(store: store)
        let bridge = CloseWorkspaceMenuBridge(closeWorkspaceCommandController: controller)

        let mainMenu = NSMenu(title: "Main")

        let workspaceRootItem = NSMenuItem(title: "Workspace", action: nil, keyEquivalent: "")
        let workspaceMenu = NSMenu(title: "Workspace")
        let workspaceShiftWItem = NSMenuItem(title: "Workspace Toggle", action: nil, keyEquivalent: "w")
        workspaceShiftWItem.keyEquivalentModifierMask = [.shift]
        workspaceMenu.addItem(workspaceShiftWItem)
        workspaceRootItem.submenu = workspaceMenu
        mainMenu.addItem(workspaceRootItem)

        let fileRootItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let closeAllItem = NSMenuItem(title: "Close All", action: nil, keyEquivalent: "w")
        closeAllItem.keyEquivalentModifierMask = [.shift]
        fileMenu.addItem(closeAllItem)
        fileRootItem.submenu = fileMenu
        mainMenu.addItem(fileRootItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        XCTAssertEqual(workspaceShiftWItem.title, "Workspace Toggle")
        XCTAssertNil(workspaceShiftWItem.target)
        XCTAssertEqual(closeAllItem.title, "Close Workspace")
        XCTAssertEqual(closeAllItem.keyEquivalent, "")
        XCTAssertEqual(closeAllItem.keyEquivalentModifierMask, [])
        XCTAssertTrue(closeAllItem.target === bridge)
        XCTAssertEqual(
            closeAllItem.action,
            #selector(CloseWorkspaceMenuBridge.performCloseWorkspace(_:))
        )
    }

    func testHelpMenuBridgeRetargetsToasttyHelpItemAndOpensGitHub() {
        var openedURL: URL?
        let bridge = HelpMenuBridge { url in
            openedURL = url
        }

        let mainMenu = NSMenu(title: "Main")
        let helpRootItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: "Help")
        let projectHelpItem = NSMenuItem(title: "Toastty Help", action: nil, keyEquivalent: "")
        helpMenu.addItem(projectHelpItem)
        helpRootItem.submenu = helpMenu
        mainMenu.addItem(helpRootItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        XCTAssertTrue(projectHelpItem.target === bridge)
        XCTAssertEqual(projectHelpItem.action, #selector(HelpMenuBridge.openProjectHelp(_:)))

        bridge.openProjectHelp(nil)

        XCTAssertEqual(openedURL, URL(string: "https://github.com/figelwump/toastty"))
    }

    func testSparkleMenuBridgeInsertsUpdaterItemAfterAboutAndTriggersCheck() throws {
        var didCheckForUpdates = false
        var canCheckForUpdates = true
        let bridge = SparkleMenuBridge(
            canCheckForUpdates: { canCheckForUpdates },
            performCheckForUpdates: {
                didCheckForUpdates = true
            }
        )

        let mainMenu = NSMenu(title: "Main")
        let appRootItem = NSMenuItem(title: "Toastty", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Toastty")
        let aboutItem = NSMenuItem(title: "About Toastty", action: nil, keyEquivalent: "")
        let reloadItem = NSMenuItem(title: "Reload Configuration", action: nil, keyEquivalent: "")
        appMenu.addItem(aboutItem)
        appMenu.addItem(reloadItem)
        appRootItem.submenu = appMenu
        mainMenu.addItem(appRootItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        XCTAssertEqual(appMenu.items.map(\.title), ["About Toastty", "Check for Updates...", "Reload Configuration"])
        let updaterItem = appMenu.items[1]
        XCTAssertTrue(updaterItem.target === bridge)
        XCTAssertEqual(updaterItem.action, #selector(SparkleMenuBridge.checkForUpdates(_:)))
        XCTAssertNotNil(updaterItem.image)
        XCTAssertEqual(updaterItem.image?.isTemplate, true)
        XCTAssertTrue(bridge.validateMenuItem(updaterItem))

        bridge.checkForUpdates(nil)
        XCTAssertTrue(didCheckForUpdates)

        canCheckForUpdates = false
        XCTAssertFalse(bridge.validateMenuItem(updaterItem))

        bridge.installIfNeeded()
        XCTAssertEqual(appMenu.items.map(\.title), ["About Toastty", "Check for Updates...", "Reload Configuration"])

        appMenu.removeItem(updaterItem)
        bridge.installIfNeeded()
        XCTAssertEqual(appMenu.items.map(\.title), ["About Toastty", "Check for Updates...", "Reload Configuration"])
    }

    func testHiddenSystemMenuItemsBridgeHidesRequestedItemsByAction() {
        let bridge = HiddenSystemMenuItemsBridge()

        let mainMenu = NSMenu(title: "Main")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let newWindowItem = NSMenuItem(
            title: "Nouvelle fenetre",
            action: #selector(NSResponder.newWindowForTab(_:)),
            keyEquivalent: "n"
        )
        let keepFileItem = NSMenuItem(title: "Close Window", action: nil, keyEquivalent: "w")
        fileMenu.addItem(newWindowItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(keepFileItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        let keepWindowItem = NSMenuItem(
            title: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        let showTabBarItem = NSMenuItem(
            title: "Afficher la barre d’onglets",
            action: #selector(NSWindow.toggleTabBar(_:)),
            keyEquivalent: ""
        )
        let showAllTabsItem = NSMenuItem(
            title: "Afficher tous les onglets",
            action: #selector(NSWindow.toggleTabOverview(_:)),
            keyEquivalent: ""
        )
        windowMenu.addItem(keepWindowItem)
        windowMenu.addItem(.separator())
        windowMenu.addItem(showTabBarItem)
        windowMenu.addItem(showAllTabsItem)
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        XCTAssertTrue(newWindowItem.isHidden)
        XCTAssertFalse(keepFileItem.isHidden)
        XCTAssertTrue(fileMenu.items[1].isHidden)

        XCTAssertTrue(showTabBarItem.isHidden)
        XCTAssertTrue(showAllTabsItem.isHidden)
        XCTAssertFalse(keepWindowItem.isHidden)
        XCTAssertTrue(windowMenu.items[1].isHidden)
    }

    func testHiddenSystemMenuItemsBridgeFallsBackToMenuTitles() {
        let bridge = HiddenSystemMenuItemsBridge()

        let mainMenu = NSMenu(title: "Main")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "New Window", action: nil, keyEquivalent: "n"))
        fileMenu.addItem(NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: ""))
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Show Tab Bar", action: nil, keyEquivalent: ""))
        windowMenu.addItem(NSMenuItem(title: "Show All Tabs", action: nil, keyEquivalent: ""))
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: nil, keyEquivalent: "m"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        XCTAssertTrue(fileMenu.items[0].isHidden)
        XCTAssertFalse(fileMenu.items[1].isHidden)
        XCTAssertTrue(windowMenu.items[0].isHidden)
        XCTAssertTrue(windowMenu.items[1].isHidden)
        XCTAssertFalse(windowMenu.items[2].isHidden)
    }

    func testHiddenSystemMenuItemsBridgeRehidesItemsAfterMenuMutation() async {
        let bridge = HiddenSystemMenuItemsBridge()

        let mainMenu = NSMenu(title: "Main")
        let fileItem = NSMenuItem(title: "Datei", action: nil, keyEquivalent: "")
        let initialFileMenu = NSMenu(title: "Datei")
        initialFileMenu.addItem(NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: ""))
        fileItem.submenu = initialFileMenu
        mainMenu.addItem(fileItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        let rebuiltFileMenu = NSMenu(title: "Datei")
        let rebuiltNewWindowItem = NSMenuItem(title: "New Window", action: nil, keyEquivalent: "n")
        let rebuiltOpenRecentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        rebuiltFileMenu.addItem(rebuiltNewWindowItem)
        rebuiltFileMenu.addItem(rebuiltOpenRecentItem)
        fileItem.submenu = rebuiltFileMenu

        NotificationCenter.default.post(name: NSMenu.didChangeItemNotification, object: mainMenu)
        await flushMainActorTasks()

        XCTAssertTrue(rebuiltNewWindowItem.isHidden)
        XCTAssertFalse(rebuiltOpenRecentItem.isHidden)
        XCTAssertTrue(rebuiltFileMenu.delegate === bridge)
    }

    func testHiddenSystemMenuItemsBridgeDoesNotReinstallDynamicBridgesForMenuMutationNotifications() async {
        var refreshCount = 0
        let bridge = HiddenSystemMenuItemsBridge(
            onDynamicMenuBridgeRefreshRequested: {
                refreshCount += 1
            }
        )

        let mainMenu = NSMenu(title: "Main")
        let fileItem = NSMenuItem(title: "Datei", action: nil, keyEquivalent: "")
        let initialFileMenu = NSMenu(title: "Datei")
        initialFileMenu.addItem(NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: ""))
        fileItem.submenu = initialFileMenu
        mainMenu.addItem(fileItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()
        XCTAssertEqual(refreshCount, 1)

        let rebuiltFileMenu = NSMenu(title: "Datei")
        rebuiltFileMenu.addItem(NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: ""))
        fileItem.submenu = rebuiltFileMenu

        NotificationCenter.default.post(name: NSMenu.didChangeItemNotification, object: mainMenu)
        await flushMainActorTasks()

        XCTAssertEqual(refreshCount, 1)

        bridge.menuWillOpen(rebuiltFileMenu)
        XCTAssertEqual(refreshCount, 2)
    }

    func testHiddenSystemMenuItemsBridgeDoesNotReinstallDynamicBridgesForNestedSubmenuOpen() {
        var refreshCount = 0
        let bridge = HiddenSystemMenuItemsBridge(
            onDynamicMenuBridgeRefreshRequested: {
                refreshCount += 1
            }
        )

        let mainMenu = NSMenu(title: "Main")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        let navigateItem = NSMenuItem(title: "Navigate Splits", action: nil, keyEquivalent: "")
        let navigateMenu = NSMenu(title: "Navigate Splits")
        let moreItem = NSMenuItem(title: "More Navigation", action: nil, keyEquivalent: "")
        let moreMenu = NSMenu(title: "More Navigation")
        moreMenu.addItem(NSMenuItem(title: "Navigate Diagonally", action: nil, keyEquivalent: ""))
        moreItem.submenu = moreMenu
        navigateMenu.addItem(moreItem)
        navigateItem.submenu = navigateMenu
        windowMenu.addItem(navigateItem)
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()
        refreshCount = 0

        bridge.menuWillOpen(windowMenu)
        XCTAssertEqual(refreshCount, 1)

        bridge.menuWillOpen(navigateMenu)
        XCTAssertEqual(refreshCount, 1)

        bridge.menuWillOpen(moreMenu)
        XCTAssertEqual(refreshCount, 1)
    }

    func testHiddenSystemMenuItemsBridgeReinstallsCloseWorkspaceBridgeWhenMenuOpensAfterMutation() async {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let closeWorkspaceBridge = CloseWorkspaceMenuBridge(
            closeWorkspaceCommandController: CloseWorkspaceCommandController(store: store)
        )
        let hiddenBridge = HiddenSystemMenuItemsBridge(
            onDynamicMenuBridgeRefreshRequested: {
                closeWorkspaceBridge.installIfNeeded()
            }
        )

        let mainMenu = NSMenu(title: "Main")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let initialFileMenu = NSMenu(title: "File")
        let initialCloseItem = NSMenuItem(title: "Close Panel", action: nil, keyEquivalent: "w")
        initialCloseItem.keyEquivalentModifierMask = [.command]
        let initialCloseAllItem = NSMenuItem(title: "Close All", action: nil, keyEquivalent: "w")
        initialCloseAllItem.keyEquivalentModifierMask = [.shift]
        initialFileMenu.addItem(initialCloseItem)
        initialFileMenu.addItem(initialCloseAllItem)
        fileItem.submenu = initialFileMenu
        mainMenu.addItem(fileItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        hiddenBridge.installIfNeeded()

        XCTAssertEqual(initialCloseAllItem.title, "Close Workspace")
        XCTAssertEqual(initialCloseAllItem.keyEquivalent, "")
        XCTAssertEqual(initialCloseAllItem.keyEquivalentModifierMask, [])
        XCTAssertTrue(initialCloseAllItem.target === closeWorkspaceBridge)
        XCTAssertEqual(
            initialCloseAllItem.action,
            #selector(CloseWorkspaceMenuBridge.performCloseWorkspace(_:))
        )

        let rebuiltFileMenu = NSMenu(title: "File")
        let rebuiltCloseItem = NSMenuItem(title: "Close Panel", action: nil, keyEquivalent: "w")
        rebuiltCloseItem.keyEquivalentModifierMask = [.command]
        let rebuiltCloseAllItem = NSMenuItem(title: "Close All", action: nil, keyEquivalent: "w")
        rebuiltCloseAllItem.keyEquivalentModifierMask = [.shift]
        rebuiltFileMenu.addItem(rebuiltCloseItem)
        rebuiltFileMenu.addItem(rebuiltCloseAllItem)
        fileItem.submenu = rebuiltFileMenu

        NotificationCenter.default.post(name: NSMenu.didChangeItemNotification, object: mainMenu)
        await flushMainActorTasks()

        XCTAssertEqual(rebuiltCloseAllItem.title, "Close All")
        XCTAssertNil(rebuiltCloseAllItem.target)
        XCTAssertNil(rebuiltCloseAllItem.action)

        hiddenBridge.menuWillOpen(rebuiltFileMenu)

        XCTAssertEqual(rebuiltCloseAllItem.title, "Close Workspace")
        XCTAssertEqual(rebuiltCloseAllItem.keyEquivalent, "")
        XCTAssertEqual(rebuiltCloseAllItem.keyEquivalentModifierMask, [])
        XCTAssertTrue(rebuiltCloseAllItem.target === closeWorkspaceBridge)
        XCTAssertEqual(
            rebuiltCloseAllItem.action,
            #selector(CloseWorkspaceMenuBridge.performCloseWorkspace(_:))
        )
    }

    func testTerminalProfilesMenuControllerSplitsFocusedSlotWithProfileBinding() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let runtimeRegistry = TerminalRuntimeRegistry()
        runtimeRegistry.bind(store: store)
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let controller = TerminalProfilesMenuController(
            store: store,
            terminalRuntimeRegistry: runtimeRegistry,
            installShellIntegrationAction: {}
        )

        XCTAssertTrue(controller.canSplitFocusedSlotWithTerminalProfile(preferredWindowID: nil))
        XCTAssertTrue(
            controller.splitFocusedSlot(
                profileID: "zmx",
                direction: .right,
                preferredWindowID: nil
            )
        )

        let workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let profiledPanels = workspace.panels.values.compactMap { panel -> TerminalPanelState? in
            guard case .terminal(let terminalState) = panel else { return nil }
            return terminalState.profileBinding?.profileID == "zmx" ? terminalState : nil
        }

        XCTAssertEqual(profiledPanels.count, 1)
    }

    func testTerminalProfilesMenuControllerRunsShellIntegrationAction() {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let runtimeRegistry = TerminalRuntimeRegistry()
        runtimeRegistry.bind(store: store)
        var didInstallShellIntegration = false
        let controller = TerminalProfilesMenuController(
            store: store,
            terminalRuntimeRegistry: runtimeRegistry,
            installShellIntegrationAction: {
                didInstallShellIntegration = true
            }
        )

        controller.installShellIntegration()
        XCTAssertTrue(didInstallShellIntegration)
    }
    private func makeSplitWorkspaceFixture() throws -> SplitWorkspaceFixture {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)

        XCTAssertTrue(store.send(.selectWindow(windowID: windowID)))
        XCTAssertTrue(store.send(.splitFocusedSlotInDirection(workspaceID: workspaceID, direction: .right)))
        let closedPanelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)

        return SplitWorkspaceFixture(
            store: store,
            windowID: windowID,
            workspaceID: workspaceID,
            closedPanelID: closedPanelID,
            controller: WindowCommandController(
                focusedPanelCommandController: makeFocusedPanelCommandController(store: store)
            )
        )
    }

    private func makeFocusedPanelCommandController(store: AppStore) -> FocusedPanelCommandController {
        let runtimeRegistry = TerminalRuntimeRegistry()
        runtimeRegistry.bind(store: store)
        return FocusedPanelCommandController(
            store: store,
            runtimeRegistry: runtimeRegistry,
            slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
        )
    }

    private func flushMainActorTasks() async {
        await MainActor.run {}
    }
}

private struct SplitWorkspaceFixture {
    let store: AppStore
    let windowID: UUID
    let workspaceID: UUID
    let closedPanelID: UUID
    let controller: WindowCommandController
}
