@testable import ToasttyApp
import SwiftUI
import XCTest

final class ToasttyKeyboardShortcutTests: XCTestCase {
    func testHelpTextAppendsShortcutGlyphs() {
        XCTAssertEqual(
            ToasttyKeyboardShortcuts.splitHorizontal.helpText("Split Horizontally"),
            "Split Horizontally (⌘D)"
        )
        XCTAssertEqual(
            ToasttyKeyboardShortcuts.splitVertical.helpText("Split Vertically"),
            "Split Vertically (⇧⌘D)"
        )
        XCTAssertEqual(
            ToasttyKeyboardShortcuts.toggleFocusedPanel.helpText("Focus Panel"),
            "Focus Panel (⇧⌘F)"
        )
        XCTAssertEqual(
            ToasttyKeyboardShortcuts.renameWorkspace.menuTitle("Rename Workspace"),
            "Rename Workspace\t⇧⌘E"
        )
    }

    func testShortcutDefinitionsMatchExpectedGlyphs() {
        XCTAssertEqual(ToasttyKeyboardShortcuts.toggleSidebar.symbolLabel, "⇧⌘W")
        XCTAssertEqual(ToasttyKeyboardShortcuts.newWorkspace.symbolLabel, "⇧⌘N")
        XCTAssertEqual(ToasttyKeyboardShortcuts.renameWorkspace.symbolLabel, "⇧⌘E")
        XCTAssertEqual(ToasttyKeyboardShortcuts.focusPreviousPane.symbolLabel, "⌘[")
        XCTAssertEqual(ToasttyKeyboardShortcuts.focusNextPane.symbolLabel, "⌘]")
    }

    func testShortcutDefinitionsRemainUnique() {
        let shortcuts = [
            ToasttyKeyboardShortcuts.toggleSidebar,
            ToasttyKeyboardShortcuts.newWorkspace,
            ToasttyKeyboardShortcuts.renameWorkspace,
            ToasttyKeyboardShortcuts.toggleFocusedPanel,
            ToasttyKeyboardShortcuts.splitHorizontal,
            ToasttyKeyboardShortcuts.splitVertical,
            ToasttyKeyboardShortcuts.focusPreviousPane,
            ToasttyKeyboardShortcuts.focusNextPane,
        ]
        let identifiers = shortcuts.map { "\($0.key.character)|\($0.modifiers.rawValue)" }

        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }
}
