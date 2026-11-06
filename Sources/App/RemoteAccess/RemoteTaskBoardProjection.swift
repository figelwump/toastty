import CoreState
import Foundation
import RemoteProtocol

/// Turns the Mac's task board into what a remote client shows: the same
/// stages, words and Status groups as the sidebar, so the two never differ.
/// The client gets every window's tasks, in the order the windows list
/// their workspaces.
@MainActor
enum RemoteTaskBoardProjection {
    /// What the Merge control and the action list read besides the item:
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
        for lane in sections.toShip {
            for item in lane.recent.shown {
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

        return RemoteTaskBoard(
            tasks: tasks.map { summary($0, context: context) },
            needsYou: entries(.needsYou),
            running: entries(.running),
            idle: entries(.idle),
            toShip: sections.toShip.map { lane in
                RemoteTaskShipLane(
                    id: lane.id,
                    projectTitle: lane.projectTitle,
                    count: lane.count,
                    recentTaskIDs: lane.recent.shown.map { wireID($0.id) }
                )
            },
            doneCount: sections.doneCount,
            finishedByProject: tallies.values.sorted { $0.projectWorkspaceID.uuidString < $1.projectWorkspaceID.uuidString }
        )
    }

    static func summary(_ item: TaskBoardItem, context: Context) -> RemoteTaskSummary {
        let stage = TaskBoardPresentation.stageDescription(item)
        return RemoteTaskSummary(
            id: wireID(item.id),
            hasRecord: item.record != nil,
            title: item.title,
            group: group(item.stage.group),
            mark: mark(item.stage),
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
            actions: actions(item, isTriageConfigured: context.isTriageConfigured())
        )
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
        if let presentation = WorkspaceMergePresentation.make(
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
    /// `SidebarSubspacePresentation.rowStatus(sessionStatus:isDone:stage:)`
    /// reads it.
    static func mark(_ stage: TaskStage) -> RemoteTaskMark? {
        switch stage {
        case .needsYou(.awaitingReply): .question
        case .needsYou(.review), .needsYou(.readyForReview): .review
        case .toShip: .toShip
        case .done, .archived: .done
        case .starting: .starting
        case .running, .idle, .needsYou: nil
        }
    }

    /// What the task space's row says instead of its sessions' summary, as
    /// the sidebar's task space row does.
    static func rowSummary(_ item: TaskBoardItem) -> String? {
        if case .needsYou(.awaitingReply) = item.stage { return TaskBoardPresentation.replyLine(item) }
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
