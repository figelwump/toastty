import CoreState
import SwiftUI

/// The words the sidebar and the Tasks view use for a task. Kept apart from
/// the views so they can be tested without hosting them.
enum TaskBoardPresentation {
    static func groupTitle(_ group: TaskStage.Group) -> String {
        switch group {
        case .needsYou: "Needs you"
        case .running: "Running"
        case .idle: "Idle"
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
    static func statusLine(_ item: TaskBoardItem, now: Date = Date()) -> String {
        let line = stageStatusLine(item, now: now)
        guard let until = item.cleanupHeldUntil else { return line }
        return "\(line) · \(heldCleanupPhrase(until: until, now: now))"
    }

    /// Whether the task lists in Needs you for its unread finished turn
    /// while its stage is calmer, as a task whose agent ended its turn to
    /// wait on another task does. The sidebar draws its task space's row as
    /// any other unread turn, and the Tasks view draws its row the same way.
    static func showsUnreadTurnOverStage(_ item: TaskBoardItem) -> Bool {
        guard item.taskSpaceStatus == .ready else { return false }
        switch item.stage {
        case .running, .idle: return true
        case .starting, .needsYou, .toShip, .done, .archived: return false
        }
    }

    /// The Tasks view row's line: the stage's, unless the row lists for an
    /// unread finished turn; see `showsUnreadTurnOverStage`. A merge under
    /// way keeps its own line, since the merge goes on without the user.
    static func tasksViewStatusLine(_ item: TaskBoardItem, now: Date = Date()) -> String {
        showsUnreadTurnOverStage(item) && item.merge == nil ? finishedTurnLine(item) : statusLine(item, now: now)
    }

    private static func finishedTurnLine(_ item: TaskBoardItem) -> String {
        "\(agentName(item)) finished · waiting for you"
    }

    /// When a held task space closes, in whole hours rounded up.
    static func heldCleanupPhrase(until: Date, now: Date) -> String {
        let remaining = until.timeIntervalSince(now)
        guard remaining > 0 else { return "task space closes soon" }
        return "task space closes in \(Int((remaining / 3_600).rounded(.up))) h"
    }

    private static func stageStatusLine(_ item: TaskBoardItem, now: Date) -> String {
        switch item.stage {
        case .starting:
            switch item.record?.setup {
            case .started?:
                return item.record.map { "Moving to worktree · \(TaskSetupPresentation.startWorkStep($0))" } ?? "Moving to worktree"
            case .routing?: return "Setting up · choosing a workspace"
            default: return "Setting up"
            }
        case .needsYou(let attention):
            switch attention {
            case .pickWorkspace: return "⚠ pick a workspace"
            case .setupFailed: return "⚠ setup failed"
            case .moveFailed: return "⚠ worktree failed"
            case .taskSpaceClosed: return "Task space closed before the task finished"
            case .agentNeedsInput: return "\(agentName(item)) is waiting for your input"
            case .startWaitsInTerminal: return "\(agentName(item)) may be waiting in its terminal"
            case .awaitingReply: return replyLine(item)
            case .agentError: return "\(agentName(item)) stopped with an error"
            case .review, .readyForReview:
                if item.record?.mergeFailure != nil { return "⚠ merge stopped" }
                if attention == .review, let problem = item.pullRequestLookupProblem { return lookupProblemLine(problem) }
                return "Ready for your review"
            case .agentFinished: return finishedTurnLine(item)
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
        case .idle:
            if restingWait(item) != nil {
                let agent = item.agent == TaskAgentActivity.none ? "No agent running" : agentName(item)
                return "\(agent) · \(waitingLine(item, now: now, capitalized: false))"
            }
            return item.agent == TaskAgentActivity.none ? "No agent running" : "\(agentName(item)) · idle"
        case .toShip: return item.finishedThroughChildren ? "Child tasks merged · waiting for a release" : "Merged · waiting for a release"
        case .done: return item.record?.shippedAt != nil ? "Shipped" : "Done"
        case .archived: return "Archived"
        }
    }

    /// The status line of a task whose pull request Toastty cannot read
    /// from GitHub, with what to do.
    static func lookupProblemLine(_ problem: PullRequestLookupProblem) -> String {
        switch problem {
        case .ghMissing: "⚠ install gh to check the PR"
        case .notSignedIn: "⚠ run gh auth login to check the PR"
        case .other: "⚠ PR check failed"
        }
    }

    /// Why Toastty cannot read the pull request, and what to do, for the
    /// detail pane and `task get`.
    static func lookupProblemReason(_ problem: PullRequestLookupProblem) -> String {
        switch problem {
        case .ghMissing:
            "gh is not installed, or not on your login shell's PATH: install it (brew install gh), then run gh auth login"
        case .notSignedIn:
            "gh is not signed in to GitHub: run gh auth login in a terminal"
        case .other(let message):
            "gh could not read the PR: \(message)"
        }
    }

    /// What a task that waits for the user's reply shows: the agent's
    /// question when it gave one.
    static func replyLine(_ item: TaskBoardItem) -> String {
        if let question = item.record?.replyRequest?.question {
            return "Asks: \(question)"
        }
        return "\(agentName(item)) is waiting for your reply"
    }

    /// The agent's `task waiting` mark while the task rests in Idle: the
    /// task waits on something outside Toastty, and its rows show a clock.
    /// A task whose agent works, or that needs the user, shows that
    /// instead.
    static func restingWait(_ item: TaskBoardItem) -> TaskWaiting? {
        item.stage == .idle ? item.record?.waiting : nil
    }

    /// What a task that waits outside Toastty waits for, and when its wake
    /// comes: "Waiting for email replies · wakes Dec 1". The sidebar row
    /// shows it under the clock; the status line adds the agent's name.
    static func waitingLine(_ item: TaskBoardItem, now: Date = Date(), capitalized: Bool = true) -> String {
        guard let waiting = item.record?.waiting else { return "" }
        let wake = waiting.hasPendingWake ? waiting.wakeAt.map { " · wakes \(wakePhrase($0, now: now))" } : nil
        return "\(capitalized ? "Waiting" : "waiting") for \(waiting.on)\(wake ?? "")"
    }

    /// When a wait's wake comes, for a row: "9:00 AM" today, "Dec 1" this
    /// year, "Feb 1, 2027" later.
    static func wakePhrase(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// When a wait's wake comes, for the detail pane: "on Dec 1 at 9:00 AM".
    static func wakeDetailPhrase(_ date: Date, now: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        return "on \(wakePhrase(date, now: now)) at \(time)"
    }

    /// What the mark of a task the user asked to release right after its
    /// merge says, in tooltips and spoken labels.
    static let releaseAfterMergeLabel = "release right after merge"

    /// When the user asked to release the task right after it merges, while
    /// the request still waits: `nil` once the task is Done or archived.
    static func releaseAfterMergeRequestedAt(_ item: TaskBoardItem) -> Date? {
        item.stage.isFinished ? nil : item.record?.releaseAfterMerge?.requestedAt
    }

    /// `label`, with the request's mark added when the task's rows show it.
    static func addingReleaseAfterMerge(to label: String, _ item: TaskBoardItem) -> String {
        releaseAfterMergeRequestedAt(item) == nil ? label : "\(label), \(releaseAfterMergeLabel)"
    }

    /// The stage's name and why, for the detail pane.
    static func stageDescription(_ item: TaskBoardItem, now: Date = Date()) -> (stage: String, why: String) {
        let description = stageDescriptionWithoutHold(item, now: now)
        guard let until = item.cleanupHeldUntil else { return description }
        return (description.stage, "\(description.why), \(heldCleanupPhrase(until: until, now: now))")
    }

    private static func stageDescriptionWithoutHold(_ item: TaskBoardItem, now: Date) -> (stage: String, why: String) {
        switch item.stage {
        case .starting: return ("Starting", statusLine(item))
        case .needsYou(let attention):
            switch attention {
            case .pickWorkspace(let reason), .setupFailed(let reason), .moveFailed(let reason):
                return ("Needs you", reason)
            case .taskSpaceClosed: return ("Needs you", "task space closed")
            case .agentNeedsInput: return ("Needs you", "the agent asked for input")
            case .startWaitsInTerminal:
                return ("Needs you", "the agent has not started its first prompt; it may wait for an answer in its terminal, such as a login or a folder-trust question")
            case .awaitingReply: return ("Needs you", "the agent asked a question")
            case .agentError: return ("Needs you", "the agent stopped with an error")
            case .review, .readyForReview:
                if let failure = item.record?.mergeFailure {
                    return ("Review", "the last merge stopped: \(failure.reason)")
                }
                if attention == .readyForReview { return ("Review", "marked ready, agent idle") }
                if let problem = item.pullRequestLookupProblem { return ("Review", lookupProblemReason(problem)) }
                return ("Review", item.pullRequestState == nil ? "PR linked, agent idle" : "PR open, agent idle")
            case .agentFinished: return ("Needs you", "the agent finished its turn")
            case .cleanupStopped(let reason): return ("Needs you", reason)
            }
        case .running: return ("Running", statusLine(item, now: now))
        case .idle:
            if let waiting = restingWait(item) {
                let wake = waiting.hasPendingWake
                    ? waiting.wakeAt.map { "; Toastty wakes the agent \(wakeDetailPhrase($0, now: now))" } : nil
                return ("Idle", "waiting for \(waiting.on)\(wake ?? "")")
            }
            return ("Idle", statusLine(item, now: now))
        case .toShip:
            return ("To ship", item.finishedThroughChildren ? "child tasks merged, waiting for a release tag" : "merged, waiting for a release tag")
        case .done:
            if item.finishedThroughChildren { return ("Done", "child tasks finished") }
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
        /// A merged task whose task space Toastty holds open: clean up now.
        case closeTaskSpace

        var title: String {
            switch self {
            case .merge: "Merge"
            case .mergeWithoutChecks: "Merge Without Checks"
            case .cancelMerge: "Cancel Merge"
            case .markDone: "Mark Done"
            case .archive: "Archive…"
            case .cleanUp: "Clean Up"
            case .keepAsIs: "Keep As Is"
            case .closeTaskSpace: "Close Task Space"
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
            case .closeTaskSpace: "Close the task space, remove its worktree and delete its branches now, instead of a day after the merge"
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
            case .closeTaskSpace: "Unable to Close the Task Space of"
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
            case .closeTaskSpace: "closeTaskSpace"
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
        if item.cleanupHeldUntil != nil {
            return [.closeTaskSpace]
        }
        switch item.stage {
        case .needsYou(let attention) where attention.isBeforeStart == false && attention != .taskSpaceClosed:
            break
        case .running, .idle:
            break
        case .needsYou(.taskSpaceClosed):
            return [.archive]
        default:
            return []
        }
        var actions: [DetailAction] = []
        if item.hasOpenPullRequest, item.taskSpaceWorkspaceID != nil {
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
        if item.stage.isBeforeStart {
            guard let record = item.record else { return [] }
            return [setupMenuItems(record, isTriageConfigured: isTriageConfigured())]
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
    static func setupMenuItems(_ record: TaskRecord, isTriageConfigured: @autoclosure () -> Bool) -> [MenuItem] {
        var items: [MenuItem] = []
        if TaskSetupPresentation.canRetry(record) {
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
        case .remoteDevice: source = "Created from Toastty Mobile"
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

/// Where a task's setup or its move into a worktree stands, for the
/// Starting rows and the setup card.
enum TaskSetupPresentation {
    /// Whether setup has not finished, or the move into a worktree is
    /// running or failed: the setup card's controls apply.
    static func isSettingUp(_ record: TaskRecord) -> Bool {
        guard record.setup.isStarted else { return true }
        switch record.startWork?.state {
        case .running?, .failed?: return true
        case .finished?, nil: return false
        }
    }

    /// What a move into a worktree is doing now, from the steps it saved.
    static func startWorkStep(_ record: TaskRecord) -> String {
        let operation = record.operation
        if record.worktree == nil {
            return "making the worktree"
        }
        if operation.hookFinishedAt == nil {
            return "running create_hook"
        }
        guard let session = operation.worktreeSession, session.sessionID != nil else {
            return "waiting for the agent's turn to end"
        }
        if session.forked, session.nativeConversationID == nil {
            return "waiting for the forked agent"
        }
        return "closing the old session"
    }

    /// Whether Retry applies: setup or a move into a worktree failed.
    static func canRetry(_ record: TaskRecord) -> Bool {
        if case .setupFailed = record.setup { return true }
        if record.setup.isStarted, case .failed? = record.startWork?.state { return true }
        return false
    }

    /// Why setup or the move failed.
    static func failureReason(_ record: TaskRecord) -> String? {
        if case .setupFailed(let reason) = record.setup { return reason }
        if record.setup.isStarted, case .failed(let reason)? = record.startWork?.state { return reason }
        return nil
    }
}

/// The question mark inside the tinted box of a task that waits for the
/// user's reply, in the sidebar and the Tasks view.
struct TaskQuestionGlyph: View {
    var body: some View {
        Image(systemName: "questionmark")
            .font(.system(size: 6.5, weight: .black))
            .foregroundStyle(ToastyTheme.sidebarTaskQuestionMark)
    }
}

/// The clock mark of a task that rests in Idle while it waits on
/// something outside Toastty (`task waiting`), in the sidebar and the
/// Tasks view. It is still, unlike the spinner of work under way: the wait
/// can last months.
struct TaskWaitingGlyph: View {
    var body: some View {
        Image(systemName: "clock")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(ToastyTheme.sidebarSubspaceQuietMark)
            .accessibilityHidden(true)
    }
}

/// The small mark on the rows of a task the user asked to release right
/// after it merges, in the To ship color. It is not a control: the request
/// is set by asking an agent, or with `toastty task set-release`.
struct TaskReleaseAfterMergeMark: View {
    var body: some View {
        Image(systemName: "bolt.fill")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(ToastyTheme.sidebarTaskToShipMark.opacity(0.85))
            .help("Release right after merge")
            .accessibilityHidden(true)
    }
}

/// The ↳ mark to the left of a task's status mark when the task is drawn
/// under the task that started it, in the sidebar and in the Tasks view.
struct TaskChildArrowMark: View {
    var size: CGFloat = 9

    var body: some View {
        Image(systemName: "arrow.turn.down.right")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(ToastyTheme.sidebarChildContextText.opacity(0.8))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A task's square mark: the same family as the sidebar's task space marks.
struct TaskStageMark: View {
    let item: TaskBoardItem

    var body: some View {
        Group {
            switch item.stage {
            case .starting:
                RoundedRectangle(cornerRadius: 1.5)
                    .strokeBorder(ToastyTheme.sidebarTaskStartingMark, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                    .frame(width: 9, height: 9)
            case .needsYou(let attention):
                switch attention {
                case .review, .readyForReview:
                    tinted(ToastyTheme.sidebarTaskReviewMarkBackground) {
                        Circle().fill(ToastyTheme.sidebarTaskReviewMark).frame(width: 4.5, height: 4.5)
                    }
                case .awaitingReply:
                    tinted(ToastyTheme.sidebarTaskQuestionMarkBackground) {
                        TaskQuestionGlyph()
                    }
                case .pickWorkspace, .setupFailed, .moveFailed:
                    RoundedRectangle(cornerRadius: 1.5)
                        .strokeBorder(ToastyTheme.sessionNeedsApprovalText, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                        .frame(width: 9, height: 9)
                case .agentError:
                    RoundedRectangle(cornerRadius: 1.5).fill(ToastyTheme.sessionErrorText).frame(width: 7, height: 7)
                case .agentFinished:
                    readySquare
                case .agentNeedsInput, .startWaitsInTerminal, .taskSpaceClosed, .cleanupStopped:
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(ToastyTheme.sessionNeedsApprovalText)
                        .frame(width: 7, height: 7)
                        .overlay {
                            RoundedRectangle(cornerRadius: 1.5).stroke(ToastyTheme.sidebarSessionRailApprovalHalo, lineWidth: 3)
                        }
                }
            case .running, .idle:
                if TaskBoardPresentation.showsUnreadTurnOverStage(item) {
                    readySquare
                } else if item.agent == .working {
                    SessionStatusIndicator(state: .spinner, size: 9, lineWidth: 1.4)
                } else if TaskBoardPresentation.restingWait(item) != nil {
                    TaskWaitingGlyph()
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

    /// The sidebar's ready square for an unread turn.
    private var readySquare: some View {
        RoundedRectangle(cornerRadius: 1.5).fill(ToastyTheme.sessionReadyText).frame(width: 7, height: 7)
    }

    private func tinted(_ background: Color, @ViewBuilder content: () -> some View) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(background)
            .frame(width: 10, height: 10)
            .overlay(content: content)
    }
}
