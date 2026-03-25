@testable import ToasttyApp
import XCTest

final class AppWindowSceneDismissalPolicyTests: XCTestCase {
    func testShouldDismissSceneAfterLosingBoundWindowWhenOtherWindowsRemain() {
        XCTAssertTrue(
            AppWindowSceneDismissalPolicy.shouldDismissSceneAfterLosingBoundWindow(
                previouslyHadBoundWindow: true,
                remainingWindowCount: 2,
                closeWasRequested: false
            )
        )
    }

    func testShouldDismissSceneAfterConfirmedCloseWhenNoWindowsRemain() {
        XCTAssertTrue(
            AppWindowSceneDismissalPolicy.shouldDismissSceneAfterLosingBoundWindow(
                previouslyHadBoundWindow: true,
                remainingWindowCount: 0,
                closeWasRequested: true
            )
        )
    }

    func testShouldNotDismissSceneOnBindingLossWhenNoWindowsRemainWithoutCloseIntent() {
        XCTAssertFalse(
            AppWindowSceneDismissalPolicy.shouldDismissSceneAfterLosingBoundWindow(
                previouslyHadBoundWindow: true,
                remainingWindowCount: 0,
                closeWasRequested: false
            )
        )
    }

    func testShouldNotDismissSceneBeforeAnyWindowWasBound() {
        XCTAssertFalse(
            AppWindowSceneDismissalPolicy.shouldDismissSceneAfterLosingBoundWindow(
                previouslyHadBoundWindow: false,
                remainingWindowCount: 0,
                closeWasRequested: true
            )
        )
    }
}
