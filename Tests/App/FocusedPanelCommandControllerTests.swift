@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class FocusedPanelCommandControllerTests: XCTestCase {
    func testClosePanelClosesWindowNativelyWhenClosingLastPanel() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)
        let sceneCoordinator = AppWindowSceneCoordinator()
        var closedWindowID: UUID?
        let controller = FocusedPanelCommandController(
            store: store,
            runtimeRegistry: registry,
            slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator(),
            sceneCoordinator: sceneCoordinator,
            closeNativeWindow: { windowID in
                closedWindowID = windowID
                _ = store.send(.closeWindow(windowID: windowID))
                return true
            }
        )

        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)

        XCTAssertEqual(controller.closePanel(panelID: panelID), .closed)
        XCTAssertTrue(store.state.windows.isEmpty)
        XCTAssertEqual(closedWindowID, windowID)
        XCTAssertTrue(sceneCoordinator.consumeSceneDismissalAfterBindingLoss(windowID: windowID))
        try StateValidator.validate(store.state)
    }

    func testClosePanelDismissesRegisteredSceneBeforeFallingBackToNativeWindowClose() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)
        let sceneCoordinator = AppWindowSceneCoordinator()
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        sceneCoordinator.registerPresentedWindow(windowID: windowID)
        sceneCoordinator.registerWindowCloseHandler(windowID: windowID) {
            _ = store.send(.closeWindow(windowID: windowID))
        }
        var closedWindowID: UUID?
        let controller = FocusedPanelCommandController(
            store: store,
            runtimeRegistry: registry,
            slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator(),
            sceneCoordinator: sceneCoordinator,
            closeNativeWindow: { windowID in
                closedWindowID = windowID
                return true
            }
        )

        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)

        XCTAssertEqual(controller.closePanel(panelID: panelID), .closed)
        XCTAssertTrue(store.state.windows.isEmpty)
        XCTAssertNil(closedWindowID)
        try StateValidator.validate(store.state)
    }

    func testClosePanelKeepsWindowAndDoesNotCloseWindowNativelyWhenOtherPanelsRemain() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        XCTAssertTrue(
            reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal), state: &state)
        )

        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)
        let sceneCoordinator = AppWindowSceneCoordinator()
        var closedWindowID: UUID?
        let controller = FocusedPanelCommandController(
            store: store,
            runtimeRegistry: registry,
            slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator(),
            sceneCoordinator: sceneCoordinator,
            closeNativeWindow: { windowID in
                closedWindowID = windowID
                return true
            }
        )

        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspace = try XCTUnwrap(store.selectedWorkspace)
        let panelID = try XCTUnwrap(
            workspace.panels.keys.first(where: { $0 != workspace.focusedPanelID })
        )

        XCTAssertEqual(controller.closePanel(panelID: panelID), .closed)
        XCTAssertNotNil(store.window(id: windowID))
        XCTAssertNil(closedWindowID)
        XCTAssertFalse(sceneCoordinator.consumeSceneDismissalAfterBindingLoss(windowID: windowID))
        try StateValidator.validate(store.state)
    }
}
