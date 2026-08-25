import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

final class ToasttyWorkspaceSessionFilterTests: XCTestCase {
    func testAllIsTheDefaultFilter() {
        XCTAssertEqual(ToasttyWorkspaceSessionFilter.defaultFilter, .all)
    }

    func testAllIsDeclaredBeforeActiveForSegmentedPickers() {
        XCTAssertEqual(ToasttyWorkspaceSessionFilter.allCases, [.all, .active])
    }

    func testPreferenceKeyRemainsStable() {
        XCTAssertEqual(
            ToasttyWorkspaceSessionFilter.preferenceKey,
            "toastty-mobile-workspace-session-filter"
        )
    }

    func testActiveExcludesIdleSessionsAndEmptyWorkspaceGroups() throws {
        let activeConversation = try XCTUnwrap(
            ToasttyMobileFixture.home.activitySessions.first { $0.state.bucket != .idle }
        )
        let idleConversation = try XCTUnwrap(
            ToasttyMobileFixture.home.activitySessions.first { $0.state.bucket == .idle }
        )
        let activeWorkspace = MobileWorkspace(
            id: activeConversation.workspaceID,
            title: activeConversation.workspaceTitle,
            conversations: [idleConversation, activeConversation]
        )
        let idleWorkspace = MobileWorkspace(
            id: idleConversation.workspaceID,
            title: idleConversation.workspaceTitle,
            conversations: [idleConversation]
        )

        let visible = ToasttyWorkspaceSessionFilter.active.workspaces(
            from: [activeWorkspace, idleWorkspace]
        )

        XCTAssertEqual(visible.map(\.id), [activeWorkspace.id])
        XCTAssertEqual(visible.first?.conversations.map(\.id), [activeConversation.id])
    }

    func testAllIncludesIdleSessionsButStillOmitsEmptyWorkspaceGroups() throws {
        let idleConversation = try XCTUnwrap(
            ToasttyMobileFixture.home.activitySessions.first { $0.state.bucket == .idle }
        )
        let idleWorkspace = MobileWorkspace(
            id: idleConversation.workspaceID,
            title: idleConversation.workspaceTitle,
            conversations: [idleConversation]
        )
        let emptyWorkspace = MobileWorkspace(id: UUID(), title: "Empty", conversations: [])

        let visible = ToasttyWorkspaceSessionFilter.all.workspaces(
            from: [idleWorkspace, emptyWorkspace]
        )

        XCTAssertEqual(visible.map(\.id), [idleWorkspace.id])
        XCTAssertEqual(visible.first?.conversations.map(\.id), [idleConversation.id])
    }
}

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

    func testUserOpenDoesNotReopenConversation() throws {
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
            SelectedConversationPresentation(id: conversation.id)
        )
        XCTAssertEqual(opened, [conversation.id])
        XCTAssertTrue(closed.isEmpty)

        controller.open(conversation)
        XCTAssertEqual(opened, [conversation.id])
        XCTAssertTrue(closed.isEmpty)
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

    func testConnectionNoticeClassifiesTransportFailures() {
        let controller = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .offline,
            latestTransportFailure: .offline
        )

        XCTAssertEqual(
            controller.connectionNoticeMessage,
            "This iPhone appears to be offline. Check its internet connection and make sure Tailscale is connected. After making changes, tap Retry or wait for Toastty to try automatically."
        )

        let expectedFragments: [(NativeTransportFailure, String)] = [
            (.dns, "Tailscale is connected on both devices"),
            (.tls, "Tailnet hostname in Toastty's Remote Access settings"),
            (.cannotConnect, "Toastty is running, and Remote Access is enabled"),
            (.timedOut, "If those are already true, restart Toastty"),
            (.connectionLost, "If those are already true, restart Toastty"),
            (.other, "Check Tailscale on both devices"),
        ]
        for (failure, fragment) in expectedFragments {
            controller.update(
                snapshot: controller.snapshot,
                connectionState: .offline,
                freshness: .unreachable,
                latestTransportFailure: failure
            )
            XCTAssertTrue(controller.connectionNoticeMessage?.contains(fragment) == true)
            XCTAssertTrue(
                controller.connectionNoticeMessage?.hasSuffix(
                    "After making changes, tap Retry or wait for Toastty to try automatically."
                ) == true
            )
        }
    }

    func testReconnectingWithoutTransportFailureExplainsRecoverySteps() {
        let controller = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .reconnecting,
            freshness: .reconnecting
        )

        XCTAssertEqual(
            controller.connectionNoticeMessage,
            "Toastty is still trying to connect to your Mac. Make sure the Mac is awake, Toastty is running with Remote Access enabled, and Tailscale is connected on both devices. If those are already true, restart Toastty. After making changes, tap Retry or wait for Toastty to try automatically."
        )
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
