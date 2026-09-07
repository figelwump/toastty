import XCTest
@testable import ToasttyMobileApp

final class ToasttyMobileRouteTests: XCTestCase {
    private let workspaceID = UUID()
    private let conversationID = UUID()

    func testConversationPushReplacementAndPopPreservePreviewContext() {
        let preview = ToasttyMobileRoute.panelPreview(workspaceID: workspaceID, panelID: UUID())
        let context: [ToasttyMobileRoute] = [.workspace(workspaceID), preview]
        let pushed = context.synchronized(with: SelectedConversationPresentation(id: conversationID))
        XCTAssertEqual(pushed, context + [.conversation(conversationID)])
        XCTAssertEqual(pushed.synchronized(with: nil), context)
        let replacement = UUID()
        // External conversation selection also keeps the previous reading context.
        XCTAssertEqual(pushed.synchronized(with: SelectedConversationPresentation(id: replacement)),
                       context + [.conversation(replacement)])
        XCTAssertFalse(context.containsConversation)
    }

    func testSynchronizedAppendsConversationOnTopOfCurrentPath() {
        let selection = SelectedConversationPresentation(id: conversationID)

        XCTAssertEqual(
            [ToasttyMobileRoute]().synchronized(with: selection),
            [.conversation(conversationID)]
        )
        XCTAssertEqual(
            [ToasttyMobileRoute.workspace(workspaceID)].synchronized(with: selection),
            [.workspace(workspaceID), .conversation(conversationID)]
        )
    }

    func testSynchronizedReplacesConversationWhenSelectionChanges() {
        let path: [ToasttyMobileRoute] = [
            .workspace(workspaceID),
            .conversation(UUID()),
        ]

        XCTAssertEqual(
            path.synchronized(with: SelectedConversationPresentation(id: conversationID)),
            [.workspace(workspaceID), .conversation(conversationID)]
        )
    }

    func testSynchronizedIsStableWhenSelectionAlreadyPresented() {
        let path: [ToasttyMobileRoute] = [
            .workspace(workspaceID),
            .conversation(conversationID),
        ]

        XCTAssertEqual(
            path.synchronized(with: SelectedConversationPresentation(id: conversationID)),
            path
        )
    }

    func testSynchronizedRemovesConversationWhenSelectionCleared() {
        let path: [ToasttyMobileRoute] = [
            .workspace(workspaceID),
            .conversation(conversationID),
        ]

        XCTAssertEqual(path.synchronized(with: nil), [.workspace(workspaceID)])
        XCTAssertEqual(
            [ToasttyMobileRoute.conversation(conversationID)].synchronized(with: nil),
            []
        )
    }

    func testContainsConversationDistinguishesRouteKinds() {
        XCTAssertFalse([ToasttyMobileRoute]().containsConversation)
        XCTAssertFalse([ToasttyMobileRoute.workspace(workspaceID)].containsConversation)
        XCTAssertTrue(
            [ToasttyMobileRoute.workspace(workspaceID), .conversation(conversationID)]
                .containsConversation
        )
    }
}
