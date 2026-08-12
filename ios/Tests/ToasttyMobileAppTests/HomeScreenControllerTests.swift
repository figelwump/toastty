import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

@MainActor
final class HomeScreenControllerTests: XCTestCase {
    func testOpenAndDismissOwnConversationPresentationState() throws {
        let conversation = try XCTUnwrap(ToasttyMobileFixture.home.needsYou.first)
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

    func testReplyRequestsFocusOnlyForOpenPromptWithoutReopeningConversation() throws {
        let conversation = try XCTUnwrap(
            ToasttyMobileFixture.home.needsYou.first {
                $0.inputAvailability.allowsReply
            }
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
            SelectedConversationPresentation(id: conversation.id)
        )

        controller.reply(conversation)

        XCTAssertEqual(
            controller.selectedConversationPresentation,
            SelectedConversationPresentation(
                id: conversation.id,
                requestsComposerFocus: true
            )
        )
        XCTAssertEqual(opened, [conversation.id])
        XCTAssertTrue(closed.isEmpty)
    }

    func testReplySafelyIgnoresConversationWithoutOpenPrompt() throws {
        let conversation = try XCTUnwrap(
            ToasttyMobileFixture.home.needsYou.first {
                $0.inputAvailability.allowsReply == false
            }
        )
        let controller = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .live
        )

        controller.reply(conversation)

        XCTAssertNil(controller.selectedConversationPresentation)
    }

    func testStableIdentifierRouteOpensOnlyConversationInCurrentSnapshot() throws {
        let conversation = try XCTUnwrap(ToasttyMobileFixture.home.needsYou.first)
        let controller = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .live
        )

        XCTAssertTrue(controller.openConversation(id: conversation.id))
        XCTAssertEqual(controller.selectedConversationID, conversation.id)

        controller.dismissConversation()
        XCTAssertFalse(controller.openConversation(id: UUID()))
        XCTAssertNil(controller.selectedConversationID)
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

    func testNeedsYouReasonUsesExactOpenPromptAndPendingFallbackCopy() {
        XCTAssertEqual(
            MobileInputAvailability.openPrompt.needsYouReason,
            "Ready for your reply"
        )
        XCTAssertEqual(
            MobileInputAvailability.pendingInteraction(preview: nil).needsYouReason,
            "Waiting for a response on the Mac"
        )
    }

    func testSelectedConversationResolvesLatestSnapshotValueByStableIdentifier() throws {
        let original = try XCTUnwrap(ToasttyMobileFixture.home.needsYou.first)
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
            workspacePath: original.workspacePath,
            agent: original.agent,
            title: "Updated live title",
            state: MobileSessionDisplayState.working,
            inputAvailability: .unavailable(reason: "working"),
            age: "now",
            lastActivity: "Updated from stream"
        )
        let workspace = MobileWorkspace(
            id: original.workspaceID,
            title: original.workspaceTitle,
            path: original.workspacePath,
            conversations: [updated]
        )

        controller.update(
            snapshot: MobileHomeSnapshot(hostName: "mac-studio", workspaces: [workspace]),
            connectionState: .live,
            freshness: .live
        )

        XCTAssertEqual(controller.selectedConversation?.title, "Updated live title")
        XCTAssertEqual(controller.selectedConversation?.state, MobileSessionDisplayState.working)
        XCTAssertNil(controller.removedSelectionMessage)
    }

    func testRemovingSelectedConversationDismissesAndExplains() throws {
        let original = try XCTUnwrap(ToasttyMobileFixture.home.needsYou.first)
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
}
