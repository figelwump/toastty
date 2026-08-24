import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

final class ToasttySessionStatusPresentationTests: XCTestCase {
    func testLiveWorkingStatusKeepsCurrentLabelAndSpinner() {
        let presentation = ToasttySessionStatusPresentation(
            bucket: .working,
            freshness: .live
        )

        XCTAssertEqual(presentation.label, "working")
        XCTAssertEqual(presentation.accessibilityLabel, "working")
        XCTAssertTrue(presentation.showsWorkingSpinner)
    }

    func testEveryNonliveFreshnessMakesActiveStatusesStaticAndLastSeen() {
        let freshnesses: [LiveProjectionFreshness] = [
            .connecting,
            .reconnecting,
            .stale,
            .unreachable,
        ]

        for freshness in freshnesses {
            for bucket in MobileSessionBucket.allCases where bucket.isVisible {
                let presentation = ToasttySessionStatusPresentation(
                    bucket: bucket,
                    freshness: freshness
                )

                XCTAssertEqual(presentation.label, "last seen \(bucket.rawValue)")
                XCTAssertEqual(
                    presentation.accessibilityLabel,
                    "Last seen \(bucket.rawValue). Updates paused."
                )
                XCTAssertFalse(presentation.showsWorkingSpinner)
            }
        }
    }

    func testIdleStatusRemainsHidden() {
        for freshness in [LiveProjectionFreshness.live, .unreachable] {
            let presentation = ToasttySessionStatusPresentation(
                bucket: .idle,
                freshness: freshness
            )

            XCTAssertFalse(presentation.isVisible)
            XCTAssertFalse(presentation.showsWorkingSpinner)
        }
    }

    func testAccessibilitySummaryUsesLastSeenStatusWhenProjectionIsStale() throws {
        let conversation = try XCTUnwrap(
            ToasttyMobileFixture.home.activitySessions.first { $0.state.bucket == .working }
        )
        let presentation = ToasttySessionStatusPresentation(
            bucket: conversation.state.bucket,
            freshness: .reconnecting
        )

        XCTAssertTrue(
            presentation.accessibilitySummary(for: conversation).contains(
                "Last seen working. Updates paused."
            )
        )
        XCTAssertFalse(
            presentation.accessibilitySummary(for: conversation).contains(", working,")
        )
    }
}
