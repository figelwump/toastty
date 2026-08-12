import XCTest
@testable import ToasttyMobileDomain

final class ToasttyMobileModelsTests: XCTestCase {
    func testEightProtocolStatesMapIntoFivePresentationBuckets() {
        XCTAssertEqual(MobileSessionState.awaitingInput.bucket, .needsYou)
        XCTAssertEqual(MobileSessionState.starting.bucket, .working)
        XCTAssertEqual(MobileSessionState.working.bucket, .working)
        XCTAssertEqual(MobileSessionState.ready.bucket, .ready)
        XCTAssertEqual(MobileSessionState.interrupted.bucket, .attention)
        XCTAssertEqual(MobileSessionState.error.bucket, .attention)
        XCTAssertEqual(MobileSessionState.ended.bucket, .offline)
        XCTAssertEqual(MobileSessionState.offline.bucket, .offline)
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
}
