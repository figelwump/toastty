import XCTest
@testable import ToasttyMobileApp
import ToasttyMobileDomain

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

    /// Only the top screen keeps a conversation open. The Coordinator tab's
    /// own screen is the coordinator's chat; a screen pushed over it closes
    /// that chat until Back returns to it.
    func testTheCoordinatorTabsOwnScreenIsTheCoordinatorsChat() {
        let coordinatorConversationID = UUID()
        var tabs = ToasttyMobileTabState()
        func open(_ tab: ToasttyMobileTab) -> UUID? {
            tabs.openConversationID(in: tab, coordinatorConversationID: coordinatorConversationID)
        }
        XCTAssertEqual(open(.coordinator), coordinatorConversationID)
        XCTAssertNil(open(.home))
        tabs.paths[.coordinator] = [.conversation(conversationID)]
        XCTAssertEqual(open(.coordinator), conversationID)
        tabs.paths[.coordinator] = [.workspace(workspaceID)]
        XCTAssertNil(open(.coordinator))
        tabs.paths[.coordinator] = []
        XCTAssertNil(tabs.openConversationID(in: .coordinator, coordinatorConversationID: nil))
        tabs.paths[.home] = [.workspace(workspaceID), .conversation(conversationID)]
        XCTAssertEqual(open(.home), conversationID)
    }

    /// The Coordinator tab's badge: unread output, an approval or an error,
    /// and only while another tab shows.
    func testTheCoordinatorBadgeCallsOnlyFromAnotherTab() {
        let marks: [(MobileCoordinatorMark?, String?)] = [
            (.unread, "New"), (.needsApproval, "!"), (.error, "Error"),
            (.working, nil), (.quiet, nil), (.notRunning, nil), (nil, nil),
        ]
        for (mark, badge) in marks {
            XCTAssertEqual(ToasttyCoordinatorTabPresentation.badge(mark, isOnScreen: false), badge, "\(String(describing: mark))")
            XCTAssertNil(ToasttyCoordinatorTabPresentation.badge(mark, isOnScreen: true), "\(String(describing: mark))")
        }
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
