import RemoteProtocol
import XCTest
@testable import ToasttyMobileDomain

/// The task board the Mac sends in the session snapshot, as Home reads it.
final class MobileTaskBoardTests: XCTestCase {
    func testCanonicalHostBoardDecodes() throws {
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "v1", withExtension: nil))
        let snapshot = try GatewayCompatibilityDecoder().decodeSessionListResponse(Data(
            contentsOf: directory.appending(path: "session-list-with-tasks.json", directoryHint: .notDirectory)))
        let board = try XCTUnwrap(snapshot.presentation().taskBoard)

        XCTAssertEqual(board.tasks.count, 6)
        let question = try XCTUnwrap(board.task(taskSpaceID: uuid(201)))
        XCTAssertEqual(question.title, "iOS task support")
        XCTAssertEqual(question.group, .needsYou)
        XCTAssertEqual(question.mark, .question)
        XCTAssertEqual(question.rowSummary, "Asks: Badge counts tasks or sessions?")
        XCTAssertEqual(question.projectWorkspaceID, uuid(200))
        let review = try XCTUnwrap(board.task(id: uuid(302)))
        XCTAssertEqual(review.pullRequest, RemoteTaskPullRequest(
            number: 263, url: URL(string: "https://github.com/example/toastty/pull/263")!, state: .open
        ))
        XCTAssertEqual(board.task(id: uuid(203))?.hasRecord, false)

        XCTAssertEqual(board.needsYou.map(\.taskID), [uuid(301), uuid(305), uuid(302), uuid(304)])
        XCTAssertEqual(board.needsYou[1], RemoteTaskBoardEntry(taskID: uuid(305), isLinkedChild: true, isContext: true))
        // The dimmed child's own stage is Running, so it does not count.
        XCTAssertEqual(board.count(.needsYou), 3)
        XCTAssertEqual(board.toShip, [
            RemoteTaskShipLane(id: "/Users/example/toastty", projectTitle: "toastty", count: 3, recentTaskIDs: [uuid(306)]),
        ])
        XCTAssertEqual(board.doneCount, 12)
        XCTAssertEqual(board.finished(projectID: uuid(200)),
                       RemoteTaskProjectTally(projectWorkspaceID: uuid(200), toShipCount: 3, doneCount: 12))
    }

    func testAnOlderHostSendsNoBoard() throws {
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "v1", withExtension: nil))
        let snapshot = try GatewayCompatibilityDecoder().decodeSessionListResponse(Data(
            contentsOf: directory.appending(path: "session-list-response.json", directoryHint: .notDirectory)))
        XCTAssertNil(snapshot.presentation().taskBoard)
    }

    /// A newer Mac may add groups, marks and pull request states. A task in
    /// a group this phone does not know is left out with its rows; an
    /// unknown mark or state reads as none.
    func testUnknownValuesFromANewerMacAreLeftOut() throws {
        let known = UUID(), unknownGroup = UUID()
        func task(_ id: UUID, group: String, mark: String?) -> [String: Any] {
            var task: [String: Any] = [
                "id": id.uuidString, "hasRecord": true, "title": "Task", "group": group,
                "statusLine": "Line", "stageTitle": "Stage", "stageReason": "Why",
                "activityAt": "2026-11-06T12:00:00.000Z",
                "pullRequest": ["number": 7, "url": "https://github.com/example/toastty/pull/7", "state": "queued"],
            ]
            task["mark"] = mark
            return task
        }
        let data = try JSONSerialization.data(withJSONObject: ["protocolVersion": "1.0", "snapshot": [
            "projectionRunID": UUID().uuidString, "conversations": [], "generatedAt": "2026-11-06T12:00:00.000Z",
            "tasks": [
                "tasks": [task(known, group: "needs_you", mark: "blocked"), task(unknownGroup, group: "paused", mark: nil)],
                "needsYou": [["taskID": known.uuidString], ["taskID": unknownGroup.uuidString], ["taskID": "nope"]],
                "running": [], "idle": [], "toShip": [], "doneCount": 2, "finishedByProject": [],
            ],
        ]])
        let board = try XCTUnwrap(GatewayCompatibilityDecoder().decodeSessionListResponse(data).presentation().taskBoard)
        XCTAssertEqual(board.tasks.map(\.id), [known])
        XCTAssertEqual(board.needsYou.map(\.taskID), [known])
        XCTAssertNil(board.task(id: known)?.mark)
        XCTAssertEqual(board.task(id: known)?.pullRequest?.number, 7)
        XCTAssertNil(board.task(id: known)?.pullRequest?.state)
        XCTAssertEqual(board.doneCount, 2)
    }

    /// The Mac sidebar's rule: an agent that works or wants the user shows
    /// first; otherwise the task's stage decides the mark.
    func testATaskSpaceRowShowsItsTaskUnlessAnAgentNeedsTheUser() {
        func status(_ session: MobileSessionStatus?, mark: RemoteTaskMark?, isDone: Bool = false) -> MobileSubspaceStatus {
            row(session, mark: mark, isDone: isDone).status
        }
        XCTAssertEqual(status(.ready, mark: .question), .question)
        XCTAssertEqual(status(.idle, mark: .review), .review)
        XCTAssertEqual(status(nil, mark: .toShip), .toShip)
        XCTAssertEqual(status(.idle, mark: .done), .done)
        XCTAssertEqual(status(nil, mark: .starting), .working)
        XCTAssertEqual(status(.needsApproval, mark: .question), .needsApproval)
        XCTAssertEqual(status(.error, mark: .review), .error)
        XCTAssertEqual(status(.working, mark: .done), .working)
        // A task in a calm stage shows its sessions; its stage already
        // counts a done mark that finishes it.
        XCTAssertEqual(status(.ready, mark: nil), .ready)
        XCTAssertEqual(status(.idle, mark: nil, isDone: true), .idle)
        // A subspace without a task keeps the done mark rule.
        XCTAssertEqual(row(.ready, mark: nil, isDone: true, hasTask: false).status, .done)

        let question = row(.ready, mark: .question)
        XCTAssertEqual(question.summary, "Asks: which badge?")
        XCTAssertEqual(question.status.pillLabel, "question")
        XCTAssertNil(row(.idle, mark: .review).status.pillLabel)
    }

    func testAFinishedTaskLeavesItsProjectUnlessAnAgentIsStillBusy() {
        let parentID = UUID()
        let quietDone = row(.idle, mark: .done, parentID: parentID)
        let busyDone = row(.working, mark: .done, parentID: parentID)
        let shipped = row(nil, mark: .toShip, parentID: parentID)
        let open = row(.ready, mark: .question, parentID: parentID)
        XCTAssertTrue(quietDone.isHiddenAsFinished)
        XCTAssertFalse(busyDone.isHiddenAsFinished)
        XCTAssertTrue(shipped.isHiddenAsFinished)
        XCTAssertFalse(open.isHiddenAsFinished)

        let parent = MobileWorkspace(id: parentID, title: "toastty", conversations: [])
        let workspaces = [parent] + [quietDone, busyDone, shipped, open].map(\.workspace)
        let tasks = [quietDone, busyDone, shipped, open].compactMap(\.task)
        let withBoard = MobileHomeSnapshot(
            hostName: "Mac", workspaces: workspaces, taskBoard: MobileTaskBoard(RemoteTaskBoard(tasks: tasks))
        )
        XCTAssertEqual(Set(withBoard.subspaceRows(of: parentID).map(\.id)), [busyDone.id, open.id])
        // The row stays reachable by ID, for a Status row or a detail card.
        XCTAssertEqual(withBoard.subspaceRow(id: quietDone.id)?.status, .done)
        // Without the task system, nothing leaves the list.
        let withoutBoard = MobileHomeSnapshot(hostName: "Mac", workspaces: workspaces)
        XCTAssertEqual(withoutBoard.subspaceRows(of: parentID).count, 4)
    }

    private func row(
        _ session: MobileSessionStatus?,
        mark: RemoteTaskMark?,
        isDone: Bool = false,
        hasTask: Bool = true,
        parentID: UUID = UUID()
    ) -> MobileSubspaceRow {
        let workspaceID = UUID()
        let conversations = session.map { status in
            [MobileConversation(
                id: UUID(), workspaceID: workspaceID, workspaceTitle: "task", cwd: nil, agent: .codex,
                title: "Agent", state: status, inputAvailability: .unavailable(reason: "test"),
                age: "now", lastActivity: "Last line"
            )]
        } ?? []
        let workspace = MobileWorkspace(
            id: workspaceID, title: "task", conversations: conversations, parentWorkspaceID: parentID, isDone: isDone
        )
        let task = hasTask ? RemoteTaskSummary(
            id: UUID(), title: "task", group: mark == .done ? .done : .needsYou, mark: mark,
            statusLine: "Line", rowSummary: mark == .question ? "Asks: which badge?" : nil,
            stageTitle: "Stage", stageReason: "Why", projectWorkspaceID: parentID,
            taskSpaceWorkspaceID: workspaceID, activityAt: Date()
        ) : nil
        return MobileSubspaceRow(workspace: workspace, task: task)
    }

    private func uuid(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
    }
}
