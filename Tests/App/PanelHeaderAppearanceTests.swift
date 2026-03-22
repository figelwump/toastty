@testable import ToasttyApp
import CoreState
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
