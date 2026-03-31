import AppKit
@testable import ToasttyApp
import XCTest

@MainActor
final class TextInputResponderPolicyTests: XCTestCase {
    func testTerminalHostViewDoesNotReserveTextInputCommands() {
        XCTAssertFalse(toasttyResponderUsesReservedTextInput(TerminalHostView()))
    }

    func testGenericTextResponderReservesTextInputCommands() {
        XCTAssertTrue(toasttyResponderUsesReservedTextInput(NSTextView()))
    }

    func testNilResponderDoesNotReserveTextInputCommands() {
        XCTAssertFalse(toasttyResponderUsesReservedTextInput(nil))
    }
}
