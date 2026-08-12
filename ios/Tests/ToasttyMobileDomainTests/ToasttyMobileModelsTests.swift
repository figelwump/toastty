import RemoteProtocol
import XCTest
@testable import ToasttyMobileDomain

final class ToasttyMobileModelsTests: XCTestCase {
    func testLegacyProtocolStatesFallBackToDesktopPresentationBuckets() {
        XCTAssertEqual(RemoteSessionState.awaitingInput.bucket, .ready)
        XCTAssertEqual(RemoteSessionState.starting.bucket, .working)
        XCTAssertEqual(RemoteSessionState.working.bucket, .working)
        XCTAssertEqual(RemoteSessionState.ready.bucket, .ready)
        XCTAssertEqual(RemoteSessionState.interrupted.bucket, .error)
        XCTAssertEqual(RemoteSessionState.error.bucket, .error)
        XCTAssertEqual(RemoteSessionState.ended.bucket, .idle)
        XCTAssertEqual(RemoteSessionState.offline.bucket, .idle)
    }

    func testReadyQueueUsesExactStatusWhileReplyAuthorityRemainsIndependent() throws {
        let snapshot = ToasttyMobileFixture.home

        XCTAssertEqual(snapshot.ready.count, 3)
        XCTAssertTrue(snapshot.ready.contains {
            $0.inputAvailability.inputReason == "Draft in progress on the Mac"
        })
        XCTAssertTrue(snapshot.ready.contains {
            $0.inputAvailability.allowsReply
        })
        XCTAssertEqual(snapshot.needsApproval.count, 1)
        XCTAssertFalse(try XCTUnwrap(snapshot.needsApproval.first).inputAvailability.allowsReply)
    }

    func testWorkspaceRollupPrioritizesReadyOverApprovalAndWorking() throws {
        let toastty = try XCTUnwrap(ToasttyMobileFixture.home.workspaces.first)

        XCTAssertEqual(toastty.rollupLabel, "1 ready")
        XCTAssertEqual(toastty.sortedConversations.first?.state.bucket, .ready)
    }

    func testFixtureCoversEveryDesktopPresentationStatus() {
        let statuses = Set(
            ToasttyMobileFixture.home.workspaces
                .flatMap(\.conversations)
                .compactMap { conversation -> RemoteSessionPresentationStatus? in
                    guard case .known(let status) = conversation.state else { return nil }
                    return status
                }
        )

        XCTAssertEqual(statuses, Set([
            .idle, .working, .needsApproval, .ready, .error,
        ]))
    }

    func testStatusAccessibilitySummaryIncludesNonColorFacts() throws {
        let conversation = try XCTUnwrap(ToasttyMobileFixture.home.ready.first)

        XCTAssertTrue(conversation.accessibilitySummary.contains("ready"))
        XCTAssertTrue(conversation.accessibilitySummary.contains(conversation.workspaceTitle))
        XCTAssertTrue(conversation.accessibilitySummary.contains(conversation.age))
    }

    func testIdleAndUnsupportedStatusesHaveNoVisibleBucket() {
        XCTAssertFalse(MobileSessionStatus.idle.bucket.isVisible)
        XCTAssertFalse(MobileSessionStatus.unsupported(rawValue: "future").bucket.isVisible)
        XCTAssertEqual(
            MobileSessionStatus.unsupported(rawValue: "future").accessibilityLabel,
            "status unavailable"
        )
    }

    func testActivityAgeAdvancesOnlyFromMonotonicReceiptAnchor() {
        let age = MobileActivityAge(
            secondsAtReceipt: 59,
            receivedAtMonotonicTime: 1_000
        )

        XCTAssertEqual(age.label(atMonotonicTime: 999), "now")
        XCTAssertEqual(age.label(atMonotonicTime: 1_001), "1m")
        XCTAssertEqual(age.label(atMonotonicTime: 4_541), "1h")
    }
}
