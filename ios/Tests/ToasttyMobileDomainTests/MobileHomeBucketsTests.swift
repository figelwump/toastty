import RemoteProtocol
import XCTest
@testable import ToasttyMobileDomain

/// Home's project cards: the Mac sidebar's buckets built from the phone's
/// snapshot and task board, and the Tasks tab's groups.
final class MobileHomeBucketsTests: XCTestCase {
    private static let defaultProjectID = UUID(uuidString: "A2000000-0000-0000-0000-000000000001")!
    private let projectID = MobileHomeBucketsTests.defaultProjectID
    private let otherProjectID = UUID(uuidString: "A2000000-0000-0000-0000-000000000002")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSessionsGoWhereTheirStateAsksForTheUser() throws {
        let card = try XCTUnwrap(cards(
            sessions: [
                session(1, "Approval", .needsApproval),
                session(2, "Unread turn", .ready),
                session(3, "Read turn", .idle),
                session(4, "Working", .working),
                session(5, "Failed", .error),
            ],
            board: RemoteTaskBoard()
        ).first)
        // On the wire `ready` is a finished turn the user has not read; a
        // turn they read is `idle`.
        XCTAssertEqual(names(card, .needsYou), ["Approval", "Unread turn", "Failed"])
        XCTAssertEqual(names(card, .running), ["Working"])
        XCTAssertEqual(names(card, .idle), ["Read turn"])
        XCTAssertEqual(card.counts, [.needsYou: 3, .running: 1, .idle: 1])
    }

    func testATaskSpaceTakesItsTasksBucketButAnApprovalBeatsAReview() throws {
        let approval = taskSpace(11, "Approval in review", session: .needsApproval)
        let unreadReview = taskSpace(12, "Unread review", session: .ready)
        let question = taskSpace(13, "Question", session: .idle)
        let failedSetup = taskSpace(14, "Failed setup", session: .idle)
        let board = RemoteTaskBoard(tasks: [
            task(21, "Approval in review", .needsYou, mark: .review, taskSpace: approval.id),
            task(22, "Unread review", .needsYou, mark: .review, taskSpace: unreadReview.id),
            task(23, "Question", .needsYou, mark: .question, taskSpace: question.id),
            // No agent asks anything, but the task's stage needs the user.
            task(24, "Failed setup", .needsYou, taskSpace: failedSetup.id),
        ])
        let card = try XCTUnwrap(cards(subspaces: [approval, unreadReview, question, failedSetup], board: board).first)
        XCTAssertEqual(names(card, .needsYou), ["Approval in review", "Question", "Failed setup"])
        // The review shows over the turn the agent finished when it opened
        // the pull request.
        XCTAssertEqual(names(card, .readyToReview), ["Unread review"])
    }

    func testAReviewTaskIsReadyToReviewAndOtherNeedsYouTasksNeedYou() throws {
        let board = RemoteTaskBoard(tasks: [
            task(21, "Open PR", .needsYou, mark: .review),
            task(22, "Asks", .needsYou, mark: .question),
            task(23, "Setup failed", .needsYou),
            task(24, "Starting", .running, mark: .starting),
            task(25, "Quiet", .idle),
            // To ship and Done list on the To ship line, not in a bucket.
            task(26, "Merged", .toShip, mark: .toShip),
            task(27, "Finished", .done, mark: .done),
        ])
        let card = try XCTUnwrap(cards(board: board).first)
        XCTAssertEqual(names(card, .readyToReview), ["Open PR"])
        XCTAssertEqual(names(card, .needsYou), ["Asks", "Setup failed"])
        XCTAssertEqual(names(card, .running), ["Starting"])
        XCTAssertEqual(names(card, .idle), ["Quiet"])
        XCTAssertEqual(card.counts, [.readyToReview: 1, .needsYou: 2, .running: 1, .idle: 1])
    }

    func testAFamilyListsInItsMostUrgentMembersBucketWithCalmerMembersDimmed() throws {
        let parentSpace = taskSpace(11, "Parent", session: .working)
        let board = RemoteTaskBoard(tasks: [
            task(21, "Parent", .running, taskSpace: parentSpace.id, childProgress: RemoteTaskChildProgress(merged: 1, total: 3)),
            task(22, "Child asks", .needsYou, mark: .question, parent: 21),
            task(23, "Child idle", .idle, parent: 21),
            task(24, "Unrelated", .running),
        ])
        let card = try XCTUnwrap(cards(subspaces: [parentSpace], board: board).first)
        let needsYou = card.layout.entries(.needsYou)
        XCTAssertEqual(needsYou.map(label), ["Parent (dimmed)", "  Child asks", "  Child idle (dimmed)"])
        // The parent is a task space row; its children key to it.
        XCTAssertEqual(needsYou.first?.key, .workspace(parentSpace.id))
        XCTAssertEqual(needsYou.first?.payload.task?.childProgress, RemoteTaskChildProgress(merged: 1, total: 3))
        XCTAssertEqual(names(card, .running), ["Unrelated"])
        XCTAssertTrue(card.layout.entries(.idle).isEmpty)
        // Each row counts where its own state is.
        XCTAssertEqual(card.counts, [.running: 2, .needsYou: 1, .idle: 1])
    }

    func testRowsKeepTheirOrderInsideABucket() throws {
        let first = taskSpace(11, "Space opened first", session: .ready)
        let second = taskSpace(12, "Space opened second", session: .needsApproval)
        let board = RemoteTaskBoard(tasks: [
            task(21, "Task created first", .needsYou),
            task(22, "Task created second", .needsYou),
        ])
        let card = try XCTUnwrap(cards(
            sessions: [session(1, "Session B", .ready), session(2, "Session A", .needsApproval)],
            subspaces: [first, second],
            board: board
        ).first)
        // Sessions in the snapshot's order, then task spaces in the order
        // they opened, then tasks without a task space, whatever their
        // status.
        XCTAssertEqual(names(card, .needsYou), [
            "Session B", "Session A", "Space opened first", "Space opened second",
            "Task created first", "Task created second",
        ])
    }

    func testTasksWithoutAnOpenProjectGoToOtherTasks() throws {
        let board = RemoteTaskBoard(
            tasks: [
                task(21, "In project", .idle),
                task(22, "Project closed", .needsYou, project: otherProjectID),
                task(23, "No project", .running, project: nil),
                task(24, "Merged elsewhere", .toShip, mark: .toShip, project: otherProjectID),
            ],
            toShip: [RemoteTaskShipLane(id: "/elsewhere", projectTitle: "elsewhere", count: 2, recentTaskIDs: [uuid(24)])],
            doneCount: 5,
            finishedByProject: [
                RemoteTaskProjectTally(projectWorkspaceID: projectID, toShipCount: 0, doneCount: 3),
                RemoteTaskProjectTally(projectWorkspaceID: otherProjectID, toShipCount: 2, doneCount: 2),
            ]
        )
        let all = cards(board: board)
        XCTAssertEqual(all.map(\.title), ["toastty", MobileHomeBuckets.otherTasksCardTitle])
        XCTAssertEqual(names(all[0], .idle), ["In project"])
        XCTAssertEqual(all[0].doneCount, 3)
        let other = all[1]
        XCTAssertTrue(other.isOtherTasks)
        XCTAssertEqual(other.id, MobileHomeBuckets.otherTasksCardID)
        XCTAssertEqual(names(other, .needsYou), ["Project closed"])
        XCTAssertEqual(names(other, .running), ["No project"])
        // The board's totals less what the open project counts.
        XCTAssertEqual(other.toShipCount, 2)
        XCTAssertEqual(other.doneCount, 2)
        XCTAssertEqual(other.toShipTasks.map(\.title), ["Merged elsewhere"])
    }

    func testAProjectCardListsItsToShipTasksThatHaveNoRow() throws {
        let working = taskSpace(11, "Still working", session: .working)
        let board = RemoteTaskBoard(
            tasks: [
                task(21, "Still working", .toShip, mark: .toShip, taskSpace: working.id),
                task(22, "Merged", .toShip, mark: .toShip),
            ],
            toShip: [RemoteTaskShipLane(id: "/toastty", projectTitle: "toastty", count: 2, recentTaskIDs: [uuid(22), uuid(21)])],
            finishedByProject: [RemoteTaskProjectTally(projectWorkspaceID: projectID, toShipCount: 2, doneCount: 0)]
        )
        let card = try XCTUnwrap(cards(subspaces: [working], board: board).first)
        // A To ship task space where an agent works keeps its row.
        XCTAssertEqual(names(card, .running), ["Still working"])
        XCTAssertEqual(card.toShipTasks.map(\.title), ["Merged"])
        XCTAssertEqual(card.toShipCount, 2)
        XCTAssertEqual(cards(subspaces: [working], board: board).count, 1)
    }

    /// The Mac sends every To ship task and where Release starts. Two open
    /// projects can share a root, so one lane holds both projects' tasks:
    /// each card lists and counts its own, and releases from its own project.
    func testCardsAndLanesListEveryToShipTaskAndOfferTheRelease() throws {
        func board(releaseWorkspaceID: UUID?, releaseTaskID: UUID? = nil, sendsEveryTask: Bool = true) -> RemoteTaskBoard {
            RemoteTaskBoard(
                tasks: [
                    task(31, "Newest", .toShip, mark: .toShip),
                    task(32, "Other project's", .toShip, mark: .toShip, project: otherProjectID),
                    task(33, "Oldest", .toShip, mark: .toShip),
                ],
                toShip: [RemoteTaskShipLane(
                    id: "/toastty", projectTitle: "toastty", count: 3,
                    recentTaskIDs: [uuid(31)],
                    taskIDs: sendsEveryTask ? [uuid(31), uuid(32), uuid(33)] : nil,
                    releaseWorkspaceID: releaseWorkspaceID,
                    releaseTaskID: releaseTaskID
                )],
                finishedByProject: [
                    RemoteTaskProjectTally(projectWorkspaceID: projectID, toShipCount: 2, doneCount: 0),
                    RemoteTaskProjectTally(projectWorkspaceID: otherProjectID, toShipCount: 1, doneCount: 0),
                ]
            )
        }
        func cards(_ board: RemoteTaskBoard) -> [MobileHomeCard] {
            MobileHomeBuckets.cards(in: MobileHomeSnapshot(
                hostName: "mac",
                workspaces: [
                    MobileWorkspace(id: projectID, title: "toastty", conversations: []),
                    MobileWorkspace(id: otherProjectID, title: "toastty-2", conversations: []),
                ],
                taskBoard: MobileTaskBoard(board)
            ))
        }
        func lane(_ board: RemoteTaskBoard) throws -> MobileTaskSections.Lane {
            try XCTUnwrap(MobileTaskSections.make(MobileTaskBoard(board)).toShip.first)
        }

        var all = cards(board(releaseWorkspaceID: otherProjectID))
        XCTAssertEqual(all[0].toShipTasks.map(\.title), ["Newest", "Oldest"])
        XCTAssertEqual(all[0].toShipCount, 2)
        XCTAssertEqual(all[1].toShipTasks.map(\.title), ["Other project's"])
        XCTAssertEqual(all[1].toShipCount, 1)
        XCTAssertEqual(all[0].release, MobileProjectRelease(
            laneID: "/toastty", projectTitle: "toastty", workspaceID: projectID, taskCount: 3,
            taskTitles: ["Newest", "Other project's", "Oldest"]
        ))
        XCTAssertEqual(all[1].release?.workspaceID, otherProjectID)
        // The Tasks tab's lane lists them all and releases where the Mac said.
        XCTAssertEqual(try lane(board(releaseWorkspaceID: otherProjectID)).tasks.count, 3)
        XCTAssertEqual(try lane(board(releaseWorkspaceID: otherProjectID)).release?.workspaceID, otherProjectID)
        XCTAssertEqual(try lane(board(releaseWorkspaceID: otherProjectID)).release?.isReleasing, false)

        // While a release runs, both read Releasing….
        let releasing = board(releaseWorkspaceID: projectID, releaseTaskID: uuid(40))
        XCTAssertEqual(cards(releasing)[0].release?.isReleasing, true)
        XCTAssertEqual(try lane(releasing).release?.releaseTaskID, uuid(40))

        // A project that cannot release offers no Release.
        XCTAssertNil(cards(board(releaseWorkspaceID: nil))[0].release)
        XCTAssertNil(try lane(board(releaseWorkspaceID: nil)).release)

        // An older Mac sends only the newest tasks and no release: the card
        // still counts all of the project's tasks.
        all = cards(board(releaseWorkspaceID: nil, sendsEveryTask: false))
        XCTAssertEqual(all[0].toShipTasks.map(\.title), ["Newest"])
        XCTAssertEqual(all[0].toShipCount, 2)
        XCTAssertEqual(try lane(board(releaseWorkspaceID: nil, sendsEveryTask: false)).tasks.map(\.title), ["Newest"])
    }

    func testHiddenRowsLeaveTheBucketsButStillCount() throws {
        let card = try XCTUnwrap(MobileHomeBuckets.cards(
            in: snapshot(sessions: [session(1, "Shown", .ready), session(2, "Hidden", .ready)], board: RemoteTaskBoard()),
            hiding: [.conversation(uuid(2, prefix: "B2"))]
        ).first)
        XCTAssertEqual(names(card, .needsYou), ["Shown"])
        XCTAssertEqual(card.counts, [.needsYou: 2])
    }

    func testNoBoardMeansNoCards() {
        XCTAssertTrue(MobileHomeBuckets.cards(in: snapshot(sessions: [session(1, "Approval", .needsApproval)], board: nil)).isEmpty)
    }

    /// The Tasks tab splits Needs you as the Mac's Tasks view does: a family
    /// whose only members that need the user wait for a review lists under
    /// Ready to review.
    func testTasksTabListsToShipFirstAndSplitsReviewsFromNeedsYou() {
        let board = MobileTaskBoard(RemoteTaskBoard(
            tasks: [
                task(21, "Asks", .needsYou, mark: .question),
                task(22, "Review parent", .needsYou, mark: .review),
                task(23, "Review child", .needsYou, mark: .review, parent: 22),
                task(24, "Mixed parent", .needsYou, mark: .review),
                task(25, "Mixed child asks", .needsYou, mark: .question, parent: 24),
                task(26, "Running parent", .running, childProgress: RemoteTaskChildProgress(merged: 0, total: 1)),
                task(27, "Child of running", .needsYou, mark: .question, parent: 26),
                task(28, "Quiet", .idle),
                task(29, "Merged", .toShip, mark: .toShip),
            ],
            toShip: [RemoteTaskShipLane(id: "/toastty", projectTitle: "toastty", count: 4, recentTaskIDs: [uuid(29)])],
            doneCount: 7
        ))
        let sections = MobileTaskSections.make(board)
        XCTAssertEqual(sections.toShip.map(\.projectTitle), ["toastty"])
        XCTAssertEqual(sections.toShip.first?.tasks.map(\.title), ["Merged"])
        XCTAssertEqual(sections.toShipCount, 4)
        XCTAssertEqual(sections.laneID(projectID: projectID), "/toastty")
        XCTAssertNil(sections.laneID(projectID: otherProjectID))
        XCTAssertEqual(sections.needsYou.map(label), ["Asks", "Mixed parent (dimmed)", "  Mixed child asks", "Child of running"])
        XCTAssertEqual(sections.readyToReview.map(label), ["Review parent", "  Review child"])
        // A child whose parent is in another group lists in its own group.
        XCTAssertEqual(sections.running.map(label), ["Running parent"])
        XCTAssertEqual(sections.idle.map(label), ["Quiet"])
        XCTAssertEqual(sections.count(.needsYou), 4)
        XCTAssertEqual(sections.count(.readyToReview), 2)
        XCTAssertEqual(sections.doneCount, 7)
        XCTAssertTrue(MobileTaskSections.make(MobileTaskBoard(RemoteTaskBoard())).isEmpty)
    }

    // MARK: - Helpers

    private func uuid(_ number: Int, prefix: String = "D2") -> UUID {
        UUID(uuidString: String(format: "\(prefix)000000-0000-0000-0000-%012d", number))!
    }

    private func session(_ number: Int, _ title: String, _ status: RemoteSessionPresentationStatus, workspace: UUID? = nil) -> MobileConversation {
        MobileConversation(
            id: uuid(number, prefix: "B2"), workspaceID: workspace ?? projectID, workspaceTitle: "toastty", cwd: nil,
            agent: .claude, title: title, state: .known(status), inputAvailability: .openPrompt, age: "1m",
            activityAge: nil, lastActivity: title
        )
    }

    private func taskSpace(_ number: Int, _ title: String, session status: RemoteSessionPresentationStatus) -> MobileWorkspace {
        let id = uuid(number, prefix: "A2")
        return MobileWorkspace(
            id: id, title: title,
            conversations: [session(100 + number, "\(title) session", status, workspace: id)],
            parentWorkspaceID: projectID
        )
    }

    private func task(
        _ number: Int, _ title: String, _ group: RemoteTaskGroup, mark: RemoteTaskMark? = nil,
        project: UUID? = MobileHomeBucketsTests.defaultProjectID, taskSpace: UUID? = nil, parent: Int? = nil,
        childProgress: RemoteTaskChildProgress? = nil
    ) -> RemoteTaskSummary {
        RemoteTaskSummary(
            id: uuid(number), title: title, group: group, mark: mark, statusLine: title,
            stageTitle: "", stageReason: "",
            projectWorkspaceID: project, projectTitle: project == nil ? nil : "toastty",
            taskSpaceWorkspaceID: taskSpace, activityAt: now,
            parentTaskID: parent.map { uuid($0) }, childProgress: childProgress
        )
    }

    private func snapshot(
        sessions: [MobileConversation] = [], subspaces: [MobileWorkspace] = [], board: RemoteTaskBoard?
    ) -> MobileHomeSnapshot {
        MobileHomeSnapshot(
            hostName: "mac",
            workspaces: [MobileWorkspace(id: projectID, title: "toastty", conversations: sessions)] + subspaces,
            taskBoard: board.map(MobileTaskBoard.init)
        )
    }

    private func cards(
        sessions: [MobileConversation] = [], subspaces: [MobileWorkspace] = [], board: RemoteTaskBoard
    ) -> [MobileHomeCard] {
        MobileHomeBuckets.cards(in: snapshot(sessions: sessions, subspaces: subspaces, board: board))
    }

    private func names(_ card: MobileHomeCard, _ bucket: TaskBucket) -> [String] {
        card.layout.entries(bucket).map(label)
    }

    private func label(_ entry: MobileHomeBucketEntry) -> String {
        let title = switch entry.payload {
        case .conversation(let conversation): conversation.title
        case .subspace(let row): row.title
        case .task(let task): task.title
        }
        return (entry.isLinkedChild ? "  " : "") + title + (entry.isContext ? " (dimmed)" : "")
    }

    private func label(_ entry: MobileTaskSections.Entry) -> String {
        (entry.isLinkedChild ? "  " : "") + entry.task.title + (entry.isContext ? " (dimmed)" : "")
    }
}
