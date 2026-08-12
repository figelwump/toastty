import RemoteProtocol
import XCTest
@testable import ToasttyMobileDomain

final class ToasttyMobileModelsTests: XCTestCase {
    func testEightProtocolStatesMapIntoFivePresentationBuckets() {
        XCTAssertEqual(RemoteSessionState.awaitingInput.bucket, .needsYou)
        XCTAssertEqual(RemoteSessionState.starting.bucket, .working)
        XCTAssertEqual(RemoteSessionState.working.bucket, .working)
        XCTAssertEqual(RemoteSessionState.ready.bucket, .ready)
        XCTAssertEqual(RemoteSessionState.interrupted.bucket, .attention)
        XCTAssertEqual(RemoteSessionState.error.bucket, .attention)
        XCTAssertEqual(RemoteSessionState.ended.bucket, .offline)
        XCTAssertEqual(RemoteSessionState.offline.bucket, .offline)
    }

    func testNeedsYouQueueUsesStateWhileReasonUsesInputAvailability() {
        let snapshot = ToasttyMobileFixture.home

        XCTAssertEqual(snapshot.needsYou.count, 3)
        XCTAssertTrue(snapshot.needsYou.contains {
            $0.inputAvailability.needsYouReason == "Draft in progress on the Mac"
        })
        XCTAssertTrue(snapshot.needsYou.contains {
            $0.inputAvailability.allowsReply
        })
    }

    func testWorkspaceRollupPrioritizesNeedsYouOverWorking() throws {
        let toastty = try XCTUnwrap(ToasttyMobileFixture.home.workspaces.first)

        XCTAssertEqual(toastty.rollupLabel, "1 need you")
        XCTAssertEqual(toastty.sortedConversations.first?.state.bucket, .needsYou)
    }

    func testStatusAccessibilitySummaryIncludesNonColorFacts() throws {
        let conversation = try XCTUnwrap(ToasttyMobileFixture.home.needsYou.first)

        XCTAssertTrue(conversation.accessibilitySummary.contains("needs you"))
        XCTAssertTrue(conversation.accessibilitySummary.contains(conversation.workspaceTitle))
        XCTAssertTrue(conversation.accessibilitySummary.contains(conversation.age))
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
