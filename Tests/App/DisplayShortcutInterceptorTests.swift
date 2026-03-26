import AppKit
@testable import ToasttyApp
import XCTest

@MainActor
final class DisplayShortcutInterceptorTests: XCTestCase {
    func testNewTabShortcutMatchesPlainCommandTOnly() throws {
        let matchingEvent = try makeKeyEvent(characters: "t", modifiers: [.command], keyCode: 0x11)
        let shiftedEvent = try makeKeyEvent(characters: "T", modifiers: [.command, .shift], keyCode: 0x11)
        let repeatedEvent = try makeKeyEvent(
            characters: "t",
            modifiers: [.command],
            keyCode: 0x11,
            isARepeat: true
        )

        XCTAssertTrue(DisplayShortcutInterceptor.isNewTabShortcut(matchingEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isNewTabShortcut(shiftedEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isNewTabShortcut(repeatedEvent))
    }

    func testTabSelectionShortcutNumberMatchesPlainCommandDigitsUpToConfiguredLimit() throws {
        let firstTabEvent = try makeKeyEvent(characters: "1", modifiers: [.command], keyCode: 0x12)
        let thirdTabEvent = try makeKeyEvent(characters: "3", modifiers: [.command], keyCode: 0x14)
        let fourthTabEvent = try makeKeyEvent(characters: "4", modifiers: [.command], keyCode: 0x15)
        let ninthTabEvent = try makeKeyEvent(characters: "9", modifiers: [.command], keyCode: 0x19)
        let zeroEvent = try makeKeyEvent(characters: "0", modifiers: [.command], keyCode: 0x1D)
        let optionDigitEvent = try makeKeyEvent(characters: "1", modifiers: [.option], keyCode: 0x12)

        XCTAssertEqual(DisplayShortcutConfig.maxWorkspaceTabSelectionShortcutCount, 9)
        XCTAssertEqual(DisplayShortcutInterceptor.tabSelectionShortcutNumber(for: firstTabEvent), 1)
        XCTAssertEqual(DisplayShortcutInterceptor.tabSelectionShortcutNumber(for: thirdTabEvent), 3)
        XCTAssertEqual(DisplayShortcutInterceptor.tabSelectionShortcutNumber(for: fourthTabEvent), 4)
        XCTAssertEqual(DisplayShortcutInterceptor.tabSelectionShortcutNumber(for: ninthTabEvent), 9)
        XCTAssertNil(DisplayShortcutInterceptor.tabSelectionShortcutNumber(for: zeroEvent))
        XCTAssertNil(DisplayShortcutInterceptor.tabSelectionShortcutNumber(for: optionDigitEvent))
    }

    func testTabNavigationDirectionMatchesCommandShiftBrackets() throws {
        let leftBracket = try makeKeyEvent(characters: "{", modifiers: [.command, .shift], keyCode: 0x21)
        let rightBracket = try makeKeyEvent(characters: "}", modifiers: [.command, .shift], keyCode: 0x1E)
        let plainLeftBracket = try makeKeyEvent(characters: "[", modifiers: [.command], keyCode: 0x21)
        let repeatedLeftBracket = try makeKeyEvent(
            characters: "{",
            modifiers: [.command, .shift],
            keyCode: 0x21,
            isARepeat: true
        )

        XCTAssertEqual(DisplayShortcutInterceptor.tabNavigationDirection(for: leftBracket), .previous)
        XCTAssertEqual(DisplayShortcutInterceptor.tabNavigationDirection(for: rightBracket), .next)
        XCTAssertNil(DisplayShortcutInterceptor.tabNavigationDirection(for: plainLeftBracket))
        XCTAssertNil(DisplayShortcutInterceptor.tabNavigationDirection(for: repeatedLeftBracket))
    }

    func testClosePanelShortcutMatchesPlainCommandWOnly() throws {
        let matchingEvent = try makeKeyEvent(characters: "w", modifiers: [.command], keyCode: 0x0D)
        let shiftedEvent = try makeKeyEvent(characters: "W", modifiers: [.command, .shift], keyCode: 0x0D)
        let repeatedEvent = try makeKeyEvent(
            characters: "w",
            modifiers: [.command],
            keyCode: 0x0D,
            isARepeat: true
        )

        XCTAssertTrue(DisplayShortcutInterceptor.isClosePanelShortcut(matchingEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isClosePanelShortcut(shiftedEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isClosePanelShortcut(repeatedEvent))
    }

    func testFocusNextUnreadShortcutMatchesCommandShiftAOnly() throws {
        let matchingEvent = try makeKeyEvent(characters: "A", modifiers: [.command, .shift], keyCode: 0x00)
        let plainCommandEvent = try makeKeyEvent(characters: "a", modifiers: [.command], keyCode: 0x00)
        let repeatedEvent = try makeKeyEvent(
            characters: "A",
            modifiers: [.command, .shift],
            keyCode: 0x00,
            isARepeat: true
        )

        XCTAssertTrue(DisplayShortcutInterceptor.isFocusNextUnreadShortcut(matchingEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isFocusNextUnreadShortcut(plainCommandEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isFocusNextUnreadShortcut(repeatedEvent))
    }

    func testRenameTabShortcutMatchesOptionShiftPhysicalEOnly() throws {
        let matchingEvent = try makeKeyEvent(characters: "E", modifiers: [.option, .shift], keyCode: 0x0E)
        let wrongKeyEvent = try makeKeyEvent(characters: "I", modifiers: [.option, .shift], keyCode: 0x22)
        let plainOptionEvent = try makeKeyEvent(characters: "e", modifiers: [.option], keyCode: 0x0E)
        let repeatedEvent = try makeKeyEvent(
            characters: "E",
            modifiers: [.option, .shift],
            keyCode: 0x0E,
            isARepeat: true
        )

        XCTAssertTrue(DisplayShortcutInterceptor.isRenameTabShortcut(matchingEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isRenameTabShortcut(wrongKeyEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isRenameTabShortcut(plainOptionEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isRenameTabShortcut(repeatedEvent))
    }

    func testClosePanelShortcutWindowIDReturnsKeyWorkspaceWindowIdentifier() {
        let windowID = UUID()
        let window = ShortcutTestWindow()
        window.identifier = NSUserInterfaceItemIdentifier(windowID.uuidString)

        let resolvedWindowID = DisplayShortcutInterceptor.closePanelShortcutWindowID(
            keyWindow: window,
            modalWindow: nil
        )

        XCTAssertEqual(resolvedWindowID, windowID)
    }

    func testClosePanelShortcutWindowIDRejectsNonUUIDIdentifier() {
        let window = ShortcutTestWindow()
        window.identifier = NSUserInterfaceItemIdentifier("not-a-uuid")

        XCTAssertNil(
            DisplayShortcutInterceptor.closePanelShortcutWindowID(
                keyWindow: window,
                modalWindow: nil
            )
        )
    }

    func testClosePanelShortcutWindowIDRejectsTextInputResponder() {
        let window = ShortcutTestWindow()
        window.identifier = NSUserInterfaceItemIdentifier(UUID().uuidString)
        window.forcedFirstResponder = NSTextView()

        XCTAssertNil(
            DisplayShortcutInterceptor.closePanelShortcutWindowID(
                keyWindow: window,
                modalWindow: nil
            )
        )
    }

    func testClosePanelShortcutWindowIDRejectsModalWindow() {
        let keyWindow = ShortcutTestWindow()
        keyWindow.identifier = NSUserInterfaceItemIdentifier(UUID().uuidString)
        let modalWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        XCTAssertNil(
            DisplayShortcutInterceptor.closePanelShortcutWindowID(
                keyWindow: keyWindow,
                modalWindow: modalWindow
            )
        )
    }

    func testClosePanelShortcutWindowIDRejectsSheetWindow() {
        let keyWindow = ShortcutTestWindow()
        keyWindow.identifier = NSUserInterfaceItemIdentifier(UUID().uuidString)
        keyWindow.forcedSheetParent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        XCTAssertNil(
            DisplayShortcutInterceptor.closePanelShortcutWindowID(
                keyWindow: keyWindow,
                modalWindow: nil
            )
        )
    }
}

private func makeKeyEvent(
    characters: String,
    modifiers: NSEvent.ModifierFlags,
    keyCode: UInt16,
    isARepeat: Bool = false
) throws -> NSEvent {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: isARepeat,
        keyCode: keyCode
    ) else {
        throw NSError(domain: "DisplayShortcutInterceptorTests", code: 1)
    }
    return event
}

private final class ShortcutTestWindow: NSWindow {
    var forcedFirstResponder: NSResponder?
    var forcedSheetParent: NSWindow?

    override var firstResponder: NSResponder? {
        forcedFirstResponder ?? super.firstResponder
    }

    override var sheetParent: NSWindow? {
        forcedSheetParent
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }
}
