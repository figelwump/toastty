import SwiftUI
import XCTest
@testable import ToasttyMobileApp

final class ToasttyComposerFocusLifecycleTests: XCTestCase {
    func testBackgroundClearsFocusAndNextActivationRejectsUIKitRestoration() {
        var policy = ToasttyComposerFocusLifecyclePolicy()

        let backgroundFocus = policy.focus(
            afterTransitionTo: .background,
            currentFocus: true
        )
        XCTAssertFalse(backgroundFocus)
        XCTAssertTrue(policy.isAwaitingActivationAfterBackground)

        let activationFocus = policy.focus(
            afterTransitionTo: .active,
            currentFocus: true
        )
        XCTAssertFalse(activationFocus)
        XCTAssertFalse(policy.isAwaitingActivationAfterBackground)
    }

    func testInactiveAndOrdinaryActiveTransitionsPreserveFocus() {
        var policy = ToasttyComposerFocusLifecyclePolicy()

        XCTAssertTrue(policy.focus(afterTransitionTo: .inactive, currentFocus: true))
        XCTAssertTrue(policy.focus(afterTransitionTo: .active, currentFocus: true))
    }

    func testFocusCanReturnAfterBackgroundActivationCycleCompletes() {
        var policy = ToasttyComposerFocusLifecyclePolicy()

        _ = policy.focus(afterTransitionTo: .background, currentFocus: true)
        _ = policy.focus(afterTransitionTo: .active, currentFocus: true)

        XCTAssertTrue(policy.focus(afterTransitionTo: .active, currentFocus: true))
    }
}
