import CoreState
import Foundation
import RemoteProtocol

/// Turns the Mac's task board into what a remote client shows: the same
/// stages, words and Status groups as the sidebar, so the two never differ.
/// The client gets every window's tasks, in the order the windows list
/// their workspaces.
@MainActor
enum RemoteTaskBoardProjection {
    static func board(items: [TaskBoardItem], state: AppState) -> RemoteTaskBoard {
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
            tasks: tasks.map(summary),
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

    static func summary(_ item: TaskBoardItem) -> RemoteTaskSummary {
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
            activityAt: item.activityAt
        )
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
