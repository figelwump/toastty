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
        XCTAssertTrue(layout.showsTitle)
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
        XCTAssertTrue(layout.showsTitle)
    }

    func testTightModeHidesMatchLabelAndPreservesMinimumFieldWidth() {
        let layout = PanelHeaderSearchLayout.resolve(
            availableWidth: 295,
            hasProfileBadge: true,
            showsIndicator: true
        )

        XCTAssertEqual(layout.mode, .tight)
        XCTAssertFalse(layout.showsProfileBadge)
        XCTAssertEqual(layout.fieldWidth, PanelHeaderSearchLayout.minimumFieldWidth)
        XCTAssertFalse(layout.showsMatchLabel)
        XCTAssertTrue(layout.showsTitle)
    }

    func testUltraTightWidthHidesTitleBeforeSearchOverflows() {
        let layout = PanelHeaderSearchLayout.resolve(
            availableWidth: 294,
            hasProfileBadge: true,
            showsIndicator: true
        )

        XCTAssertEqual(layout.mode, .compact)
        XCTAssertFalse(layout.showsProfileBadge)
        XCTAssertFalse(layout.showsTitle)
        XCTAssertGreaterThan(layout.fieldWidth, PanelHeaderSearchLayout.minimumFieldWidth)
        XCTAssertTrue(layout.showsMatchLabel)
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
        XCTAssertTrue(layout.showsTitle)
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
        XCTAssertTrue(layout.showsTitle)
    }
}
