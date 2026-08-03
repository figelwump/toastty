import AppKit
@testable import ToasttyApp
import XCTest

#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit

final class GhosttyClipboardBridgeTests: XCTestCase {
    func testStandardClipboardUsesSystemPasteboard() {
        let pasteboard = GhosttyClipboardBridge.pasteboard(for: GHOSTTY_CLIPBOARD_STANDARD)

        XCTAssertEqual(pasteboard?.name, NSPasteboard.general.name)
    }

    func testSelectionClipboardUsesToasttyPrivatePasteboard() {
        let pasteboard = GhosttyClipboardBridge.pasteboard(for: GHOSTTY_CLIPBOARD_SELECTION)

        XCTAssertEqual(pasteboard?.name, GhosttyClipboardBridge.selectionPasteboardName)
        XCTAssertNotEqual(pasteboard?.name, NSPasteboard.general.name)
    }

    func testGhosttyRuntimeAdvertisesSelectionClipboardSupport() {
        XCTAssertTrue(GhosttyClipboardBridge.runtimeSupportsSelectionClipboard)
    }
}

@MainActor
final class TerminalHostViewGhosttyBridgeTests: TerminalHostViewTestCase {
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

    func testGhosttyLinkHoverModifierFlagsStripsShiftWhenCommandIsPressed() {
        let flags = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.command.rawValue
                | NSEvent.ModifierFlags.shift.rawValue
                | UInt(NX_DEVICERSHIFTKEYMASK)
        )

        let normalized = TerminalHostView.ghosttyLinkHoverModifierFlags(for: flags)

        XCTAssertTrue(normalized.contains(.command))
        XCTAssertFalse(normalized.contains(.shift))
        XCTAssertEqual(normalized.rawValue & UInt(NX_DEVICERSHIFTKEYMASK), 0)
    }

    func testGhosttyLinkHoverModifierFlagsKeepsShiftWithoutCommand() {
        let flags = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICERSHIFTKEYMASK)
        )

        let normalized = TerminalHostView.ghosttyLinkHoverModifierFlags(for: flags)

        XCTAssertEqual(normalized, flags)
    }

    func testUnshiftedCodepointSkipsCharacterLookupForFlagsChangedEvents() {
        var providerWasCalled = false

        let codepoint = TerminalHostView.ghosttyUnshiftedCodepoint(eventType: .flagsChanged) {
            providerWasCalled = true
            return "x"
        }

        XCTAssertEqual(codepoint, 0)
        XCTAssertFalse(providerWasCalled)
    }

    func testUnshiftedCodepointUsesFirstScalarForKeyDownEvents() {
        let codepoint = TerminalHostView.ghosttyUnshiftedCodepoint(eventType: .keyDown) {
            "A"
        }

        XCTAssertEqual(codepoint, UnicodeScalar("A").value)
    }

    func testGhosttyTextPreservesBacktabForShiftTab() {
        let text = TerminalHostView.ghosttyText(
            eventType: .keyDown,
            keyCode: 48,
            modifierFlags: [.shift],
            characterProvider: { "\u{19}" },
            translatedCharacterProvider: { "\t" }
        )

        XCTAssertNil(text)
    }

    func testGhosttyTextPreservesBareTabAsText() {
        let text = TerminalHostView.ghosttyText(
            eventType: .keyDown,
            keyCode: 48,
            modifierFlags: [],
            characterProvider: { "\t" },
            translatedCharacterProvider: { "\t" }
        )

        XCTAssertEqual(text, "\t")
    }

    func testGhosttyTextSuppressesModifiedTabTextForControlTab() {
        let text = TerminalHostView.ghosttyText(
            eventType: .keyDown,
            keyCode: 48,
            modifierFlags: [.control],
            characterProvider: { "\t" },
            translatedCharacterProvider: { "\t" }
        )

        XCTAssertNil(text)
    }

    func testGhosttyTextNormalizesControlCharacterWhenNeeded() {
        let text = TerminalHostView.ghosttyText(
            eventType: .keyDown,
            keyCode: 8,
            modifierFlags: [.control],
            characterProvider: { "\u{03}" },
            translatedCharacterProvider: { "c" }
        )

        XCTAssertEqual(text, "c")
    }

    func testLocalInterruptKeyRecognizesEscape() {
        XCTAssertTrue(
            TerminalHostView.isLocalInterruptKey(
                keyCode: 53,
                modifierFlags: [],
                charactersIgnoringModifiers: nil
            )
        )
    }

    func testLocalInterruptKeyRecognizesControlC() {
        XCTAssertTrue(
            TerminalHostView.isLocalInterruptKey(
                keyCode: 8,
                modifierFlags: [.control],
                charactersIgnoringModifiers: "c"
            )
        )
    }

    func testLocalInterruptKeyIgnoresPlainC() {
        XCTAssertFalse(
            TerminalHostView.isLocalInterruptKey(
                keyCode: 8,
                modifierFlags: [],
                charactersIgnoringModifiers: "c"
            )
        )
    }

    func testLocalInterruptKeyIgnoresCommandC() {
        XCTAssertFalse(
            TerminalHostView.isLocalInterruptKey(
                keyCode: 8,
                modifierFlags: [.command],
                charactersIgnoringModifiers: "c"
            )
        )
    }
}
#endif
