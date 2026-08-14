import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

@MainActor
final class HomeScreenControllerTests: XCTestCase {
    func testOpenAndDismissOwnConversationPresentationState() throws {
        let conversation = try XCTUnwrap(fixtureConversation(in: .ready))
        let controller = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .live
        )

        controller.open(conversation)
        XCTAssertEqual(controller.selectedConversation, conversation)
        XCTAssertEqual(controller.selectedConversationID, conversation.id)

        controller.dismissConversation()
        XCTAssertNil(controller.selectedConversation)
    }

    func testUserOpenRequestsFocusForOpenPromptWithoutReopeningConversation() throws {
        let conversation = try XCTUnwrap(
            fixtureConversation(in: .ready) { $0.inputAvailability.allowsReply }
        )
        let controller = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .live
        )
        var opened: [UUID] = []
        var closed: [UUID] = []
        controller.installConversationLifecycle(
            onOpen: { opened.append($0) },
            onClose: { closed.append($0) }
        )

        controller.open(conversation)
        XCTAssertEqual(
            controller.selectedConversationPresentation,
            SelectedConversationPresentation(
                id: conversation.id,
                requestsComposerFocus: true
            )
        )
        XCTAssertEqual(opened, [conversation.id])
        XCTAssertTrue(closed.isEmpty)

        controller.open(conversation)
        XCTAssertEqual(opened, [conversation.id])
        XCTAssertTrue(closed.isEmpty)
    }

    func testUserOpenDoesNotRequestFocusWithoutOpenPrompt() throws {
        let conversation = try XCTUnwrap(
            fixtureConversation(in: .ready) { $0.inputAvailability.allowsReply == false }
        )
        let controller = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .live
        )

        controller.open(conversation)

        XCTAssertEqual(
            controller.selectedConversationPresentation,
            SelectedConversationPresentation(id: conversation.id)
        )
    }

    func testStableIdentifierRouteOpensOnlyConversationInCurrentSnapshot() throws {
        let conversation = try XCTUnwrap(fixtureConversation(in: .ready))
        let controller = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .live
        )

        XCTAssertTrue(controller.openConversation(id: conversation.id))
        XCTAssertEqual(controller.selectedConversationID, conversation.id)
        XCTAssertEqual(
            controller.selectedConversationPresentation,
            SelectedConversationPresentation(id: conversation.id)
        )

        controller.dismissConversation()
        XCTAssertFalse(controller.openConversation(id: UUID()))
        XCTAssertNil(controller.selectedConversationID)
    }

    func testStableIdentifierRouteOpensLockedConversationWithoutFocus() throws {
        let conversation = try XCTUnwrap(
            fixtureConversation(in: .needsApproval) {
                $0.inputAvailability.allowsReply == false
            }
        )
        let controller = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .live
        )

        XCTAssertTrue(
            controller.openConversation(
                id: conversation.id,
                requestsComposerFocus: true
            )
        )
        XCTAssertEqual(
            controller.selectedConversationPresentation,
            SelectedConversationPresentation(id: conversation.id)
        )
    }

    func testConnectionNoticeClassifiesTransportFailures() {
        let controller = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .offline,
            latestTransportFailure: .offline
        )

        XCTAssertEqual(
            controller.connectionNoticeMessage,
            "This iPhone appears to be offline. Showing the last available update."
        )

        let expectedFragments: [(NativeTransportFailure, String)] = [
            (.dns, "couldn't find your Mac"),
            (.tls, "secure connection"),
            (.cannotConnect, "gateway on your Mac is unreachable"),
            (.timedOut, "gateway on your Mac is unreachable"),
            (.connectionLost, "gateway on your Mac is unreachable"),
            (.other, "couldn't connect to your Mac"),
        ]
        for (failure, fragment) in expectedFragments {
            controller.update(
                snapshot: controller.snapshot,
                connectionState: .offline,
                freshness: .unreachable,
                latestTransportFailure: failure
            )
            XCTAssertTrue(controller.connectionNoticeMessage?.contains(fragment) == true)
        }
    }

    func testInputReasonUsesExactOpenPromptAndPendingFallbackCopy() {
        XCTAssertEqual(
            MobileInputAvailability.openPrompt.inputReason,
            "Ready for your reply"
        )
        XCTAssertEqual(
            MobileInputAvailability.pendingInteraction(preview: nil).inputReason,
            "Waiting for a response on the Mac"
        )
    }

    func testSelectedConversationResolvesLatestSnapshotValueByStableIdentifier() throws {
        let original = try XCTUnwrap(fixtureConversation(in: .ready))
        let controller = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .live
        )
        controller.open(original)

        let updated = MobileConversation(
            id: original.id,
            workspaceID: original.workspaceID,
            workspaceTitle: original.workspaceTitle,
            cwd: original.cwd,
            agent: original.agent,
            title: "Updated live title",
            state: MobileSessionStatus.working,
            inputAvailability: .unavailable(reason: "working"),
            age: "now",
            lastActivity: "Updated from stream"
        )
        let workspace = MobileWorkspace(
            id: original.workspaceID,
            title: original.workspaceTitle,
            conversations: [updated]
        )

        controller.update(
            snapshot: MobileHomeSnapshot(hostName: "mac-studio", workspaces: [workspace]),
            connectionState: .live,
            freshness: .live
        )

        XCTAssertEqual(controller.selectedConversation?.title, "Updated live title")
        XCTAssertEqual(controller.selectedConversation?.state, MobileSessionStatus.working)
        XCTAssertNil(controller.removedSelectionMessage)
    }

    func testRemovingSelectedConversationDismissesAndExplains() throws {
        let original = try XCTUnwrap(fixtureConversation(in: .ready))
        let controller = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .live
        )
        controller.open(original)

        controller.update(
            snapshot: MobileHomeSnapshot(hostName: "mac-studio", workspaces: []),
            connectionState: .reconnecting,
            freshness: .reconnecting
        )

        XCTAssertNil(controller.selectedConversationID)
        XCTAssertNil(controller.selectedConversation)
        XCTAssertEqual(
            controller.removedSelectionMessage,
            "\(original.title) is no longer available on your Mac."
        )

        controller.dismissRemovalMessage()
        XCTAssertNil(controller.removedSelectionMessage)
    }

    private func fixtureConversation(
        in bucket: MobileSessionBucket,
        where predicate: (MobileConversation) -> Bool = { _ in true }
    ) -> MobileConversation? {
        ToasttyMobileFixture.home.activitySessions.first {
            $0.state.bucket == bucket && predicate($0)
        }
    }
}
