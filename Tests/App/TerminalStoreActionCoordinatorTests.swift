#if TOASTTY_HAS_GHOSTTY_KIT
@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class TerminalStoreActionCoordinatorTests: XCTestCase {
    func testSendSplitActionRegistersPendingSplitSourceForNewPanel() throws {
        let fixture = try makeStoreActionFixture()

        XCTAssertTrue(
            fixture.coordinator.sendSplitAction(
                workspaceID: fixture.workspaceID,
                action: .splitFocusedSlot(workspaceID: fixture.workspaceID, orientation: .horizontal)
            )
        )

        let workspace = try XCTUnwrap(fixture.store.selectedWorkspace)
        let newPanelIDs = Set(workspace.panels.keys).subtracting([fixture.sourcePanelID])
        let newPanelID = try XCTUnwrap(newPanelIDs.first)
        guard case .pending = fixture.controllerStore.splitSourceSurfaceState(for: newPanelID) else {
            XCTFail("expected pending split source registration for the new panel")
            return
        }
    }

    func testBindRequestsFocusRestoreWhenSelectedWorkspaceFocusedModeToggles() throws {
        var focusRestoreRequests = 0
        let fixture = try makeStoreActionFixture {
            focusRestoreRequests += 1
        }

        XCTAssertTrue(fixture.store.send(.toggleFocusedPanelMode(workspaceID: fixture.workspaceID)))
        XCTAssertEqual(focusRestoreRequests, 1)
    }

    func testBindReplacesPreviousObserverRegistration() throws {
        var focusRestoreRequests = 0
        let fixture = try makeStoreActionFixture {
            focusRestoreRequests += 1
        }

        fixture.coordinator.bind(store: fixture.store)

        XCTAssertTrue(fixture.store.send(.toggleFocusedPanelMode(workspaceID: fixture.workspaceID)))
        XCTAssertEqual(focusRestoreRequests, 1)
    }

    func testUnbindStopsObservingStoreActions() throws {
        var focusRestoreRequests = 0
        let fixture = try makeStoreActionFixture {
            focusRestoreRequests += 1
        }

        fixture.coordinator.unbind()

        XCTAssertTrue(fixture.store.send(.toggleFocusedPanelMode(workspaceID: fixture.workspaceID)))
        XCTAssertEqual(focusRestoreRequests, 0)
    }
}

@MainActor
private func makeStoreActionFixture(
    requestSelectedWorkspaceSlotFocusRestore: @escaping () -> Void = {}
) throws -> (
    store: AppStore,
    coordinator: TerminalStoreActionCoordinator,
    controllerStore: TerminalControllerStore,
    workspaceID: UUID,
    sourcePanelID: UUID
) {
    let state = AppState.bootstrap()
    let store = AppStore(state: state, persistTerminalFontPreference: false)
    let registry = TerminalRuntimeRegistry()
    let metadataService = TerminalMetadataService(store: store, registry: registry)
    let controllerStore = TerminalControllerStore()
    let coordinator = TerminalStoreActionCoordinator(
        controllerStore: controllerStore,
        metadataService: metadataService,
        requestSelectedWorkspaceSlotFocusRestore: requestSelectedWorkspaceSlotFocusRestore
    )
    coordinator.bind(store: store)

    let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
    let sourcePanelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
    return (store, coordinator, controllerStore, workspaceID, sourcePanelID)
}
#endif
