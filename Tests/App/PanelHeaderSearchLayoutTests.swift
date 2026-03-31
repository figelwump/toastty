@testable import ToasttyApp
import XCTest

final class PanelHeaderSearchLayoutTests: XCTestCase {
    func testRegularModeKeepsProfileBadgeWhenHeaderIsWide() {
        let layout = PanelHeaderSearchLayout.resolve(
            availableWidth: 520,
            hasProfileBadge: true,
            showsIndicator: true
        )

        XCTAssertEqual(layout.mode, .regular)
        XCTAssertEqual(layout.fieldWidth, PanelHeaderSearchLayout.regularFieldWidth)
        XCTAssertTrue(layout.showsProfileBadge)
        XCTAssertTrue(layout.showsMatchLabel)
    }

    func testCompactModeDropsProfileBadgeBeforeShrinkingBelowRegularFieldWidth() {
        let layout = PanelHeaderSearchLayout.resolve(
            availableWidth: 360,
            hasProfileBadge: true,
            showsIndicator: true
        )

        XCTAssertEqual(layout.mode, .compact)
        XCTAssertFalse(layout.showsProfileBadge)
        XCTAssertGreaterThanOrEqual(layout.fieldWidth, PanelHeaderSearchLayout.matchLabelWidthThreshold)
        XCTAssertLessThan(layout.fieldWidth, PanelHeaderSearchLayout.regularFieldWidth)
        XCTAssertTrue(layout.showsMatchLabel)
    }

    func testTightModeHidesMatchLabelAndPreservesMinimumFieldWidth() {
        let layout = PanelHeaderSearchLayout.resolve(
            availableWidth: 292,
            hasProfileBadge: true,
            showsIndicator: true
        )

        XCTAssertEqual(layout.mode, .tight)
        XCTAssertFalse(layout.showsProfileBadge)
        XCTAssertEqual(layout.fieldWidth, PanelHeaderSearchLayout.minimumFieldWidth)
        XCTAssertFalse(layout.showsMatchLabel)
    }

    func testRegularModeStillAppliesWithoutProfileBadge() {
        let layout = PanelHeaderSearchLayout.resolve(
            availableWidth: 420,
            hasProfileBadge: false,
            showsIndicator: false
        )

        XCTAssertEqual(layout.mode, .regular)
        XCTAssertEqual(layout.fieldWidth, PanelHeaderSearchLayout.regularFieldWidth)
        XCTAssertFalse(layout.showsProfileBadge)
    }

    func testSentinelWidthResolvesToRegularLayout() {
        let layout = PanelHeaderSearchLayout.resolve(
            availableWidth: .greatestFiniteMagnitude,
            hasProfileBadge: true,
            showsIndicator: true
        )

        XCTAssertEqual(layout.mode, .regular)
        XCTAssertEqual(layout.fieldWidth, PanelHeaderSearchLayout.regularFieldWidth)
        XCTAssertTrue(layout.showsProfileBadge)
        XCTAssertTrue(layout.showsMatchLabel)
    }
}
