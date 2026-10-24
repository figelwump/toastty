import CoreState
import SwiftUI

/// The words the sidebar and the Tasks view use for a task. Kept apart from
/// the views so they can be tested without hosting them.
enum TaskBoardPresentation {
    static func groupTitle(_ group: TaskStage.Group) -> String {
        switch group {
        case .inbox: "Inbox"
        case .needsYou: "Needs you"
        case .running: "Running"
        case .toShip: "To ship"
        case .done: "Done"
        case .archived: "Archived"
        }
    }

    /// The agent's display name, from its profile ID.
    static func agentName(_ item: TaskBoardItem) -> String {
        guard let agent = item.record?.resolved?.agent ?? item.record?.pinned.agent, agent.isEmpty == false else {
            return "The agent"
        }
        return agent.prefix(1).uppercased() + agent.dropFirst()
    }

    /// One line on what the task is doing or waiting for.
    static func statusLine(_ item: TaskBoardItem) -> String {
        switch item.stage {
        case .inbox:
            switch item.record?.setup {
            case .routing?: return "setting up"
            case .settingUp?: return "setting up"
            default: return "moving to worktree"
            }
        case .needsYou(let attention):
            switch attention {
            case .pickWorkspace: return "⚠ pick a workspace"
            case .setupFailed: return "⚠ setup failed"
            case .moveFailed: return "⚠ worktree failed"
            case .taskSpaceClosed: return "Task space closed before the task finished"
            case .agentNeedsInput: return "\(agentName(item)) is waiting for your input"
            case .agentError: return "\(agentName(item)) stopped with an error"
            case .review, .readyForReview: return "Ready for your review"
            case .agentFinished: return "\(agentName(item)) finished · waiting for you"
            case .cleanupStopped:
                switch item.record?.cleanup?.kind {
                case .archive?: return "⚠ archive stopped"
                case .release?: return "Released · clean up?"
                case .merge?, nil: return "Merged · clean up?"
                }
            }
        case .running:
            switch item.merge {
            case .checking?, .merging?: return "Merging…"
            case .waitingForChecks?: return "Waiting for checks"
            case .cleaningUp?: return "Cleaning up…"
            case nil: break
            }
            switch item.agent {
            case .working: return "\(agentName(item)) · working"
            case .none: return "No agent running"
            case .finished, .idle, .needsInput, .error:
                if let waitingOn = item.waitingOnTitle {
                    return "\(agentName(item)) · waiting for \(waitingOn)"
                }
                return "\(agentName(item)) · idle"
            }
        case .toShip: return "Merged · waiting for a release"
        case .done: return item.record?.shippedAt != nil ? "Shipped" : "Done"
        case .archived: return "Archived"
        }
    }

    /// The stage's name and why, for the detail pane.
    static func stageDescription(_ item: TaskBoardItem) -> (stage: String, why: String) {
        switch item.stage {
        case .inbox: return ("Inbox", statusLine(item))
        case .needsYou(let attention):
            switch attention {
            case .pickWorkspace(let reason), .setupFailed(let reason), .moveFailed(let reason):
                return ("Needs you", reason)
            case .taskSpaceClosed: return ("Needs you", "task space closed")
            case .agentNeedsInput: return ("Needs you", "the agent asked for input")
            case .agentError: return ("Needs you", "the agent stopped with an error")
            case .review:
                return ("Review", item.pullRequestState == nil ? "PR linked, agent idle" : "PR open, agent idle")
            case .readyForReview: return ("Review", "marked ready, agent idle")
            case .agentFinished: return ("Needs you", "the agent finished its turn")
            case .cleanupStopped(let reason): return ("Needs you", reason)
            }
        case .running: return ("Running", statusLine(item))
        case .toShip: return ("To ship", "merged, waiting for a release tag")
        case .done:
            if let tag = item.record?.releaseTag { return ("Done", "shipped in \(tag)") }
            return ("Done", item.record?.mergedAt != nil || item.pullRequestState?.state == .merged ? "merged" : "marked done")
        case .archived: return ("Archived", "closed without finishing")
        }
    }

    /// The task actions the detail pane offers, in order.
    enum DetailAction: Hashable, CustomStringConvertible {
        case merge
        case mergeWithoutChecks
        case cancelMerge
        case markDone
        case archive
        case cleanUp
        case keepAsIs

        var title: String {
            switch self {
            case .merge: "Merge"
            case .mergeWithoutChecks: "Merge Without Checks"
            case .cancelMerge: "Cancel Merge"
            case .markDone: "Mark Done"
            case .archive: "Archive…"
            case .cleanUp: "Clean Up"
            case .keepAsIs: "Keep As Is"
            }
        }

        var isPrimary: Bool { self == .merge || self == .cleanUp }

        var help: String {
            switch self {
            case .merge: "The task's agent checks the pull request, then merges it; Toastty then closes the task space and removes its worktree"
            case .mergeWithoutChecks: "Merge the pull request now, without the agent's checks"
            case .cancelMerge: "Stop the merge: the agent's check, or Toastty's wait for GitHub's checks"
            case .markDone: "Finish the task without a merge"
            case .archive: "Close the task without merging"
            case .cleanUp: "Try the cleanup again"
            case .keepAsIs: "Leave the task space and worktree as they are"
            }
        }

        /// The start of a failure alert's title, before the task's title.
        var failureTitle: String {
            switch self {
            case .merge, .mergeWithoutChecks: "Unable to Merge"
            case .cancelMerge: "Unable to Cancel the Merge of"
            case .markDone: "Unable to Mark Done"
            case .archive: "Unable to Archive"
            case .cleanUp: "Unable to Clean Up"
            case .keepAsIs: "Unable to Keep As Is"
            }
        }

        var description: String {
            switch self {
            case .merge: "merge"
            case .mergeWithoutChecks: "mergeWithoutChecks"
            case .cancelMerge: "cancelMerge"
            case .markDone: "markDone"
            case .archive: "archive"
            case .cleanUp: "cleanUp"
            case .keepAsIs: "keepAsIs"
            }
        }
    }

    static func detailActions(_ item: TaskBoardItem) -> [DetailAction] {
        guard let record = item.record else { return [] }
        if case .needsYou(.cleanupStopped) = item.stage {
            return [.cleanUp, .keepAsIs]
        }
        switch item.merge {
        case .checking?, .waitingForChecks?:
            return [.cancelMerge]
        case .merging?, .cleaningUp?:
            return []
        case nil:
            break
        }
        switch item.stage {
        case .needsYou(let attention) where attention.isBeforeStart == false && attention != .taskSpaceClosed:
            break
        case .running:
            break
        case .needsYou(.taskSpaceClosed):
            return [.archive]
        default:
            return []
        }
        var actions: [DetailAction] = []
        let hasOpenPullRequest = item.pullRequest != nil && item.pullRequestState?.state != .merged
            && item.pullRequestState?.state != .closed
        if hasOpenPullRequest, item.taskSpaceWorkspaceID != nil {
            actions += [.merge, .mergeWithoutChecks]
        } else if record.release == nil {
            actions.append(.markDone)
        }
        actions.append(.archive)
        return actions
    }

    /// One item of a task's menu, with what it acts on. The detail pane
    /// shows these as buttons, and a task's rows show them as a context menu.
    enum MenuItem: Hashable {
        case openTaskSpace(workspaceID: UUID)
        case openPullRequest(number: Int, url: URL)
        case trackAsTask(workspaceID: UUID)
        /// `showsShortcut` while Option+Shift+M would run this action: the
        /// task space is the one the window shows.
        case action(DetailAction, taskID: UUID, showsShortcut: Bool = false)
        case retry(taskID: UUID, title: String)
        case retryTriage(taskID: UUID)
        case delete(taskID: UUID)

        var title: String {
            switch self {
            case .openTaskSpace: "Open Task Space"
            case .openPullRequest(let number, _): "Open PR #\(number)"
            case .trackAsTask: "Track as Task"
            case .action(let action, _, let showsShortcut):
                showsShortcut ? ToasttyKeyboardShortcuts.mergeWorkspacePullRequest.menuTitle(action.title) : action.title
            case .retry(_, let title): title
            case .retryTriage: "Retry Triage"
            case .delete: "Delete Task"
            }
        }

        var isDestructive: Bool {
            if case .delete = self { return true }
            return false
        }

        /// The item without its shortcut hint, to compare a menu built
        /// earlier with the task's menu now.
        var withoutShortcut: Self {
            if case .action(let action, let taskID, true) = self {
                return .action(action, taskID: taskID)
            }
            return self
        }
    }

    /// The task's menu, in sections: where to go, then what to do. The
    /// detail pane's actions come in its order; one that does not apply now
    /// is left out, as in the command palette. Open Task Space is left out
    /// when `currentWorkspaceID` is the task space, which the window already
    /// shows. `showsMergeShortcut` when Option+Shift+M would merge it there.
    /// `isTriageConfigured` reads tasks.toml, so it runs only for a task
    /// that waits for a workspace.
    static func menuItems(
        _ item: TaskBoardItem,
        currentWorkspaceID: UUID? = nil,
        showsMergeShortcut: Bool = false,
        isTriageConfigured: @autoclosure () -> Bool = false
    ) -> [[MenuItem]] {
        if item.stage.group == .inbox {
            guard let record = item.record else { return [] }
            return [inboxMenuItems(record, isTriageConfigured: isTriageConfigured())]
        }
        var navigation: [MenuItem] = []
        let isCurrent = item.taskSpaceWorkspaceID != nil && item.taskSpaceWorkspaceID == currentWorkspaceID
        if let workspaceID = item.taskSpaceWorkspaceID, isCurrent == false {
            navigation.append(.openTaskSpace(workspaceID: workspaceID))
        }
        if let link = item.pullRequest, let url = URL(string: link.url) {
            navigation.append(.openPullRequest(number: link.number, url: url))
        }
        if case .taskSpace(let workspaceID) = item.id {
            navigation.append(.trackAsTask(workspaceID: workspaceID))
        }
        var actions: [MenuItem] = []
        if let record = item.record {
            actions = detailActions(item).map { action in
                .action(action, taskID: record.id, showsShortcut: action == .merge && isCurrent && showsMergeShortcut)
            }
            if item.stage == .needsYou(.taskSpaceClosed) {
                actions.append(.delete(taskID: record.id))
            }
        }
        return [navigation, actions].filter { $0.isEmpty == false }
    }

    /// A task that has not started yet: retry what failed, or delete it.
    static func inboxMenuItems(_ record: TaskRecord, isTriageConfigured: @autoclosure () -> Bool) -> [MenuItem] {
        var items: [MenuItem] = []
        if SidebarInboxRowPresentation.canRetry(record) {
            items.append(.retry(taskID: record.id, title: record.setup.isStarted ? "Retry Move" : "Retry Setup"))
        } else if case .needsWorkspace = record.setup, isTriageConfigured() {
            items.append(.retryTriage(taskID: record.id))
        }
        items.append(.delete(taskID: record.id))
        return items
    }

    static func pullRequestLine(_ item: TaskBoardItem) -> String? {
        guard let link = item.pullRequest else { return nil }
        guard let state = item.pullRequestState else { return "PR #\(link.number)" }
        if state.state == .open, state.isDraft {
            return "PR #\(link.number) · draft"
        }
        return "PR #\(link.number) · \(state.state.rawValue)"
    }

    /// "Created from the CLI · 2d ago · toastty".
    static func originLine(_ item: TaskBoardItem, now: Date) -> String {
        guard let record = item.record else {
            return ["Task space without a task record", item.projectTitle].compactMap { $0 }.joined(separator: " · ")
        }
        let source: String
        switch record.source {
        case .cli: source = "Created from the CLI"
        case .agent: source = "Created by an agent"
        case .recovered: source = "Rebuilt from its task space"
        case .adopted: source = "Tracked from an existing task space"
        case .quickEntry: source = "Created from quick entry"
        }
        let age = TaskAge.label(since: record.createdAt, now: now)
        return [source, age == "now" ? "just now" : "\(age) ago", item.projectTitle].compactMap { $0 }.joined(separator: " · ")
    }

    /// What happened to the task, oldest first.
    static func history(_ item: TaskBoardItem) -> [String] {
        guard let record = item.record else { return [] }
        var lines = ["Created" + (record.attachments.isEmpty ? "" : ", with \(record.attachments.count) \(record.attachments.count == 1 ? "attachment" : "attachments")")]
        if let worktree = record.worktree {
            if worktree.isDetached {
                let at = record.operation.base.map { " at \($0.ref) (\($0.sha.prefix(8)))" } ?? ""
                lines.append("Started in a worktree on no branch\(at)")
            } else {
                lines.append("Moved to worktree \(worktree.branch)")
            }
        }
        if let link = item.pullRequest {
            lines.append("PR #\(link.number) opened")
        }
        if record.readyForReviewAt != nil { lines.append("Marked ready for review") }
        if record.mergeRequestedAt != nil { lines.append("Merge accepted") }
        if record.mergeCancelledAt != nil, record.mergeRequestedAt == nil { lines.append("Merge cancelled") }
        if let release = record.release {
            lines.append("Releasing \(release.childTaskIDs.count) \(release.childTaskIDs.count == 1 ? "task" : "tasks")")
        }
        if record.mergedAt != nil { lines.append("Merged") }
        if let tag = record.releaseTag { lines.append("Shipped in \(tag)") }
        if record.doneAt != nil { lines.append("Marked done") }
        if record.archivedAt != nil { lines.append("Archived") }
        if record.attachmentsRemovedAt != nil { lines.append("Attached files removed a week after it finished") }
        if let cleanup = record.cleanup {
            lines.append(contentsOf: cleanup.stepsDone.map { $0.prefix(1).uppercased() + $0.dropFirst() })
        }
        return lines
    }
}

/// A task's square mark: the same family as the sidebar's task space marks.
struct TaskStageMark: View {
    let item: TaskBoardItem

    var body: some View {
        Group {
            switch item.stage {
            case .inbox:
                RoundedRectangle(cornerRadius: 1.5)
                    .strokeBorder(ToastyTheme.sidebarTaskInboxMark, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                    .frame(width: 9, height: 9)
            case .needsYou(let attention):
                switch attention {
                case .review, .readyForReview:
                    tinted(ToastyTheme.sidebarTaskReviewMarkBackground) {
                        Circle().fill(ToastyTheme.sidebarTaskReviewMark).frame(width: 4.5, height: 4.5)
                    }
                case .pickWorkspace, .setupFailed, .moveFailed:
                    RoundedRectangle(cornerRadius: 1.5)
                        .strokeBorder(ToastyTheme.sessionNeedsApprovalText, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                        .frame(width: 9, height: 9)
                case .agentError:
                    RoundedRectangle(cornerRadius: 1.5).fill(ToastyTheme.sessionErrorText).frame(width: 7, height: 7)
                case .agentFinished:
                    // The sidebar's ready square: filled while the turn is
                    // unread, an outline once the user has looked.
                    if item.hasUnreadTurn {
                        RoundedRectangle(cornerRadius: 1.5).fill(ToastyTheme.sessionReadyText).frame(width: 7, height: 7)
                    } else {
                        RoundedRectangle(cornerRadius: 1.5)
                            .strokeBorder(ToastyTheme.sessionReadyText, lineWidth: 1.2)
                            .frame(width: 7, height: 7)
                    }
                case .agentNeedsInput, .taskSpaceClosed, .cleanupStopped:
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(ToastyTheme.sessionNeedsApprovalText)
                        .frame(width: 7, height: 7)
                        .overlay {
                            RoundedRectangle(cornerRadius: 1.5).stroke(ToastyTheme.sidebarSessionRailApprovalHalo, lineWidth: 3)
                        }
                }
            case .running:
                if item.agent == .working {
                    SessionStatusIndicator(state: .spinner, size: 9, lineWidth: 1.4)
                } else {
                    RoundedRectangle(cornerRadius: 1.5)
                        .strokeBorder(ToastyTheme.sidebarSubspaceQuietMark, lineWidth: 1.2)
                        .frame(width: 7, height: 7)
                }
            case .toShip:
                tinted(ToastyTheme.sidebarTaskToShipMarkBackground) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 6.5, weight: .black))
                        .foregroundStyle(ToastyTheme.sidebarTaskToShipMark)
                }
            case .done:
                tinted(ToastyTheme.sidebarSubspaceDoneMarkBackground) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 6.5, weight: .black))
                        .foregroundStyle(ToastyTheme.sidebarSubspaceDoneMark)
                }
            case .archived:
                tinted(ToastyTheme.sidebarWorkspaceTagBackground) {
                    Image(systemName: "xmark")
                        .font(.system(size: 6, weight: .black))
                        .foregroundStyle(ToastyTheme.sidebarSubspaceQuietMark)
                }
            }
        }
        .frame(width: 12, height: 16)
        .accessibilityHidden(true)
    }

    private func tinted(_ background: Color, @ViewBuilder content: () -> some View) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(background)
            .frame(width: 10, height: 10)
            .overlay(content: content)
    }
}
