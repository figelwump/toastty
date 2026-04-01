@testable import ToasttyApp
import AppKit
import XCTest

@MainActor
final class AlertButtonConfigurationTests: XCTestCase {
    func testDefaultActionButtonUsesReturnShortcutWithoutDestructiveStyling() {
        let alert = NSAlert()

        let button = alert.addConfiguredButton(
            withTitle: "Quit",
            behavior: .defaultAction
        )

        XCTAssertEqual(button.keyEquivalent, "\r")
        XCTAssertEqual(button.keyEquivalentModifierMask, [])
        XCTAssertFalse(button.hasDestructiveAction)
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
