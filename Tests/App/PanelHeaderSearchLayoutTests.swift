@testable import ToasttyApp
import XCTest

final class PanelHeaderSearchLayoutTests: XCTestCase {
    func testWideClusterShowsRegularChrome() {
        let chrome = PanelHeaderSearchLayout.resolveSearchChrome(
            availableWidth: .greatestFiniteMagnitude
        )

        XCTAssertEqual(chrome.fieldWidth, PanelHeaderSearchLayout.regularFieldWidth)
        XCTAssertTrue(chrome.showsMatchLabel)
        XCTAssertTrue(chrome.showsNavigationButtons)
    }

    func testMediumClusterHidesMatchLabelBeforeDroppingNavigationButtons() {
        let chrome = PanelHeaderSearchLayout.resolveSearchChrome(availableWidth: 240)

        XCTAssertEqual(chrome.fieldWidth, 181)
        XCTAssertFalse(chrome.showsMatchLabel)
        XCTAssertTrue(chrome.showsNavigationButtons)
    }

    func testNarrowClusterDropsNavigationButtonsBeforeSearchFieldCollapses() {
        let chrome = PanelHeaderSearchLayout.resolveSearchChrome(availableWidth: 180)

        XCTAssertEqual(chrome.fieldWidth, 159)
        XCTAssertFalse(chrome.showsMatchLabel)
        XCTAssertFalse(chrome.showsNavigationButtons)
    }

    func testMinimumSearchBarWidthKeepsCloseOnlyFieldReadable() {
        let chrome = PanelHeaderSearchLayout.resolveSearchChrome(
            availableWidth: PanelHeaderSearchLayout.minimumSearchBarWidth
        )

        XCTAssertEqual(chrome.fieldWidth, PanelHeaderSearchLayout.minimumCloseOnlyFieldWidth)
        XCTAssertFalse(chrome.showsMatchLabel)
        XCTAssertFalse(chrome.showsNavigationButtons)
    }

    func testUltraTightClusterUsesAllRemainingWidthForCloseOnlyField() {
        let chrome = PanelHeaderSearchLayout.resolveSearchChrome(availableWidth: 80)

        XCTAssertEqual(chrome.fieldWidth, 59)
        XCTAssertFalse(chrome.showsMatchLabel)
        XCTAssertFalse(chrome.showsNavigationButtons)
    }
}
