import Foundation
import RemoteProtocol

// MARK: - Task families

/// Parent tasks whose agents ended their turns to wait on other tasks, as in
/// the user's screenshots of 2026-11-17. The Mac lists such a task as
/// Running (`TaskStage`: an agent that waits on another task is still
/// running, read or not), while its task space's unread turn makes the row
/// "ready".
public extension ToasttyMobileFixture {
    static let familiesWorkspaceID = UUID(uuidString: "A4000000-0000-0000-0000-000000000001")!
    /// Waits on a task that is not its child, with an unread turn; its one
    /// child merged.
    static let familiesUnreadSubspaceID = UUID(uuidString: "A4000000-0000-0000-0000-000000000011")!
    /// Waits on its running child, with an unread turn.
    static let familiesUnreadParentSubspaceID = UUID(uuidString: "A4000000-0000-0000-0000-000000000012")!
    static let familiesUnreadChildSubspaceID = UUID(uuidString: "A4000000-0000-0000-0000-000000000013")!
    /// A second child of that parent, whose finished turn is unread.
    static let familiesFinishedChildSubspaceID = UUID(uuidString: "A4000000-0000-0000-0000-000000000016")!
    /// Waits on its running child, with its turn read.
    static let familiesReadParentSubspaceID = UUID(uuidString: "A4000000-0000-0000-0000-000000000014")!
    static let familiesReadChildSubspaceID = UUID(uuidString: "A4000000-0000-0000-0000-000000000015")!

    static let familiesUnreadTaskID = UUID(uuidString: "D4000000-0000-0000-0000-000000000001")!
    static let familiesUnreadParentTaskID = UUID(uuidString: "D4000000-0000-0000-0000-000000000002")!
    static let familiesUnreadChildTaskID = UUID(uuidString: "D4000000-0000-0000-0000-000000000003")!
    static let familiesFinishedChildTaskID = UUID(uuidString: "D4000000-0000-0000-0000-000000000006")!
    static let familiesReadParentTaskID = UUID(uuidString: "D4000000-0000-0000-0000-000000000004")!
    static let familiesReadChildTaskID = UUID(uuidString: "D4000000-0000-0000-0000-000000000005")!

    /// One project with three parents that wait on other tasks: two with
    /// an unread turn (one of them with a running child and a child whose own
    /// turn is unread) and one whose turn was read, with a running child.
    static let familiesTaskHome: MobileHomeSnapshot = {
        let projectID = familiesWorkspaceID
        let now = Date()
        func space(
            _ id: UUID, _ title: String, number: Int, status: RemoteSessionPresentationStatus, last: String
        ) -> MobileWorkspace {
            MobileWorkspace(
                id: id,
                title: title,
                conversations: [
                    conversation(
                        number, workspaceID: id, workspaceTitle: title,
                        cwd: "~/GiantThings/repos/emptyos-\(title)", agent: .claude,
                        title: "", status: status,
                        availability: status == .working
                            ? .unavailable(reason: "working") : .unavailable(reason: "prompt not open"),
                        age: status == .working ? "now" : "2m", last: last
                    ),
                ],
                parentWorkspaceID: projectID
            )
        }
        func task(
            _ id: UUID, _ title: String, status: String, taskSpace: UUID,
            parent: (id: UUID, title: String)? = nil, childProgress: RemoteTaskChildProgress? = nil,
            finished: Bool = false
        ) -> RemoteTaskSummary {
            RemoteTaskSummary(
                id: id, title: title, group: finished ? .needsYou : .running, statusLine: status,
                stageTitle: finished ? "Needs you" : "Running", stageReason: finished ? "the agent finished a turn" : status,
                projectWorkspaceID: projectID, projectTitle: "emptyos", taskSpaceWorkspaceID: taskSpace,
                activityAt: now, parentTaskID: parent?.id, parentTaskTitle: parent?.title,
                childProgress: childProgress
            )
        }
        let unreadParent = (id: familiesUnreadParentTaskID, title: "Website tasks and coordinator")
        let readParent = (id: familiesReadParentTaskID, title: "Merge main into the coordinator branch")
        let board = RemoteTaskBoard(
            tasks: [
                task(
                    familiesUnreadTaskID, "EmptyOS.app step 4 and step 5 owner",
                    status: "Claude · waiting for Move list 2026-11-17-1", taskSpace: familiesUnreadSubspaceID,
                    childProgress: RemoteTaskChildProgress(merged: 1, total: 1)
                ),
                task(
                    unreadParent.id, unreadParent.title, status: "Claude · waiting for Website copy pass",
                    taskSpace: familiesUnreadParentSubspaceID, childProgress: RemoteTaskChildProgress(merged: 0, total: 2)
                ),
                task(
                    familiesUnreadChildTaskID, "Website copy pass", status: "Claude · working",
                    taskSpace: familiesUnreadChildSubspaceID, parent: unreadParent
                ),
                task(
                    familiesFinishedChildTaskID, "Website hero pass", status: "Claude · finished, unread",
                    taskSpace: familiesFinishedChildSubspaceID, parent: unreadParent, finished: true
                ),
                task(
                    readParent.id, readParent.title, status: "Claude · waiting for Step 4 plan: record move list 1",
                    taskSpace: familiesReadParentSubspaceID, childProgress: RemoteTaskChildProgress(merged: 1, total: 2)
                ),
                task(
                    familiesReadChildTaskID, "Step 4 plan: record move list 1", status: "Claude · working",
                    taskSpace: familiesReadChildSubspaceID, parent: readParent
                ),
            ],
            needsYou: [RemoteTaskBoardEntry(taskID: familiesFinishedChildTaskID)],
            running: [
                RemoteTaskBoardEntry(taskID: familiesUnreadTaskID),
                RemoteTaskBoardEntry(taskID: familiesUnreadParentTaskID),
                RemoteTaskBoardEntry(taskID: familiesUnreadChildTaskID, isLinkedChild: true),
                RemoteTaskBoardEntry(taskID: familiesReadParentTaskID),
                RemoteTaskBoardEntry(taskID: familiesReadChildTaskID, isLinkedChild: true),
            ],
            doneCount: 1,
            finishedByProject: [RemoteTaskProjectTally(projectWorkspaceID: projectID, toShipCount: 0, doneCount: 1)]
        )
        let workspaces = [
            MobileWorkspace(id: projectID, title: "emptyos", conversations: []),
            space(
                familiesUnreadSubspaceID, "step-4-owner", number: 60, status: .ready,
                last: "Claude is waiting for your input"
            ),
            space(
                familiesUnreadParentSubspaceID, "website-tasks", number: 61, status: .ready,
                last: "Started Website copy pass; I wait for it"
            ),
            space(
                familiesUnreadChildSubspaceID, "website-copy", number: 62, status: .working,
                last: "Running grep -rn \"hero\" site/"
            ),
            space(
                familiesFinishedChildSubspaceID, "website-hero", number: 65, status: .ready,
                last: "Replaced the hero images; ready for a look"
            ),
            space(
                familiesReadParentSubspaceID, "merge-main", number: 63, status: .idle,
                last: "Waiting for Step 4 plan: record move list 1"
            ),
            space(
                familiesReadChildSubspaceID, "step-4-plan", number: 64, status: .working,
                last: "Running grep -rn \"docs\" docs/plans"
            ),
        ]
        return MobileHomeSnapshot(hostName: home.hostName, workspaces: workspaces, taskBoard: MobileTaskBoard(board))
    }()
}
