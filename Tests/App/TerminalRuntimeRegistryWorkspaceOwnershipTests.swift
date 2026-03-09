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

        let sourceWorkspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let originalController = registry.controller(for: panelID, workspaceID: sourceWorkspaceID)

        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        XCTAssertTrue(store.send(.createWorkspace(windowID: windowID, title: "Second Workspace")))
        let targetWorkspaceID = try XCTUnwrap(store.selectedWorkspace?.id)

        XCTAssertTrue(
            store.send(.movePanelToWorkspace(panelID: panelID, targetWorkspaceID: targetWorkspaceID, targetSlotID: nil))
        )
        registry.synchronize(with: store.state)

        let migratedController = registry.controller(for: panelID, workspaceID: targetWorkspaceID)

        XCTAssertTrue(originalController === migratedController)
    }

    func testControllerMovesToDetachedWindowWithoutResettingTerminalRuntime() throws {
        let state = AppState.bootstrap()
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)

        let sourceWorkspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let originalController = registry.controller(for: panelID, workspaceID: sourceWorkspaceID)

        XCTAssertTrue(store.send(.detachPanelToNewWindow(panelID: panelID)))
        registry.synchronize(with: store.state)

        let detachedWorkspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let migratedController = registry.controller(for: panelID, workspaceID: detachedWorkspaceID)

        XCTAssertTrue(originalController === migratedController)
    }

    func testStaleSourceWorkspaceLookupAfterDetachDoesNotResetTerminalRuntime() throws {
        let state = AppState.bootstrap()
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)

        let sourceWorkspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let originalController = registry.controller(for: panelID, workspaceID: sourceWorkspaceID)

        XCTAssertTrue(store.send(.detachPanelToNewWindow(panelID: panelID)))
        registry.synchronize(with: store.state)

        let staleController = registry.controller(for: panelID, workspaceID: sourceWorkspaceID)
        let detachedWorkspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let migratedController = registry.controller(for: panelID, workspaceID: detachedWorkspaceID)

        XCTAssertTrue(staleController === originalController)
        XCTAssertTrue(migratedController === originalController)
    }
}
#endif
