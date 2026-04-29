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
            ToasttyKeyboardShortcuts.selectPreviousTab.menuTitle("Select Previous Tab"),
            "Select Previous Tab\t⇧⌘["
        )
        XCTAssertEqual(
            ToasttyKeyboardShortcuts.selectNextTab.menuTitle("Select Next Tab"),
            "Select Next Tab\t⇧⌘]"
        )
        XCTAssertEqual(
            ToasttyKeyboardShortcuts.selectPreviousRightPanelTab.menuTitle("Select Previous Right Panel Tab"),
            "Select Previous Right Panel Tab\t⌃⌘["
        )
        XCTAssertEqual(
            ToasttyKeyboardShortcuts.closeWorkspace.menuTitle("Close workspace"),
            "Close workspace\t⇧⌘W"
        )
    }

    func testShortcutDefinitionsMatchExpectedGlyphs() {
        XCTAssertEqual(ToasttyKeyboardShortcuts.commandPalette.symbolLabel, "⇧⌘P")
        XCTAssertEqual(ToasttyKeyboardShortcuts.newWindow.symbolLabel, "⌘N")
        XCTAssertEqual(ToasttyKeyboardShortcuts.toggleSidebar.symbolLabel, "⌘B")
        XCTAssertEqual(ToasttyKeyboardShortcuts.toggleRightPanel.symbolLabel, "⇧⌘B")
        XCTAssertEqual(ToasttyKeyboardShortcuts.newScratchpad.symbolLabel, "⌃⌘S")
        XCTAssertEqual(ToasttyKeyboardShortcuts.newWorkspace.symbolLabel, "⇧⌘N")
        XCTAssertEqual(ToasttyKeyboardShortcuts.renameWorkspace.symbolLabel, "⇧⌘E")
        XCTAssertEqual(ToasttyKeyboardShortcuts.renameTab.symbolLabel, "⌥⇧E")
        XCTAssertEqual(ToasttyKeyboardShortcuts.selectPreviousTab.symbolLabel, "⇧⌘[")
        XCTAssertEqual(ToasttyKeyboardShortcuts.selectNextTab.symbolLabel, "⇧⌘]")
        XCTAssertEqual(ToasttyKeyboardShortcuts.selectPreviousRightPanelTab.symbolLabel, "⌃⌘[")
        XCTAssertEqual(ToasttyKeyboardShortcuts.selectNextRightPanelTab.symbolLabel, "⌃⌘]")
        XCTAssertEqual(ToasttyKeyboardShortcuts.closeWorkspace.symbolLabel, "⇧⌘W")
        XCTAssertEqual(ToasttyKeyboardShortcuts.watchRunningCommand.symbolLabel, "⇧⌘M")
        XCTAssertEqual(ToasttyKeyboardShortcuts.find.symbolLabel, "⌘F")
        XCTAssertEqual(ToasttyKeyboardShortcuts.findNext.symbolLabel, "⌘G")
        XCTAssertEqual(ToasttyKeyboardShortcuts.findPrevious.symbolLabel, "⇧⌘G")
        XCTAssertEqual(ToasttyKeyboardShortcuts.focusPreviousPane.symbolLabel, "⌘[")
        XCTAssertEqual(ToasttyKeyboardShortcuts.focusNextPane.symbolLabel, "⌘]")
        XCTAssertTrue(ToasttyKeyboardShortcuts.focusPaneLeft.symbolLabel.hasPrefix("⌥⌘"))
        XCTAssertTrue(ToasttyKeyboardShortcuts.focusPaneRight.symbolLabel.hasPrefix("⌥⌘"))
    }

    func testShortcutDefinitionsRemainUnique() {
        let shortcuts = [
            ToasttyKeyboardShortcuts.commandPalette,
            ToasttyKeyboardShortcuts.newWindow,
            ToasttyKeyboardShortcuts.toggleSidebar,
            ToasttyKeyboardShortcuts.toggleRightPanel,
            ToasttyKeyboardShortcuts.newScratchpad,
            ToasttyKeyboardShortcuts.newWorkspace,
            ToasttyKeyboardShortcuts.renameWorkspace,
            ToasttyKeyboardShortcuts.renameTab,
            ToasttyKeyboardShortcuts.selectPreviousTab,
            ToasttyKeyboardShortcuts.selectNextTab,
            ToasttyKeyboardShortcuts.selectPreviousRightPanelTab,
            ToasttyKeyboardShortcuts.selectNextRightPanelTab,
            ToasttyKeyboardShortcuts.closeWorkspace,
            ToasttyKeyboardShortcuts.toggleFocusedPanel,
            ToasttyKeyboardShortcuts.watchRunningCommand,
            ToasttyKeyboardShortcuts.find,
            ToasttyKeyboardShortcuts.findNext,
            ToasttyKeyboardShortcuts.findPrevious,
            ToasttyKeyboardShortcuts.splitHorizontal,
            ToasttyKeyboardShortcuts.splitVertical,
            ToasttyKeyboardShortcuts.focusPreviousPane,
            ToasttyKeyboardShortcuts.focusNextPane,
            ToasttyKeyboardShortcuts.focusPaneLeft,
            ToasttyKeyboardShortcuts.focusPaneRight,
            ToasttyKeyboardShortcuts.focusPaneUp,
            ToasttyKeyboardShortcuts.focusPaneDown,
        ]
        let identifiers = shortcuts.map { "\($0.key.character)|\($0.modifiers.rawValue)" }

        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }
}
