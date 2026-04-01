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
            selectedWindowID: nil
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let controller = WindowCommandController(
            store: store,
            focusedPanelCommandController: makeFocusedPanelCommandController(store: store),
            preferredWindowIDProvider: { nil }
        )

        XCTAssertFalse(controller.canCloseWindow())
        XCTAssertFalse(controller.closeWindow())
    }

    func testCloseWindowLeavesWindowEmptyWhenClosingLastPanel() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        XCTAssertTrue(store.send(.selectWindow(windowID: windowID)))

        let controller = WindowCommandController(
            store: store,
            focusedPanelCommandController: makeFocusedPanelCommandController(store: store),
            preferredWindowIDProvider: { windowID }
        )

        XCTAssertTrue(controller.canCloseWindow())
        XCTAssertTrue(controller.closeWindow())
        let window = try XCTUnwrap(store.window(id: windowID))
        XCTAssertTrue(window.workspaceIDs.isEmpty)
        XCTAssertNil(window.selectedWorkspaceID)
        XCTAssertEqual(store.state.selectedWindowID, windowID)
    }

    func testCloseWindowDoesNotFallbackWithoutKeyToasttyWindow() throws {
        let fixture = try makeSplitWorkspaceFixture(preferredWindowIDProvider: { nil })
        let store = fixture.store

        XCTAssertFalse(fixture.controller.canCloseWindow())
        XCTAssertFalse(fixture.controller.closeWindow())

        let window = try XCTUnwrap(store.window(id: fixture.windowID))
        let workspace = try XCTUnwrap(store.state.workspacesByID[fixture.workspaceID])
        XCTAssertEqual(window.workspaceIDs, [fixture.workspaceID])
        XCTAssertEqual(workspace.panels.count, 2)
        XCTAssertNotNil(workspace.panels[fixture.closedPanelID])
    }

    func testFileCloseMenuBridgeReplacesSystemCloseItemsAndClosesFocusedPanel() throws {
        let fixture = try makeSplitWorkspaceFixture()
        let store = fixture.store
        let bridge = makeFileCloseMenuBridge(store: store)

        let mainMenu = NSMenu(title: "Main")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let closeItem = NSMenuItem(
            title: "Fermer la fenetre",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        closeItem.keyEquivalentModifierMask = [.command]
        let closeAllItem = NSMenuItem(title: "Close All", action: nil, keyEquivalent: "w")
        closeAllItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(closeItem)
        fileMenu.addItem(closeAllItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        XCTAssertEqual(menuItemTitles(in: fileMenu), ["Close Panel", "Close Workspace"])
        let closePanelItem = try XCTUnwrap(fileMenu.items.first)
        let closeWorkspaceItem = try XCTUnwrap(fileMenu.items.last)
        XCTAssertEqual(closePanelItem.keyEquivalent, "")
        XCTAssertEqual(closePanelItem.keyEquivalentModifierMask, [])
        XCTAssertTrue(closePanelItem.target === bridge)
        XCTAssertEqual(closePanelItem.action, #selector(FileCloseMenuBridge.performCloseWindow(_:)))
        XCTAssertTrue(bridge.validateMenuItem(closePanelItem))
        XCTAssertEqual(closeWorkspaceItem.keyEquivalent, "")
        XCTAssertEqual(closeWorkspaceItem.keyEquivalentModifierMask, [])
        XCTAssertTrue(closeWorkspaceItem.target === bridge)
        XCTAssertEqual(closeWorkspaceItem.action, #selector(FileCloseMenuBridge.performCloseWorkspace(_:)))
        XCTAssertTrue(bridge.validateMenuItem(closeWorkspaceItem))

        bridge.installIfNeeded()
        XCTAssertEqual(menuItemTitles(in: fileMenu), ["Close Panel", "Close Workspace"])

        bridge.performCloseWindow(nil)

        let window = try XCTUnwrap(store.window(id: fixture.windowID))
        XCTAssertEqual(store.state.windows.count, 1)
        XCTAssertEqual(window.workspaceIDs, [fixture.workspaceID])
        let workspace = try XCTUnwrap(store.state.workspacesByID[fixture.workspaceID])
        XCTAssertEqual(workspace.panels.count, 1)
        XCTAssertNil(workspace.panels[fixture.closedPanelID])
        XCTAssertNotNil(workspace.focusedPanelID)
        XCTAssertEqual(store.state.selectedWindowID, fixture.windowID)
        XCTAssertTrue(bridge.validateMenuItem(closePanelItem))
    }

    func testFileCloseMenuBridgeDisablesCloseActionsWithoutKeyToasttyWindow() throws {
        let fixture = try makeSplitWorkspaceFixture(preferredWindowIDProvider: { nil })
        let store = fixture.store
        let bridge = makeFileCloseMenuBridge(store: store, preferredWindowIDProvider: { nil })

        let mainMenu = NSMenu(title: "Main")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let closeItem = NSMenuItem(
            title: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        closeItem.keyEquivalentModifierMask = [.command]
        let closeAllItem = NSMenuItem(title: "Close All", action: nil, keyEquivalent: "w")
        closeAllItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(closeItem)
        fileMenu.addItem(closeAllItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        let closePanelItem = try XCTUnwrap(fileMenu.items.first)
        let closeWorkspaceItem = try XCTUnwrap(fileMenu.items.last)
        XCTAssertFalse(bridge.validateMenuItem(closePanelItem))
        XCTAssertFalse(bridge.validateMenuItem(closeWorkspaceItem))

        bridge.performCloseWindow(nil)
        bridge.performCloseWorkspace(nil)

        let workspace = try XCTUnwrap(store.state.workspacesByID[fixture.workspaceID])
        XCTAssertEqual(workspace.panels.count, 2)
        XCTAssertNotNil(workspace.panels[fixture.closedPanelID])
        XCTAssertNil(store.pendingCloseWorkspaceRequest)
    }

    func testFileCloseMenuBridgeReinstallDoesNotRetriggerMenuMutations() {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let bridge = makeFileCloseMenuBridge(store: store)

        let mainMenu = NSMenu(title: "Main")
        let fileItem = NSMenuItem(title: "Archivo", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "Archivo")
        let closeItem = NSMenuItem(title: "Cerrar", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeItem.keyEquivalentModifierMask = [.command]
        let closeAllItem = NSMenuItem(title: "Close All", action: nil, keyEquivalent: "w")
        closeAllItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(closeItem)
        fileMenu.addItem(closeAllItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        var mutationNotificationCount = 0
        let notificationCenter = NotificationCenter.default
        let observedNames: [Notification.Name] = [
            NSMenu.didAddItemNotification,
            NSMenu.didChangeItemNotification,
            NSMenu.didRemoveItemNotification,
        ]
        let observers = observedNames.map { name in
            notificationCenter.addObserver(
                forName: name,
                object: fileMenu,
                queue: nil
            ) { _ in
                mutationNotificationCount += 1
            }
        }
        defer {
            for observer in observers {
                notificationCenter.removeObserver(observer)
            }
        }

        bridge.installIfNeeded()

        XCTAssertEqual(menuItemTitles(in: fileMenu), ["Close Panel", "Close Workspace"])
        XCTAssertEqual(mutationNotificationCount, 0)
    }

    func testFileCloseMenuBridgeDoesNotTouchEarlierNonFileCloseShortcuts() throws {
        let fixture = try makeSplitWorkspaceFixture()
        let store = fixture.store
        let bridge = makeFileCloseMenuBridge(store: store)

        let mainMenu = NSMenu(title: "Main")

        let workspaceItem = NSMenuItem(title: "Workspace", action: nil, keyEquivalent: "")
        let workspaceMenu = NSMenu(title: "Workspace")
        let workspaceCloseItem = NSMenuItem(title: "Workspace Toggle", action: nil, keyEquivalent: "w")
        workspaceCloseItem.keyEquivalentModifierMask = [.command]
        workspaceMenu.addItem(workspaceCloseItem)
        workspaceItem.submenu = workspaceMenu
        mainMenu.addItem(workspaceItem)

        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let fileCloseItem = NSMenuItem(
            title: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        fileCloseItem.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(fileCloseItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        XCTAssertNil(workspaceCloseItem.target)
        XCTAssertNil(workspaceCloseItem.action)
        XCTAssertEqual(menuItemTitles(in: fileMenu), ["Close Panel", "Close Workspace"])
        let ownedCloseItem = try XCTUnwrap(fileMenu.items.first)
        XCTAssertTrue(ownedCloseItem.target === bridge)
        XCTAssertEqual(ownedCloseItem.action, #selector(FileCloseMenuBridge.performCloseWindow(_:)))

        bridge.performCloseWindow(nil)

        let window = try XCTUnwrap(store.window(id: fixture.windowID))
        XCTAssertEqual(store.state.windows.count, 1)
        XCTAssertEqual(window.workspaceIDs, [fixture.workspaceID])
        let workspace = try XCTUnwrap(store.state.workspacesByID[fixture.workspaceID])
        XCTAssertEqual(workspace.panels.count, 1)
        XCTAssertNil(workspace.panels[fixture.closedPanelID])
    }

    func testFileCloseMenuBridgeReplacesRetargetedCloseItemsThatDriftBackIntoFileMenu() throws {
        let fixture = try makeSplitWorkspaceFixture()
        let store = fixture.store
        let bridge = makeFileCloseMenuBridge(store: store)

        let mainMenu = NSMenu(title: "Main")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let driftedClosePanelItem = NSMenuItem(title: "Close Panel", action: nil, keyEquivalent: "")
        let driftedCloseWorkspaceItem = NSMenuItem(title: "Close Workspace", action: nil, keyEquivalent: "")
        fileMenu.addItem(driftedClosePanelItem)
        fileMenu.addItem(driftedCloseWorkspaceItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()
        XCTAssertEqual(menuItemTitles(in: fileMenu), ["Close Panel", "Close Workspace"])
        let closePanelItem = try XCTUnwrap(fileMenu.items.first)
        let closeWorkspaceItem = try XCTUnwrap(fileMenu.items.last)
        XCTAssertTrue(closePanelItem !== driftedClosePanelItem)
        XCTAssertTrue(closeWorkspaceItem !== driftedCloseWorkspaceItem)
        XCTAssertEqual(closePanelItem.action, #selector(FileCloseMenuBridge.performCloseWindow(_:)))
        XCTAssertEqual(closeWorkspaceItem.action, #selector(FileCloseMenuBridge.performCloseWorkspace(_:)))
    }

    func testFileCloseMenuBridgeRequestsSelectedWorkspaceClose() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let firstWindowID = try XCTUnwrap(store.state.windows.first?.id)
        let firstWorkspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        XCTAssertTrue(store.send(.createWorkspace(windowID: firstWindowID, title: "Second")))
        let secondWorkspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        XCTAssertNotEqual(firstWorkspaceID, secondWorkspaceID)

        let bridge = makeFileCloseMenuBridge(store: store)

        let mainMenu = NSMenu(title: "Main")
        let fileItem = NSMenuItem(title: "Archivo", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "Archivo")
        let closeItem = NSMenuItem(title: "Cerrar", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeItem.keyEquivalentModifierMask = [.command]
        let closeAllItem = NSMenuItem(title: "Close All", action: nil, keyEquivalent: "w")
        closeAllItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(closeItem)
        fileMenu.addItem(closeAllItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        XCTAssertEqual(menuItemTitles(in: fileMenu), ["Close Panel", "Close Workspace"])
        let closeWorkspaceMenuItem = try XCTUnwrap(fileMenu.items.last)
        XCTAssertEqual(closeWorkspaceMenuItem.keyEquivalent, "")
        XCTAssertEqual(closeWorkspaceMenuItem.keyEquivalentModifierMask, [])
        XCTAssertTrue(closeWorkspaceMenuItem.target === bridge)
        XCTAssertEqual(closeWorkspaceMenuItem.action, #selector(FileCloseMenuBridge.performCloseWorkspace(_:)))
        XCTAssertTrue(bridge.validateMenuItem(closeWorkspaceMenuItem))

        bridge.performCloseWorkspace(nil)

        let window = try XCTUnwrap(store.window(id: firstWindowID))
        XCTAssertEqual(window.workspaceIDs, [firstWorkspaceID, secondWorkspaceID])
        XCTAssertEqual(window.selectedWorkspaceID, secondWorkspaceID)
        XCTAssertEqual(
            store.pendingCloseWorkspaceRequest,
            PendingWorkspaceCloseRequest(windowID: firstWindowID, workspaceID: secondWorkspaceID)
        )
        XCTAssertNotNil(store.state.workspacesByID[secondWorkspaceID])
        XCTAssertTrue(bridge.validateMenuItem(closeWorkspaceMenuItem))
    }

    func testFileCloseMenuBridgeMatchesSystemCloseAllMaskWithoutExplicitCommandBit() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let bridge = makeFileCloseMenuBridge(store: store)

        let mainMenu = NSMenu(title: "Main")
        let fileItem = NSMenuItem(title: "Datei", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "Datei")
        let closeItem = NSMenuItem(title: "Schließen", action: nil, keyEquivalent: "w")
        closeItem.keyEquivalentModifierMask = [.command]
        let closeAllItem = NSMenuItem(title: "Close All", action: nil, keyEquivalent: "w")
        closeAllItem.keyEquivalentModifierMask = [.shift]
        fileMenu.addItem(closeItem)
        fileMenu.addItem(closeAllItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        XCTAssertEqual(menuItemTitles(in: fileMenu), ["Close Panel", "Close Workspace"])
        let ownedCloseWorkspaceItem = try XCTUnwrap(fileMenu.items.last)
        XCTAssertEqual(ownedCloseWorkspaceItem.keyEquivalent, "")
        XCTAssertEqual(ownedCloseWorkspaceItem.keyEquivalentModifierMask, [])
        XCTAssertTrue(ownedCloseWorkspaceItem.target === bridge)
        XCTAssertEqual(ownedCloseWorkspaceItem.action, #selector(FileCloseMenuBridge.performCloseWorkspace(_:)))
    }

    func testFileCloseMenuBridgeRemovesLingeringCloseAllTitleWithoutShortcut() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let bridge = makeFileCloseMenuBridge(store: store)

        let mainMenu = NSMenu(title: "Main")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let closeAllItem = NSMenuItem(title: "Close All", action: nil, keyEquivalent: "")
        fileMenu.addItem(closeAllItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        XCTAssertEqual(menuItemTitles(in: fileMenu), ["Close Panel", "Close Workspace"])
    }

    func testFileCloseMenuBridgeDoesNotTouchNonFileShiftWItem() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let bridge = makeFileCloseMenuBridge(store: store)

        let mainMenu = NSMenu(title: "Main")

        let workspaceRootItem = NSMenuItem(title: "Workspace", action: nil, keyEquivalent: "")
        let workspaceMenu = NSMenu(title: "Workspace")
        let workspaceShiftWItem = NSMenuItem(title: "Workspace Toggle", action: nil, keyEquivalent: "w")
        workspaceShiftWItem.keyEquivalentModifierMask = [.shift]
        workspaceMenu.addItem(workspaceShiftWItem)
        workspaceRootItem.submenu = workspaceMenu
        mainMenu.addItem(workspaceRootItem)

        let fileRootItem = NSMenuItem(title: "Archivo", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "Archivo")
        let closeItem = NSMenuItem(title: "Cerrar", action: nil, keyEquivalent: "w")
        closeItem.keyEquivalentModifierMask = [.command]
        let closeAllItem = NSMenuItem(title: "Close All", action: nil, keyEquivalent: "w")
        closeAllItem.keyEquivalentModifierMask = [.shift]
        fileMenu.addItem(closeItem)
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
        XCTAssertEqual(menuItemTitles(in: fileMenu), ["Close Panel", "Close Workspace"])
        let ownedCloseWorkspaceItem = try XCTUnwrap(fileMenu.items.last)
        XCTAssertEqual(ownedCloseWorkspaceItem.keyEquivalent, "")
        XCTAssertEqual(ownedCloseWorkspaceItem.keyEquivalentModifierMask, [])
        XCTAssertTrue(ownedCloseWorkspaceItem.target === bridge)
        XCTAssertEqual(ownedCloseWorkspaceItem.action, #selector(FileCloseMenuBridge.performCloseWorkspace(_:)))
    }

    func testWorkspaceMenuBridgeRetargetsAndValidatesTabAndUnreadOrActiveItems() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        XCTAssertTrue(store.send(.selectWindow(windowID: windowID)))
        XCTAssertTrue(store.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil)))

        let workspaceAfterCreate = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let secondTabID = try XCTUnwrap(workspaceAfterCreate.resolvedSelectedTabID)
        let secondPanelID = try XCTUnwrap(workspaceAfterCreate.focusedPanelID)
        let firstTabID = try XCTUnwrap(workspaceAfterCreate.tabIDs.first(where: { $0 != secondTabID }))

        XCTAssertTrue(store.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: firstTabID)))
        XCTAssertTrue(store.send(.recordDesktopNotification(workspaceID: workspaceID, panelID: secondPanelID)))

        let bridge = makeWorkspaceMenuBridge(store: store)
        let mainMenu = NSMenu(title: "Main")
        let workspaceItem = NSMenuItem(title: "Workspace", action: nil, keyEquivalent: "")
        let workspaceMenu = NSMenu(title: "Workspace")
        let renameTabItem = NSMenuItem(title: "Rename Tab", action: nil, keyEquivalent: "e")
        renameTabItem.keyEquivalentModifierMask = [.option, .shift]
        let previousItem = NSMenuItem(title: "Select Previous Tab", action: nil, keyEquivalent: "[")
        previousItem.keyEquivalentModifierMask = [.command, .shift]
        let nextItem = NSMenuItem(title: "Select Next Tab", action: nil, keyEquivalent: "]")
        nextItem.keyEquivalentModifierMask = [.command, .shift]
        let unreadItem = NSMenuItem(title: "Jump to Next Unread or Active", action: nil, keyEquivalent: "a")
        unreadItem.keyEquivalentModifierMask = [.command, .shift]
        workspaceMenu.addItem(renameTabItem)
        workspaceMenu.addItem(previousItem)
        workspaceMenu.addItem(nextItem)
        workspaceMenu.addItem(unreadItem)
        workspaceItem.submenu = workspaceMenu
        mainMenu.addItem(workspaceItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        XCTAssertTrue(renameTabItem.target === bridge)
        XCTAssertEqual(renameTabItem.action, #selector(WorkspaceMenuBridge.renameSelectedTab(_:)))
        XCTAssertTrue(previousItem.target === bridge)
        XCTAssertEqual(previousItem.action, #selector(WorkspaceMenuBridge.selectPreviousTab(_:)))
        XCTAssertTrue(nextItem.target === bridge)
        XCTAssertEqual(nextItem.action, #selector(WorkspaceMenuBridge.selectNextTab(_:)))
        XCTAssertTrue(unreadItem.target === bridge)
        XCTAssertEqual(unreadItem.action, #selector(WorkspaceMenuBridge.focusNextUnreadOrActivePanel(_:)))
        XCTAssertTrue(bridge.validateMenuItem(renameTabItem))
        XCTAssertTrue(bridge.validateMenuItem(previousItem))
        XCTAssertTrue(bridge.validateMenuItem(nextItem))
        XCTAssertTrue(bridge.validateMenuItem(unreadItem))

        bridge.renameSelectedTab(nil)
        XCTAssertEqual(
            store.pendingRenameWorkspaceTabRequest,
            PendingWorkspaceTabRenameRequest(windowID: windowID, workspaceID: workspaceID, tabID: firstTabID)
        )
        store.pendingRenameWorkspaceTabRequest = nil

        bridge.selectNextTab(nil)
        XCTAssertEqual(store.state.workspacesByID[workspaceID]?.resolvedSelectedTabID, secondTabID)

        bridge.selectPreviousTab(nil)
        XCTAssertEqual(store.state.workspacesByID[workspaceID]?.resolvedSelectedTabID, firstTabID)

        bridge.focusNextUnreadOrActivePanel(nil)

        let workspaceAfterUnreadJump = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspaceAfterUnreadJump.resolvedSelectedTabID, secondTabID)
        XCTAssertEqual(workspaceAfterUnreadJump.focusedPanelID, secondPanelID)
        XCTAssertFalse(try XCTUnwrap(workspaceAfterUnreadJump.tabsByID[secondTabID]).unreadPanelIDs.contains(secondPanelID))
        XCTAssertFalse(bridge.validateMenuItem(unreadItem))
    }

    func testWorkspaceMenuBridgeRoutesLifecycleItemsToPreferredWindow() throws {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: firstWindowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let bridge = makeWorkspaceMenuBridge(
            store: store,
            preferredWindowIDProvider: { secondWindowID }
        )

        let mainMenu = NSMenu(title: "Main")
        let workspaceItem = NSMenuItem(title: "Workspace", action: nil, keyEquivalent: "")
        let workspaceMenu = NSMenu(title: "Workspace")
        let newWorkspaceItem = NSMenuItem(title: "New Workspace", action: nil, keyEquivalent: "n")
        newWorkspaceItem.keyEquivalentModifierMask = [.command, .shift]
        let renameWorkspaceItem = NSMenuItem(title: "Rename Workspace", action: nil, keyEquivalent: "e")
        renameWorkspaceItem.keyEquivalentModifierMask = [.command, .shift]
        let renameTabItem = NSMenuItem(title: "Rename Tab", action: nil, keyEquivalent: "e")
        renameTabItem.keyEquivalentModifierMask = [.option, .shift]
        let closeWorkspaceItem = NSMenuItem(title: "Close Workspace", action: nil, keyEquivalent: "w")
        closeWorkspaceItem.keyEquivalentModifierMask = [.command, .shift]
        workspaceMenu.addItem(renameTabItem)
        workspaceMenu.addItem(newWorkspaceItem)
        workspaceMenu.addItem(renameWorkspaceItem)
        workspaceMenu.addItem(closeWorkspaceItem)
        workspaceItem.submenu = workspaceMenu
        mainMenu.addItem(workspaceItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        XCTAssertTrue(newWorkspaceItem.target === bridge)
        XCTAssertEqual(newWorkspaceItem.action, #selector(WorkspaceMenuBridge.createWorkspace(_:)))
        XCTAssertTrue(renameWorkspaceItem.target === bridge)
        XCTAssertEqual(renameWorkspaceItem.action, #selector(WorkspaceMenuBridge.renameWorkspace(_:)))
        XCTAssertTrue(renameTabItem.target === bridge)
        XCTAssertEqual(renameTabItem.action, #selector(WorkspaceMenuBridge.renameSelectedTab(_:)))
        XCTAssertTrue(closeWorkspaceItem.target === bridge)
        XCTAssertEqual(closeWorkspaceItem.action, #selector(WorkspaceMenuBridge.closeWorkspace(_:)))
        XCTAssertTrue(bridge.validateMenuItem(newWorkspaceItem))
        XCTAssertTrue(bridge.validateMenuItem(renameWorkspaceItem))
        XCTAssertTrue(bridge.validateMenuItem(renameTabItem))
        XCTAssertTrue(bridge.validateMenuItem(closeWorkspaceItem))

        bridge.renameSelectedTab(nil)
        XCTAssertEqual(
            store.pendingRenameWorkspaceTabRequest,
            PendingWorkspaceTabRenameRequest(
                windowID: secondWindowID,
                workspaceID: secondWorkspace.id,
                tabID: try XCTUnwrap(store.state.workspacesByID[secondWorkspace.id]?.resolvedSelectedTabID)
            )
        )

        store.pendingRenameWorkspaceTabRequest = nil
        bridge.renameWorkspace(nil)
        XCTAssertEqual(
            store.pendingRenameWorkspaceRequest,
            PendingWorkspaceRenameRequest(windowID: secondWindowID, workspaceID: secondWorkspace.id)
        )

        store.pendingRenameWorkspaceRequest = nil
        bridge.closeWorkspace(nil)
        XCTAssertEqual(
            store.pendingCloseWorkspaceRequest,
            PendingWorkspaceCloseRequest(windowID: secondWindowID, workspaceID: secondWorkspace.id)
        )

        store.pendingCloseWorkspaceRequest = nil
        bridge.createWorkspace(nil)

        let updatedFirstWindow = try XCTUnwrap(store.state.window(id: firstWindowID))
        let updatedSecondWindow = try XCTUnwrap(store.state.window(id: secondWindowID))
        XCTAssertEqual(updatedFirstWindow.workspaceIDs, [firstWorkspace.id])
        XCTAssertEqual(updatedSecondWindow.workspaceIDs.count, 2)
        XCTAssertEqual(updatedSecondWindow.workspaceIDs.first, secondWorkspace.id)
        XCTAssertEqual(updatedSecondWindow.selectedWorkspaceID, updatedSecondWindow.workspaceIDs.last)
    }

    func testWorkspaceMenuBridgeFallsBackToSelectedWindowWhenAppKitKeyWindowIsUnavailable() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        XCTAssertEqual(store.state.selectedWindowID, windowID)
        let bridge = makeWorkspaceMenuBridge(
            store: store,
            preferredWindowIDProvider: {
                currentToasttyWorkspaceCommandWindowID(in: store, keyWindow: nil)
            }
        )

        let mainMenu = NSMenu(title: "Main")
        let workspaceItem = NSMenuItem(title: "Workspace", action: nil, keyEquivalent: "")
        let workspaceMenu = NSMenu(title: "Workspace")
        let renameWorkspaceItem = NSMenuItem(title: "Rename Workspace", action: nil, keyEquivalent: "e")
        renameWorkspaceItem.keyEquivalentModifierMask = [.command, .shift]
        let renameTabItem = NSMenuItem(title: "Rename Tab", action: nil, keyEquivalent: "e")
        renameTabItem.keyEquivalentModifierMask = [.option, .shift]
        workspaceMenu.addItem(renameTabItem)
        workspaceMenu.addItem(renameWorkspaceItem)
        workspaceItem.submenu = workspaceMenu
        mainMenu.addItem(workspaceItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        XCTAssertTrue(renameWorkspaceItem.target === bridge)
        XCTAssertEqual(renameWorkspaceItem.action, #selector(WorkspaceMenuBridge.renameWorkspace(_:)))
        XCTAssertTrue(bridge.validateMenuItem(renameWorkspaceItem))
        XCTAssertTrue(bridge.validateMenuItem(renameTabItem))

        bridge.renameSelectedTab(nil)
        XCTAssertEqual(
            store.pendingRenameWorkspaceTabRequest,
            PendingWorkspaceTabRenameRequest(windowID: windowID, workspaceID: workspaceID, tabID: try XCTUnwrap(store.state.workspacesByID[workspaceID]?.resolvedSelectedTabID))
        )

        store.pendingRenameWorkspaceTabRequest = nil

        bridge.renameWorkspace(nil)

        XCTAssertEqual(
            store.pendingRenameWorkspaceRequest,
            PendingWorkspaceRenameRequest(windowID: windowID, workspaceID: workspaceID)
        )
    }

    func testCurrentToasttyWorkspaceCommandWindowIDRejectsMissingSelectedWindowFallback() {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        var state = store.state
        state.selectedWindowID = UUID()
        store.replaceState(state)

        XCTAssertNil(currentToasttyWorkspaceCommandWindowID(in: store, keyWindow: nil))
    }

    func testWorkspaceMenuBridgeDisablesItemsWithoutKeyToasttyWindow() {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let bridge = makeWorkspaceMenuBridge(store: store, preferredWindowIDProvider: { nil })

        let mainMenu = NSMenu(title: "Main")
        let workspaceItem = NSMenuItem(title: "Workspace", action: nil, keyEquivalent: "")
        let workspaceMenu = NSMenu(title: "Workspace")
        let newWorkspaceItem = NSMenuItem(title: "New Workspace", action: nil, keyEquivalent: "n")
        let renameWorkspaceItem = NSMenuItem(title: "Rename Workspace", action: nil, keyEquivalent: "e")
        let renameTabItem = NSMenuItem(title: "Rename Tab", action: nil, keyEquivalent: "e")
        let closeWorkspaceItem = NSMenuItem(title: "Close Workspace", action: nil, keyEquivalent: "w")
        let previousItem = NSMenuItem(title: "Select Previous Tab", action: nil, keyEquivalent: "[")
        let nextItem = NSMenuItem(title: "Select Next Tab", action: nil, keyEquivalent: "]")
        let unreadItem = NSMenuItem(title: "Jump to Next Unread or Active", action: nil, keyEquivalent: "a")
        workspaceMenu.addItem(newWorkspaceItem)
        workspaceMenu.addItem(renameWorkspaceItem)
        workspaceMenu.addItem(renameTabItem)
        workspaceMenu.addItem(closeWorkspaceItem)
        workspaceMenu.addItem(previousItem)
        workspaceMenu.addItem(nextItem)
        workspaceMenu.addItem(unreadItem)
        workspaceItem.submenu = workspaceMenu
        mainMenu.addItem(workspaceItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        XCTAssertFalse(bridge.validateMenuItem(newWorkspaceItem))
        XCTAssertFalse(bridge.validateMenuItem(renameWorkspaceItem))
        XCTAssertFalse(bridge.validateMenuItem(renameTabItem))
        XCTAssertFalse(bridge.validateMenuItem(closeWorkspaceItem))
        XCTAssertFalse(bridge.validateMenuItem(previousItem))
        XCTAssertFalse(bridge.validateMenuItem(nextItem))
        XCTAssertFalse(bridge.validateMenuItem(unreadItem))
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

        XCTAssertFalse(fileMenu.items[0].isHidden)
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
        let rebuiltNewWindowItem = NSMenuItem(
            title: "New Window",
            action: #selector(NSResponder.newWindowForTab(_:)),
            keyEquivalent: "n"
        )
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

    func testHiddenSystemMenuItemsBridgeRefreshesOwnedFileSplitSectionForMenuTreeRefresh() {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let fileSplitBridge = FileSplitMenuBridge(
            splitLayoutCommandController: SplitLayoutCommandController(store: store)
        )
        let hiddenBridge = HiddenSystemMenuItemsBridge(
            onOwnedMenuSectionRefreshRequested: {
                fileSplitBridge.installIfNeeded()
            }
        )

        let mainMenu = NSMenu(title: "Main")
        let fileItem = NSMenuItem(title: "Datei", action: nil, keyEquivalent: "")
        let initialFileMenu = NSMenu(title: "Datei")
        let initialCloseItem = NSMenuItem(title: "Close Panel", action: nil, keyEquivalent: "w")
        initialCloseItem.keyEquivalentModifierMask = [.command]
        let initialCloseWorkspaceItem = NSMenuItem(title: "Close Workspace", action: nil, keyEquivalent: "")
        initialFileMenu.addItem(initialCloseItem)
        initialFileMenu.addItem(initialCloseWorkspaceItem)
        fileItem.submenu = initialFileMenu
        mainMenu.addItem(fileItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        hiddenBridge.installIfNeeded()

        XCTAssertEqual(
            menuItemTitles(in: initialFileMenu),
            ["Split Right", "Split Left", "Split Down", "Split Up", "<separator>", "Close Panel", "Close Workspace"]
        )

        let rebuiltFileMenu = NSMenu(title: "Datei")
        let rebuiltCloseItem = NSMenuItem(title: "Close Panel", action: nil, keyEquivalent: "w")
        rebuiltCloseItem.keyEquivalentModifierMask = [.command]
        let rebuiltCloseWorkspaceItem = NSMenuItem(title: "Close Workspace", action: nil, keyEquivalent: "")
        rebuiltFileMenu.addItem(rebuiltCloseItem)
        rebuiltFileMenu.addItem(rebuiltCloseWorkspaceItem)
        fileItem.submenu = rebuiltFileMenu

        hiddenBridge.installIfNeeded()

        XCTAssertEqual(
            menuItemTitles(in: rebuiltFileMenu),
            ["Split Right", "Split Left", "Split Down", "Split Up", "<separator>", "Close Panel", "Close Workspace"]
        )
    }

    func testHiddenSystemMenuItemsBridgeRefreshesOwnedWindowSplitSectionForMenuTreeRefresh() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowSplitBridge = WindowSplitMenuBridge(
            splitLayoutCommandController: SplitLayoutCommandController(store: store)
        )
        let hiddenBridge = HiddenSystemMenuItemsBridge(
            onOwnedMenuSectionRefreshRequested: {
                windowSplitBridge.installIfNeeded()
            }
        )

        let mainMenu = NSMenu(title: "Main")
        let windowItem = NSMenuItem(title: "Fenster", action: nil, keyEquivalent: "")
        let initialWindowMenu = NSMenu(title: "Fenster")
        initialWindowMenu.addItem(NSMenuItem(title: "Minimize", action: nil, keyEquivalent: "m"))
        initialWindowMenu.addItem(NSMenuItem(title: "Arrange in Front", action: nil, keyEquivalent: ""))
        initialWindowMenu.addItem(.separator())
        initialWindowMenu.addItem(NSMenuItem(title: "Window 1", action: nil, keyEquivalent: ""))
        windowItem.submenu = initialWindowMenu
        mainMenu.addItem(windowItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        hiddenBridge.installIfNeeded()

        let rebuiltWindowMenu = NSMenu(title: "Fenster")
        rebuiltWindowMenu.addItem(NSMenuItem(title: "Minimize", action: nil, keyEquivalent: "m"))
        rebuiltWindowMenu.addItem(NSMenuItem(title: "Arrange in Front", action: nil, keyEquivalent: ""))
        rebuiltWindowMenu.addItem(.separator())
        rebuiltWindowMenu.addItem(NSMenuItem(title: "Window 1", action: nil, keyEquivalent: ""))
        windowItem.submenu = rebuiltWindowMenu

        hiddenBridge.installIfNeeded()

        XCTAssertEqual(
            menuItemTitles(in: rebuiltWindowMenu),
            [
                "Minimize",
                "Arrange in Front",
                "<separator>",
                "Select Previous Split",
                "Select Next Split",
                "Navigate Splits",
                "Resize Splits",
                "<separator>",
                "Window 1",
            ]
        )

        let navigateMenu = try XCTUnwrap(rebuiltWindowMenu.items[5].submenu)
        XCTAssertEqual(menuItemTitles(in: navigateMenu), ["Navigate Up", "Navigate Down", "Navigate Left", "Navigate Right"])

        let resizeMenu = try XCTUnwrap(rebuiltWindowMenu.items[6].submenu)
        XCTAssertEqual(
            menuItemTitles(in: resizeMenu),
            ["Equalize Splits", "<separator>", "Resize Left", "Resize Right", "Resize Up", "Resize Down"]
        )
    }

    func testHiddenSystemMenuItemsBridgeRefreshesOwnedFileCloseSectionForMenuTreeRefresh() async {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let fileSplitBridge = FileSplitMenuBridge(
            splitLayoutCommandController: SplitLayoutCommandController(store: store)
        )
        let fileCloseBridge = makeFileCloseMenuBridge(store: store)
        let hiddenBridge = HiddenSystemMenuItemsBridge(
            onOwnedMenuSectionRefreshRequested: {
                fileSplitBridge.installIfNeeded()
                fileCloseBridge.installIfNeeded()
            }
        )

        let mainMenu = NSMenu(title: "Main")
        let fileItem = NSMenuItem(title: "Datei", action: nil, keyEquivalent: "")
        let initialFileMenu = NSMenu(title: "Datei")
        let initialCloseItem = NSMenuItem(title: "Schließen", action: nil, keyEquivalent: "w")
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

        XCTAssertEqual(
            menuItemTitles(in: initialFileMenu),
            ["Split Right", "Split Left", "Split Down", "Split Up", "<separator>", "Close Panel", "Close Workspace"]
        )

        let rebuiltFileMenu = NSMenu(title: "Datei")
        let rebuiltCloseItem = NSMenuItem(title: "Schließen", action: nil, keyEquivalent: "w")
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

        XCTAssertEqual(
            menuItemTitles(in: rebuiltFileMenu),
            ["Split Right", "Split Left", "Split Down", "Split Up", "<separator>", "Close Panel", "Close Workspace"]
        )
    }

    func testFileSplitMenuBridgeInsertsSplitSectionBeforeCloseCommands() {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let bridge = FileSplitMenuBridge(
            splitLayoutCommandController: SplitLayoutCommandController(store: store)
        )

        let mainMenu = NSMenu(title: "Main")
        let fileRootItem = NSMenuItem(title: "Archivo", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "Archivo")
        let closePanelItem = NSMenuItem(title: "Close Panel", action: nil, keyEquivalent: "w")
        closePanelItem.keyEquivalentModifierMask = [.command]
        let closeWorkspaceItem = NSMenuItem(title: "Close Workspace", action: nil, keyEquivalent: "")
        fileMenu.addItem(closePanelItem)
        fileMenu.addItem(closeWorkspaceItem)
        fileRootItem.submenu = fileMenu
        mainMenu.addItem(fileRootItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        XCTAssertEqual(
            menuItemTitles(in: fileMenu),
            ["Split Right", "Split Left", "Split Down", "Split Up", "<separator>", "Close Panel", "Close Workspace"]
        )
        XCTAssertEqual(fileMenu.items[0].keyEquivalent, "d")
        XCTAssertEqual(fileMenu.items[0].keyEquivalentModifierMask, [.command])
        XCTAssertEqual(fileMenu.items[2].keyEquivalent, "d")
        XCTAssertEqual(fileMenu.items[2].keyEquivalentModifierMask, [.command, .shift])
        XCTAssertTrue(bridge.validateMenuItem(fileMenu.items[0]))

        bridge.installIfNeeded()
        XCTAssertEqual(
            menuItemTitles(in: fileMenu),
            ["Split Right", "Split Left", "Split Down", "Split Up", "<separator>", "Close Panel", "Close Workspace"]
        )
    }

    func testFileSplitMenuBridgeReinstallsManagedItemsWhenConfigurationDrifts() {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let bridge = FileSplitMenuBridge(
            splitLayoutCommandController: SplitLayoutCommandController(store: store)
        )

        let mainMenu = NSMenu(title: "Main")
        let fileRootItem = NSMenuItem(title: "Archivo", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "Archivo")
        let closePanelItem = NSMenuItem(title: "Close Panel", action: nil, keyEquivalent: "w")
        closePanelItem.keyEquivalentModifierMask = [.command]
        let closeWorkspaceItem = NSMenuItem(title: "Close Workspace", action: nil, keyEquivalent: "")
        fileMenu.addItem(closePanelItem)
        fileMenu.addItem(closeWorkspaceItem)
        fileRootItem.submenu = fileMenu
        mainMenu.addItem(fileRootItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        fileMenu.items[0].target = nil
        fileMenu.items[0].keyEquivalent = ""

        bridge.installIfNeeded()

        XCTAssertTrue(fileMenu.items[0].target === bridge)
        XCTAssertEqual(fileMenu.items[0].keyEquivalent, "d")
        XCTAssertEqual(
            menuItemTitles(in: fileMenu),
            ["Split Right", "Split Left", "Split Down", "Split Up", "<separator>", "Close Panel", "Close Workspace"]
        )
    }

    func testWindowSplitMenuBridgeInsertsSectionBeforeWindowList() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let bridge = WindowSplitMenuBridge(
            splitLayoutCommandController: SplitLayoutCommandController(store: store)
        )

        let mainMenu = NSMenu(title: "Main")
        let windowRootItem = NSMenuItem(title: "Fenster", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Fenster")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: nil, keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Arrange in Front", action: nil, keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Window 1", action: nil, keyEquivalent: ""))
        windowRootItem.submenu = windowMenu
        mainMenu.addItem(windowRootItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        XCTAssertEqual(
            menuItemTitles(in: windowMenu),
            [
                "Minimize",
                "Arrange in Front",
                "<separator>",
                "Select Previous Split",
                "Select Next Split",
                "Navigate Splits",
                "Resize Splits",
                "<separator>",
                "Window 1",
            ]
        )

        let previousItem = windowMenu.items[3]
        XCTAssertEqual(previousItem.keyEquivalent, "[")
        XCTAssertEqual(previousItem.keyEquivalentModifierMask, [.command])
        XCTAssertTrue(bridge.validateMenuItem(previousItem))

        let nextItem = windowMenu.items[4]
        XCTAssertEqual(nextItem.keyEquivalent, "]")
        XCTAssertEqual(nextItem.keyEquivalentModifierMask, [.command])

        let navigateMenu = try XCTUnwrap(windowMenu.items[5].submenu)
        XCTAssertEqual(menuItemTitles(in: navigateMenu), ["Navigate Up", "Navigate Down", "Navigate Left", "Navigate Right"])

        let resizeMenu = try XCTUnwrap(windowMenu.items[6].submenu)
        XCTAssertEqual(
            menuItemTitles(in: resizeMenu),
            ["Equalize Splits", "<separator>", "Resize Left", "Resize Right", "Resize Up", "Resize Down"]
        )
        XCTAssertEqual(resizeMenu.items[0].keyEquivalent, "=")
        XCTAssertEqual(resizeMenu.items[0].keyEquivalentModifierMask, [.command, .control])
        XCTAssertEqual(
            resizeMenu.items[2].keyEquivalent,
            String(ToasttyKeyboardShortcuts.resizeSplitLeft.key.character)
        )
        XCTAssertEqual(resizeMenu.items[2].keyEquivalentModifierMask, [.command, .control])
        XCTAssertEqual(
            resizeMenu.items[3].keyEquivalent,
            String(ToasttyKeyboardShortcuts.resizeSplitRight.key.character)
        )
        XCTAssertEqual(
            resizeMenu.items[4].keyEquivalent,
            String(ToasttyKeyboardShortcuts.resizeSplitUp.key.character)
        )
        XCTAssertEqual(
            resizeMenu.items[5].keyEquivalent,
            String(ToasttyKeyboardShortcuts.resizeSplitDown.key.character)
        )

        bridge.installIfNeeded()
        XCTAssertEqual(
            menuItemTitles(in: windowMenu),
            [
                "Minimize",
                "Arrange in Front",
                "<separator>",
                "Select Previous Split",
                "Select Next Split",
                "Navigate Splits",
                "Resize Splits",
                "<separator>",
                "Window 1",
            ]
        )
    }

    func testWindowSplitMenuBridgeReinstallsManagedItemsWhenSubmenuDrifts() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let bridge = WindowSplitMenuBridge(
            splitLayoutCommandController: SplitLayoutCommandController(store: store)
        )

        let mainMenu = NSMenu(title: "Main")
        let windowRootItem = NSMenuItem(title: "Fenster", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Fenster")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: nil, keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Arrange in Front", action: nil, keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Window 1", action: nil, keyEquivalent: ""))
        windowRootItem.submenu = windowMenu
        mainMenu.addItem(windowRootItem)

        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        bridge.installIfNeeded()

        let navigateItem = windowMenu.items[5]
        let driftedNavigateMenu = try XCTUnwrap(navigateItem.submenu)
        driftedNavigateMenu.removeAllItems()

        bridge.installIfNeeded()

        let repairedNavigateMenu = try XCTUnwrap(windowMenu.items[5].submenu)
        XCTAssertEqual(
            menuItemTitles(in: repairedNavigateMenu),
            ["Navigate Up", "Navigate Down", "Navigate Left", "Navigate Right"]
        )
    }

    func testSplitLayoutCommandControllerCanAdjustSplitLayoutInFocusModeWhenFocusedSubtreeHasMultipleSlots() throws {
        var state = try XCTUnwrap(AutomationFixtureLoader.load(named: "split-workspace"))
        let windowID = try XCTUnwrap(state.windows.first?.id)
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        var workspace = try XCTUnwrap(state.workspacesByID[workspaceID])

        workspace.focusedPanelModeActive = true
        workspace.focusModeRootNodeID = workspace.layoutTree.resolvedNodeID
        state.workspacesByID[workspaceID] = workspace

        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let controller = SplitLayoutCommandController(store: store)

        XCTAssertTrue(controller.canAdjustSplitLayout(preferredWindowID: windowID))
    }

    func testSplitLayoutCommandControllerCannotAdjustSplitLayoutInFocusModeForSingleSlotSubtree() throws {
        var state = AppState.bootstrap()
        let windowID = try XCTUnwrap(state.windows.first?.id)
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        var workspace = try XCTUnwrap(state.workspacesByID[workspaceID])

        workspace.focusedPanelModeActive = true
        workspace.focusModeRootNodeID = workspace.layoutTree.allSlotInfos.first?.slotID
        state.workspacesByID[workspaceID] = workspace

        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let controller = SplitLayoutCommandController(store: store)

        XCTAssertFalse(controller.canAdjustSplitLayout(preferredWindowID: windowID))
    }

    func testSplitLayoutCommandControllerResizeUsesAppOwnedStepAmount() throws {
        let state = try XCTUnwrap(AutomationFixtureLoader.load(named: "split-workspace"))
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let controller = SplitLayoutCommandController(store: store)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        let initialWorkspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])

        guard case .split(_, let orientation, let initialRatio, _, _) = initialWorkspace.layoutTree else {
            XCTFail("expected split-workspace fixture to have split root")
            return
        }
        XCTAssertEqual(orientation, .horizontal)

        XCTAssertTrue(controller.resizeSplit(direction: .right, preferredWindowID: windowID))

        let resizedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        guard case .split(_, _, let resizedRatio, _, _) = resizedWorkspace.layoutTree else {
            XCTFail("expected split root after resize")
            return
        }

        XCTAssertEqual(resizedRatio, initialRatio + 0.025, accuracy: 0.0001)
    }

    func testTerminalProfilesMenuControllerSplitsFocusedSlotWithProfileBinding() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let runtimeRegistry = TerminalRuntimeRegistry()
        runtimeRegistry.bind(store: store)
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let controller = TerminalProfilesMenuController(
            store: store,
            terminalRuntimeRegistry: runtimeRegistry,
            installShellIntegrationAction: {},
            openProfilesConfigurationAction: {}
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
            },
            openProfilesConfigurationAction: {}
        )

        controller.installShellIntegration()
        XCTAssertTrue(didInstallShellIntegration)
    }

    func testTerminalProfilesMenuControllerRunsOpenProfilesConfigurationAction() {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let runtimeRegistry = TerminalRuntimeRegistry()
        runtimeRegistry.bind(store: store)
        var didOpenProfilesConfiguration = false
        let controller = TerminalProfilesMenuController(
            store: store,
            terminalRuntimeRegistry: runtimeRegistry,
            installShellIntegrationAction: {},
            openProfilesConfigurationAction: {
                didOpenProfilesConfiguration = true
            }
        )

        controller.openProfilesConfiguration()
        XCTAssertTrue(didOpenProfilesConfiguration)
    }

    private func makeSplitWorkspaceFixture(
        preferredWindowIDProvider: (() -> UUID?)? = nil
    ) throws -> SplitWorkspaceFixture {
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
                store: store,
                focusedPanelCommandController: makeFocusedPanelCommandController(store: store),
                preferredWindowIDProvider: preferredWindowIDProvider ?? { windowID }
            )
        )
    }

    private func makeFileCloseMenuBridge(
        store: AppStore,
        preferredWindowIDProvider: (() -> UUID?)? = nil
    ) -> FileCloseMenuBridge {
        let resolvedWindowIDProvider = preferredWindowIDProvider ?? { store.state.selectedWindowID }
        return FileCloseMenuBridge(
            windowCommandController: WindowCommandController(
                store: store,
                focusedPanelCommandController: makeFocusedPanelCommandController(store: store),
                preferredWindowIDProvider: resolvedWindowIDProvider
            ),
            closeWorkspaceCommandController: CloseWorkspaceCommandController(
                store: store,
                preferredWindowIDProvider: resolvedWindowIDProvider
            )
        )
    }

    private func makeWorkspaceMenuBridge(
        store: AppStore,
        preferredWindowIDProvider: (() -> UUID?)? = nil
    ) -> WorkspaceMenuBridge {
        let resolvedWindowIDProvider = preferredWindowIDProvider ?? { store.state.selectedWindowID }
        return WorkspaceMenuBridge(
            createWorkspaceCommandController: CreateWorkspaceCommandController(
                store: store,
                preferredWindowIDProvider: resolvedWindowIDProvider
            ),
            renameWorkspaceCommandController: RenameWorkspaceCommandController(
                store: store,
                preferredWindowIDProvider: resolvedWindowIDProvider
            ),
            closeWorkspaceCommandController: CloseWorkspaceCommandController(
                store: store,
                preferredWindowIDProvider: resolvedWindowIDProvider
            ),
            workspaceTabCommandController: WorkspaceTabCommandController(
                store: store,
                sessionRuntimeStore: makeSessionRuntimeStore(store: store),
                preferredWindowIDProvider: resolvedWindowIDProvider
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

    private func makeSessionRuntimeStore(store: AppStore) -> SessionRuntimeStore {
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        return sessionRuntimeStore
    }

    private func flushMainActorTasks() async {
        await MainActor.run {}
    }

    private func menuItemTitles(in menu: NSMenu) -> [String] {
        menu.items.map { item in
            item.isSeparatorItem ? "<separator>" : item.title
        }
    }
}

private struct SplitWorkspaceFixture {
    let store: AppStore
    let windowID: UUID
    let workspaceID: UUID
    let closedPanelID: UUID
    let controller: WindowCommandController
}
