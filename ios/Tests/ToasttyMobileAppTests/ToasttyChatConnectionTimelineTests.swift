import XCTest
@testable import ToasttyMobileApp

/// The chat's one connection signal: nothing for a short reconnect, then
/// "reconnecting…", then offline, with time in the background not counted.
final class ToasttyChatConnectionTimelineTests: XCTestCase {
    private let start = ContinuousClock.now

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        start.advanced(by: .milliseconds(milliseconds))
    }

    private func timeline() -> ToasttyChatConnectionTimeline {
        ToasttyChatConnectionTimeline(reconnectingDelay: .milliseconds(1500), offlineDelay: .seconds(15))
    }

    func testAShortReconnectShowsNothingAndALongOneShowsReconnectingThenOffline() {
        var subject = timeline()
        XCTAssertNil(subject.update(freshness: .live, now: at(0)))
        XCTAssertEqual(subject.connection, .live)

        XCTAssertEqual(subject.update(freshness: .reconnecting, now: at(100)), at(1600))
        XCTAssertEqual(subject.connection, .live)
        // Each state on the way counts from when the chat stopped being live.
        XCTAssertEqual(subject.update(freshness: .stale, now: at(900)), at(1600))
        XCTAssertEqual(subject.connection, .live)

        XCTAssertEqual(subject.update(freshness: .stale, now: at(1600)), at(15_100))
        XCTAssertEqual(subject.connection, .reconnecting)

        XCTAssertNil(subject.update(freshness: .reconnecting, now: at(15_100)))
        XCTAssertEqual(subject.connection, .offline)

        XCTAssertNil(subject.update(freshness: .live, now: at(16_000)))
        XCTAssertEqual(subject.connection, .live)

        // A new outage counts from its own start.
        XCTAssertEqual(subject.update(freshness: .stale, now: at(20_000)), at(21_500))
        XCTAssertEqual(subject.connection, .live)
    }

    func testTimeInTheBackgroundDoesNotCountAndTheChatKeepsWhatItShowed() {
        var subject = timeline()
        _ = subject.update(freshness: .live, now: at(0))
        subject.enterBackground()
        // The stream is suspended a few seconds into the background.
        XCTAssertNil(subject.update(freshness: .stale, now: at(10_000)))
        XCTAssertNil(subject.update(freshness: .stale, now: at(60_000)))
        XCTAssertEqual(subject.connection, .live)

        subject.enterForeground(now: at(70_000))
        XCTAssertEqual(subject.update(freshness: .stale, now: at(70_000)), at(71_500))
        XCTAssertEqual(subject.connection, .live)
        XCTAssertEqual(subject.update(freshness: .reconnecting, now: at(71_500)), at(85_000))
        XCTAssertEqual(subject.connection, .reconnecting)
    }

    func testAChatThatLeftReconnectingOrOfflineSaysReconnectingOnReturnAndCountsAgain() {
        for leftAt in [1_600, 15_000] {
            var subject = timeline()
            _ = subject.update(freshness: .reconnecting, now: at(0))
            _ = subject.update(freshness: .reconnecting, now: at(leftAt))
            XCTAssertNotEqual(subject.connection, .live)
            subject.enterBackground()
            subject.enterForeground(now: at(40_000))
            // No blank header between the screen that left and the return.
            XCTAssertEqual(subject.update(freshness: .reconnecting, now: at(40_000)), at(53_500))
            XCTAssertEqual(subject.connection, .reconnecting)
        }
    }

    func testAReturnFromControlCenterKeepsTheCountAndRetry() {
        var subject = timeline()
        _ = subject.update(freshness: .reconnecting, now: at(0))
        _ = subject.update(freshness: .reconnecting, now: at(15_000))
        XCTAssertEqual(subject.connection, .offline)
        // The scene went inactive and active again, never to the background.
        subject.enterForeground(now: at(16_000))
        XCTAssertNil(subject.update(freshness: .reconnecting, now: at(16_000)))
        XCTAssertEqual(subject.connection, .offline)
    }

    func testAFailureThatOnlyRetryEndsIsOfflineAtOnceAlsoAfterAReturn() {
        var subject = timeline()
        XCTAssertNil(subject.update(freshness: .unreachable, now: at(0)))
        XCTAssertEqual(subject.connection, .offline)
        subject.enterBackground()
        subject.enterForeground(now: at(5_000))
        XCTAssertNil(subject.update(freshness: .unreachable, now: at(5_000)))
        XCTAssertEqual(subject.connection, .offline)
    }

    func testRetryShowsReconnectingAtOnceAndCountsTowardOfflineAgain() {
        var subject = timeline()
        _ = subject.update(freshness: .unreachable, now: at(0))
        subject.retry(now: at(20_000))
        // The restart moves the connection back to connecting.
        XCTAssertEqual(subject.update(freshness: .reconnecting, now: at(20_000)), at(33_500))
        XCTAssertEqual(subject.connection, .reconnecting)
        XCTAssertNil(subject.update(freshness: .reconnecting, now: at(33_500)))
        XCTAssertEqual(subject.connection, .offline)

        // Retry while live changes nothing.
        var live = timeline()
        _ = live.update(freshness: .live, now: at(0))
        live.retry(now: at(100))
        XCTAssertNil(live.update(freshness: .live, now: at(100)))
        XCTAssertEqual(live.connection, .live)
    }

    func testFixturesWithoutATimelineMapFreshnessDirectly() {
        XCTAssertEqual(ToasttyChatConnection(freshness: .live), .live)
        XCTAssertEqual(ToasttyChatConnection(freshness: .connecting), .reconnecting)
        XCTAssertEqual(ToasttyChatConnection(freshness: .reconnecting), .reconnecting)
        XCTAssertEqual(ToasttyChatConnection(freshness: .stale), .offline)
        XCTAssertEqual(ToasttyChatConnection(freshness: .unreachable), .offline)
    }
}
