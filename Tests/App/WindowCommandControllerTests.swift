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

    func testHiddenSystemMenuItemsBridgeRehidesItemsAfterMenuMutation() {
        let bridge = HiddenSystemMenuItemsBridge()

        let mainMenu = NSMenu(title: "Main")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let initialFileMenu = NSMenu(title: "File")
        initialFileMenu.addItem(NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: ""))
        fileItem.submenu = initialFileMenu
        mainMenu.addItem(fileItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        let rebuiltFileMenu = NSMenu(title: "File")
        let rebuiltNewWindowItem = NSMenuItem(title: "New Window", action: nil, keyEquivalent: "n")
        let rebuiltOpenRecentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        rebuiltFileMenu.addItem(rebuiltNewWindowItem)
        rebuiltFileMenu.addItem(rebuiltOpenRecentItem)
        fileItem.submenu = rebuiltFileMenu

        NotificationCenter.default.post(name: NSMenu.didChangeItemNotification, object: mainMenu)
        let refreshExpectation = expectation(description: "menu refresh")
        DispatchQueue.main.async {
            refreshExpectation.fulfill()
        }
        wait(for: [refreshExpectation], timeout: 1)

        XCTAssertTrue(rebuiltNewWindowItem.isHidden)
        XCTAssertFalse(rebuiltOpenRecentItem.isHidden)
        XCTAssertTrue(rebuiltFileMenu.delegate === bridge)
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
}

private struct SplitWorkspaceFixture {
    let store: AppStore
    let windowID: UUID
    let workspaceID: UUID
    let closedPanelID: UUID
    let controller: WindowCommandController
}
