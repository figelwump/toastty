@testable import ToasttyApp
import AppKit
import XCTest

@MainActor
final class AlertButtonConfigurationTests: XCTestCase {
    func testDefaultActionButtonUsesReturnAndDestructiveStyling() {
        let alert = NSAlert()

        let button = alert.addConfiguredButton(
            withTitle: "Quit",
            behavior: .defaultAction,
            isDestructive: true
        )

        XCTAssertEqual(button.keyEquivalent, "\r")
        XCTAssertEqual(button.keyEquivalentModifierMask, [])
        XCTAssertTrue(button.hasDestructiveAction)
    }

    func testCancelActionButtonUsesEscapeShortcut() {
        let alert = NSAlert()

        let button = alert.addConfiguredButton(
            withTitle: "Not Now",
            behavior: .cancelAction
        )

        XCTAssertEqual(button.keyEquivalent, "\u{1B}")
        XCTAssertEqual(button.keyEquivalentModifierMask, [])
        XCTAssertFalse(button.hasDestructiveAction)
    }
}
