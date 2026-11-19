import Foundation
import RemoteProtocol

// MARK: - Task actions

/// The task fixture's Merge control states and task actions. A Mac computes
/// these; the fixture writes them out so every state is reachable without
/// one, and answers task actions and archive checks the way a Mac would.
public extension ToasttyMobileFixture {
    static let emptyosWorkspaceID = UUID(uuidString: "A1000000-0000-0000-0000-000000000005")!
    static let mergingSubspaceID = UUID(uuidString: "A1000000-0000-0000-0000-000000000021")!
    static let completeSubspaceID = UUID(uuidString: "A1000000-0000-0000-0000-000000000022")!
    static let cleanupStoppedSubspaceID = UUID(uuidString: "A1000000-0000-0000-0000-000000000023")!
    static let mergedDoneSubspaceID = UUID(uuidString: "A1000000-0000-0000-0000-000000000024")!
    static let markedDoneSubspaceID = UUID(uuidString: "A1000000-0000-0000-0000-000000000025")!
    static let archiveSubspaceID = UUID(uuidString: "A1000000-0000-0000-0000-000000000026")!

    static let mergingTaskID = UUID(uuidString: "D1000000-0000-0000-0000-000000000006")!
    static let completeTaskID = UUID(uuidString: "D1000000-0000-0000-0000-000000000007")!
    static let cleanupStoppedTaskID = UUID(uuidString: "D1000000-0000-0000-0000-000000000008")!
    static let mergedDoneTaskID = UUID(uuidString: "D1000000-0000-0000-0000-000000000009")!
    static let markedDoneTaskID = UUID(uuidString: "D1000000-0000-0000-0000-000000000010")!
    static let archiveTaskID = UUID(uuidString: "D1000000-0000-0000-0000-000000000011")!
    /// A Done task that started Website hero refresh; not on the board.
    static let finishedParentTaskID = UUID(uuidString: "D1000000-0000-0000-0000-000000000013")!

    /// The Mac's titles, as `TaskBoardPresentation` words them.
    internal static let mergeItem = RemoteTaskActionItem(action: .merge, title: "Merge")
    internal static let archiveItem = RemoteTaskActionItem(action: .archive, title: "Archive…")
    internal static let archiveTaskItem = RemoteTaskActionItem(action: .archive, title: "Archive Task…")
    internal static let markDoneItem = RemoteTaskActionItem(action: .markDone, title: "Mark Done")
    internal static let cancelMergeItem = RemoteTaskActionItem(action: .cancelMerge, title: "Cancel Merge")
    internal static let cleanUpItem = RemoteTaskActionItem(action: .cleanUp, title: "Clean Up")
    internal static let keepAsIsItem = RemoteTaskActionItem(action: .keepAsIs, title: "Keep As Is")
    internal static let deleteItem = RemoteTaskActionItem(action: .delete, title: "Delete Task")

    internal static func mergeControl(pullRequest number: Int) -> RemoteTaskMergeControl {
        RemoteTaskMergeControl(
            kind: .merge,
            title: "Merge PR #\(number)",
            action: RemoteTaskActionItem(action: .merge, title: "Merge PR #\(number)"),
            menu: [archiveTaskItem]
        )
    }

    internal static func mergingControl(pullRequest number: Int) -> RemoteTaskMergeControl {
        RemoteTaskMergeControl(kind: .merging, title: "Merging PR #\(number)…", menu: [cancelMergeItem])
    }

    private static func fixturePullRequest(_ number: Int, _ state: RemoteTaskPullRequestState) -> RemoteTaskPullRequest {
        RemoteTaskPullRequest(
            number: number, url: URL(string: "https://github.com/example/emptyos/pull/\(number)")!, state: state
        )
    }

    /// One emptyos task for each Merge control state the toastty tasks do
    /// not show. The two done tasks keep an agent at work, so their task
    /// spaces still list.
    internal static func taskActionTasks(now: Date) -> [RemoteTaskSummary] {
        func task(
            _ id: UUID, _ title: String, group: RemoteTaskGroup, mark: RemoteTaskMark? = nil,
            status: String, stage: String, why: String, taskSpace: UUID,
            pullRequest: RemoteTaskPullRequest? = nil, control: RemoteTaskMergeControl, actions: [RemoteTaskActionItem],
            parent: (id: UUID, title: String)? = nil
        ) -> RemoteTaskSummary {
            RemoteTaskSummary(
                id: id, title: title, group: group, mark: mark, statusLine: status,
                stageTitle: stage, stageReason: why,
                projectWorkspaceID: emptyosWorkspaceID, projectTitle: "emptyos", taskSpaceWorkspaceID: taskSpace,
                pullRequest: pullRequest, activityAt: now, mergeControl: control, actions: actions,
                parentTaskID: parent?.id, parentTaskTitle: parent?.title
            )
        }
        return [
            task(
                mergingTaskID, "Parser rewrite", group: .running, status: "Merging…", stage: "Running",
                why: "Merging…", taskSpace: mergingSubspaceID, pullRequest: fixturePullRequest(88, .open),
                control: mergingControl(pullRequest: 88), actions: [cancelMergeItem]
            ),
            task(
                completeTaskID, "Website hero refresh", group: .needsYou, mark: .review,
                status: "Ready for your review", stage: "Review", why: "marked ready, agent idle",
                taskSpace: completeSubspaceID,
                control: RemoteTaskMergeControl(
                    kind: .completeTask, title: "Complete Task",
                    action: RemoteTaskActionItem(action: .markDone, title: "Complete Task")
                ),
                actions: [markDoneItem, archiveItem],
                // Its parent is Done and off the board, so Needs you names
                // it with ↖.
                parent: (finishedParentTaskID, "Website refresh")
            ),
            task(
                cleanupStoppedTaskID, "Gateway test flake", group: .needsYou,
                status: "Merged · clean up?", stage: "Needs you", why: "The worktree has uncommitted changes.",
                taskSpace: cleanupStoppedSubspaceID, pullRequest: fixturePullRequest(91, .merged),
                control: RemoteTaskMergeControl(
                    kind: .cleanupStopped, title: "Cleanup Stopped · PR #91",
                    detail: "The worktree has uncommitted changes.", menu: [cleanUpItem, keepAsIsItem]
                ),
                actions: [cleanUpItem, keepAsIsItem]
            ),
            task(
                mergedDoneTaskID, "Thing sharing copy", group: .done, mark: .done, status: "Done",
                stage: "Done", why: "merged", taskSpace: mergedDoneSubspaceID, pullRequest: fixturePullRequest(93, .merged),
                control: RemoteTaskMergeControl(kind: .done, title: "Done · PR #93", menu: [archiveTaskItem]),
                actions: []
            ),
            task(
                markedDoneTaskID, "Docs typo sweep", group: .done, mark: .done, status: "Done",
                stage: "Done", why: "marked done", taskSpace: markedDoneSubspaceID,
                control: RemoteTaskMergeControl(kind: .done, title: "Done", menu: [archiveTaskItem]),
                actions: []
            ),
            task(
                archiveTaskID, "Spike: zmx sessions", group: .idle, status: "Codex · idle", stage: "Idle",
                why: "Codex · idle", taskSpace: archiveSubspaceID,
                control: RemoteTaskMergeControl(kind: .archive, title: "Archive Task…", action: archiveTaskItem),
                actions: [markDoneItem, archiveItem]
            ),
        ]
    }

    /// The emptyos project and its task spaces, one session each.
    internal static func taskActionWorkspaces() -> [MobileWorkspace] {
        func pullRequest(_ number: Int, color: String = "#5BA08A") -> RemoteWorkspaceAnnotation {
            RemoteWorkspaceAnnotation(
                key: "github-pr", text: "PR #\(number)",
                url: URL(string: "https://github.com/example/emptyos/pull/\(number)"), color: color
            )
        }
        func space(
            _ id: UUID, _ title: String, number: Int, agent: AgentKind, sessionTitle: String,
            status: RemoteSessionPresentationStatus, age: String, last: String,
            annotations: [RemoteWorkspaceAnnotation] = [], isDone: Bool = false
        ) -> MobileWorkspace {
            MobileWorkspace(
                id: id,
                title: title,
                conversations: [
                    conversation(
                        number, workspaceID: id, workspaceTitle: title,
                        cwd: "~/GiantThings/repos/emptyos-\(title)", agent: agent,
                        title: sessionTitle, status: status,
                        availability: status == .working
                            ? .unavailable(reason: "working") : .unavailable(reason: "prompt not open"),
                        age: age, last: last
                    ),
                ],
                annotations: annotations,
                parentWorkspaceID: emptyosWorkspaceID,
                isDone: isDone
            )
        }
        return [
            MobileWorkspace(
                id: emptyosWorkspaceID,
                title: "emptyos",
                conversations: [
                    conversation(
                        36, workspaceID: emptyosWorkspaceID, workspaceTitle: "emptyos",
                        cwd: "~/GiantThings/repos/emptyos", agent: .claude,
                        title: "Gateway notes", status: .idle,
                        availability: .unavailable(reason: "prompt not open"),
                        age: "3h", last: "Notes saved"
                    ),
                ]
            ),
            space(
                mergingSubspaceID, "parser-rewrite", number: 30, agent: .claude,
                sessionTitle: "Rewrite the parser", status: .working, age: "now",
                last: "Checking PR #88 before it merges", annotations: [pullRequest(88)]
            ),
            space(
                completeSubspaceID, "website-hero", number: 31, agent: .codex,
                sessionTitle: "Refresh the hero", status: .idle, age: "12m", last: "Marked the task ready for review"
            ),
            space(
                cleanupStoppedSubspaceID, "gateway-test-flake", number: 32, agent: .codex,
                sessionTitle: "Fix the gateway flake", status: .idle, age: "30m",
                last: "PR #91 merged", annotations: [pullRequest(91, color: "#B98CE0")]
            ),
            space(
                mergedDoneSubspaceID, "thing-sharing-copy", number: 33, agent: .claude,
                sessionTitle: "Thing sharing copy", status: .working, age: "now",
                last: "Writing the follow-up notes", annotations: [pullRequest(93, color: "#B98CE0")]
            ),
            space(
                markedDoneSubspaceID, "docs-typo-sweep", number: 34, agent: .claude,
                sessionTitle: "Sweep docs for typos", status: .working, age: "now",
                last: "Checking the last page", isDone: true
            ),
            space(
                archiveSubspaceID, "zmx-sessions-spike", number: 35, agent: .codex,
                sessionTitle: "Try zmx sessions", status: .idle, age: "2h", last: "Spike notes are in the PR description"
            ),
        ]
    }

    /// What a Mac answers to an archive check. Website hero refresh has
    /// nothing to lose but unpushed commits, as in the mockup; Spike: zmx
    /// sessions has uncommitted files, which stop an archive from the phone.
    static func archiveCheck(taskID: UUID, board: RemoteTaskBoard) -> RemoteTaskArchiveCheckResult {
        guard let task = board.tasks.first(where: { $0.id == taskID }) else {
            return .rejected(reason: .taskNotFound, message: nil)
        }
        guard task.offers(.archive) else {
            return .rejected(reason: .notOffered, message: task.statusLine)
        }
        let branch = "task/" + task.title.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let blocked = taskID == archiveTaskID
        return .ready(RemoteTaskArchiveCheck(
            closesTaskSpace: task.taskSpaceWorkspaceID != nil,
            agentSessions: task.taskSpaceWorkspaceID == nil ? 0 : 1,
            removesWorktree: true,
            uncommittedFiles: blocked ? 3 : 0,
            branch: branch,
            unpushedCommits: taskID == reviewTaskID ? 2 : 0,
            orphanedCommits: 0,
            unsavedDocuments: 0,
            pullRequest: task.pullRequest.flatMap { $0.state == .merged || $0.state == .closed ? nil : $0 }
                .map { RemoteTaskPullRequest(number: $0.number, url: $0.url) },
            blockedReason: blocked
                ? "The worktree has 3 uncommitted files. Commit and push them, or archive on the Mac to discard them."
                : nil
        ))
    }

    /// The result of a task action, and the board a Mac would send after
    /// it. An archive or a mark done closes the task's task space.
    static func applyTaskAction(
        _ request: RemoteTaskActionRequest,
        to board: RemoteTaskBoard
    ) -> (result: RemoteTaskActionResult, board: RemoteTaskBoard, closedTaskSpaceID: UUID?) {
        guard let index = board.tasks.firstIndex(where: { $0.id == request.taskID }) else {
            return (.rejected(reason: .taskNotFound, message: nil), board, nil)
        }
        var task = board.tasks[index]
        if let expected = request.expectedPullRequestNumber, task.pullRequest?.number != expected {
            return (.rejected(reason: .pullRequestChanged, message: nil), board, nil)
        }
        guard task.offers(request.action) else {
            return (.rejected(reason: .notOffered, message: task.statusLine), board, nil)
        }
        var next = board
        var closedTaskSpaceID: UUID?
        func move(to group: RemoteTaskGroup) {
            for keyPath in [\RemoteTaskBoard.needsYou, \.running, \.idle] {
                next[keyPath: keyPath].removeAll { $0.taskID == task.id }
            }
            switch group {
            case .needsYou: next.needsYou.append(RemoteTaskBoardEntry(taskID: task.id))
            case .running: next.running.append(RemoteTaskBoardEntry(taskID: task.id))
            case .idle: next.idle.append(RemoteTaskBoardEntry(taskID: task.id))
            case .toShip, .done, .archived: break
            }
            task.group = group
        }
        func finish(as group: RemoteTaskGroup) {
            move(to: group)
            closedTaskSpaceID = task.taskSpaceWorkspaceID
            task.taskSpaceWorkspaceID = nil
            task.mergeControl = nil
            task.actions = []
            if group == .done { next.doneCount += 1 }
        }
        switch request.action {
        case .merge:
            guard let number = task.pullRequest?.number else { break }
            move(to: .running)
            task.mark = nil
            task.statusLine = "Merging…"
            task.stageTitle = "Running"
            task.stageReason = "Merging…"
            task.mergeControl = mergingControl(pullRequest: number)
            task.actions = [cancelMergeItem]
        case .cancelMerge:
            guard let number = task.pullRequest?.number else { break }
            move(to: .needsYou)
            task.mark = .review
            task.statusLine = "Ready for your review"
            task.stageTitle = "Review"
            task.stageReason = "PR open, agent idle"
            task.mergeControl = mergeControl(pullRequest: number)
            task.actions = [mergeItem, archiveItem]
        case .markDone:
            task.mark = .done
            task.statusLine = "Done"
            task.stageTitle = "Done"
            task.stageReason = "marked done"
            finish(as: .done)
        case .archive:
            finish(as: .archived)
            next.tasks.remove(at: index)
            return (.performed, next, closedTaskSpaceID)
        case .cleanUp:
            // A stopped cleanup that stops again, so the refusal shows.
            return (.rejected(
                reason: .failed,
                message: "The worktree still has uncommitted changes. Commit or discard them on the Mac, then clean up."
            ), board, nil)
        case .keepAsIs:
            move(to: .done)
            task.mark = .done
            task.statusLine = "Done"
            task.stageTitle = "Done"
            task.stageReason = "merged"
            task.mergeControl = task.pullRequest.map {
                RemoteTaskMergeControl(kind: .done, title: "Done · PR #\($0.number)", menu: [archiveTaskItem])
            }
            task.actions = []
            next.doneCount += 1
        case .retry:
            move(to: .running)
            task.mark = .starting
            task.statusLine = "Setting up · making the worktree"
            task.rowSummary = task.statusLine
            task.stageTitle = "Starting"
            task.stageReason = task.statusLine
            task.actions = [deleteItem]
        case .delete:
            for keyPath in [\RemoteTaskBoard.needsYou, \.running, \.idle] {
                next[keyPath: keyPath].removeAll { $0.taskID == task.id }
            }
            next.tasks.remove(at: index)
            return (.performed, next, nil)
        }
        next.tasks[index] = task
        return (.performed, next, closedTaskSpaceID)
    }
}
