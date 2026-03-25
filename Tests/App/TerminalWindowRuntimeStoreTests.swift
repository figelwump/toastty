#if TOASTTY_HAS_GHOSTTY_KIT
@testable import ToasttyApp
import CoreState
import Foundation
import GhosttyKit
import XCTest

@MainActor
final class TerminalWindowRuntimeStoreTests: XCTestCase {
    func testSynchronizeReturnsRemovedPanelIDsForPanelsMissingFromState() throws {
        let store = AppStore(state: AppState.bootstrap(), persistTerminalFontPreference: false)
        let runtimeStore = TerminalWindowRuntimeStore()
        let delegate = TestTerminalSurfaceControllerDelegate()

        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        _ = runtimeStore.controller(
            for: panelID,
            workspaceID: workspaceID,
            windowID: windowID,
            state: store.state,
            delegate: delegate
        )

        let replacementState = AppState.bootstrap()
        let removedPanelIDs = runtimeStore.synchronize(with: replacementState)

        XCTAssertEqual(removedPanelIDs, [panelID])
        XCTAssertNil(runtimeStore.existingController(for: panelID))
    }

    func testControllerMovesToTargetWorkspaceWithoutResettingTerminalRuntime() throws {
        let store = AppStore(state: AppState.bootstrap(), persistTerminalFontPreference: false)
        let runtimeStore = TerminalWindowRuntimeStore()
        let delegate = TestTerminalSurfaceControllerDelegate()

        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let originalController = runtimeStore.controller(
            for: panelID,
            workspaceID: sourceWorkspaceID,
            windowID: windowID,
            state: store.state,
            delegate: delegate
        )

        XCTAssertTrue(store.send(.createWorkspace(windowID: windowID, title: "Second Workspace")))
        let targetWorkspaceID = try XCTUnwrap(store.selectedWorkspace?.id)

        XCTAssertTrue(
            store.send(.movePanelToWorkspace(panelID: panelID, targetWorkspaceID: targetWorkspaceID, targetSlotID: nil))
        )
        _ = runtimeStore.synchronize(with: store.state)

        let migratedController = runtimeStore.controller(
            for: panelID,
            workspaceID: targetWorkspaceID,
            windowID: windowID,
            state: store.state,
            delegate: delegate
        )

        XCTAssertTrue(originalController === migratedController)
    }

    func testStaleSourceWorkspaceLookupAfterDetachKeepsOriginalControllerAvailable() throws {
        let store = AppStore(state: AppState.bootstrap(), persistTerminalFontPreference: false)
        let runtimeStore = TerminalWindowRuntimeStore()
        let delegate = TestTerminalSurfaceControllerDelegate()

        let sourceWindowID = try XCTUnwrap(store.state.windows.first?.id)
        let sourceWorkspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let originalController = runtimeStore.controller(
            for: panelID,
            workspaceID: sourceWorkspaceID,
            windowID: sourceWindowID,
            state: store.state,
            delegate: delegate
        )

        XCTAssertTrue(store.send(.detachPanelToNewWindow(panelID: panelID)))
        _ = runtimeStore.synchronize(with: store.state)

        let staleController = runtimeStore.controller(
            for: panelID,
            workspaceID: sourceWorkspaceID,
            windowID: sourceWindowID,
            state: store.state,
            delegate: delegate
        )
        let detachedWindowID = try XCTUnwrap(store.selectedWindow?.id)
        let detachedWorkspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let migratedController = runtimeStore.controller(
            for: panelID,
            workspaceID: detachedWorkspaceID,
            windowID: detachedWindowID,
            state: store.state,
            delegate: delegate
        )

        XCTAssertTrue(staleController === originalController)
        XCTAssertTrue(migratedController === originalController)
    }

    func testSynchronizeKeepsControllersForBackgroundTabsInSelectedWorkspace() throws {
        let store = AppStore(state: AppState.bootstrap(), persistTerminalFontPreference: false)
        let runtimeStore = TerminalWindowRuntimeStore()
        let delegate = TestTerminalSurfaceControllerDelegate()

        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let originalPanelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let originalController = runtimeStore.controller(
            for: originalPanelID,
            workspaceID: workspaceID,
            windowID: windowID,
            state: store.state,
            delegate: delegate
        )

        XCTAssertTrue(store.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil)))
        let workspaceWithTwoTabs = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let originalTabID = try XCTUnwrap(workspaceWithTwoTabs.tabIDs.first)
        let selectedTabID = try XCTUnwrap(workspaceWithTwoTabs.selectedTabID)
        let selectedTab = try XCTUnwrap(workspaceWithTwoTabs.tab(id: selectedTabID))
        let selectedPanelID = try XCTUnwrap(selectedTab.focusedPanelID)
        let selectedController = runtimeStore.controller(
            for: selectedPanelID,
            workspaceID: workspaceID,
            windowID: windowID,
            state: store.state,
            delegate: delegate
        )

        let removedAfterTabCreate = runtimeStore.synchronize(with: store.state)
        XCTAssertTrue(removedAfterTabCreate.isEmpty)
        XCTAssertTrue(runtimeStore.existingController(for: originalPanelID) === originalController)
        XCTAssertTrue(runtimeStore.existingController(for: selectedPanelID) === selectedController)

        XCTAssertTrue(store.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: originalTabID)))

        let removedAfterTabSwitch = runtimeStore.synchronize(with: store.state)
        XCTAssertTrue(removedAfterTabSwitch.isEmpty)
        XCTAssertTrue(runtimeStore.existingController(for: originalPanelID) === originalController)
        XCTAssertTrue(runtimeStore.existingController(for: selectedPanelID) === selectedController)
    }
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
        expectedWorkingDirectory: String?
    ) {
        _ = panelID
        _ = previousChildren
        _ = expectedWorkingDirectory
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
