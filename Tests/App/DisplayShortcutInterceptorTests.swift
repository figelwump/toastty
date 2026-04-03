import AppKit
@testable import ToasttyApp
import WebKit
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

    func testFocusNextUnreadOrActiveShortcutMatchesCommandShiftAOnly() throws {
        let matchingEvent = try makeKeyEvent(characters: "A", modifiers: [.command, .shift], keyCode: 0x00)
        let plainCommandEvent = try makeKeyEvent(characters: "a", modifiers: [.command], keyCode: 0x00)
        let repeatedEvent = try makeKeyEvent(
            characters: "A",
            modifiers: [.command, .shift],
            keyCode: 0x00,
            isARepeat: true
        )

        XCTAssertTrue(DisplayShortcutInterceptor.isFocusNextUnreadOrActiveShortcut(matchingEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isFocusNextUnreadOrActiveShortcut(plainCommandEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isFocusNextUnreadOrActiveShortcut(repeatedEvent))
    }

    func testToggleFocusedPanelShortcutMatchesCommandShiftFOnly() throws {
        let matchingEvent = try makeKeyEvent(characters: "F", modifiers: [.command, .shift], keyCode: 0x03)
        let plainCommandEvent = try makeKeyEvent(characters: "f", modifiers: [.command], keyCode: 0x03)
        let repeatedEvent = try makeKeyEvent(
            characters: "F",
            modifiers: [.command, .shift],
            keyCode: 0x03,
            isARepeat: true
        )

        XCTAssertTrue(DisplayShortcutInterceptor.isToggleFocusedPanelShortcut(matchingEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isToggleFocusedPanelShortcut(plainCommandEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isToggleFocusedPanelShortcut(repeatedEvent))
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

    func testFocusSplitDirectionMatchesPlainCommandBrackets() throws {
        let leftBracket = try makeKeyEvent(characters: "[", modifiers: [.command], keyCode: 0x21)
        let rightBracket = try makeKeyEvent(characters: "]", modifiers: [.command], keyCode: 0x1E)
        let shiftedLeftBracket = try makeKeyEvent(characters: "{", modifiers: [.command, .shift], keyCode: 0x21)
        let repeatedRightBracket = try makeKeyEvent(
            characters: "]",
            modifiers: [.command],
            keyCode: 0x1E,
            isARepeat: true
        )

        XCTAssertEqual(DisplayShortcutInterceptor.focusSplitDirection(for: leftBracket), .previous)
        XCTAssertEqual(DisplayShortcutInterceptor.focusSplitDirection(for: rightBracket), .next)
        XCTAssertNil(DisplayShortcutInterceptor.focusSplitDirection(for: shiftedLeftBracket))
        XCTAssertNil(DisplayShortcutInterceptor.focusSplitDirection(for: repeatedRightBracket))
    }

    func testBrowserOpenLocationShortcutMatchesPlainCommandLOnly() throws {
        let matchingEvent = try makeKeyEvent(characters: "l", modifiers: [.command], keyCode: 0x25)
        let shiftedEvent = try makeKeyEvent(characters: "L", modifiers: [.command, .shift], keyCode: 0x25)
        let repeatedEvent = try makeKeyEvent(
            characters: "l",
            modifiers: [.command],
            keyCode: 0x25,
            isARepeat: true
        )

        XCTAssertTrue(DisplayShortcutInterceptor.isBrowserOpenLocationShortcut(matchingEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isBrowserOpenLocationShortcut(shiftedEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isBrowserOpenLocationShortcut(repeatedEvent))
    }

    func testNewBrowserShortcutMatchesCommandControlBOnly() throws {
        let matchingEvent = try makeKeyEvent(characters: "b", modifiers: [.command, .control], keyCode: 0x0B)
        let shiftedEvent = try makeKeyEvent(characters: "B", modifiers: [.command, .control, .shift], keyCode: 0x0B)
        let repeatedEvent = try makeKeyEvent(
            characters: "b",
            modifiers: [.command, .control],
            keyCode: 0x0B,
            isARepeat: true
        )

        XCTAssertTrue(DisplayShortcutInterceptor.isNewBrowserShortcut(matchingEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isNewBrowserShortcut(shiftedEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isNewBrowserShortcut(repeatedEvent))
    }

    func testNewBrowserTabShortcutMatchesCommandControlShiftBOnly() throws {
        let matchingEvent = try makeKeyEvent(
            characters: "B",
            modifiers: [.command, .control, .shift],
            keyCode: 0x0B
        )
        let plainEvent = try makeKeyEvent(characters: "b", modifiers: [.command, .control], keyCode: 0x0B)
        let repeatedEvent = try makeKeyEvent(
            characters: "B",
            modifiers: [.command, .control, .shift],
            keyCode: 0x0B,
            isARepeat: true
        )

        XCTAssertTrue(DisplayShortcutInterceptor.isNewBrowserTabShortcut(matchingEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isNewBrowserTabShortcut(plainEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isNewBrowserTabShortcut(repeatedEvent))
    }

    func testBrowserReloadShortcutMatchesPlainCommandROnly() throws {
        let matchingEvent = try makeKeyEvent(characters: "r", modifiers: [.command], keyCode: 0x0F)
        let shiftedEvent = try makeKeyEvent(characters: "R", modifiers: [.command, .shift], keyCode: 0x0F)
        let repeatedEvent = try makeKeyEvent(
            characters: "r",
            modifiers: [.command],
            keyCode: 0x0F,
            isARepeat: true
        )

        XCTAssertTrue(DisplayShortcutInterceptor.isBrowserReloadShortcut(matchingEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isBrowserReloadShortcut(shiftedEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isBrowserReloadShortcut(repeatedEvent))
    }

    func testBrowserShortcutsRequireAppOwnedWindowSelection() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        XCTAssertTrue(
            store.createBrowserPanelFromCommand(
                preferredWindowID: windowID,
                request: BrowserPanelCreateRequest(
                    initialURL: "https://example.com",
                    placementOverride: .splitRight
                )
            )
        )
        let interceptor = makeInterceptor(store: store)
        let openLocationEvent = try makeKeyEvent(characters: "l", modifiers: [.command], keyCode: 0x25)
        let reloadEvent = try makeKeyEvent(characters: "r", modifiers: [.command], keyCode: 0x0F)

        XCTAssertNotNil(store.focusedBrowserPanelSelection(preferredWindowID: nil))
        XCTAssertEqual(
            interceptor.shortcutAction(for: openLocationEvent, appOwnedWindowID: windowID),
            .browserOpenLocation
        )
        XCTAssertEqual(
            interceptor.shortcutAction(for: reloadEvent, appOwnedWindowID: windowID),
            .browserReload
        )
        XCTAssertNil(interceptor.shortcutAction(for: openLocationEvent, appOwnedWindowID: nil))
        XCTAssertNil(interceptor.shortcutAction(for: reloadEvent, appOwnedWindowID: nil))
    }

    func testBrowserCreationShortcutsRequireAppOwnedWindowSelection() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let interceptor = makeInterceptor(store: store)
        let newBrowserEvent = try makeKeyEvent(characters: "b", modifiers: [.command, .control], keyCode: 0x0B)
        let newBrowserTabEvent = try makeKeyEvent(
            characters: "B",
            modifiers: [.command, .control, .shift],
            keyCode: 0x0B
        )

        XCTAssertEqual(
            interceptor.shortcutAction(for: newBrowserEvent, appOwnedWindowID: windowID),
            .createBrowser
        )
        XCTAssertEqual(
            interceptor.shortcutAction(for: newBrowserTabEvent, appOwnedWindowID: windowID),
            .createBrowserTab
        )
        XCTAssertNil(interceptor.shortcutAction(for: newBrowserEvent, appOwnedWindowID: nil))
        XCTAssertNil(interceptor.shortcutAction(for: newBrowserTabEvent, appOwnedWindowID: nil))
    }

    func testCreateBrowserActionUsesRequestedPlacement() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        let interceptor = makeInterceptor(store: store)

        XCTAssertTrue(interceptor.handle(.createBrowser, appOwnedWindowID: windowID))
        let workspaceAfterBrowser = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspaceAfterBrowser.layoutTree.allSlotInfos.count, 2)
        XCTAssertEqual(workspaceAfterBrowser.orderedTabs.count, 1)
        guard case .web = workspaceAfterBrowser.panels[try XCTUnwrap(workspaceAfterBrowser.focusedPanelID)] else {
            XCTFail("expected createBrowser shortcut to focus a browser panel in the current tab")
            return
        }

        XCTAssertTrue(interceptor.handle(.createBrowserTab, appOwnedWindowID: windowID))
        let workspaceAfterBrowserTab = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspaceAfterBrowserTab.orderedTabs.count, 2)
    }

    func testFocusSplitActionConsumesShortcutWhenWorkspaceWindowResolves() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let originalFocusedPanelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let interceptor = makeInterceptor(store: store)

        XCTAssertTrue(interceptor.handle(.focusSplit(.previous), appOwnedWindowID: windowID))
        XCTAssertEqual(store.selectedWorkspace?.focusedPanelID, originalFocusedPanelID)
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

    func testClosePanelShortcutWindowIDAllowsTerminalHostViewResponder() {
        let windowID = UUID()
        let window = ShortcutTestWindow()
        window.identifier = NSUserInterfaceItemIdentifier(windowID.uuidString)
        window.forcedFirstResponder = TerminalHostView()

        XCTAssertEqual(
            DisplayShortcutInterceptor.closePanelShortcutWindowID(
                keyWindow: window,
                modalWindow: nil
            ),
            windowID
        )
    }

    func testClosePanelShortcutWindowIDAllowsWebKitHostedTextInputResponder() {
        let windowID = UUID()
        let window = ShortcutTestWindow()
        window.identifier = NSUserInterfaceItemIdentifier(windowID.uuidString)

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        webView.addSubview(textView)
        window.contentView = webView
        window.forcedFirstResponder = textView

        XCTAssertEqual(
            DisplayShortcutInterceptor.closePanelShortcutWindowID(
                keyWindow: window,
                modalWindow: nil
            ),
            windowID
        )
    }

    func testClosePanelShortcutWindowIDAllowsBrowserChromeTextFieldResponder() {
        let windowID = UUID()
        let window = ShortcutTestWindow()
        window.identifier = NSUserInterfaceItemIdentifier(windowID.uuidString)
        window.forcedFirstResponder = BrowserChromeTextField()

        XCTAssertEqual(
            DisplayShortcutInterceptor.closePanelShortcutWindowID(
                keyWindow: window,
                modalWindow: nil
            ),
            windowID
        )
    }

    func testClosePanelShortcutWindowIDAllowsBrowserChromeFieldEditorResponder() throws {
        let windowID = UUID()
        let window = ShortcutTestWindow()
        window.identifier = NSUserInterfaceItemIdentifier(windowID.uuidString)
        let textField = BrowserChromeTextField()
        let fieldEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        fieldEditor.delegate = textField
        window.forcedFirstResponder = fieldEditor

        let resolvedWindowID = DisplayShortcutInterceptor.closePanelShortcutWindowID(
            keyWindow: window,
            modalWindow: nil
        )
        XCTAssertEqual(resolvedWindowID, windowID)

        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let interceptor = makeInterceptor(store: store)
        let focusPreviousEvent = try makeKeyEvent(characters: "[", modifiers: [.command], keyCode: 0x21)
        let closeEvent = try makeKeyEvent(characters: "w", modifiers: [.command], keyCode: 0x0D)

        XCTAssertEqual(
            interceptor.shortcutAction(for: focusPreviousEvent, appOwnedWindowID: resolvedWindowID),
            .focusSplit(.previous)
        )
        XCTAssertEqual(
            interceptor.shortcutAction(for: closeEvent, appOwnedWindowID: resolvedWindowID),
            .closePanel
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

@MainActor
private func makeInterceptor(store: AppStore) -> DisplayShortcutInterceptor {
    let terminalRuntimeRegistry = TerminalRuntimeRegistry()
    terminalRuntimeRegistry.bind(store: store)
    let webPanelRuntimeRegistry = WebPanelRuntimeRegistry()
    webPanelRuntimeRegistry.bind(store: store)
    let sessionRuntimeStore = SessionRuntimeStore()
    sessionRuntimeStore.bind(store: store)
    let focusedPanelCommandController = FocusedPanelCommandController(
        store: store,
        runtimeRegistry: terminalRuntimeRegistry,
        slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
    )
    return DisplayShortcutInterceptor(
        store: store,
        terminalRuntimeRegistry: terminalRuntimeRegistry,
        webPanelRuntimeRegistry: webPanelRuntimeRegistry,
        sessionRuntimeStore: sessionRuntimeStore,
        focusedPanelCommandController: focusedPanelCommandController,
        installEventMonitor: false
    )
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
