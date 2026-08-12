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
