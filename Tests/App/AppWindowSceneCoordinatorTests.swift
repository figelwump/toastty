@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class AppWindowSceneCoordinatorTests: XCTestCase {
    func testReserveMissingWindowIDsSkipsPresentedAndPendingWindows() {
        let coordinator = AppWindowSceneCoordinator()
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let thirdWindowID = UUID()
        let state = makeState(windowIDs: [firstWindowID, secondWindowID, thirdWindowID])

        coordinator.registerPresentedWindow(windowID: firstWindowID)

        let firstReservation = coordinator.reserveMissingWindowIDs(
            in: state,
            excluding: [firstWindowID]
        )
        let secondReservation = coordinator.reserveMissingWindowIDs(
            in: state,
            excluding: [firstWindowID]
        )

        XCTAssertEqual(firstReservation, [secondWindowID, thirdWindowID])
        XCTAssertTrue(secondReservation.isEmpty)
    }

    func testReserveMissingWindowIDsDropsPendingWindowsRemovedFromState() {
        let coordinator = AppWindowSceneCoordinator()
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let fullState = makeState(windowIDs: [firstWindowID, secondWindowID])
        let trimmedState = makeState(windowIDs: [firstWindowID])

        _ = coordinator.reserveMissingWindowIDs(in: fullState, excluding: [firstWindowID])
        let trimmedReservation = coordinator.reserveMissingWindowIDs(in: trimmedState)

        XCTAssertEqual(trimmedReservation, [firstWindowID])
    }

    func testUnregisterPresentedWindowAllowsItToBeReservedAgain() {
        let coordinator = AppWindowSceneCoordinator()
        let windowID = UUID()
        let state = makeState(windowIDs: [windowID])

        coordinator.registerPresentedWindow(windowID: windowID)
        coordinator.unregisterPresentedWindow(windowID: windowID)

        XCTAssertEqual(coordinator.reserveMissingWindowIDs(in: state), [windowID])
    }

    func testClaimWindowIDUsesPendingReservationFirst() {
        let coordinator = AppWindowSceneCoordinator()
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = makeState(windowIDs: [firstWindowID, secondWindowID])

        XCTAssertEqual(
            coordinator.reserveMissingWindowIDs(in: state, excluding: [firstWindowID]),
            [secondWindowID]
        )

        XCTAssertEqual(coordinator.claimWindowID(in: state), secondWindowID)
    }

    func testClaimWindowIDFallsBackToFirstAvailableWindow() {
        let coordinator = AppWindowSceneCoordinator()
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = makeState(windowIDs: [firstWindowID, secondWindowID])

        XCTAssertEqual(coordinator.claimWindowID(in: state), firstWindowID)
        XCTAssertEqual(coordinator.claimWindowID(in: state), secondWindowID)
        XCTAssertNil(coordinator.claimWindowID(in: state))
    }

    private func makeState(windowIDs: [UUID]) -> AppState {
        var workspacesByID: [UUID: WorkspaceState] = [:]
        let windows = windowIDs.map { windowID in
            let workspace = WorkspaceState.bootstrap(title: windowID.uuidString)
            workspacesByID[workspace.id] = workspace
            return WindowState(
                id: windowID,
                frame: CGRectCodable(x: 0, y: 0, width: 900, height: 700),
                workspaceIDs: [workspace.id],
                selectedWorkspaceID: workspace.id
            )
        }

        return AppState(
            windows: windows,
            workspacesByID: workspacesByID,
            selectedWindowID: windows.first?.id
        )
    }
}
