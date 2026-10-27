@testable import ToasttyApp
import AppKit
import CoreState
import SwiftUI
import XCTest

final class PanelHeaderAppearanceTests: XCTestCase {
    func testFocusedWithoutUnreadUsesFocusedTreatment() {
        let appearance = PanelHeaderAppearance.resolve(
            isFocused: true,
            hasUnreadNotification: false,
            sessionStatusKind: nil,
            isWaiting: false
        )

        XCTAssertEqual(appearance.treatment, .focused)
        XCTAssertEqual(appearance.indicatorState, .hidden)
        XCTAssertFalse(appearance.showsTintedFill)
    }

    func testUnreadWithoutSessionStatusUsesBellTreatment() {
        let appearance = PanelHeaderAppearance.resolve(
            isFocused: false,
            hasUnreadNotification: true,
            sessionStatusKind: nil,
            isWaiting: false
        )

        XCTAssertEqual(appearance.treatment, .unread(.bell))
        XCTAssertEqual(appearance.indicatorState, .dot)
        XCTAssertTrue(appearance.showsTintedFill)
    }

    func testFocusedUnreadKeepsUnreadTreatmentDuringAutoReadWindow() {
        let appearance = PanelHeaderAppearance.resolve(
            isFocused: true,
            hasUnreadNotification: true,
            sessionStatusKind: nil,
            isWaiting: false
        )

        XCTAssertEqual(appearance.treatment, .unread(.bell))
        XCTAssertEqual(appearance.indicatorState, .dot)
        XCTAssertEqual(appearance.dividerHeight, 2)
    }

    func testUnreadNeedsApprovalUsesNeedsApprovalTreatment() {
        let appearance = PanelHeaderAppearance.resolve(
            isFocused: false,
            hasUnreadNotification: true,
            sessionStatusKind: .needsApproval,
            isWaiting: false
        )

        XCTAssertEqual(appearance.treatment, .unread(.needsApproval))
        XCTAssertEqual(appearance.indicatorState, .dot)
    }

    func testUnreadReadyUsesReadyTreatment() {
        let appearance = PanelHeaderAppearance.resolve(
            isFocused: false,
            hasUnreadNotification: true,
            sessionStatusKind: .ready,
            isWaiting: false
        )

        XCTAssertEqual(appearance.treatment, .unread(.ready))
        XCTAssertEqual(appearance.indicatorState, .dot)
    }

    func testUnreadReadyUsesWarmTealHeaderColors() throws {
        let treatment = PanelHeaderAppearance.resolve(
            isFocused: false,
            hasUnreadNotification: true,
            sessionStatusKind: .ready,
            isWaiting: false
        ).treatment

        let backgroundColor = try XCTUnwrap(
            NSColor(ToastyTheme.panelHeaderBackgroundColor(for: treatment, appIsActive: true))
                .usingColorSpace(.deviceRGB)
        )
        let expectedBackground = try XCTUnwrap(
            NSColor(ToastyTheme.panelHeaderReadyBackground).usingColorSpace(.deviceRGB)
        )
        let dividerColor = try XCTUnwrap(
            NSColor(ToastyTheme.panelHeaderDividerColor(for: treatment, appIsActive: true))
                .usingColorSpace(.deviceRGB)
        )
        let expectedDivider = try XCTUnwrap(
            NSColor(ToastyTheme.panelHeaderReadyDivider.opacity(0.82)).usingColorSpace(.deviceRGB)
        )

        XCTAssertEqual(backgroundColor.redComponent, expectedBackground.redComponent, accuracy: 0.001)
        XCTAssertEqual(backgroundColor.greenComponent, expectedBackground.greenComponent, accuracy: 0.001)
        XCTAssertEqual(backgroundColor.blueComponent, expectedBackground.blueComponent, accuracy: 0.001)
        XCTAssertEqual(backgroundColor.alphaComponent, expectedBackground.alphaComponent, accuracy: 0.001)
        XCTAssertEqual(dividerColor.redComponent, expectedDivider.redComponent, accuracy: 0.001)
        XCTAssertEqual(dividerColor.greenComponent, expectedDivider.greenComponent, accuracy: 0.001)
        XCTAssertEqual(dividerColor.blueComponent, expectedDivider.blueComponent, accuracy: 0.001)
        XCTAssertEqual(dividerColor.alphaComponent, expectedDivider.alphaComponent, accuracy: 0.001)
    }

    func testUnreadErrorUsesErrorTreatment() {
        let appearance = PanelHeaderAppearance.resolve(
            isFocused: false,
            hasUnreadNotification: true,
            sessionStatusKind: .error,
            isWaiting: false
        )

        XCTAssertEqual(appearance.treatment, .unread(.error))
        XCTAssertEqual(appearance.indicatorState, .dot)
    }

    func testWorkingWithoutUnreadKeepsSpinnerOnNeutralHeader() {
        let appearance = PanelHeaderAppearance.resolve(
            isFocused: false,
            hasUnreadNotification: false,
            sessionStatusKind: .working,
            isWaiting: false
        )

        XCTAssertEqual(appearance.treatment, .neutral)
        XCTAssertEqual(appearance.indicatorState, .spinner)
        XCTAssertFalse(appearance.showsTintedFill)
    }

    func testWaitingDoesNotSpinAndPreservesUnreadTreatment() {
        for focused in [false, true] {
            let waiting = PanelHeaderAppearance.resolve(
                isFocused: focused, hasUnreadNotification: false, sessionStatusKind: .working,
                isWaiting: true
            )
            XCTAssertEqual(waiting.indicatorState, .hidden)
            XCTAssertEqual(waiting.treatment, focused ? .focused : .neutral)

            let unread = PanelHeaderAppearance.resolve(
                isFocused: focused, hasUnreadNotification: true, sessionStatusKind: .working,
                isWaiting: true
            )
            XCTAssertEqual(unread.indicatorState, .dot)
            XCTAssertEqual(unread.treatment, .unread(.bell))
        }
        let resuming = PanelHeaderAppearance.resolve(
            isFocused: false, hasUnreadNotification: false, sessionStatusKind: .working,
            isWaiting: false
        )
        XCTAssertEqual(resuming.indicatorState, .spinner)
    }
}
