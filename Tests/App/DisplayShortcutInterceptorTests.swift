import AppKit
@testable import ToasttyApp
import XCTest

@MainActor
final class DisplayShortcutInterceptorTests: XCTestCase {
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
