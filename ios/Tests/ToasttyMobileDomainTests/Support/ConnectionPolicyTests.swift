import XCTest
@testable import ToasttyMobileDomain

final class ConnectionPolicyTests: XCTestCase {
    func testBackoffDoublesAndCapsAtThirtySeconds() {
        let policy = ConnectionRetryPolicy()

        XCTAssertEqual(policy.delay(afterFailureCount: 1, jitterUnit: 0.5), .seconds(1))
        XCTAssertEqual(policy.delay(afterFailureCount: 2, jitterUnit: 0.5), .seconds(2))
        XCTAssertEqual(policy.delay(afterFailureCount: 6, jitterUnit: 0.5), .seconds(30))
        XCTAssertEqual(policy.delay(afterFailureCount: 40, jitterUnit: 0.5), .seconds(30))
    }

    func testJitterIsClampedAndCannotExceedMaximum() {
        let policy = ConnectionRetryPolicy(initialDelay: .seconds(30), maximumDelay: .seconds(30))

        XCTAssertEqual(policy.delay(afterFailureCount: 1, jitterUnit: -10), .seconds(24))
        XCTAssertEqual(policy.delay(afterFailureCount: 1, jitterUnit: 10), .seconds(30))
    }

    func testReconnectingBannerStartsAfterSecondFailure() {
        let policy = ConnectionRetryPolicy()

        XCTAssertFalse(policy.shouldShowReconnectingBanner(afterFailureCount: 1))
        XCTAssertTrue(policy.shouldShowReconnectingBanner(afterFailureCount: 2))
    }
}
