import CoreState
import Foundation

/// Presentation rules shared by the queue and detail pane. No rule here sends
/// input or treats an agent's report as a fact read from GitHub.
enum CoordinatorReviewPresentation {
    /// Window-local selection owns the snapshot the user chose. Background
    /// updates can reorder rows, but only explicit selection replaces a brief.
    struct Selection: Equatable {
        private(set) var taskID: UUID?
        private(set) var reviewedBrief: CoordinatorReviewItem?

        mutating func selectInitial(_ entries: [CoordinatorReviewQueueEntry], saved: [CoordinatorReviewItem]) {
            guard taskID == nil, let first = entries.first else { return }
            select(first, saved: saved)
        }

        mutating func select(_ entry: CoordinatorReviewQueueEntry, saved: [CoordinatorReviewItem]) {
            taskID = entry.id
            reviewedBrief = CoordinatorReviewPresentation.displayedReview(entry, saved: saved)
        }
    }

    enum State: Equatable {
        case needsReview, needsBrief, headChanged, headUnknown, baseChanged, baseUnknown, closed
        case approvalRecorded, sending, delivered, deliveryUncertain, deliveryFailed
        case queued, checking, blocked, agentFailed, agentReportedMerge, changesRequested
        case merged, mergedDifferentHead, mergedDifferentBase

        var title: String {
            switch self {
            case .needsReview: "Ready for review"
            case .needsBrief: "Review brief needed"
            case .headChanged: "Head changed · review again"
            case .headUnknown: "Pull request head needs verification"
            case .baseChanged: "Destination changed · review again"
            case .baseUnknown: "Destination needs verification"
            case .closed: "Pull request closed"
            case .approvalRecorded: "Decision saved"
            case .sending: "Sending to task agent"
            case .delivered: "Delivered · awaiting result"
            case .deliveryUncertain: "Delivery uncertain · inspect task"
            case .deliveryFailed: "Delivery failed"
            case .queued: "Task agent queued the request"
            case .checking: "Task agent checking"
            case .blocked: "Task agent blocked"
            case .agentFailed: "Task agent reported failure"
            case .agentReportedMerge: "Agent reports merged · awaiting GitHub"
            case .changesRequested: "Changes requested"
            case .merged: "Merged · confirmed by GitHub"
            case .mergedDifferentHead: "Merged at a different head"
            case .mergedDifferentBase: "Merged into a different destination"
            }
        }

        var symbol: String {
            switch self {
            case .merged: "checkmark.circle.fill"
            case .headChanged, .headUnknown, .baseChanged, .baseUnknown, .mergedDifferentHead, .mergedDifferentBase,
                 .deliveryUncertain, .deliveryFailed, .blocked, .agentFailed: "exclamationmark.triangle"
            case .needsBrief: "doc.badge.clock"
            case .closed: "xmark.circle"
            case .needsReview: "circle.inset.filled"
            case .changesRequested: "bubble.left"
            case .approvalRecorded, .sending, .delivered, .queued, .checking, .agentReportedMerge: "clock"
            }
        }

        var needsAttention: Bool {
            switch self {
            case .needsReview, .needsBrief, .headChanged, .headUnknown, .baseChanged, .baseUnknown,
                 .deliveryUncertain, .deliveryFailed, .blocked, .agentFailed: true
            default: false
            }
        }

        var isComplete: Bool {
            switch self {
            case .merged, .mergedDifferentHead, .mergedDifferentBase, .closed: true
            default: false
            }
        }
    }

    /// Native reconciliation owns current queue membership and priority. Keep
    /// saved results reachable after cleanup removes a task from that queue.
    static func queue(native: [CoordinatorReviewQueueEntry], saved: [CoordinatorReviewItem], tasks: [TaskBoardItem] = []) -> [CoordinatorReviewQueueEntry] {
        var entries = native
        let visibleTasks = Set(native.map(\.taskID))
        let savedByTask = Dictionary(grouping: saved, by: \.taskID)
        let tasksByID = Dictionary(tasks.compactMap { task -> (UUID, TaskBoardItem)? in
            if let taskID = task.taskID { return (taskID, task) }
            if case .task(let taskID) = task.id { return (taskID, task) }
            return nil
        }, uniquingKeysWith: { first, _ in first })
        for (taskID, versions) in savedByTask where visibleTasks.contains(taskID) == false {
            guard let review = latest(versions) else { continue }
            entries.append(CoordinatorReviewQueueEntry(
                facts: CoordinatorReviewTaskFacts(
                    taskID: taskID, taskTitle: review.taskTitle, projectRoot: review.projectRoot,
                    pullRequestURL: review.pullRequestURL, headSHA: review.headSHA,
                    baseRefName: review.baseRefName, needsReview: false
                ),
                review: review
            ))
        }
        let completedTasks = Set(entries.compactMap { entry in
            isComplete(entry, task: tasksByID[entry.taskID], saved: savedByTask[entry.taskID] ?? []) ? entry.taskID : nil
        })
        return entries.sorted {
            // History stays reachable without crowding out the native queue.
            let lhsSavedOnly = !visibleTasks.contains($0.taskID)
            let rhsSavedOnly = !visibleTasks.contains($1.taskID)
            if lhsSavedOnly != rhsSavedOnly { return !lhsSavedOnly }
            let lhsComplete = completedTasks.contains($0.taskID)
            let rhsComplete = completedTasks.contains($1.taskID)
            if lhsComplete != rhsComplete { return lhsComplete == false }
            if rank($0.effectivePriority) != rank($1.effectivePriority) { return rank($0.effectivePriority) < rank($1.effectivePriority) }
            let lhsDate = $0.review?.createdAt ?? .distantPast
            let rhsDate = $1.review?.createdAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// An old brief can explain a changed head. The action gate still compares
    /// its exact SHA with current task facts before it enables a decision.
    static func displayedReview(_ entry: CoordinatorReviewQueueEntry, saved: [CoordinatorReviewItem]) -> CoordinatorReviewItem? {
        entry.review ?? latest(saved.filter {
            $0.taskID == entry.taskID && $0.pullRequestURL == entry.facts.pullRequestURL
        })
    }

    static func isComplete(_ entry: CoordinatorReviewQueueEntry, task: TaskBoardItem? = nil, saved: [CoordinatorReviewItem] = []) -> Bool {
        guard let review = displayedReview(entry, saved: saved) else { return false }
        return terminalOutcome(review, task: task) != nil
    }

    /// Keep the exact displayed revision until the user explicitly refreshes.
    static func matchesReviewedBrief(_ review: CoordinatorReviewItem, reviewed: CoordinatorReviewItem?) -> Bool {
        guard let reviewed else { return false }
        return reviewed.id == review.id && reviewed.revision == review.revision && reviewed.headSHA == review.headSHA
            && reviewed.baseRefName == review.baseRefName && reviewed.brief == review.brief
    }

    static func canDecide(_ review: CoordinatorReviewItem, currentReviewID: UUID?, reviewed: CoordinatorReviewItem?) -> Bool {
        currentReviewID == review.id && matchesReviewedBrief(review, reviewed: reviewed)
    }

    private static func latest(_ reviews: [CoordinatorReviewItem]) -> CoordinatorReviewItem? {
        reviews.max {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func isStale(_ review: CoordinatorReviewItem, task: TaskBoardItem?) -> Bool {
        if review.observedOutcome.state == .headChanged { return true }
        if let head = review.observedOutcome.headSHA, head.caseInsensitiveCompare(review.headSHA) != .orderedSame { return true }
        if let base = review.baseRefName, let actualBase = currentBase(review, task: task), actualBase != base { return true }
        guard let task else { return false }
        if let root = task.record?.projectRoot, root != review.projectRoot { return true }
        if let link = task.pullRequest, link.url != review.pullRequestURL { return true }
        if let head = task.pullRequestState?.headSHA, CoordinatorReviewItem.isValidCommitID(head),
           head.caseInsensitiveCompare(review.headSHA) != .orderedSame { return true }
        return false
    }

    static func state(_ review: CoordinatorReviewItem, task: TaskBoardItem? = nil) -> State {
        if let terminal = terminalOutcome(review, task: task) { return terminal }
        if let base = review.baseRefName, let actualBase = currentBase(review, task: task), base != actualBase { return .baseChanged }
        if isStale(review, task: task) { return .headChanged }
        if currentHead(review, task: task).map(CoordinatorReviewItem.isValidCommitID) != true { return .headUnknown }
        if review.baseRefName == nil || currentBase(review, task: task) == nil { return .baseUnknown }
        guard let action = review.userAction else { return .needsReview }
        if let outcome = action.agentOutcome {
            return switch outcome.state {
            case .queued: .queued
            case .checking: .checking
            case .blocked: .blocked
            case .failed: .agentFailed
            case .headChanged: .headChanged
            case .merged: .agentReportedMerge
            case .changesRequested: .changesRequested
            }
        }
        return switch action.deliveryState {
        case .pending: .approvalRecorded
        case .dispatching: .sending
        case .delivered: action.kind == .changesRequested ? .changesRequested : .delivered
        case .uncertain: .deliveryUncertain
        case .failed: .deliveryFailed
        }
    }

    static func canRequestChanges(_ review: CoordinatorReviewItem, task: TaskBoardItem?) -> Bool {
        task?.pullRequest?.url == review.pullRequestURL && review.userAction == nil && state(review, task: task) == .needsReview
    }

    static func canApprove(_ review: CoordinatorReviewItem, task: TaskBoardItem?) -> Bool {
        canRequestChanges(review, task: task) && task?.pullRequestState?.isDraft != true
    }

    static func canRetry(_ review: CoordinatorReviewItem, task: TaskBoardItem?) -> Bool {
        guard let task, task.pullRequest?.url == review.pullRequestURL,
              let head = currentHead(review, task: task), CoordinatorReviewItem.isValidCommitID(head),
              head.caseInsensitiveCompare(review.headSHA) == .orderedSame,
              let action = review.userAction, !isStale(review, task: task),
              review.baseRefName != nil, currentBase(review, task: task) == review.baseRefName,
              terminalOutcome(review, task: task) == nil,
              action.kind != .merge || task.pullRequestState?.isDraft != true else { return false }
        return action.deliveryState == .uncertain || action.deliveryState == .failed
            || (action.deliveryState == .delivered && [.blocked, .failed].contains(action.agentOutcome?.state))
    }

    private static func currentBase(_ review: CoordinatorReviewItem, task: TaskBoardItem?) -> String? {
        if task?.pullRequest?.url == review.pullRequestURL { return task?.pullRequestState?.baseRefName }
        return review.observedOutcome.baseRefName
    }

    private static func currentHead(_ review: CoordinatorReviewItem, task: TaskBoardItem?) -> String? {
        if task?.pullRequest?.url == review.pullRequestURL { return task?.pullRequestState?.headSHA }
        return review.observedOutcome.headSHA
    }

    private static func terminalOutcome(_ review: CoordinatorReviewItem, task: TaskBoardItem?) -> State? {
        let live = task?.pullRequest?.url == review.pullRequestURL ? task?.pullRequestState : nil
        if review.observedOutcome.state == .merged || live?.state == .merged {
            let head = live?.state == .merged ? live?.headSHA : review.observedOutcome.headSHA
            let base = live?.state == .merged ? live?.baseRefName : review.observedOutcome.baseRefName
            if let head, head.caseInsensitiveCompare(review.headSHA) != .orderedSame { return .mergedDifferentHead }
            if let expected = review.baseRefName, let base, expected != base { return .mergedDifferentBase }
            return .merged
        }
        if review.observedOutcome.state == .closed || live?.state == .closed { return .closed }
        return nil
    }

    static func priorityTitle(_ priority: CoordinatorReviewBrief.Priority) -> String {
        switch priority {
        case .urgent: "Urgent"
        case .blocking: "Blocking"
        case .ready: "Ready"
        }
    }

    static func deliveryDescription(_ delivery: CoordinatorReviewAction.DeliveryState) -> String {
        switch delivery {
        case .pending: "Saved; not yet sent"
        case .dispatching: "Sending to the task agent"
        case .delivered: "Delivered to the task agent"
        case .uncertain: "Delivery is uncertain. Inspect the task before taking another action."
        case .failed: "Delivery failed. Inspect the task for details."
        }
    }

    static func agentOutcomeDescription(_ outcome: CoordinatorReviewAction.AgentOutcome.State) -> String {
        switch outcome {
        case .queued: "Request queued"
        case .checking: "Checks in progress"
        case .blocked: "Work blocked"
        case .failed: "Action failed"
        case .headChanged: "Pull request head changed"
        case .merged: "Merged; waiting for GitHub confirmation"
        case .changesRequested: "Changes requested"
        }
    }

    private static func rank(_ priority: CoordinatorReviewBrief.Priority) -> Int {
        switch priority {
        case .urgent: 0
        case .blocking: 1
        case .ready: 2
        }
    }
}
