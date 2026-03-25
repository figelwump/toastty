import AppKit
import Carbon.HIToolbox
@testable import ToasttyApp
import XCTest

final class DisplayShortcutConfigTests: XCTestCase {
    func testWorkspaceSwitchShortcutLabelsUseOptionDigitGlyphs() {
        XCTAssertEqual(DisplayShortcutConfig.workspaceSwitchShortcutLabel(for: 1), "⌥1")
        XCTAssertEqual(DisplayShortcutConfig.workspaceSwitchShortcutLabel(for: 9), "⌥9")
        XCTAssertNil(DisplayShortcutConfig.workspaceSwitchShortcutLabel(for: 10))
    }

    func testWorkspaceTabSelectionShortcutLabelsUseCommandDigitGlyphsUpToNine() {
        XCTAssertEqual(DisplayShortcutConfig.workspaceTabSelectionShortcutLabel(for: 1), "⌘1")
        XCTAssertEqual(DisplayShortcutConfig.workspaceTabSelectionShortcutLabel(for: 9), "⌘9")
        XCTAssertNil(DisplayShortcutConfig.workspaceTabSelectionShortcutLabel(for: 10))
    }

    func testPanelFocusShortcutLabelsUseOptionShiftDigitGlyphs() {
        XCTAssertEqual(DisplayShortcutConfig.panelFocusShortcutLabel(for: 1), "⌥⇧1")
        XCTAssertEqual(DisplayShortcutConfig.panelFocusShortcutLabel(for: 10), "⌥⇧0")
        XCTAssertNil(DisplayShortcutConfig.panelFocusShortcutLabel(for: 11))
    }

    func testPanelFocusShortcutUsesKeyCodeInsteadOfShiftedCharacters() throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.option, .shift],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "¡",
                charactersIgnoringModifiers: "!",
                isARepeat: false,
                keyCode: UInt16(kVK_ANSI_1)
            )
        )

        XCTAssertEqual(DisplayShortcutConfig.shortcutNumber(for: event, scope: .panelFocus), 1)
    }

    func testPanelFocusZeroShortcutUsesKeyCodeInsteadOfShiftedCharacters() throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.option, .shift],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "º",
                charactersIgnoringModifiers: ")",
                isARepeat: false,
                keyCode: UInt16(kVK_ANSI_0)
            )
        )

        XCTAssertEqual(DisplayShortcutConfig.shortcutNumber(for: event, scope: .panelFocus), 10)
    }

    func testWorkspaceSwitchShortcutIgnoresNumericPadModifierNoise() throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.option, .numericPad],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "2",
                charactersIgnoringModifiers: "2",
                isARepeat: false,
                keyCode: UInt16(kVK_ANSI_Keypad2)
            )
        )

        XCTAssertEqual(DisplayShortcutConfig.shortcutNumber(for: event, scope: .workspaceSwitch), 2)
    }

    func testActionPrefersWorkspaceSwitchForOptionDigit() throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.option],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "3",
                charactersIgnoringModifiers: "3",
                isARepeat: false,
                keyCode: UInt16(kVK_ANSI_3)
            )
        )

        XCTAssertEqual(DisplayShortcutConfig.action(for: event), .workspaceSwitch(3))
    }

    func testActionPrefersPanelFocusForOptionShiftDigit() throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.option, .shift],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "£",
                charactersIgnoringModifiers: "#",
                isARepeat: false,
                keyCode: UInt16(kVK_ANSI_3)
            )
        )

        XCTAssertEqual(DisplayShortcutConfig.action(for: event), .panelFocus(3))
    }
}
