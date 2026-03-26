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

    func testDismissSceneInvokesRegisteredHandler() {
        let coordinator = AppWindowSceneCoordinator()
        let windowID = UUID()
        var dismissCallCount = 0

        coordinator.registerPresentedWindow(windowID: windowID)
        coordinator.registerWindowCloseHandler(windowID: windowID) {
            dismissCallCount += 1
        }

        XCTAssertTrue(coordinator.dismissScene(windowID: windowID))
        XCTAssertEqual(dismissCallCount, 1)
    }

    func testDismissSceneReturnsFalseAfterWindowUnregisters() {
        let coordinator = AppWindowSceneCoordinator()
        let windowID = UUID()

        coordinator.registerPresentedWindow(windowID: windowID)
        coordinator.registerWindowCloseHandler(windowID: windowID, closeWindow: {})
        coordinator.unregisterWindowCloseHandler(windowID: windowID)

        XCTAssertFalse(coordinator.dismissScene(windowID: windowID))
    }

    func testConsumeSceneDismissalAfterBindingLossReturnsTrueOnceForRequestedWindow() {
        let coordinator = AppWindowSceneCoordinator()
        let windowID = UUID()

        coordinator.requestSceneDismissalAfterBindingLoss(windowID: windowID)

        XCTAssertTrue(coordinator.consumeSceneDismissalAfterBindingLoss(windowID: windowID))
        XCTAssertFalse(coordinator.consumeSceneDismissalAfterBindingLoss(windowID: windowID))
    }

    func testCancelSceneDismissalAfterBindingLossRemovesPendingRequest() {
        let coordinator = AppWindowSceneCoordinator()
        let windowID = UUID()

        coordinator.requestSceneDismissalAfterBindingLoss(windowID: windowID)
        coordinator.cancelSceneDismissalAfterBindingLoss(windowID: windowID)

        XCTAssertFalse(coordinator.consumeSceneDismissalAfterBindingLoss(windowID: windowID))
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
            selectedWindowID: windows.first?.id,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
    }
}
