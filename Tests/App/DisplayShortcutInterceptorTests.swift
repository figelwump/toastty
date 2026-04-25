import AppKit
import Carbon.HIToolbox
@testable import ToasttyApp
import CoreState
import WebKit
import XCTest

@MainActor
final class DisplayShortcutInterceptorTests: XCTestCase {
    func testCommandPaletteShortcutMatchesCommandShiftPOnly() throws {
        let matchingEvent = try makeKeyEvent(characters: "P", modifiers: [.command, .shift], keyCode: 0x23)
        let plainCommandEvent = try makeKeyEvent(characters: "p", modifiers: [.command], keyCode: 0x23)
        let repeatedEvent = try makeKeyEvent(
            characters: "P",
            modifiers: [.command, .shift],
            keyCode: 0x23,
            isARepeat: true
        )

        XCTAssertTrue(DisplayShortcutInterceptor.isCommandPaletteShortcut(matchingEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isCommandPaletteShortcut(plainCommandEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isCommandPaletteShortcut(repeatedEvent))
    }

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

    func testFindShortcutMatchesPlainCommandFOnly() throws {
        let matchingEvent = try makeKeyEvent(characters: "f", modifiers: [.command], keyCode: 0x03)
        let shiftedEvent = try makeKeyEvent(characters: "F", modifiers: [.command, .shift], keyCode: 0x03)
        let repeatedEvent = try makeKeyEvent(
            characters: "f",
            modifiers: [.command],
            keyCode: 0x03,
            isARepeat: true
        )

        XCTAssertTrue(DisplayShortcutInterceptor.isFindShortcut(matchingEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isFindShortcut(shiftedEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isFindShortcut(repeatedEvent))
    }

    func testFindNextShortcutMatchesPlainCommandGOnly() throws {
        let matchingEvent = try makeKeyEvent(characters: "g", modifiers: [.command], keyCode: 0x05)
        let shiftedEvent = try makeKeyEvent(characters: "G", modifiers: [.command, .shift], keyCode: 0x05)
        let repeatedEvent = try makeKeyEvent(
            characters: "g",
            modifiers: [.command],
            keyCode: 0x05,
            isARepeat: true
        )

        XCTAssertTrue(DisplayShortcutInterceptor.isFindNextShortcut(matchingEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isFindNextShortcut(shiftedEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isFindNextShortcut(repeatedEvent))
    }

    func testFindPreviousShortcutMatchesCommandShiftGOnly() throws {
        let matchingEvent = try makeKeyEvent(characters: "G", modifiers: [.command, .shift], keyCode: 0x05)
        let plainEvent = try makeKeyEvent(characters: "g", modifiers: [.command], keyCode: 0x05)
        let repeatedEvent = try makeKeyEvent(
            characters: "G",
            modifiers: [.command, .shift],
            keyCode: 0x05,
            isARepeat: true
        )

        XCTAssertTrue(DisplayShortcutInterceptor.isFindPreviousShortcut(matchingEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isFindPreviousShortcut(plainEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isFindPreviousShortcut(repeatedEvent))
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

    func testToggleLaterFlagShortcutMatchesCommandShiftLOnly() throws {
        let matchingEvent = try makeKeyEvent(characters: "L", modifiers: [.command, .shift], keyCode: 0x25)
        let plainCommandEvent = try makeKeyEvent(characters: "l", modifiers: [.command], keyCode: 0x25)
        let repeatedEvent = try makeKeyEvent(
            characters: "L",
            modifiers: [.command, .shift],
            keyCode: 0x25,
            isARepeat: true
        )

        XCTAssertTrue(DisplayShortcutInterceptor.isToggleLaterFlagShortcut(matchingEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isToggleLaterFlagShortcut(plainCommandEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isToggleLaterFlagShortcut(repeatedEvent))
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

    func testWatchRunningCommandShortcutMatchesCommandShiftMOnly() throws {
        let matchingEvent = try makeKeyEvent(characters: "M", modifiers: [.command, .shift], keyCode: 0x2E)
        let plainCommandEvent = try makeKeyEvent(characters: "m", modifiers: [.command], keyCode: 0x2E)
        let repeatedEvent = try makeKeyEvent(
            characters: "M",
            modifiers: [.command, .shift],
            keyCode: 0x2E,
            isARepeat: true
        )

        XCTAssertTrue(DisplayShortcutInterceptor.isWatchRunningCommandShortcut(matchingEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isWatchRunningCommandShortcut(plainCommandEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isWatchRunningCommandShortcut(repeatedEvent))
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

    func testDirectionalFocusSplitDirectionMatchesCommandOptionArrowsOnly() throws {
        let leftArrow = try makeKeyEvent(
            characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
            modifiers: [.command, .option, .numericPad],
            keyCode: 0x7B
        )
        let downArrow = try makeKeyEvent(
            characters: String(UnicodeScalar(NSDownArrowFunctionKey)!),
            modifiers: [.command, .option, .numericPad],
            keyCode: 0x7D
        )
        let plainLeftArrow = try makeKeyEvent(
            characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
            modifiers: [.option, .numericPad],
            keyCode: 0x7B
        )
        let shiftedLeftArrow = try makeKeyEvent(
            characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
            modifiers: [.command, .option, .shift, .numericPad],
            keyCode: 0x7B
        )
        let repeatedRightArrow = try makeKeyEvent(
            characters: String(UnicodeScalar(NSRightArrowFunctionKey)!),
            modifiers: [.command, .option, .numericPad],
            keyCode: 0x7C,
            isARepeat: true
        )

        XCTAssertEqual(DisplayShortcutInterceptor.directionalFocusSplitDirection(for: leftArrow), .left)
        XCTAssertEqual(DisplayShortcutInterceptor.directionalFocusSplitDirection(for: downArrow), .down)
        XCTAssertNil(DisplayShortcutInterceptor.directionalFocusSplitDirection(for: plainLeftArrow))
        XCTAssertNil(DisplayShortcutInterceptor.directionalFocusSplitDirection(for: shiftedLeftArrow))
        XCTAssertNil(DisplayShortcutInterceptor.directionalFocusSplitDirection(for: repeatedRightArrow))
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

    func testToggleRightPanelShortcutMatchesCommandOptionBOnly() throws {
        let matchingEvent = try makeKeyEvent(characters: "b", modifiers: [.command, .option], keyCode: 0x0B)
        let browserEvent = try makeKeyEvent(characters: "b", modifiers: [.command, .control], keyCode: 0x0B)
        let repeatedEvent = try makeKeyEvent(
            characters: "b",
            modifiers: [.command, .option],
            keyCode: 0x0B,
            isARepeat: true
        )

        XCTAssertTrue(DisplayShortcutInterceptor.isToggleRightPanelShortcut(matchingEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isToggleRightPanelShortcut(browserEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isToggleRightPanelShortcut(repeatedEvent))
    }

    func testSplitDirectionMatchesCommandDVariantsOnly() throws {
        let splitRightEvent = try makeKeyEvent(characters: "d", modifiers: [.command], keyCode: 0x02)
        let splitDownEvent = try makeKeyEvent(characters: "D", modifiers: [.command, .shift], keyCode: 0x02)
        let plainEvent = try makeKeyEvent(characters: "d", modifiers: [], keyCode: 0x02)
        let repeatedEvent = try makeKeyEvent(
            characters: "d",
            modifiers: [.command],
            keyCode: 0x02,
            isARepeat: true
        )

        XCTAssertEqual(DisplayShortcutInterceptor.splitDirection(for: splitRightEvent), .right)
        XCTAssertEqual(DisplayShortcutInterceptor.splitDirection(for: splitDownEvent), .down)
        XCTAssertNil(DisplayShortcutInterceptor.splitDirection(for: plainEvent))
        XCTAssertNil(DisplayShortcutInterceptor.splitDirection(for: repeatedEvent))
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

    func testSaveShortcutMatchesPlainCommandSOnly() throws {
        let matchingEvent = try makeKeyEvent(characters: "s", modifiers: [.command], keyCode: 0x01)
        let shiftedEvent = try makeKeyEvent(characters: "S", modifiers: [.command, .shift], keyCode: 0x01)
        let repeatedEvent = try makeKeyEvent(
            characters: "s",
            modifiers: [.command],
            keyCode: 0x01,
            isARepeat: true
        )

        XCTAssertTrue(DisplayShortcutInterceptor.isSaveShortcut(matchingEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isSaveShortcut(shiftedEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isSaveShortcut(repeatedEvent))
    }

    func testEnterEditShortcutMatchesPlainCommandEOnly() throws {
        let matchingEvent = try makeKeyEvent(characters: "e", modifiers: [.command], keyCode: UInt16(kVK_ANSI_E))
        let shiftedEvent = try makeKeyEvent(characters: "E", modifiers: [.command, .shift], keyCode: UInt16(kVK_ANSI_E))
        let repeatedEvent = try makeKeyEvent(
            characters: "e",
            modifiers: [.command],
            keyCode: UInt16(kVK_ANSI_E),
            isARepeat: true
        )

        XCTAssertTrue(DisplayShortcutInterceptor.isEnterEditShortcut(matchingEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isEnterEditShortcut(shiftedEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isEnterEditShortcut(repeatedEvent))
    }

    func testCancelEditShortcutMatchesBareEscapeOnly() throws {
        let matchingEvent = try makeKeyEvent(characters: "\u{1b}", modifiers: [], keyCode: UInt16(kVK_Escape))
        let modifiedEvent = try makeKeyEvent(
            characters: "\u{1b}",
            modifiers: [.shift],
            keyCode: UInt16(kVK_Escape)
        )
        let repeatedEvent = try makeKeyEvent(
            characters: "\u{1b}",
            modifiers: [],
            keyCode: UInt16(kVK_Escape),
            isARepeat: true
        )

        XCTAssertTrue(DisplayShortcutInterceptor.isCancelEditShortcut(matchingEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isCancelEditShortcut(modifiedEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isCancelEditShortcut(repeatedEvent))
    }

    func testTextSizeShortcutDirectionMatchesCommandScaleKeys() throws {
        let commandEqualEvent = try makeKeyEvent(characters: "=", modifiers: [.command], keyCode: 0x18)
        let commandPlusEvent = try makeKeyEvent(characters: "+", modifiers: [.command, .shift], keyCode: 0x18)
        let commandMinusEvent = try makeKeyEvent(characters: "-", modifiers: [.command], keyCode: 0x1B)
        let commandZeroEvent = try makeKeyEvent(characters: "0", modifiers: [.command], keyCode: 0x1D)
        let plainMinusEvent = try makeKeyEvent(characters: "-", modifiers: [], keyCode: 0x1B)

        XCTAssertEqual(DisplayShortcutInterceptor.textSizeShortcutDirection(for: commandEqualEvent), .increase)
        XCTAssertEqual(DisplayShortcutInterceptor.textSizeShortcutDirection(for: commandPlusEvent), .increase)
        XCTAssertEqual(DisplayShortcutInterceptor.textSizeShortcutDirection(for: commandMinusEvent), .decrease)
        XCTAssertEqual(DisplayShortcutInterceptor.textSizeShortcutDirection(for: commandZeroEvent), .reset)
        XCTAssertNil(DisplayShortcutInterceptor.textSizeShortcutDirection(for: plainMinusEvent))
    }

    func testResizeSplitDirectionMatchesCommandControlArrowsOnly() throws {
        let leftArrow = try makeKeyEvent(
            characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
            modifiers: [.command, .control, .numericPad],
            keyCode: 0x7B
        )
        let upArrow = try makeKeyEvent(
            characters: String(UnicodeScalar(NSUpArrowFunctionKey)!),
            modifiers: [.command, .control, .numericPad],
            keyCode: 0x7E
        )
        let plainLeftArrow = try makeKeyEvent(
            characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
            modifiers: [.control],
            keyCode: 0x7B
        )
        let shiftedLeftArrow = try makeKeyEvent(
            characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
            modifiers: [.command, .control, .shift, .numericPad],
            keyCode: 0x7B
        )
        let repeatedRightArrow = try makeKeyEvent(
            characters: String(UnicodeScalar(NSRightArrowFunctionKey)!),
            modifiers: [.command, .control, .numericPad],
            keyCode: 0x7C,
            isARepeat: true
        )

        XCTAssertEqual(DisplayShortcutInterceptor.resizeSplitDirection(for: leftArrow), .left)
        XCTAssertEqual(DisplayShortcutInterceptor.resizeSplitDirection(for: upArrow), .up)
        XCTAssertNil(DisplayShortcutInterceptor.resizeSplitDirection(for: plainLeftArrow))
        XCTAssertNil(DisplayShortcutInterceptor.resizeSplitDirection(for: shiftedLeftArrow))
        XCTAssertNil(DisplayShortcutInterceptor.resizeSplitDirection(for: repeatedRightArrow))
    }

    func testEqualizeSplitsShortcutMatchesCommandControlEqualsOnly() throws {
        let matchingEvent = try makeKeyEvent(characters: "=", modifiers: [.command, .control], keyCode: 0x18)
        let shiftedEvent = try makeKeyEvent(characters: "+", modifiers: [.command, .control, .shift], keyCode: 0x18)
        let repeatedEvent = try makeKeyEvent(
            characters: "=",
            modifiers: [.command, .control],
            keyCode: 0x18,
            isARepeat: true
        )

        XCTAssertTrue(DisplayShortcutInterceptor.isEqualizeSplitsShortcut(matchingEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isEqualizeSplitsShortcut(shiftedEvent))
        XCTAssertFalse(DisplayShortcutInterceptor.isEqualizeSplitsShortcut(repeatedEvent))
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

    func testCommandPaletteShortcutRequiresAppOwnedWindowUnlessPaletteIsAlreadyActive() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let paletteEvent = try makeKeyEvent(
            characters: "P",
            modifiers: [.command, .shift],
            keyCode: 0x23
        )
        let inactiveInterceptor = makeInterceptor(store: store)
        let activeInterceptor = makeInterceptor(
            store: store,
            isCommandPalettePresented: { true }
        )

        XCTAssertEqual(
            inactiveInterceptor.shortcutAction(for: paletteEvent, appOwnedWindowID: windowID),
            .commandPalette
        )
        XCTAssertNil(inactiveInterceptor.shortcutAction(for: paletteEvent, appOwnedWindowID: nil))
        XCTAssertEqual(
            activeInterceptor.shortcutAction(for: paletteEvent, appOwnedWindowID: nil),
            .commandPalette
        )
    }

    func testCommandPaletteActionDelegatesToggleWithOriginWindowID() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        var toggledWindowID: UUID?
        let interceptor = makeInterceptor(
            store: store,
            toggleCommandPalette: { originWindowID in
                toggledWindowID = originWindowID
                return true
            }
        )

        XCTAssertTrue(interceptor.handle(.commandPalette, appOwnedWindowID: windowID))
        XCTAssertEqual(toggledWindowID, windowID)
    }

    func testToggleLaterFlagShortcutRequiresAppOwnedWindowSelection() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let interceptor = makeInterceptor(store: store)
        let toggleLaterEvent = try makeKeyEvent(
            characters: "L",
            modifiers: [.command, .shift],
            keyCode: 0x25
        )

        XCTAssertEqual(
            interceptor.shortcutAction(for: toggleLaterEvent, appOwnedWindowID: windowID),
            .toggleLaterFlag
        )
        XCTAssertNil(interceptor.shortcutAction(for: toggleLaterEvent, appOwnedWindowID: nil))
    }

    func testToggleLaterFlagActionTogglesFocusedManagedSession() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)

        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        terminalRuntimeRegistry.bind(store: store)
        let webPanelRuntimeRegistry = WebPanelRuntimeRegistry()
        webPanelRuntimeRegistry.bind(store: store)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        sessionRuntimeStore.startSession(
            sessionID: "sess-later-shortcut",
            agent: .codex,
            panelID: panelID,
            windowID: windowID,
            workspaceID: workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: Date(timeIntervalSince1970: 1_700_000_400)
        )
        sessionRuntimeStore.updateStatus(
            sessionID: "sess-later-shortcut",
            status: SessionStatus(kind: .idle, summary: "Waiting", detail: "Revisit later"),
            at: Date(timeIntervalSince1970: 1_700_000_401)
        )

        let focusedPanelCommandController = FocusedPanelCommandController(
            store: store,
            runtimeRegistry: terminalRuntimeRegistry,
            slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
        )
        let interceptor = DisplayShortcutInterceptor(
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            webPanelRuntimeRegistry: webPanelRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            focusedPanelCommandController: focusedPanelCommandController,
            installEventMonitor: false
        )

        XCTAssertTrue(interceptor.handle(.toggleLaterFlag, appOwnedWindowID: windowID))
        XCTAssertTrue(sessionRuntimeStore.isLaterFlagged(sessionID: "sess-later-shortcut"))
        XCTAssertTrue(interceptor.handle(.toggleLaterFlag, appOwnedWindowID: windowID))
        XCTAssertFalse(sessionRuntimeStore.isLaterFlagged(sessionID: "sess-later-shortcut"))
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

    func testMarkdownSaveShortcutUsesFocusedMarkdownSelection() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("README.md")
        try "# Preview\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: windowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fileURL.path,
                    placementOverride: .splitRight
                )
            )
        )
        let interceptor = makeInterceptor(store: store)
        let saveEvent = try makeKeyEvent(characters: "s", modifiers: [.command], keyCode: 0x01)

        XCTAssertEqual(
            interceptor.shortcutAction(for: saveEvent, appOwnedWindowID: windowID),
            .saveLocalDocument
        )
        XCTAssertTrue(interceptor.handle(.saveLocalDocument, appOwnedWindowID: windowID))
        XCTAssertNil(interceptor.shortcutAction(for: saveEvent, appOwnedWindowID: nil))
    }

    func testLocalDocumentEnterEditShortcutRequiresPreviewMode() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("README.md")
        try "# Preview\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: windowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fileURL.path,
                    placementOverride: .splitRight
                )
            )
        )

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
        let interceptor = DisplayShortcutInterceptor(
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            webPanelRuntimeRegistry: webPanelRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            focusedPanelCommandController: focusedPanelCommandController,
            installEventMonitor: false
        )

        let selection = try XCTUnwrap(store.focusedLocalDocumentPanelSelection(preferredWindowID: windowID))
        let workspace = try XCTUnwrap(store.state.workspacesByID[selection.workspaceID])
        guard case .web(let webState) = workspace.panels[selection.panelID] else {
            XCTFail("expected focused local-document panel")
            return
        }

        let runtime = webPanelRuntimeRegistry.localDocumentRuntime(for: selection.panelID)
        runtime.apply(webState: webState)
        try await waitUntil { runtime.automationState().currentBootstrap != nil }

        let editEvent = try makeKeyEvent(characters: "e", modifiers: [.command], keyCode: UInt16(kVK_ANSI_E))

        XCTAssertEqual(
            interceptor.shortcutAction(for: editEvent, appOwnedWindowID: windowID),
            .enterLocalDocumentEdit
        )
        XCTAssertTrue(interceptor.handle(.enterLocalDocumentEdit, appOwnedWindowID: windowID))
        XCTAssertNil(interceptor.shortcutAction(for: editEvent, appOwnedWindowID: nil))

        let bootstrap = try XCTUnwrap(runtime.automationState().currentBootstrap)
        XCTAssertTrue(bootstrap.isEditing)
        XCTAssertNil(interceptor.shortcutAction(for: editEvent, appOwnedWindowID: windowID))
    }

    func testLocalDocumentFindShortcutsTargetFocusedPanelAndActiveSearch() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("README.md")
        try "# Toastty\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: windowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fileURL.path,
                    placementOverride: .splitRight
                )
            )
        )

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
        let interceptor = DisplayShortcutInterceptor(
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            webPanelRuntimeRegistry: webPanelRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            focusedPanelCommandController: focusedPanelCommandController,
            installEventMonitor: false
        )

        let selection = try XCTUnwrap(store.focusedLocalDocumentPanelSelection(preferredWindowID: windowID))
        let workspace = try XCTUnwrap(store.state.workspacesByID[selection.workspaceID])
        guard case .web(let webState) = workspace.panels[selection.panelID] else {
            XCTFail("expected focused local-document panel")
            return
        }

        let runtime = webPanelRuntimeRegistry.localDocumentRuntime(for: selection.panelID)
        runtime.apply(webState: webState)
        try await waitUntil { runtime.automationState().currentBootstrap != nil }

        let findEvent = try makeKeyEvent(characters: "f", modifiers: [.command], keyCode: 0x03)
        let findNextEvent = try makeKeyEvent(characters: "g", modifiers: [.command], keyCode: 0x05)
        let findPreviousEvent = try makeKeyEvent(characters: "G", modifiers: [.command, .shift], keyCode: 0x05)

        XCTAssertEqual(
            interceptor.shortcutAction(for: findEvent, appOwnedWindowID: windowID),
            .startLocalDocumentSearch
        )
        XCTAssertNil(interceptor.shortcutAction(for: findNextEvent, appOwnedWindowID: windowID))
        XCTAssertNil(interceptor.shortcutAction(for: findPreviousEvent, appOwnedWindowID: windowID))

        XCTAssertTrue(interceptor.handle(.startLocalDocumentSearch, appOwnedWindowID: windowID))
        runtime.updateSearchQuery("toastty")

        XCTAssertEqual(
            interceptor.shortcutAction(for: findNextEvent, appOwnedWindowID: windowID),
            .findNextLocalDocumentSearch
        )
        XCTAssertEqual(
            interceptor.shortcutAction(for: findPreviousEvent, appOwnedWindowID: windowID),
            .findPreviousLocalDocumentSearch
        )
        XCTAssertNil(interceptor.shortcutAction(for: findEvent, appOwnedWindowID: nil))
    }

    func testTextSizeShortcutTargetsFocusedTerminalMarkdownAndBrowser() throws {
        let increaseEvent = try makeKeyEvent(characters: "=", modifiers: [.command], keyCode: 0x18)

        let terminalStore = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let terminalWindowID = try XCTUnwrap(terminalStore.state.windows.first?.id)
        let terminalInterceptor = makeInterceptor(store: terminalStore)
        XCTAssertEqual(
            terminalInterceptor.shortcutAction(for: increaseEvent, appOwnedWindowID: terminalWindowID),
            .increaseTextSize
        )

        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("README.md")
        try "# Preview\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let markdownStore = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let markdownWindowID = try XCTUnwrap(markdownStore.state.windows.first?.id)
        XCTAssertTrue(
            markdownStore.createLocalDocumentPanelFromCommand(
                preferredWindowID: markdownWindowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fileURL.path,
                    placementOverride: .splitRight
                )
            )
        )
        let markdownInterceptor = makeInterceptor(store: markdownStore)
        XCTAssertEqual(
            markdownInterceptor.shortcutAction(for: increaseEvent, appOwnedWindowID: markdownWindowID),
            .increaseTextSize
        )

        let browserStore = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let browserWindowID = try XCTUnwrap(browserStore.state.windows.first?.id)
        XCTAssertTrue(
            browserStore.createBrowserPanelFromCommand(
                preferredWindowID: browserWindowID,
                request: BrowserPanelCreateRequest(
                    initialURL: "https://example.com",
                    placementOverride: .splitRight
                )
            )
        )
        let browserInterceptor = makeInterceptor(store: browserStore)
        XCTAssertEqual(
            browserInterceptor.shortcutAction(for: increaseEvent, appOwnedWindowID: browserWindowID),
            .increaseTextSize
        )
    }

    func testLocalDocumentCancelEditShortcutRequiresActiveEditMode() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("README.md")
        try "# Preview\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: windowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fileURL.path,
                    placementOverride: .splitRight
                )
            )
        )

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
        let interceptor = DisplayShortcutInterceptor(
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            webPanelRuntimeRegistry: webPanelRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            focusedPanelCommandController: focusedPanelCommandController,
            installEventMonitor: false
        )

        let selection = try XCTUnwrap(store.focusedLocalDocumentPanelSelection(preferredWindowID: windowID))
        let workspace = try XCTUnwrap(store.state.workspacesByID[selection.workspaceID])
        guard case .web(let webState) = workspace.panels[selection.panelID] else {
            XCTFail("expected focused local-document panel")
            return
        }

        let runtime = webPanelRuntimeRegistry.localDocumentRuntime(for: selection.panelID)
        runtime.apply(webState: webState)
        try await waitUntil { runtime.automationState().currentBootstrap != nil }

        let escapeEvent = try makeKeyEvent(characters: "\u{1b}", modifiers: [], keyCode: UInt16(kVK_Escape))

        XCTAssertNil(interceptor.shortcutAction(for: escapeEvent, appOwnedWindowID: windowID))

        runtime.enterEditMode()
        let baseRevision = try XCTUnwrap(runtime.automationState().currentBootstrap?.contentRevision)
        runtime.updateDraftContent("# Changed\n", baseContentRevision: baseRevision)

        XCTAssertEqual(
            interceptor.shortcutAction(for: escapeEvent, appOwnedWindowID: windowID),
            .cancelLocalDocumentEdit
        )
        XCTAssertTrue(interceptor.handle(.cancelLocalDocumentEdit, appOwnedWindowID: windowID))

        let bootstrap = try XCTUnwrap(runtime.automationState().currentBootstrap)
        XCTAssertFalse(bootstrap.isEditing)
        XCTAssertFalse(bootstrap.isDirty)
        XCTAssertEqual(bootstrap.content, "# Preview\n")
    }

    func testTextSizeShortcutHandleAdjustsFocusedMarkdownScale() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("README.md")
        try "# Preview\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: windowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fileURL.path,
                    placementOverride: .splitRight
                )
            )
        )

        let interceptor = makeInterceptor(store: store)

        XCTAssertTrue(interceptor.handle(.increaseTextSize, appOwnedWindowID: windowID))
        XCTAssertEqual(store.state.effectiveMarkdownTextScale(for: windowID), 1.1, accuracy: 0.0001)
        XCTAssertEqual(store.state.effectiveTerminalFontPoints(for: windowID), AppState.defaultTerminalFontPoints)
    }

    func testTextSizeShortcutHandleAdjustsFocusedBrowserZoom() throws {
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
        let browserSelection = try XCTUnwrap(store.focusedBrowserPanelSelection(preferredWindowID: windowID))
        let interceptor = makeInterceptor(store: store)

        XCTAssertTrue(interceptor.handle(.increaseTextSize, appOwnedWindowID: windowID))

        let workspace = try XCTUnwrap(store.state.workspacesByID[browserSelection.workspaceID])
        guard case .web(let webState) = workspace.panels[browserSelection.panelID] else {
            XCTFail("expected focused browser panel")
            return
        }
        XCTAssertEqual(webState.effectiveBrowserPageZoom, 1.1, accuracy: 0.0001)
        XCTAssertEqual(store.state.effectiveTerminalFontPoints(for: windowID), AppState.defaultTerminalFontPoints)
    }

    func testMarkdownSplitShortcutsCreateTerminalPanelsInFocusedWorkspace() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let fileURL = tempDirectoryURL.appendingPathComponent("README.md")
        try "# Preview\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let scenarios: [(NSEvent, DisplayShortcutInterceptor.ShortcutAction)] = [
            (
                try makeKeyEvent(characters: "d", modifiers: [.command], keyCode: 0x02),
                .split(.right)
            ),
            (
                try makeKeyEvent(characters: "D", modifiers: [.command, .shift], keyCode: 0x02),
                .split(.down)
            ),
        ]

        for (event, expectedAction) in scenarios {
            let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
            let windowID = try XCTUnwrap(store.state.windows.first?.id)
            let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
            XCTAssertTrue(
                store.createLocalDocumentPanelFromCommand(
                    preferredWindowID: windowID,
                    request: LocalDocumentPanelCreateRequest(
                        filePath: fileURL.path,
                        placementOverride: .splitRight
                    )
                )
            )

            let interceptor = makeInterceptor(store: store)
            let workspaceBeforeSplit = try XCTUnwrap(store.state.workspacesByID[workspaceID])

            XCTAssertEqual(
                interceptor.shortcutAction(for: event, appOwnedWindowID: windowID),
                expectedAction
            )
            XCTAssertTrue(interceptor.handle(expectedAction, appOwnedWindowID: windowID))

            let workspaceAfterSplit = try XCTUnwrap(store.state.workspacesByID[workspaceID])
            XCTAssertEqual(workspaceAfterSplit.panels.count, workspaceBeforeSplit.panels.count + 1)
            XCTAssertEqual(workspaceAfterSplit.orderedTabs.count, workspaceBeforeSplit.orderedTabs.count)

            let focusedPanelID = try XCTUnwrap(workspaceAfterSplit.focusedPanelID)
            guard case .terminal = workspaceAfterSplit.panels[focusedPanelID] else {
                XCTFail("expected markdown split shortcut to focus a new terminal panel")
                continue
            }
        }
    }

    func testCreateBrowserActionUsesRequestedPlacement() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        let interceptor = makeInterceptor(store: store)

        XCTAssertTrue(interceptor.handle(.createBrowser, appOwnedWindowID: windowID))
        let workspaceAfterBrowser = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspaceAfterBrowser.layoutTree.allSlotInfos.count, 1)
        XCTAssertEqual(workspaceAfterBrowser.orderedTabs.count, 1)
        let rightPanelTab = try XCTUnwrap(workspaceAfterBrowser.rightAuxPanel.activeTab)
        guard case .web = rightPanelTab.panelState else {
            XCTFail("expected createBrowser shortcut to create a browser panel in the right panel")
            return
        }

        XCTAssertTrue(interceptor.handle(.createBrowserTab, appOwnedWindowID: windowID))
        let workspaceAfterBrowserTab = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspaceAfterBrowserTab.orderedTabs.count, 2)
    }

    func testToggleRightPanelActionTogglesSelectedWorkspacePanel() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        let event = try makeKeyEvent(characters: "b", modifiers: [.command, .option], keyCode: 0x0B)
        let interceptor = makeInterceptor(store: store)

        XCTAssertTrue(interceptor.handle(.createBrowser, appOwnedWindowID: windowID))
        XCTAssertEqual(interceptor.shortcutAction(for: event, appOwnedWindowID: windowID), .toggleRightPanel)

        XCTAssertTrue(interceptor.handle(.toggleRightPanel, appOwnedWindowID: windowID))
        XCTAssertFalse(try XCTUnwrap(store.state.workspacesByID[workspaceID]).rightAuxPanel.isVisible)

        XCTAssertTrue(interceptor.handle(.toggleRightPanel, appOwnedWindowID: windowID))
        XCTAssertTrue(try XCTUnwrap(store.state.workspacesByID[workspaceID]).rightAuxPanel.isVisible)
    }

    func testToggleRightPanelActionCanOpenEmptyPanelShell() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        let interceptor = makeInterceptor(store: store)

        XCTAssertTrue(interceptor.handle(.toggleRightPanel, appOwnedWindowID: windowID))

        let workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertTrue(workspace.rightAuxPanel.isVisible)
        XCTAssertTrue(workspace.rightAuxPanel.tabIDs.isEmpty)
    }

    func testClosePanelActionPrefersFocusedRightPanelTab() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        let interceptor = makeInterceptor(store: store)

        XCTAssertTrue(interceptor.handle(.createBrowser, appOwnedWindowID: windowID))
        let workspaceAfterBrowser = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let tab = try XCTUnwrap(workspaceAfterBrowser.rightAuxPanel.activeTab)
        let mainFocusedPanelID = workspaceAfterBrowser.focusedPanelID
        XCTAssertTrue(store.send(.focusRightAuxPanel(workspaceID: workspaceID, panelID: tab.panelID)))

        XCTAssertTrue(interceptor.handle(.closePanel, appOwnedWindowID: windowID))

        let workspaceAfterClose = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertTrue(workspaceAfterClose.rightAuxPanel.tabIDs.isEmpty)
        XCTAssertTrue(workspaceAfterClose.rightAuxPanel.isVisible)
        XCTAssertEqual(workspaceAfterClose.focusedPanelID, mainFocusedPanelID)
        XCTAssertEqual(workspaceAfterClose.layoutTree.allSlotInfos.count, 1)
    }

    func testFocusSplitActionConsumesShortcutWhenWorkspaceWindowResolves() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let originalFocusedPanelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let interceptor = makeInterceptor(store: store)

        XCTAssertTrue(interceptor.handle(.focusSplit(.previous), appOwnedWindowID: windowID))
        XCTAssertEqual(store.selectedWorkspace?.focusedPanelID, originalFocusedPanelID)
    }

    func testBrowserFocusedDirectionalFocusShortcutUsesAppOwnedActionAndMovesFocus() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
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
        let leftArrowEvent = try makeKeyEvent(
            characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
            modifiers: [.command, .option, .numericPad],
            keyCode: 0x7B
        )
        let workspaceBeforeFocus = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let browserPanelID = try XCTUnwrap(workspaceBeforeFocus.focusedPanelID)

        XCTAssertEqual(
            interceptor.shortcutAction(for: leftArrowEvent, appOwnedWindowID: windowID),
            .focusSplit(.left)
        )
        XCTAssertTrue(interceptor.handle(.focusSplit(.left), appOwnedWindowID: windowID))

        let workspaceAfterFocus = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertNotEqual(workspaceAfterFocus.focusedPanelID, browserPanelID)
    }

    func testBrowserFocusedDirectionalFocusShortcutStillConsumesNoOpDirection() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
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
        let workspaceBeforeFocus = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let browserPanelID = try XCTUnwrap(workspaceBeforeFocus.focusedPanelID)
        let upArrowEvent = try makeKeyEvent(
            characters: String(UnicodeScalar(NSUpArrowFunctionKey)!),
            modifiers: [.command, .option, .numericPad],
            keyCode: 0x7E
        )

        XCTAssertEqual(
            interceptor.shortcutAction(for: upArrowEvent, appOwnedWindowID: windowID),
            .focusSplit(.up)
        )
        XCTAssertTrue(interceptor.handle(.focusSplit(.up), appOwnedWindowID: windowID))

        let workspaceAfterFocus = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspaceAfterFocus.focusedPanelID, browserPanelID)
    }

    func testBrowserFocusedResizeShortcutPreservesBrowserFocusAndAdjustsLayout() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
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
        let workspaceBeforeResize = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let browserPanelID = try XCTUnwrap(workspaceBeforeResize.focusedPanelID)
        let initialRatio = try XCTUnwrap(rootSplitRatio(in: workspaceBeforeResize))
        let leftArrowEvent = try makeKeyEvent(
            characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
            modifiers: [.command, .control, .numericPad],
            keyCode: 0x7B
        )

        XCTAssertEqual(
            interceptor.shortcutAction(for: leftArrowEvent, appOwnedWindowID: windowID),
            .resizeSplit(.left)
        )

        XCTAssertTrue(interceptor.handle(.resizeSplit(.left), appOwnedWindowID: windowID))

        let workspaceAfterResize = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspaceAfterResize.focusedPanelID, browserPanelID)
        XCTAssertNotEqual(try XCTUnwrap(rootSplitRatio(in: workspaceAfterResize)), initialRatio)
    }

    func testBrowserFocusedEqualizeShortcutPreservesBrowserFocusAndResetsLayoutRatio() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
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
        let browserPanelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)

        XCTAssertTrue(interceptor.handle(.resizeSplit(.left), appOwnedWindowID: windowID))
        XCTAssertTrue(interceptor.handle(.equalizeSplits, appOwnedWindowID: windowID))

        let workspaceAfterEqualize = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspaceAfterEqualize.focusedPanelID, browserPanelID)
        XCTAssertEqual(try XCTUnwrap(rootSplitRatio(in: workspaceAfterEqualize)), 0.5, accuracy: 0.0001)
    }

    func testBrowserFocusedResizeShortcutStillConsumesNoOpDirection() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
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
        let workspaceBeforeResize = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let browserPanelID = try XCTUnwrap(workspaceBeforeResize.focusedPanelID)
        let initialRatio = try XCTUnwrap(rootSplitRatio(in: workspaceBeforeResize))

        XCTAssertTrue(interceptor.handle(.resizeSplit(.up), appOwnedWindowID: windowID))

        let workspaceAfterResize = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspaceAfterResize.focusedPanelID, browserPanelID)
        XCTAssertEqual(try XCTUnwrap(rootSplitRatio(in: workspaceAfterResize)), initialRatio, accuracy: 0.0001)
    }

    func testBrowserFocusedEqualizeShortcutStillConsumesAlreadyEqualLayout() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
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
        let workspaceBeforeEqualize = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let browserPanelID = try XCTUnwrap(workspaceBeforeEqualize.focusedPanelID)
        let initialRatio = try XCTUnwrap(rootSplitRatio(in: workspaceBeforeEqualize))
        XCTAssertEqual(initialRatio, 0.5, accuracy: 0.0001)

        XCTAssertTrue(interceptor.handle(.equalizeSplits, appOwnedWindowID: windowID))

        let workspaceAfterEqualize = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspaceAfterEqualize.focusedPanelID, browserPanelID)
        XCTAssertEqual(try XCTUnwrap(rootSplitRatio(in: workspaceAfterEqualize)), initialRatio, accuracy: 0.0001)
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

    func testClosePanelShortcutWindowIDAllowsLocalDocumentSearchFieldEditorResponder() throws {
        let windowID = UUID()
        let window = ShortcutTestWindow()
        window.identifier = NSUserInterfaceItemIdentifier(windowID.uuidString)
        let textField = LocalDocumentSearchTextField()
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

private func rootSplitRatio(in workspace: WorkspaceState) -> Double? {
    guard case .split(_, _, let ratio, _, _) = workspace.layoutTree else {
        return nil
    }
    return ratio
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    pollNanoseconds: UInt64 = 10_000_000,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ predicate: @escaping @MainActor () -> Bool
) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while await predicate() == false {
        if DispatchTime.now().uptimeNanoseconds >= deadline {
            XCTFail("Timed out waiting for condition", file: file, line: line)
            return
        }
        try await Task.sleep(nanoseconds: pollNanoseconds)
    }
}

@MainActor
private func makeInterceptor(
    store: AppStore,
    promptStateResolver: ((UUID) -> TerminalPromptState)? = nil,
    isCommandPalettePresented: @escaping @MainActor () -> Bool = { false },
    toggleCommandPalette: @escaping @MainActor (UUID?) -> Bool = { _ in false }
) -> DisplayShortcutInterceptor {
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
    let processWatchCommandController = ProcessWatchCommandController(
        store: store,
        terminalRuntimeRegistry: terminalRuntimeRegistry,
        sessionRuntimeStore: sessionRuntimeStore,
        promptStateResolver: promptStateResolver
    )
    return DisplayShortcutInterceptor(
        store: store,
        terminalRuntimeRegistry: terminalRuntimeRegistry,
        webPanelRuntimeRegistry: webPanelRuntimeRegistry,
        sessionRuntimeStore: sessionRuntimeStore,
        focusedPanelCommandController: focusedPanelCommandController,
        processWatchCommandController: processWatchCommandController,
        isCommandPalettePresented: isCommandPalettePresented,
        toggleCommandPalette: toggleCommandPalette,
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
