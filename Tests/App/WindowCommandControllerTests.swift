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
