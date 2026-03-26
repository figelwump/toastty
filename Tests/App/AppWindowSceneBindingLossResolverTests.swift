@testable import ToasttyApp
import XCTest

final class AppWindowSceneBindingLossResolverTests: XCTestCase {
    func testResolveClearsStaleRestoredBindingWithoutDismissingLastScene() {
        let windowID = UUID()

        let resolution = AppWindowSceneBindingLossResolver.resolve(
            previouslyHadBoundWindow: true,
            remainingWindowCount: 0,
            closeWasRequested: false
        )

        XCTAssertEqual(
            resolution.nextState,
            AppWindowSceneBindingState(
                boundWindowID: nil,
                hasBoundWindow: false,
                sceneWindowIDValue: nil,
                shouldDismissAfterNextBindingLoss: false
            )
        )
        XCTAssertFalse(resolution.shouldDismissScene)
    }

    func testResolveClearsBindingAndDismissesAfterConfirmedLastWindowClose() {
        let windowID = UUID()

        let resolution = AppWindowSceneBindingLossResolver.resolve(
            previouslyHadBoundWindow: true,
            remainingWindowCount: 0,
            closeWasRequested: true
        )

        XCTAssertEqual(
            resolution.nextState,
            AppWindowSceneBindingState(
                boundWindowID: nil,
                hasBoundWindow: false,
                sceneWindowIDValue: nil,
                shouldDismissAfterNextBindingLoss: false
            )
        )
        XCTAssertTrue(resolution.shouldDismissScene)
    }

    func testResolveDismissesSceneWhenOtherWindowsRemain() {
        let resolution = AppWindowSceneBindingLossResolver.resolve(
            previouslyHadBoundWindow: true,
            remainingWindowCount: 2,
            closeWasRequested: false
        )

        XCTAssertEqual(
            resolution.nextState,
            AppWindowSceneBindingState(
                boundWindowID: nil,
                hasBoundWindow: false,
                sceneWindowIDValue: nil,
                shouldDismissAfterNextBindingLoss: false
            )
        )
        XCTAssertTrue(resolution.shouldDismissScene)
    }
}
