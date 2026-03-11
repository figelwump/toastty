import AppKit
@testable import ToasttyApp
import XCTest

#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit

final class TerminalHostViewTests: XCTestCase {
    func testFlagsChangedReturnsPressForLeftCommandPress() {
        let action = TerminalHostView.ghosttyModifierActionForFlagsChanged(
            keyCode: 0x37,
            modifierFlags: [.command]
        )

        XCTAssertEqual(action?.rawValue, GHOSTTY_ACTION_PRESS.rawValue)
    }

    func testFlagsChangedReturnsReleaseForRightCommandReleaseWhileLeftRemainsHeld() {
        let action = TerminalHostView.ghosttyModifierActionForFlagsChanged(
            keyCode: 0x36,
            modifierFlags: [.command]
        )

        XCTAssertEqual(action?.rawValue, GHOSTTY_ACTION_RELEASE.rawValue)
    }

    func testFlagsChangedReturnsPressForRightShiftPress() {
        let modifierFlags = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICERSHIFTKEYMASK)
        )
        let action = TerminalHostView.ghosttyModifierActionForFlagsChanged(
            keyCode: 0x3C,
            modifierFlags: modifierFlags
        )

        XCTAssertEqual(action?.rawValue, GHOSTTY_ACTION_PRESS.rawValue)
    }

    func testFlagsChangedReturnsNilForNonModifierKeyCode() {
        let action = TerminalHostView.ghosttyModifierActionForFlagsChanged(
            keyCode: 0x24,
            modifierFlags: []
        )

        XCTAssertNil(action)
    }
}
#endif
