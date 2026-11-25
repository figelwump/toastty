import CoreState
import Foundation
import RemoteProtocol

/// Turns the Mac's task board into what a remote client shows: the same
/// stages, words and Status groups as the sidebar, so the two never differ.
/// The client gets every window's tasks, in the order the windows list
/// their workspaces.
@MainActor
enum RemoteTaskBoardProjection {
    /// What the Merge control and the action list read besides the items:
    /// the workspace tree, the merge Toastty runs for a task space, and
    /// whether tasks.toml configures triage.
    struct Context {
        var state: AppState
        var mergeRequest: (UUID) -> WorkspaceMergeRequest? = { _ in nil }
        var isTriageConfigured: () -> Bool = { false }
    }

    static func board(items: [TaskBoardItem], state: AppState) -> RemoteTaskBoard {
        board(items: items, context: Context(state: state))
    }

    static func board(items: [TaskBoardItem], context: Context) -> RemoteTaskBoard {
        let state = context.state
        var workspaceIDs: [UUID] = []
        var seen: Set<UUID> = []
        for window in state.windows {
            for id in window.workspaceIDs where seen.insert(id).inserted {
                workspaceIDs.append(id)
            }
        }
        let ordered = SidebarStatusSections.sidebarOrder(items, workspaceIDs: workspaceIDs)
        let sections = SidebarStatusSections.make(ordered)

        var listed: Set<TaskBoardItem.Subject> = []
        for group in SidebarStatusSections.rowGroups {
            for entry in sections.entries(group) {
                listed.insert(entry.id)
            }
        }
        // Every task that waits to ship, so a client can list what a
        // release ships.
        for lane in sections.toShip {
            for item in lane.recent.shown + lane.recent.hidden {
                listed.insert(item.id)
            }
        }
        // A finished task's open task space still lists in its project.
        let tasks = ordered.filter { item in
            listed.contains(item.id) || item.taskSpaceWorkspaceID != nil
        }

        func entries(_ group: TaskStage.Group) -> [RemoteTaskBoardEntry] {
            sections.entries(group).map { entry in
                RemoteTaskBoardEntry(
                    taskID: wireID(entry.item.id),
                    isLinkedChild: entry.isLinkedChild,
                    isContext: entry.isContext
                )
            }
        }

        var tallies: [UUID: RemoteTaskProjectTally] = [:]
        for item in items {
            guard let projectID = item.projectWorkspaceID, item.stage == .toShip || item.stage == .done else { continue }
            var tally = tallies[projectID] ?? RemoteTaskProjectTally(projectWorkspaceID: projectID, toShipCount: 0, doneCount: 0)
            if item.stage == .toShip {
                tally.toShipCount += 1
            } else {
                tally.doneCount += 1
            }
            tallies[projectID] = tally
        }

        let family = Family(items: items)
        return RemoteTaskBoard(
            tasks: tasks.map { summary($0, context: context, family: family) },
            needsYou: entries(.needsYou),
            running: entries(.running),
            idle: entries(.idle),
            toShip: sections.toShip.map { lane in
                RemoteTaskShipLane(
                    id: lane.id,
                    projectTitle: lane.projectTitle,
                    count: lane.count,
                    recentTaskIDs: lane.recent.shown.map { wireID($0.id) },
                    taskIDs: (lane.recent.shown + lane.recent.hidden).map { wireID($0.id) }
                )
            },
            doneCount: sections.doneCount,
            finishedByProject: tallies.values.sorted { $0.projectWorkspaceID.uuidString < $1.projectWorkspaceID.uuidString }
        )
    }

    /// The most recently active Done and archived tasks, at most `limit`,
    /// for the chips of links to them and the mention list: a task the
    /// board does not list has no chip on a device without them. A task with an open task space is
    /// here as well as on the board, so its chip stays when its task space
    /// closes. A task space with no task record is not a task.
    static func finishedTasks(
        _ items: [TaskBoardItem], limit: Int = RemoteFinishedTasksPolicy.limit
    ) -> [RemoteFinishedTask] {
        let finished = items.filter { item in
            guard case .task = item.id else { return false }
            switch item.stage {
            case .done, .archived: return true
            default: return false
            }
        }
        // The same tasks keep the same order, so the revision holds.
        let recent = finished.sorted { lhs, rhs in
            if lhs.activityAt != rhs.activityAt { return lhs.activityAt > rhs.activityAt }
            return wireID(lhs.id).uuidString < wireID(rhs.id).uuidString
        }.prefix(limit)
        return recent.map { item in
            // Without the held task space's countdown, so the revision does
            // not change each hour.
            let stage = TaskBoardPresentation.stageDescriptionWithoutHold(item)
            return RemoteFinishedTask(
                id: wireID(item.id),
                title: item.title,
                group: group(item.stage.group),
                stageTitle: stage.stage,
                stageReason: stage.why,
                statusLine: TaskBoardPresentation.stageStatusLine(item),
                projectTitle: item.projectTitle,
                pullRequest: pullRequest(item),
                // As the Mac's own mention list reads it
                // (`CoordinatorMentionCandidate.candidates(from:)`).
                doneAt: item.record?.doneAt ?? item.activityAt
            )
        }
    }

    /// Each task's parent and children among all the Mac's tasks, Done and
    /// archived ones included, which the board itself leaves out.
    @MainActor
    struct Family {
        var itemsByTaskID: [UUID: TaskBoardItem]
        var childrenByParentID: [UUID: [TaskBoardItem]]

        init(items: [TaskBoardItem]) {
            itemsByTaskID = Dictionary(
                items.compactMap { item in item.taskID.map { ($0, item) } },
                uniquingKeysWith: { first, _ in first }
            )
            childrenByParentID = Dictionary(grouping: items.filter { $0.parentTaskID != nil && $0.parentTaskID != $0.taskID }) {
                $0.parentTaskID!
            }
        }

        /// The task that started this one, while the Mac still has it.
        func parent(of item: TaskBoardItem) -> TaskBoardItem? {
            guard let parentID = item.parentTaskID, parentID != item.taskID else { return nil }
            return itemsByTaskID[parentID]
        }

        /// The sidebar's "N/M merged" for a parent task.
        func childProgress(of item: TaskBoardItem) -> RemoteTaskChildProgress? {
            guard let taskID = item.taskID,
                  let progress = TaskBoard.childProgress(of: taskID, items: childrenByParentID[taskID] ?? []) else { return nil }
            // The existing wire field counts To ship and Done children.
            return RemoteTaskChildProgress(merged: progress.finished, total: progress.total)
        }
    }

    /// Without `family`, the summary names no parent and no child progress.
    static func summary(_ item: TaskBoardItem, context: Context, family: Family = Family(items: [])) -> RemoteTaskSummary {
        let stage = TaskBoardPresentation.stageDescription(item)
        let parent = family.parent(of: item)
        return RemoteTaskSummary(
            id: wireID(item.id),
            hasRecord: item.record != nil,
            title: item.title,
            group: group(item.stage.group),
            mark: mark(item.stage, waitsOutside: item.record?.waiting != nil),
            showsAgentActivity: TaskBoardPresentation.showsAgentActivity(item),
            statusLine: TaskBoardPresentation.statusLine(item),
            rowSummary: rowSummary(item),
            stageTitle: stage.stage,
            stageReason: stage.why,
            projectWorkspaceID: item.projectWorkspaceID,
            projectTitle: item.projectTitle,
            taskSpaceWorkspaceID: item.taskSpaceWorkspaceID,
            pullRequest: pullRequest(item),
            activityAt: item.activityAt,
            mergeControl: mergeControl(item, context: context),
            actions: actions(item, isTriageConfigured: context.isTriageConfigured()),
            releaseAfterMergeRequestedAt: TaskBoardPresentation.releaseAfterMergeRequestedAt(item),
            parentTaskID: parent?.taskID,
            parentTaskTitle: parent?.title,
            childProgress: family.childProgress(of: item),
            macStep: macStep(item)
        )
    }

    static let pickWorkspaceMacStep =
        "Pick the workspace on your Mac: open Tasks with ⌘⇧T, select this task, and choose a workspace."

    /// What only the Mac can do for the task. The workspace picker is in the
    /// task's setup card in the Tasks view; no task action picks one.
    static func macStep(_ item: TaskBoardItem) -> String? {
        if case .needsYou(.pickWorkspace) = item.stage { return pickWorkspaceMacStep }
        return nil
    }

    // MARK: - Actions

    static let archiveTaskItem = RemoteTaskActionItem(action: .archive, title: "Archive Task…")

    /// The task's menu as the Mac's sidebar and Tasks view offer it, less
    /// where to go and what stays on the Mac: Merge Without Checks.
    static func actions(_ item: TaskBoardItem, isTriageConfigured: @autoclosure () -> Bool) -> [RemoteTaskActionItem] {
        TaskBoardPresentation.menuItems(item, isTriageConfigured: isTriageConfigured()).joined().compactMap { menuItem in
            switch menuItem {
            case .openTaskSpace, .openPullRequest, .trackAsTask:
                return nil
            case .action(let action, _, _):
                return remoteAction(action).map { RemoteTaskActionItem(action: $0, title: action.title) }
            case .retry(_, let title):
                return RemoteTaskActionItem(action: .retry, title: title)
            case .retryTriage:
                return RemoteTaskActionItem(action: .retry, title: menuItem.title)
            case .delete:
                return RemoteTaskActionItem(action: .delete, title: menuItem.title)
            }
        }
    }

    static func remoteAction(_ action: TaskBoardPresentation.DetailAction) -> RemoteTaskAction? {
        switch action {
        case .merge: .merge
        case .mergeWithoutChecks: nil
        case .cancelMerge: .cancelMerge
        case .markDone: .markDone
        case .archive: .archive
        case .cleanUp: .cleanUp
        case .keepAsIs: .keepAsIs
        case .closeTaskSpace: nil
        }
    }

    /// The Merge control the Mac's top bar shows for the task's open task
    /// space: `WorkspaceMergePresentation` while the task space links a pull
    /// request, else the task's own control, as `WorkspaceView` chooses.
    /// Merge Without Checks stays on the Mac, so it is not in the menu.
    static func mergeControl(_ item: TaskBoardItem, context: Context) -> RemoteTaskMergeControl? {
        guard let record = item.record,
              let workspaceID = item.taskSpaceWorkspaceID,
              let workspace = context.state.workspacesByID[workspaceID],
              workspace.parentWorkspaceID != nil,
              workspace.taskID == record.id else { return nil }
        if item.allowsPullRequestActions, let presentation = WorkspaceMergePresentation.make(
            workspace: workspace,
            request: context.mergeRequest(workspaceID),
            isCheckingMerge: item.merge == .checking,
            isTaskMerged: record.mergedAt != nil,
            pullRequestState: item.pullRequestState
        ) {
            let merge = RemoteTaskActionItem(action: .merge, title: "Merge \(presentation.pullRequest)")
            switch presentation {
            case .ready(_, _, nil):
                return RemoteTaskMergeControl(kind: .merge, title: presentation.title, action: merge, menu: [archiveTaskItem])
            case .ready(_, _, let blocker?):
                return RemoteTaskMergeControl(
                    kind: .openPullRequest, title: presentation.title, detail: blocker.label, menu: [merge, archiveTaskItem]
                )
            case .merging, .cleaningUp, .closing:
                let canCancel = TaskBoardPresentation.detailActions(item).contains(.cancelMerge)
                return RemoteTaskMergeControl(
                    kind: .merging,
                    title: presentation.title,
                    menu: canCancel ? [RemoteTaskActionItem(action: .cancelMerge, title: TaskBoardPresentation.DetailAction.cancelMerge.title)] : []
                )
            case .cleanupFailed(_, let reason):
                return RemoteTaskMergeControl(kind: .cleanupStopped, title: presentation.title, detail: reason, menu: [
                    RemoteTaskActionItem(action: .cleanUp, title: TaskBoardPresentation.DetailAction.cleanUp.title),
                    RemoteTaskActionItem(action: .keepAsIs, title: TaskBoardPresentation.DetailAction.keepAsIs.title),
                ])
            case .done:
                return RemoteTaskMergeControl(kind: .done, title: presentation.title, menu: [archiveTaskItem])
            }
        }
        // `WorkspaceHeaderTaskControl`: a task space without a pull request.
        switch item.stage {
        case .done:
            return RemoteTaskMergeControl(kind: .done, title: "Done", menu: [archiveTaskItem])
        case .needsYou(.readyForReview):
            return RemoteTaskMergeControl(
                kind: .completeTask, title: "Complete Task", action: RemoteTaskActionItem(action: .markDone, title: "Complete Task")
            )
        default:
            return RemoteTaskMergeControl(kind: .archive, title: archiveTaskItem.title, action: archiveTaskItem)
        }
    }

    /// A task's record ID, or a watched task space's workspace ID.
    static func wireID(_ subject: TaskBoardItem.Subject) -> UUID {
        switch subject {
        case .task(let id), .taskSpace(let id): id
        }
    }

    static func group(_ group: TaskStage.Group) -> RemoteTaskGroup {
        switch group {
        case .needsYou: .needsYou
        case .running: .running
        case .idle: .idle
        case .toShip: .toShip
        case .done: .done
        case .archived: .archived
        }
    }

    /// The part of the row status the stage decides, as
    /// `SidebarSubspacePresentation.rowStatus(sessionStatus:isDone:stage:waitsOutside:)`
    /// reads it. `waitsOutside` is the task's `task waiting` mark, which
    /// gives an Idle task the clock.
    static func mark(_ stage: TaskStage, waitsOutside: Bool = false) -> RemoteTaskMark? {
        switch stage {
        case .needsYou(.awaitingReply): .question
        case .needsYou(.review), .needsYou(.readyForReview): .review
        case .toShip: .toShip
        case .done, .archived: .done
        case .starting: .starting
        case .idle where waitsOutside: .waiting
        case .running, .idle, .needsYou: nil
        }
    }

    /// What the task space's row says instead of its sessions' summary, as
    /// the sidebar's task space row does.
    static func rowSummary(_ item: TaskBoardItem) -> String? {
        if case .needsYou(.awaitingReply) = item.stage { return TaskBoardPresentation.replyLine(item) }
        if case .needsYou(.startWaitsInTerminal) = item.stage { return TaskBoardPresentation.statusLine(item) }
        // Under the clock, while the agent is quiet and its turn read.
        if TaskBoardPresentation.restingWait(item) != nil, item.taskSpaceStatus != .ready {
            return TaskBoardPresentation.waitingLine(item)
        }
        return item.stage.isBeforeStart ? TaskBoardPresentation.statusLine(item) : nil
    }

    static func pullRequest(_ item: TaskBoardItem) -> RemoteTaskPullRequest? {
        guard let link = item.pullRequest, let url = URL(string: link.url) else { return nil }
        let state: RemoteTaskPullRequestState? = item.pullRequestState.map { answer in
            switch answer.state {
            case .open: answer.isDraft ? .draft : .open
            case .merged: .merged
            case .closed: .closed
            }
        }
        return RemoteTaskPullRequest(number: link.number, url: url, state: state)
    }
}
