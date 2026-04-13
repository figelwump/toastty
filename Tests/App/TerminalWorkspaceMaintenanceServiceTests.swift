#if TOASTTY_HAS_GHOSTTY_KIT
@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class TerminalWorkspaceMaintenanceServiceTests: XCTestCase {
    func testSynchronizePulsesSelectedTabPanelsWhenTabSelectionChanges() throws {
        let fixture = try makeMaintenanceFixture(state: try makeTwoTabFixtureState())
        let workspace = try XCTUnwrap(fixture.store.state.workspacesByID[fixture.workspaceID])
        let originalTabID = try XCTUnwrap(workspace.tabIDs.first)
        let originalTab = try XCTUnwrap(workspace.tab(id: originalTabID))
        let originalPanelID = try XCTUnwrap(originalTab.focusedPanelID)
        let initiallySelectedTabID = try XCTUnwrap(workspace.selectedTabID)
        let initiallySelectedTab = try XCTUnwrap(workspace.tab(id: initiallySelectedTabID))
        let initiallySelectedPanelID = try XCTUnwrap(initiallySelectedTab.focusedPanelID)

        fixture.service.synchronize(
            state: fixture.store.state,
            livePanelIDs: Set(fixture.panelIDs),
            removedPanelIDs: []
        )

        XCTAssertEqual(Set(fixture.pulseRecorder.panelIDs), [initiallySelectedPanelID])
        fixture.pulseRecorder.panelIDs.removeAll()

        XCTAssertTrue(
            fixture.store.send(.selectWorkspaceTab(workspaceID: fixture.workspaceID, tabID: originalTabID))
        )
        fixture.service.synchronize(
            state: fixture.store.state,
            livePanelIDs: Set(fixture.panelIDs),
            removedPanelIDs: []
        )

        XCTAssertEqual(Set(fixture.pulseRecorder.panelIDs), [originalPanelID])
    }
}

@MainActor
private func makeMaintenanceFixture(state: AppState = .bootstrap()) throws -> (
    store: AppStore,
    service: TerminalWorkspaceMaintenanceService,
    workspaceID: UUID,
    panelIDs: [UUID],
    pulseRecorder: PulseRecorder
) {
    let store = AppStore(state: state, persistTerminalFontPreference: false)
    let registry = TerminalRuntimeRegistry()
    let metadataService = TerminalMetadataService(store: store, registry: registry)
    let workspace = try XCTUnwrap(store.selectedWorkspace)
    let workspaceID = workspace.id
    let panelIDs = workspace.allPanelsByID.keys.sorted { $0.uuidString < $1.uuidString }
    let pulseRecorder = PulseRecorder()
    let service = TerminalWorkspaceMaintenanceService(
        store: store,
        metadataService: metadataService,
        controllerForPanelID: { panelID in
            pulseRecorder.panelIDs.append(panelID)
            return nil
        },
        visibilityPulseScheduler: { pulse in
            pulse()
            pulse()
            return nil
        }
    )
    return (
        store,
        service,
        workspaceID,
        panelIDs,
        pulseRecorder
    )
}

@MainActor
private func makeTwoTabFixtureState() throws -> AppState {
    var state = AppState.bootstrap()
    let reducer = AppReducer()
    let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
    XCTAssertTrue(
        reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state),
        "expected second tab creation to succeed"
    )
    return state
}

@MainActor
private final class PulseRecorder {
    var panelIDs: [UUID] = []
}
#endif
