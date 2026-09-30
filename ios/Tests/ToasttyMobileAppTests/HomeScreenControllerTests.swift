import RemoteProtocol
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

    func testActiveExcludesIdleSessionsAndWorkspacesWithNothingActive() throws {
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
        // Open panels no longer keep an idle workspace under Active.
        let idleWorkspace = MobileWorkspace(
            id: idleConversation.workspaceID,
            title: idleConversation.workspaceTitle,
            conversations: [idleConversation],
            panels: ToasttyMobileFixture.previewPanels
        )
        let panelOnlyWorkspace = MobileWorkspace(
            id: UUID(),
            title: "Panels",
            conversations: [],
            panels: ToasttyMobileFixture.previewPanels
        )
        let workspaces = [activeWorkspace, idleWorkspace, panelOnlyWorkspace]

        let visible = ToasttyWorkspaceSessionFilter.active.workspaces(from: workspaces)

        XCTAssertEqual(visible.map(\.id), [activeWorkspace.id])
        XCTAssertEqual(visible.first?.conversations.map(\.id), [activeConversation.id])
        XCTAssertEqual(ToasttyWorkspaceSessionFilter.active.hiddenSessionCount(in: workspaces), 2)
        XCTAssertEqual(ToasttyWorkspaceSessionFilter.hiddenSessionsLabel(count: 2), "2 idle sessions hidden")
        XCTAssertEqual(ToasttyWorkspaceSessionFilter.hiddenSessionsLabel(count: 1), "1 idle session hidden")

        // All still lists every session and keeps panels reachable.
        let all = ToasttyWorkspaceSessionFilter.all.workspaces(from: workspaces)
        XCTAssertEqual(all.map(\.id), workspaces.map(\.id))
        XCTAssertEqual(ToasttyWorkspaceSessionFilter.all.hiddenSessionCount(in: workspaces), 0)
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

final class ToasttySubspacePresentationTests: XCTestCase {
    private let parentID = UUID()
    private let otherParentID = UUID()
    private let spawnerID = UUID()

    private func conversation(
        id: UUID = UUID(),
        in workspaceID: UUID,
        _ status: MobileSessionStatus
    ) -> MobileConversation {
        MobileConversation(
            id: id, workspaceID: workspaceID, workspaceTitle: "workspace", cwd: nil, agent: .claude,
            title: "session", state: status, inputAvailability: .unavailable(reason: "test"),
            age: "now", lastActivity: "activity"
        )
    }

    private func subspace(
        _ title: String,
        under parentID: UUID,
        _ status: MobileSessionStatus,
        spawner: UUID? = nil,
        isDone: Bool = false
    ) -> MobileWorkspace {
        let id = UUID()
        return MobileWorkspace(
            id: id, title: title, conversations: [conversation(in: id, status)],
            parentWorkspaceID: parentID, spawningConversationID: spawner, isDone: isDone
        )
    }

    func testActiveKeepsAParentWhoseOnlyActivityIsASubspaceAndCountsWhatItHides() throws {
        let snapshot = MobileHomeSnapshot(hostName: "Mac", workspaces: [
            MobileWorkspace(id: parentID, title: "parent", conversations: [conversation(in: parentID, .idle)]),
            subspace("working", under: parentID, .working),
            subspace("idle", under: parentID, .idle),
            subspace("done", under: parentID, .ready, isDone: true),
            MobileWorkspace(
                id: otherParentID, title: "quiet", conversations: [conversation(in: otherParentID, .idle)]
            ),
            subspace("finished", under: otherParentID, .idle, isDone: true),
        ])

        let active = ToasttyWorkspaceSessionFilter.active.sections(in: snapshot)
        XCTAssertEqual(active.map(\.id), [parentID])
        let section = try XCTUnwrap(active.first)
        XCTAssertTrue(section.workspace.conversations.isEmpty)
        XCTAssertEqual(section.subspaceRows.map(\.workspace.title), ["working"])
        XCTAssertEqual(section.subspaceTotal, 3)
        XCTAssertEqual(
            ToasttyWorkspaceSessionFilter.active.hiddenCounts(in: snapshot),
            ToasttyHiddenCounts(idleSessions: 2, idleSubspaces: 1, doneSubspaces: 2)
        )

        let all = ToasttyWorkspaceSessionFilter.all.sections(in: snapshot)
        XCTAssertEqual(Set(all.map(\.id)), [parentID, otherParentID])
        XCTAssertEqual(
            all.first { $0.id == parentID }?.subspaceRows.map(\.workspace.title),
            ["working", "idle", "done"]
        )
        XCTAssertNil(ToasttyWorkspaceSessionFilter.all.hiddenCounts(in: snapshot).label)
    }

    func testHiddenLabelListsOnlyWhatIsHidden() {
        XCTAssertNil(ToasttyHiddenCounts().label)
        XCTAssertEqual(ToasttyHiddenCounts(idleSessions: 1).label, "1 idle session hidden")
        XCTAssertEqual(
            ToasttyHiddenCounts(idleSessions: 3, doneSubspaces: 1).label,
            "3 idle sessions and 1 done subspace hidden"
        )
        XCTAssertEqual(
            ToasttyHiddenCounts(idleSessions: 2, idleSubspaces: 1, doneSubspaces: 2).label,
            "2 idle sessions, 1 idle subspace and 2 done subspaces hidden"
        )
    }

    func testSpawnerChipCountsOwnWorkspaceFirstThenPointsAtAnotherWorkspace() throws {
        let spawner = conversation(id: spawnerID, in: parentID, .working)
        let elsewhere = subspace("elsewhere", under: otherParentID, .error, spawner: spawnerID)
        let own = [
            subspace("one", under: parentID, .needsApproval, spawner: spawnerID),
            subspace("two", under: parentID, .idle, spawner: spawnerID, isDone: true),
            subspace("someone else's", under: parentID, .error, spawner: UUID()),
        ]
        let parents = [
            MobileWorkspace(id: parentID, title: "parent", conversations: [spawner]),
            MobileWorkspace(id: otherParentID, title: "other", conversations: []),
        ]

        let full = MobileHomeSnapshot(hostName: "Mac", workspaces: parents + own + [elsewhere])
        let ownChip = try XCTUnwrap(ToasttySpawnerChip.chip(for: spawner, in: full, filter: .all))
        XCTAssertEqual(ownChip.count, 2)
        XCTAssertEqual(ownChip.tone, .needsApproval)
        XCTAssertEqual(ownChip.parentWorkspaceID, parentID)
        XCTAssertNil(ownChip.otherWorkspaceTitle)
        XCTAssertEqual(ownChip.accessibilityLabel, "2 subspaces")

        // With none of its own, the chip points at the workspace that holds one.
        let otherChip = try XCTUnwrap(ToasttySpawnerChip.chip(
            for: spawner,
            in: MobileHomeSnapshot(hostName: "Mac", workspaces: parents + [elsewhere]),
            filter: .all
        ))
        XCTAssertEqual(otherChip.count, 1)
        XCTAssertEqual(otherChip.tone, .error)
        XCTAssertEqual(otherChip.parentWorkspaceID, otherParentID)
        XCTAssertEqual(otherChip.accessibilityLabel, "1 subspace in other")

        XCTAssertNil(ToasttySpawnerChip.chip(
            for: spawner, in: MobileHomeSnapshot(hostName: "Mac", workspaces: parents), filter: .all
        ))

        // Active lists only the subspace that wants approval, so the chip
        // counts that one; with none listed there is no chip to lead nowhere.
        XCTAssertEqual(ToasttySpawnerChip.chip(for: spawner, in: full, filter: .active)?.count, 1)
        XCTAssertNil(ToasttySpawnerChip.chip(
            for: spawner,
            in: MobileHomeSnapshot(hostName: "Mac", workspaces: parents + [own[1]]),
            filter: .active
        ))
    }

    func testSpawnerFilterGivesWayWhenItWouldHideASubspaceThatNeedsTheUser() {
        let mine = MobileSubspaceRow(workspace: subspace("mine", under: parentID, .working, spawner: spawnerID))
        let quiet = MobileSubspaceRow(workspace: subspace("quiet", under: parentID, .idle, spawner: UUID()))
        let asking = MobileSubspaceRow(
            workspace: subspace("asking", under: parentID, .needsApproval, spawner: UUID())
        )

        let filtered = ToasttySubspaceGroupPresentation.rows([mine, quiet], spawnedBy: spawnerID)
        XCTAssertEqual(filtered.rows.map(\.id), [mine.id])
        XCTAssertTrue(filtered.isFiltered)

        let yielded = ToasttySubspaceGroupPresentation.rows([mine, quiet, asking], spawnedBy: spawnerID)
        XCTAssertEqual(yielded.rows.count, 3)
        XCTAssertFalse(yielded.isFiltered)

        XCTAssertEqual(ToasttySubspaceGroupPresentation.countLabel(shown: 2, total: 3), "2/3")
        XCTAssertEqual(ToasttySubspaceGroupPresentation.countLabel(shown: 3, total: 3), "3")
    }

    func testCollapsedGroupsRoundTripThroughTheirStoredValue() {
        var groups = ToasttyCollapsedSubspaceGroups(storedValue: "not-a-uuid,")
        XCTAssertFalse(groups.contains(parentID))
        groups.set(parentID, collapsed: true)
        groups.set(otherParentID, collapsed: true)
        groups.set(otherParentID, collapsed: false)

        let restored = ToasttyCollapsedSubspaceGroups(storedValue: groups.storedValue)
        XCTAssertTrue(restored.contains(parentID))
        XCTAssertFalse(restored.contains(otherParentID))
    }
}

@MainActor
final class ConversationFlagControllerTests: XCTestCase {
    private let workspaceID = UUID()
    private let conversationID = UUID()

    private func snapshot(isFlagged: Bool, generation: Int = 0) -> MobileHomeSnapshot {
        MobileHomeSnapshot(hostName: "Mac \(generation)", workspaces: [
            MobileWorkspace(id: workspaceID, title: "toastty", conversations: [
                MobileConversation(
                    id: conversationID, workspaceID: workspaceID, workspaceTitle: "toastty", cwd: nil,
                    agent: .claude, title: "Session", state: MobileSessionStatus.ready,
                    inputAvailability: .unavailable(reason: "test"), age: "now",
                    lastActivity: "Done", isFlaggedForLater: isFlagged
                ),
            ]),
        ])
    }

    private func liveController(supportsFlag: Bool = true) -> HomeScreenController {
        let controller = HomeScreenController(
            runtimeMode: .live(gatewayURL: URL(string: "https://toastty.example")!),
            snapshot: snapshot(isFlagged: false), connectionState: .live
        )
        controller.update(
            snapshot: snapshot(isFlagged: false), connectionState: .live, freshness: .live,
            hostSupportsConversationFlag: supportsFlag
        )
        return controller
    }

    private func isShownFlagged(_ controller: HomeScreenController) -> Bool? {
        controller.conversation(id: conversationID)?.isFlaggedForLater
    }

    func testFlagShowsAtOnceAndTheMacsSnapshotConfirmsIt() async throws {
        let controller = liveController()
        var requests: [Bool] = []
        controller.installConversationFlag { _, isFlagged in
            requests.append(isFlagged)
            return .applied
        }

        controller.setConversationFlag(conversationID, isFlagged: true)
        XCTAssertEqual(isShownFlagged(controller), true)
        XCTAssertEqual(controller.subspaceDoneNotice?.message, "Flagged for later")
        XCTAssertEqual(controller.subspaceDoneNotice?.canUndo, true)
        try await waitUntil { requests == [true] }
        controller.update(snapshot: snapshot(isFlagged: true, generation: 1), connectionState: .live, freshness: .live)
        try await waitUntil { controller.hasPendingConversationFlag == false }
        XCTAssertEqual(isShownFlagged(controller), true)

        // Undo sends the opposite state without another notice.
        controller.undoSubspaceDoneNotice()
        XCTAssertNil(controller.subspaceDoneNotice)
        XCTAssertEqual(isShownFlagged(controller), false)
        try await waitUntil { requests == [true, false] }

        // The Mac clears the flag itself when the session starts new work.
        controller.update(snapshot: snapshot(isFlagged: false, generation: 2), connectionState: .live, freshness: .live)
        try await waitUntil { controller.hasPendingConversationFlag == false }
        XCTAssertEqual(isShownFlagged(controller), false)
    }

    func testASnapshotThatClearsTheFlagBeforeTheReplyWins() async throws {
        let controller = liveController()
        let reply = AsyncStream<SubspaceDoneOutcome>.makeStream()
        controller.installConversationFlag { _, _ in
            for await outcome in reply.stream { return outcome }
            return .failed
        }

        controller.setConversationFlag(conversationID, isFlagged: true)
        XCTAssertEqual(isShownFlagged(controller), true)
        // The Mac applied the flag, then the session started new work and
        // cleared it, both before the phone got its reply.
        controller.update(snapshot: snapshot(isFlagged: true, generation: 1), connectionState: .live, freshness: .live)
        controller.update(snapshot: snapshot(isFlagged: false, generation: 2), connectionState: .live, freshness: .live)
        reply.continuation.yield(.applied)
        try await waitUntil { controller.hasPendingConversationFlag == false }

        XCTAssertEqual(isShownFlagged(controller), false)
    }

    func testRefusalPutsTheFlagBackAndSaysSo() async throws {
        let controller = liveController()
        controller.installConversationFlag { _, _ in .refused }

        controller.setConversationFlag(conversationID, isFlagged: true)
        try await waitUntil { controller.subspaceDoneNotice?.kind == .failed }

        XCTAssertEqual(isShownFlagged(controller), false)
        XCTAssertEqual(controller.subspaceDoneNotice?.message, "Session is no longer running on your Mac.")
    }

    func testFlagIsReadOnlyWithoutHostSupportOrSendAccess() {
        var requests = 0
        let unsupported = liveController(supportsFlag: false)
        unsupported.installConversationFlag { _, _ in requests += 1; return .applied }
        XCTAssertFalse(unsupported.canFlagConversations)
        unsupported.setConversationFlag(conversationID, isFlagged: true)
        XCTAssertEqual(isShownFlagged(unsupported), false)
        XCTAssertEqual(requests, 0)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met in time", file: file, line: line)
    }
}

@MainActor
final class SubspaceDoneControllerTests: XCTestCase {
    private let parentID = UUID()
    private let subspaceID = UUID()

    private func snapshot(isDone: Bool, generation: Int = 0) -> MobileHomeSnapshot {
        MobileHomeSnapshot(hostName: "Mac \(generation)", workspaces: [
            MobileWorkspace(id: parentID, title: "parent", conversations: []),
            MobileWorkspace(
                id: subspaceID, title: "task", conversations: [],
                parentWorkspaceID: parentID, isDone: isDone
            ),
        ])
    }

    private func liveController(supportsDone: Bool = true) -> HomeScreenController {
        let controller = HomeScreenController(
            runtimeMode: .live(gatewayURL: URL(string: "https://toastty.example")!),
            snapshot: snapshot(isDone: false), connectionState: .live
        )
        controller.update(
            snapshot: snapshot(isDone: false), connectionState: .live, freshness: .live,
            hostSupportsSubspaceDone: supportsDone
        )
        return controller
    }

    private func isShownDone(_ controller: HomeScreenController) -> Bool? {
        controller.snapshot.subspaceRow(id: subspaceID)?.workspace.isDone
    }

    func testDoneShowsAtOnceAndTheMacsSnapshotConfirmsIt() async throws {
        let controller = liveController()
        let gate = AsyncStream<SubspaceDoneOutcome>.makeStream()
        var requests: [(UUID, Bool)] = []
        controller.installSubspaceDone { workspaceID, isDone in
            requests.append((workspaceID, isDone))
            for await outcome in gate.stream { return outcome }
            return .failed
        }

        controller.setSubspaceDone(subspaceID, isDone: true)
        XCTAssertEqual(isShownDone(controller), true)
        XCTAssertEqual(controller.hostSnapshot.subspaceRow(id: subspaceID)?.workspace.isDone, false)
        XCTAssertEqual(controller.subspaceDoneNotice?.message, "Marked done")
        XCTAssertEqual(controller.subspaceDoneNotice?.canUndo, true)

        // An unrelated snapshot that arrives first does not undo the check.
        controller.update(snapshot: snapshot(isDone: false, generation: 1), connectionState: .live, freshness: .live)
        XCTAssertEqual(isShownDone(controller), true)

        gate.continuation.yield(.applied)
        try await waitUntil { requests.count == 1 }
        controller.update(snapshot: snapshot(isDone: true, generation: 2), connectionState: .live, freshness: .live)
        XCTAssertEqual(isShownDone(controller), true)
        try await waitUntil { controller.hasPendingSubspaceDone == false }
        XCTAssertEqual(controller.snapshot, controller.hostSnapshot)
        XCTAssertEqual(requests.map(\.1), [true])

        // An agent starting new work clears the mark on the Mac.
        controller.update(snapshot: snapshot(isDone: false, generation: 3), connectionState: .live, freshness: .live)
        XCTAssertEqual(isShownDone(controller), false)
    }

    func testRefusalAndFailurePutTheRowBackAndSaySo() async throws {
        for (outcome, message) in [
            (SubspaceDoneOutcome.refused, "task can't be marked done right now."),
            (.failed, "Couldn't update task. Check the connection to your Mac."),
        ] {
            let controller = liveController()
            controller.installSubspaceDone { _, _ in outcome }

            controller.setSubspaceDone(subspaceID, isDone: true)
            XCTAssertEqual(isShownDone(controller), true)
            try await waitUntil { controller.subspaceDoneNotice?.kind == .failed }

            XCTAssertEqual(isShownDone(controller), false)
            XCTAssertEqual(controller.subspaceDoneNotice?.message, message)
            XCTAssertEqual(controller.subspaceDoneNotice?.canUndo, false)
        }
    }

    func testUndoSendsTheOppositeStateWithoutAnotherNotice() async throws {
        let controller = liveController()
        var requests: [Bool] = []
        controller.installSubspaceDone { _, isDone in
            requests.append(isDone)
            return .applied
        }

        controller.setSubspaceDone(subspaceID, isDone: true)
        try await waitUntil { requests == [true] }
        controller.update(snapshot: snapshot(isDone: true, generation: 1), connectionState: .live, freshness: .live)
        controller.undoSubspaceDoneNotice()

        XCTAssertNil(controller.subspaceDoneNotice)
        XCTAssertEqual(isShownDone(controller), false)
        try await waitUntil { requests == [true, false] }
    }

    func testUndoBeforeTheFirstReplyStillEndsOnTheLastStateAskedFor() async throws {
        let controller = liveController()
        let replies = [
            AsyncStream<SubspaceDoneOutcome>.makeStream(),
            AsyncStream<SubspaceDoneOutcome>.makeStream(),
        ]
        var requests: [Bool] = []
        controller.installSubspaceDone { _, isDone in
            requests.append(isDone)
            for await outcome in replies[requests.count - 1].stream { return outcome }
            return .failed
        }

        controller.setSubspaceDone(subspaceID, isDone: true)
        try await waitUntil { requests == [true] }
        controller.undoSubspaceDoneNotice()
        XCTAssertEqual(isShownDone(controller), false)
        // The Mac still shows the task open, which must not be mistaken for
        // the undo having arrived: the first request is still on its way.
        controller.update(snapshot: snapshot(isDone: false, generation: 1), connectionState: .live, freshness: .live)
        XCTAssertEqual(requests, [true], "Requests for one subspace go out one at a time")

        replies[0].continuation.yield(.applied)
        try await waitUntil { requests == [true, false] }
        // The snapshot from the first request arrives while the undo is on
        // its way.
        controller.update(snapshot: snapshot(isDone: true, generation: 2), connectionState: .live, freshness: .live)
        XCTAssertEqual(isShownDone(controller), false)

        replies[1].continuation.yield(.applied)
        controller.update(snapshot: snapshot(isDone: false, generation: 3), connectionState: .live, freshness: .live)
        try await waitUntil { controller.hasPendingSubspaceDone == false }
        XCTAssertEqual(isShownDone(controller), false)
        XCTAssertEqual(requests, [true, false])
    }

    func testTheSameSnapshotPresentedAgainDoesNotUndoAnAcceptedChange() async throws {
        let controller = liveController()
        let stamp = Date(timeIntervalSince1970: 1_788_696_000)
        func present(_ generation: Int, isDone: Bool, stamp: Date) {
            controller.update(
                snapshot: snapshot(isDone: isDone, generation: generation),
                connectionState: .live, freshness: .live, hostSnapshotStamp: stamp
            )
        }
        present(0, isDone: false, stamp: stamp)
        controller.installSubspaceDone { _, _ in .applied }

        controller.setSubspaceDone(subspaceID, isDone: true)
        try await waitUntil { controller.subspaceDoneNotice != nil }
        try await Task.sleep(for: .milliseconds(50))
        // A connection-state change presents the Mac's previous snapshot
        // again, with fresh ages, before the one carrying the change.
        present(1, isDone: false, stamp: stamp)
        XCTAssertEqual(isShownDone(controller), true)

        present(2, isDone: true, stamp: stamp.addingTimeInterval(1))
        XCTAssertEqual(isShownDone(controller), true)
        XCTAssertFalse(controller.hasPendingSubspaceDone)
    }

    func testDoneIsReadOnlyWithoutHostSupportOrALiveConnection() {
        var requests = 0
        let unsupported = liveController(supportsDone: false)
        unsupported.installSubspaceDone { _, _ in requests += 1; return .applied }
        XCTAssertFalse(unsupported.canMarkSubspacesDone)
        unsupported.setSubspaceDone(subspaceID, isDone: true)
        XCTAssertEqual(isShownDone(unsupported), false)

        let stale = liveController()
        stale.installSubspaceDone { _, _ in requests += 1; return .applied }
        stale.update(snapshot: snapshot(isDone: false), connectionState: .reconnecting, freshness: .reconnecting)
        XCTAssertFalse(stale.canMarkSubspacesDone)
        stale.setSubspaceDone(subspaceID, isDone: true)
        XCTAssertEqual(isShownDone(stale), false)

        // Only subspaces hold a mark.
        let live = liveController()
        live.installSubspaceDone { _, _ in requests += 1; return .applied }
        live.setSubspaceDone(parentID, isDone: true)
        XCTAssertNil(live.subspaceDoneNotice)
        XCTAssertEqual(requests, 0)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met in time", file: file, line: line)
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

    func testNextSessionQueueListsApprovalThenErrorThenReadyAndSkipsTheCurrentSession() {
        let controller = HomeScreenController(
            runtimeMode: .fixture,
            snapshot: ToasttyMobileFixture.home,
            connectionState: .live
        )
        func ids(_ numbers: [Int]) -> [UUID] {
            numbers.map { UUID(uuidString: String(format: "B1000000-0000-0000-0000-%012d", $0))! }
        }

        // Fixture: 1 (2m) and 9 (5m) need approval, 4 has an error, 7 (9m),
        // 3 (18m), 10 (25m) and 8 (3h) are ready. 12 is ready too, but its
        // subspace is marked done, so it is left out.
        XCTAssertEqual(
            controller.sessionsNeedingAttention(excluding: ids([7])[0]).map(\.id),
            ids([1, 9, 4, 3, 10, 8])
        )
        XCTAssertEqual(
            controller.sessionsNeedingAttention(excluding: ids([1])[0]).map(\.id),
            ids([9, 4, 7, 3, 10, 8])
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
