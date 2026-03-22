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
            sessionStatusKind: nil
        )

        XCTAssertEqual(appearance.treatment, .focused)
        XCTAssertEqual(appearance.indicatorState, .hidden)
        XCTAssertFalse(appearance.showsTintedFill)
    }

    func testUnreadWithoutSessionStatusUsesBellTreatment() {
        let appearance = PanelHeaderAppearance.resolve(
            isFocused: false,
            hasUnreadNotification: true,
            sessionStatusKind: nil
        )

        XCTAssertEqual(appearance.treatment, .unread(.bell))
        XCTAssertEqual(appearance.indicatorState, .dot)
        XCTAssertTrue(appearance.showsTintedFill)
    }

    func testFocusedUnreadKeepsUnreadTreatmentDuringAutoReadWindow() {
        let appearance = PanelHeaderAppearance.resolve(
            isFocused: true,
            hasUnreadNotification: true,
            sessionStatusKind: nil
        )

        XCTAssertEqual(appearance.treatment, .unread(.bell))
        XCTAssertEqual(appearance.indicatorState, .dot)
        XCTAssertEqual(appearance.dividerHeight, 2)
    }

    func testUnreadNeedsApprovalUsesNeedsApprovalTreatment() {
        let appearance = PanelHeaderAppearance.resolve(
            isFocused: false,
            hasUnreadNotification: true,
            sessionStatusKind: .needsApproval
        )

        XCTAssertEqual(appearance.treatment, .unread(.needsApproval))
        XCTAssertEqual(appearance.indicatorState, .dot)
    }

    func testUnreadReadyUsesReadyTreatment() {
        let appearance = PanelHeaderAppearance.resolve(
            isFocused: false,
            hasUnreadNotification: true,
            sessionStatusKind: .ready
        )

        XCTAssertEqual(appearance.treatment, .unread(.ready))
        XCTAssertEqual(appearance.indicatorState, .dot)
    }

    func testUnreadReadyUsesGreenHeaderColors() throws {
        let treatment = PanelHeaderAppearance.resolve(
            isFocused: false,
            hasUnreadNotification: true,
            sessionStatusKind: .ready
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
            sessionStatusKind: .error
        )

        XCTAssertEqual(appearance.treatment, .unread(.error))
        XCTAssertEqual(appearance.indicatorState, .dot)
    }

    func testWorkingWithoutUnreadKeepsSpinnerOnNeutralHeader() {
        let appearance = PanelHeaderAppearance.resolve(
            isFocused: false,
            hasUnreadNotification: false,
            sessionStatusKind: .working
        )

        XCTAssertEqual(appearance.treatment, .neutral)
        XCTAssertEqual(appearance.indicatorState, .spinner)
        XCTAssertFalse(appearance.showsTintedFill)
    }
}
