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
        var restoredWorkspaceIDs: [UUID] = []
        let fixture = try makeStoreActionFixture { workspaceID in
            restoredWorkspaceIDs.append(workspaceID)
        }

        XCTAssertTrue(fixture.store.send(.toggleFocusedPanelMode(workspaceID: fixture.workspaceID)))
        XCTAssertEqual(restoredWorkspaceIDs, [fixture.workspaceID])
    }

    func testBindRequestsWorkspaceFocusRestoreWhenFocusedPanelIDIsNil() throws {
        let state = try stateWithNilFocusedPanelID()
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let metadataService = TerminalMetadataService(store: store, registry: registry)
        let controllerStore = TerminalControllerStore()
        var restoredWorkspaceIDs: [UUID] = []
        let coordinator = TerminalStoreActionCoordinator(
            metadataService: metadataService,
            registerPendingSplitSourceIfNeeded: { workspaceID, previousState, nextState in
                controllerStore.registerPendingSplitSourceIfNeeded(
                    workspaceID: workspaceID,
                    previousState: previousState,
                    nextState: nextState
                )
            },
            requestWorkspaceFocusRestore: { workspaceID in
                restoredWorkspaceIDs.append(workspaceID)
            }
        )
        coordinator.bind(store: store)

        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        XCTAssertTrue(store.send(.toggleFocusedPanelMode(workspaceID: workspaceID)))
        XCTAssertEqual(restoredWorkspaceIDs, [workspaceID])
    }

    func testBindReplacesPreviousObserverRegistration() throws {
        var restoredWorkspaceIDs: [UUID] = []
        let fixture = try makeStoreActionFixture { workspaceID in
            restoredWorkspaceIDs.append(workspaceID)
        }

        fixture.coordinator.bind(store: fixture.store)

        XCTAssertTrue(fixture.store.send(.toggleFocusedPanelMode(workspaceID: fixture.workspaceID)))
        XCTAssertEqual(restoredWorkspaceIDs, [fixture.workspaceID])
    }

    func testUnbindStopsObservingStoreActions() throws {
        var restoredWorkspaceIDs: [UUID] = []
        let fixture = try makeStoreActionFixture { workspaceID in
            restoredWorkspaceIDs.append(workspaceID)
        }

        fixture.coordinator.unbind()

        XCTAssertTrue(fixture.store.send(.toggleFocusedPanelMode(workspaceID: fixture.workspaceID)))
        XCTAssertTrue(restoredWorkspaceIDs.isEmpty)
    }
}

@MainActor
private func makeStoreActionFixture(
    requestWorkspaceFocusRestore: @escaping (UUID) -> Void = { _ in }
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
        metadataService: metadataService,
        registerPendingSplitSourceIfNeeded: { workspaceID, previousState, nextState in
            controllerStore.registerPendingSplitSourceIfNeeded(
                workspaceID: workspaceID,
                previousState: previousState,
                nextState: nextState
            )
        },
        requestWorkspaceFocusRestore: requestWorkspaceFocusRestore
    )
    coordinator.bind(store: store)

    let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
    let sourcePanelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
    return (store, coordinator, controllerStore, workspaceID, sourcePanelID)
}

private func stateWithNilFocusedPanelID() throws -> AppState {
    var state = AppState.bootstrap()
    let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
    var workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
    workspace.focusedPanelID = nil
    state.workspacesByID[workspaceID] = workspace
    return state
}
#endif
