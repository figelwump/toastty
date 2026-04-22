#if TOASTTY_HAS_GHOSTTY_KIT
@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class TerminalRuntimeRegistryWorkspaceOwnershipTests: XCTestCase {
    func testControllerMovesToTargetWorkspaceWithoutResettingTerminalRuntime() throws {
        let state = AppState.bootstrap()
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)

        let sourceWindowID = try XCTUnwrap(store.state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let originalController = registry.controller(
            for: panelID,
            workspaceID: sourceWorkspaceID,
            windowID: sourceWindowID
        )

        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        XCTAssertTrue(store.send(.createWorkspace(windowID: windowID, title: "Second Workspace", activate: true)))
        let targetWorkspaceID = try XCTUnwrap(store.selectedWorkspace?.id)

        XCTAssertTrue(
            store.send(.movePanelToWorkspace(panelID: panelID, targetWorkspaceID: targetWorkspaceID, targetSlotID: nil))
        )

        let migratedController = registry.controller(
            for: panelID,
            workspaceID: targetWorkspaceID,
            windowID: sourceWindowID
        )

        XCTAssertTrue(originalController === migratedController)
    }

    func testControllerMovesToDetachedWindowWithoutResettingTerminalRuntime() throws {
        let state = AppState.bootstrap()
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)

        let sourceWindowID = try XCTUnwrap(store.state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let originalController = registry.controller(
            for: panelID,
            workspaceID: sourceWorkspaceID,
            windowID: sourceWindowID
        )

        XCTAssertTrue(store.send(.detachPanelToNewWindow(panelID: panelID)))

        let detachedWindowID = try XCTUnwrap(store.selectedWindow?.id)
        let detachedWorkspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let migratedController = registry.controller(
            for: panelID,
            workspaceID: detachedWorkspaceID,
            windowID: detachedWindowID
        )

        XCTAssertTrue(originalController === migratedController)
    }

    func testStaleSourceWorkspaceLookupAfterDetachDoesNotResetTerminalRuntime() throws {
        let state = AppState.bootstrap()
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)

        let sourceWindowID = try XCTUnwrap(store.state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let originalController = registry.controller(
            for: panelID,
            workspaceID: sourceWorkspaceID,
            windowID: sourceWindowID
        )

        XCTAssertTrue(store.send(.detachPanelToNewWindow(panelID: panelID)))

        let staleController = registry.controller(
            for: panelID,
            workspaceID: sourceWorkspaceID,
            windowID: sourceWindowID
        )
        let detachedWindowID = try XCTUnwrap(store.selectedWindow?.id)
        let detachedWorkspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let migratedController = registry.controller(
            for: panelID,
            workspaceID: detachedWorkspaceID,
            windowID: detachedWindowID
        )

        XCTAssertTrue(staleController === originalController)
        XCTAssertTrue(migratedController === originalController)
    }
}
#endif
