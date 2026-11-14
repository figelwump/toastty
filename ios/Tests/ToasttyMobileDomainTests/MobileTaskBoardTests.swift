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
        // The Mac's Merge control and action list for each task.
        XCTAssertEqual(review.mergeControl?.kind, .merge)
        XCTAssertEqual(review.mergeControl?.title, "Merge PR #263")
        XCTAssertEqual(review.mergeControl?.action?.action, .merge)
        XCTAssertEqual(review.mergeControl?.menu.map(\.action), [.archive])
        XCTAssertEqual(review.actions.map(\.action), [.merge, .archive])
        XCTAssertEqual(question.mergeControl?.kind, .archive)
        XCTAssertEqual(question.actions.map(\.action), [.markDone, .archive])
        XCTAssertEqual(board.task(id: uuid(304))?.actions.map(\.title), ["Retry Setup", "Delete Task"])
        XCTAssertNil(board.task(id: uuid(304))?.mergeControl)

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

        // Families: a child names its parent, a parent counts its merged
        // children, and a Done parent that is not on the board still has
        // its title.
        let child = try XCTUnwrap(board.task(id: uuid(305)))
        XCTAssertEqual(child.parentTaskID, uuid(301))
        XCTAssertEqual(child.parentTaskTitle, "iOS task support")
        XCTAssertEqual(board.parent(of: child)?.id, uuid(301))
        XCTAssertEqual(question.childProgress, RemoteTaskChildProgress(merged: 1, total: 2))
        XCTAssertNil(question.parentTaskID)
        XCTAssertNil(board.parent(of: question))
        let shipped = try XCTUnwrap(board.task(id: uuid(306)))
        XCTAssertEqual(shipped.parentTaskID, uuid(399))
        XCTAssertEqual(shipped.parentTaskTitle, "Mobile release prep")
        XCTAssertNil(board.parent(of: shipped))
        XCTAssertNil(review.parentTaskID)
        XCTAssertNil(review.childProgress)
        // The project card's To ship tasks come from the lane by project.
        XCTAssertEqual(board.toShipTasks(projectID: uuid(200)).map(\.id), [uuid(306)])
        XCTAssertEqual(board.toShipTasks(projectID: uuid(201)), [])
    }

    /// An older Mac sends no parent or child progress, and a value this
    /// phone cannot read reads as none. Neither drops a task.
    func testParentAndChildProgressAreOptional() throws {
        let older = UUID(), malformed = UUID(), outOfRange = UUID(), titleOnly = UUID()
        func task(_ id: UUID, extra: [String: Any] = [:]) -> [String: Any] {
            [
                "id": id.uuidString, "hasRecord": true, "title": "Task", "group": "running",
                "statusLine": "Line", "stageTitle": "Stage", "stageReason": "Why",
                "activityAt": "2026-11-06T12:00:00.000Z",
            ].merging(extra) { _, new in new }
        }
        let data = try JSONSerialization.data(withJSONObject: ["protocolVersion": "1.0", "snapshot": [
            "projectionRunID": UUID().uuidString, "conversations": [], "generatedAt": "2026-11-06T12:00:00.000Z",
            "tasks": [
                "tasks": [
                    task(older),
                    task(malformed, extra: [
                        "parentTaskID": "not-a-uuid", "parentTaskTitle": "Lost parent",
                        "childProgress": ["merged": "one", "total": 2],
                    ]),
                    task(outOfRange, extra: ["childProgress": ["merged": 3, "total": 2]]),
                    task(titleOnly, extra: ["parentTaskTitle": 7, "childProgress": "2/3"]),
                ],
                "needsYou": [], "running": [older, malformed, outOfRange, titleOnly].map { ["taskID": $0.uuidString] },
                "idle": [], "toShip": [], "doneCount": 0, "finishedByProject": [],
            ],
        ]])
        let board = try XCTUnwrap(GatewayCompatibilityDecoder().decodeSessionListResponse(data).presentation().taskBoard)
        XCTAssertEqual(board.tasks.map(\.id), [older, malformed, outOfRange, titleOnly])
        XCTAssertEqual(board.running.count, 4)
        for task in board.tasks {
            XCTAssertNil(task.parentTaskID)
            XCTAssertNil(task.parentTaskTitle)
            XCTAssertNil(task.childProgress)
        }
    }

    /// A lane's full task list and release fields are optional: an older
    /// Mac omits them, and a value this phone cannot read reads as none
    /// without losing the lane.
    func testALanesReleaseFieldsAreOptional() throws {
        let newest = UUID(), oldest = UUID(), project = UUID(), release = UUID()
        func task(_ id: UUID) -> [String: Any] {
            [
                "id": id.uuidString, "hasRecord": true, "title": "Task", "group": "to_ship", "mark": "to_ship",
                "statusLine": "Merged", "stageTitle": "To ship", "stageReason": "merged",
                "activityAt": "2026-11-06T12:00:00.000Z", "projectWorkspaceID": project.uuidString,
            ]
        }
        let lanes: [[String: Any]] = [
            [
                "id": "/repo/a", "projectTitle": "a", "count": 2, "recentTaskIDs": [newest.uuidString],
                // A task this phone was not sent is left out of the list.
                "taskIDs": [newest.uuidString, UUID().uuidString, oldest.uuidString],
                "releaseWorkspaceID": project.uuidString,
                // The release task need not be on the board.
                "releaseTaskID": release.uuidString,
            ],
            ["id": "/repo/b", "projectTitle": "b", "count": 1, "recentTaskIDs": [oldest.uuidString]],
            [
                "id": "/repo/c", "projectTitle": "c", "count": 1, "recentTaskIDs": [],
                "taskIDs": "all", "releaseWorkspaceID": "nope", "releaseTaskID": 7,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: ["protocolVersion": "1.0", "snapshot": [
            "projectionRunID": UUID().uuidString, "conversations": [], "generatedAt": "2026-11-06T12:00:00.000Z",
            "tasks": [
                "tasks": [task(newest), task(oldest)], "needsYou": [], "running": [], "idle": [],
                "toShip": lanes, "doneCount": 0, "finishedByProject": [],
            ],
        ]])
        let board = try XCTUnwrap(GatewayCompatibilityDecoder().decodeSessionListResponse(data).presentation().taskBoard)
        XCTAssertEqual(board.toShip.map(\.id), ["/repo/a", "/repo/b", "/repo/c"])
        XCTAssertEqual(board.toShip[0].taskIDs, [newest, oldest])
        XCTAssertEqual(board.toShip[0].releaseWorkspaceID, project)
        XCTAssertEqual(board.toShip[0].releaseTaskID, release)
        for lane in board.toShip.dropFirst() {
            XCTAssertNil(lane.taskIDs)
            XCTAssertNil(lane.releaseWorkspaceID)
            XCTAssertNil(lane.releaseTaskID)
        }
        XCTAssertFalse(board.listsEveryToShipTask)
        // Each lane lists what the Mac sent: all, or the newest few.
        XCTAssertEqual(MobileTaskSections.make(board).toShip.map { $0.tasks.map(\.id) }, [[newest, oldest], [oldest], []])
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

    /// The Merge control and the actions come from the Mac. A newer Mac may
    /// add control kinds and actions: an unknown kind shows no control, and
    /// an unknown action is left out of its list and menu.
    func testMergeControlAndActionsDecodeAndUnknownOnesAreLeftOut() throws {
        let merge = UUID(), newer = UUID(), older = UUID()
        func task(_ id: UUID, extra: [String: Any]) -> [String: Any] {
            [
                "id": id.uuidString, "hasRecord": true, "title": "Task", "group": "needs_you",
                "statusLine": "Ready for your review", "stageTitle": "Review", "stageReason": "PR open, agent idle",
                "activityAt": "2026-11-06T12:00:00.000Z",
            ].merging(extra) { _, new in new }
        }
        let data = try JSONSerialization.data(withJSONObject: ["protocolVersion": "1.0", "snapshot": [
            "projectionRunID": UUID().uuidString, "conversations": [], "generatedAt": "2026-11-06T12:00:00.000Z",
            "tasks": [
                "tasks": [
                    task(merge, extra: [
                        "mergeControl": [
                            "kind": "open_pull_request", "title": "Open PR #263", "detail": "Checks failing",
                            "menu": [
                                ["action": "merge", "title": "Merge PR #263"],
                                ["action": "merge_without_checks", "title": "Merge Without Checks"],
                                ["action": "archive", "title": "Archive Task…"],
                            ],
                        ],
                        "actions": [
                            ["action": "merge", "title": "Merge"],
                            ["action": "release", "title": "Release"],
                            ["action": "archive", "title": "Archive…"],
                        ],
                        "releaseAfterMergeRequestedAt": "2026-11-05T09:30:00.000Z",
                    ]),
                    task(newer, extra: ["mergeControl": ["kind": "queued", "title": "Queued", "menu": []]]),
                    task(older, extra: [:]),
                ],
                "needsYou": [["taskID": merge.uuidString]], "running": [], "idle": [], "toShip": [],
                "doneCount": 0, "finishedByProject": [],
            ],
        ]])
        let board = try XCTUnwrap(GatewayCompatibilityDecoder().decodeSessionListResponse(data).presentation().taskBoard)
        let task = try XCTUnwrap(board.task(id: merge))
        XCTAssertEqual(task.mergeControl, RemoteTaskMergeControl(
            kind: .openPullRequest,
            title: "Open PR #263",
            detail: "Checks failing",
            menu: [
                RemoteTaskActionItem(action: .merge, title: "Merge PR #263"),
                RemoteTaskActionItem(action: .archive, title: "Archive Task…"),
            ]
        ))
        XCTAssertEqual(task.actions.map(\.action), [.merge, .archive])
        XCTAssertTrue(task.offers(.merge))
        XCTAssertFalse(task.offers(.delete))
        XCTAssertNil(board.task(id: newer)?.mergeControl)
        XCTAssertNil(board.task(id: older)?.mergeControl)
        XCTAssertEqual(board.task(id: older)?.actions, [])
        // The request to release right after the merge, which a later
        // release of this app can show. Older Macs do not send it.
        XCTAssertEqual(task.releaseAfterMergeRequestedAt, ISO8601DateFormatter().date(from: "2026-11-05T09:30:00Z"))
        XCTAssertNotNil(task.releaseAfterMergeRequestedAt)
        XCTAssertNil(board.task(id: older)?.releaseAfterMergeRequestedAt)
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
