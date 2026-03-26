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
        XCTAssertEqual(
            ToasttyKeyboardShortcuts.renameTab.menuTitle("Rename Tab"),
            "Rename Tab\t⌥⇧E"
        )
        XCTAssertEqual(
            ToasttyKeyboardShortcuts.closeWorkspace.menuTitle("Close workspace"),
            "Close workspace\t⇧⌘W"
        )
    }

    func testShortcutDefinitionsMatchExpectedGlyphs() {
        XCTAssertEqual(ToasttyKeyboardShortcuts.newWindow.symbolLabel, "⌘N")
        XCTAssertEqual(ToasttyKeyboardShortcuts.toggleSidebar.symbolLabel, "⌘B")
        XCTAssertEqual(ToasttyKeyboardShortcuts.newWorkspace.symbolLabel, "⇧⌘N")
        XCTAssertEqual(ToasttyKeyboardShortcuts.renameWorkspace.symbolLabel, "⇧⌘E")
        XCTAssertEqual(ToasttyKeyboardShortcuts.renameTab.symbolLabel, "⌥⇧E")
        XCTAssertEqual(ToasttyKeyboardShortcuts.closeWorkspace.symbolLabel, "⇧⌘W")
        XCTAssertEqual(ToasttyKeyboardShortcuts.focusPreviousPane.symbolLabel, "⌘[")
        XCTAssertEqual(ToasttyKeyboardShortcuts.focusNextPane.symbolLabel, "⌘]")
    }

    func testShortcutDefinitionsRemainUnique() {
        let shortcuts = [
            ToasttyKeyboardShortcuts.newWindow,
            ToasttyKeyboardShortcuts.toggleSidebar,
            ToasttyKeyboardShortcuts.newWorkspace,
            ToasttyKeyboardShortcuts.renameWorkspace,
            ToasttyKeyboardShortcuts.renameTab,
            ToasttyKeyboardShortcuts.closeWorkspace,
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
