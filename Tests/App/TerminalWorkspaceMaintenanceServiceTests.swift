#if TOASTTY_HAS_GHOSTTY_KIT
@testable import ToasttyApp
import CoreState
import Foundation
import GhosttyKit
import XCTest

@MainActor
final class TerminalWorkspaceMaintenanceServiceTests: XCTestCase {
    func testSynchronizePublishesPanelDisplayTitleOverrides() throws {
        let fixture = try makeMaintenanceFixture()
        fixture.visibleTextStore.textByPanelID[fixture.panelID] = """
        dev@host ~/repo % claude
        Claude Code v1.2.3
        """
        fixture.activityInferenceService.refreshVisibleTextInference(
            state: fixture.store.state,
            selectedPanelWorkspaceIDs: [fixture.panelID: fixture.workspaceID],
            backgroundPanelWorkspaceIDs: [:]
        )

        fixture.service.synchronize(
            state: fixture.store.state,
            livePanelIDs: [fixture.panelID],
            removedPanelIDs: []
        )

        XCTAssertEqual(
            fixture.publishedDisplayTitleOverrides.overridesByPanelID[fixture.panelID],
            "Claude Code"
        )
    }

    func testSynchronizePublishesWorkspaceActivitySubtext() throws {
        let fixture = try makeMaintenanceFixture()
        fixture.visibleTextStore.textByPanelID[fixture.panelID] = """
        dev@host ~/repo % codex
        OpenAI Codex (v0.1)
        Applying diff...
        """
        fixture.activityInferenceService.refreshVisibleTextInference(
            state: fixture.store.state,
            selectedPanelWorkspaceIDs: [fixture.panelID: fixture.workspaceID],
            backgroundPanelWorkspaceIDs: [:]
        )

        fixture.service.synchronize(
            state: fixture.store.state,
            livePanelIDs: [fixture.panelID],
            removedPanelIDs: []
        )

        XCTAssertEqual(
            fixture.publishedSubtext.subtextByWorkspaceID[fixture.workspaceID],
            "1 busy"
        )
    }

    func testHandleSurfaceUnregisterClearsPublishedWorkspaceActivitySubtext() throws {
        let fixture = try makeMaintenanceFixture()
        fixture.visibleTextStore.textByPanelID[fixture.panelID] = """
        dev@host ~/repo % codex
        OpenAI Codex (v0.1)
        Applying diff...
        """
        fixture.activityInferenceService.refreshVisibleTextInference(
            state: fixture.store.state,
            selectedPanelWorkspaceIDs: [fixture.panelID: fixture.workspaceID],
            backgroundPanelWorkspaceIDs: [:]
        )
        fixture.service.synchronize(
            state: fixture.store.state,
            livePanelIDs: [fixture.panelID],
            removedPanelIDs: []
        )
        XCTAssertEqual(
            fixture.publishedSubtext.subtextByWorkspaceID[fixture.workspaceID],
            "1 busy"
        )

        fixture.service.handleSurfaceUnregister(panelID: fixture.panelID)

        XCTAssertNil(fixture.publishedSubtext.subtextByWorkspaceID[fixture.workspaceID])
    }

    func testHandleSurfaceUnregisterPreservesRemainingWorkspaceActivitySubtext() throws {
        let fixture = try makeMaintenanceFixture(state: try makeSplitFixtureState())
        XCTAssertEqual(fixture.panelIDs.count, 2)

        let trackedPanels = Dictionary(uniqueKeysWithValues: fixture.panelIDs.map { ($0, fixture.workspaceID) })
        for panelID in fixture.panelIDs {
            fixture.visibleTextStore.textByPanelID[panelID] = """
            dev@host ~/repo % codex
            OpenAI Codex (v0.1)
            Applying diff...
            """
        }

        fixture.activityInferenceService.refreshVisibleTextInference(
            state: fixture.store.state,
            selectedPanelWorkspaceIDs: trackedPanels,
            backgroundPanelWorkspaceIDs: [:]
        )
        fixture.service.synchronize(
            state: fixture.store.state,
            livePanelIDs: Set(fixture.panelIDs),
            removedPanelIDs: []
        )
        XCTAssertEqual(
            fixture.publishedSubtext.subtextByWorkspaceID[fixture.workspaceID],
            "2 busy"
        )

        fixture.service.handleSurfaceUnregister(panelID: fixture.panelID)

        XCTAssertEqual(
            fixture.publishedSubtext.subtextByWorkspaceID[fixture.workspaceID],
            "1 busy"
        )
    }

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
    activityInferenceService: TerminalActivityInferenceService,
    workspaceID: UUID,
    panelID: UUID,
    panelIDs: [UUID],
    visibleTextStore: VisibleTextStore,
    pulseRecorder: PulseRecorder,
    publishedDisplayTitleOverrides: PublishedDisplayTitleOverrideStore,
    publishedSubtext: PublishedSubtextStore
) {
    let store = AppStore(state: state, persistTerminalFontPreference: false)
    let registry = TerminalRuntimeRegistry()
    let metadataService = TerminalMetadataService(store: store, registry: registry)
    let visibleTextStore = VisibleTextStore()
    let activityInferenceService = TerminalActivityInferenceService(readVisibleText: { panelID in
        visibleTextStore.textByPanelID[panelID]
    })
    let controllerStore = TerminalControllerStore()
    let workspace = try XCTUnwrap(store.selectedWorkspace)
    let workspaceID = workspace.id
    let panelID = try XCTUnwrap(workspace.focusedPanelID)
    let panelIDs = workspace.allPanelsByID.keys.sorted { $0.uuidString < $1.uuidString }
    let delegate = TestTerminalSurfaceControllerDelegate()
    for panelID in panelIDs {
        _ = controllerStore.controller(for: panelID, delegate: delegate)
    }
    let pulseRecorder = PulseRecorder()
    let publishedDisplayTitleOverrides = PublishedDisplayTitleOverrideStore()
    let publishedSubtext = PublishedSubtextStore()
    let service = TerminalWorkspaceMaintenanceService(
        store: store,
        metadataService: metadataService,
        activityInferenceService: activityInferenceService,
        containsController: { panelID in
            controllerStore.containsController(for: panelID)
        },
        controllerForPanelID: { panelID in
            pulseRecorder.panelIDs.append(panelID)
            return nil
        },
        updatePanelDisplayTitleOverrides: { nextOverridesByPanelID in
            publishedDisplayTitleOverrides.overridesByPanelID = nextOverridesByPanelID
        }
    ) { nextSubtextByWorkspaceID in
        publishedSubtext.subtextByWorkspaceID = nextSubtextByWorkspaceID
    } visibilityPulseScheduler: { pulse in
        pulse()
        pulse()
        return nil
    }
    return (
        store,
        service,
        activityInferenceService,
        workspaceID,
        panelID,
        panelIDs,
        visibleTextStore,
        pulseRecorder,
        publishedDisplayTitleOverrides,
        publishedSubtext
    )
}

@MainActor
private func makeSplitFixtureState() throws -> AppState {
    var state = AppState.bootstrap()
    let reducer = AppReducer()
    let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
    XCTAssertTrue(
        reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal), state: &state),
        "expected split fixture creation to succeed"
    )
    return state
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
private final class PublishedSubtextStore {
    var subtextByWorkspaceID: [UUID: String] = [:]
}

@MainActor
private final class PublishedDisplayTitleOverrideStore {
    var overridesByPanelID: [UUID: String] = [:]
}

@MainActor
private final class VisibleTextStore {
    var textByPanelID: [UUID: String] = [:]
}

@MainActor
private final class PulseRecorder {
    var panelIDs: [UUID] = []
}

@MainActor
private final class TestTerminalSurfaceControllerDelegate: TerminalSurfaceControllerDelegate {
    func prepareImageFileDrop(from urls: [URL], targetPanelID: UUID) -> PreparedImageFileDrop? {
        _ = urls
        _ = targetPanelID
        return nil
    }

    func handlePreparedImageFileDrop(_ drop: PreparedImageFileDrop) -> Bool {
        _ = drop
        return false
    }

    func handleLocalInterruptKey(for panelID: UUID, kind: TerminalLocalInterruptKind) {
        _ = panelID
        _ = kind
    }

    func splitSourceSurfaceState(forNewPanelID panelID: UUID) -> TerminalSplitSourceSurfaceState {
        _ = panelID
        return .none
    }

    func consumeSplitSource(forNewPanelID panelID: UUID) {
        _ = panelID
    }

    func surfaceLaunchConfiguration(for panelID: UUID) -> TerminalSurfaceLaunchConfiguration {
        _ = panelID
        return .empty
    }

    func markInitialSurfaceLaunchCompleted(for panelID: UUID) {
        _ = panelID
    }

    func registerSurfaceHandle(_ surface: ghostty_surface_t, for panelID: UUID) {
        _ = surface
        _ = panelID
    }

    func unregisterSurfaceHandle(_ surface: ghostty_surface_t, for panelID: UUID) {
        _ = surface
        _ = panelID
    }

    func surfaceCreationChildPIDSnapshot() -> Set<pid_t> {
        []
    }

    func registerSurfaceChildPIDAfterCreation(
        panelID: UUID,
        previousChildren: Set<pid_t>,
        expectedWorkingDirectory: String?,
        isRestoredLaunch: Bool
    ) {
        _ = panelID
        _ = previousChildren
        _ = expectedWorkingDirectory
        _ = isRestoredLaunch
    }

    func requestImmediateProcessWorkingDirectoryRefresh(
        panelID: UUID,
        source: String
    ) {
        _ = panelID
        _ = source
    }
}
#endif
