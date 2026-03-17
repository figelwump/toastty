#if TOASTTY_HAS_GHOSTTY_KIT
@testable import ToasttyApp
import CoreState
import Foundation
import GhosttyKit
import XCTest

@MainActor
final class TerminalWorkspaceRuntimeTests: XCTestCase {
    func testSynchronizeLivePanelsOnlyInvalidatesControllersInThatWorkspaceRuntime() {
        let firstRuntime = TerminalWorkspaceRuntime(workspaceID: UUID())
        let secondRuntime = TerminalWorkspaceRuntime(workspaceID: UUID())
        let firstPanelID = UUID()
        let secondPanelID = UUID()
        let delegate = TestTerminalSurfaceControllerDelegate()

        _ = firstRuntime.controller(for: firstPanelID, delegate: delegate)
        _ = secondRuntime.controller(for: secondPanelID, delegate: delegate)

        _ = firstRuntime.synchronizeLivePanels([])

        XCTAssertNil(firstRuntime.existingController(for: firstPanelID))
        XCTAssertNotNil(secondRuntime.existingController(for: secondPanelID))
    }

    func testRegisterPendingSplitSourceUsesWorkspaceScopedTransition() throws {
        let (workspaceID, previousState, nextState, newPanelID, _) = try makeSplitTransition()
        let runtime = TerminalWorkspaceRuntime(workspaceID: workspaceID)

        runtime.registerPendingSplitSourceIfNeeded(
            previousState: previousState,
            nextState: nextState
        )

        guard case .pending = runtime.splitSourceSurfaceState(for: newPanelID) else {
            XCTFail("expected pending split source state for the new panel")
            return
        }
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

@MainActor
private func makeSplitTransition() throws -> (
    workspaceID: UUID,
    previousState: AppState,
    nextState: AppState,
    newPanelID: UUID,
    sourcePanelID: UUID
) {
    let previousState = AppState.bootstrap()
    let reducer = AppReducer()
    let workspaceID = try XCTUnwrap(previousState.windows.first?.selectedWorkspaceID)
    let sourcePanelID = try XCTUnwrap(previousState.workspacesByID[workspaceID]?.focusedPanelID)
    var nextState = previousState

    XCTAssertTrue(
        reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal), state: &nextState),
        "expected split fixture creation to succeed"
    )

    let previousPanelIDs = Set(try XCTUnwrap(previousState.workspacesByID[workspaceID]?.panels.keys))
    let nextPanelIDs = Set(try XCTUnwrap(nextState.workspacesByID[workspaceID]?.panels.keys))
    let newPanelID = try XCTUnwrap(nextPanelIDs.subtracting(previousPanelIDs).first)
    return (workspaceID, previousState, nextState, newPanelID, sourcePanelID)
}
#endif
