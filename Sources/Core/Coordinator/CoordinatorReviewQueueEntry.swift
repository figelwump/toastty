import Foundation

/// Current task facts from native task and PR state. They are not a journal.
public struct CoordinatorReviewTaskFacts: Equatable, Sendable {
    public let taskID: UUID
    public var taskTitle: String
    public var projectRoot: String
    public var pullRequestURL: String?
    public var headSHA: String?
    public var baseRefName: String?
    public var needsReview: Bool
    public var isUrgent: Bool
    public var blocksOtherWork: Bool

    public init(
        taskID: UUID, taskTitle: String, projectRoot: String,
        pullRequestURL: String? = nil, headSHA: String? = nil, baseRefName: String? = nil,
        needsReview: Bool, isUrgent: Bool = false, blocksOtherWork: Bool = false
    ) {
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.projectRoot = projectRoot
        self.pullRequestURL = pullRequestURL
        self.headSHA = headSHA
        self.baseRefName = baseRefName
        self.needsReview = needsReview
        self.isUrgent = isUrgent
        self.blocksOtherWork = blocksOtherWork
    }
}

/// One native queue row. A missing brief remains visible without a coordinator.
public struct CoordinatorReviewQueueEntry: Equatable, Identifiable, Sendable {
    public var id: UUID { facts.taskID }
    public var taskID: UUID { facts.taskID }
    public var facts: CoordinatorReviewTaskFacts
    public var review: CoordinatorReviewItem?
    public var needsBrief: Bool { review == nil }

    public var effectivePriority: CoordinatorReviewBrief.Priority {
        if let priority = review?.priorityOverride { return priority }
        if facts.isUrgent { return .urgent }
        if facts.blocksOtherWork { return .blocking }
        return review?.brief.priority ?? .ready
    }

    public init(facts: CoordinatorReviewTaskFacts, review: CoordinatorReviewItem? = nil) {
        self.facts = facts
        self.review = review
    }

    /// A reported merge stays pending until the PR service confirms it.
    public var hasPendingAction: Bool {
        guard let review, let action = review.userAction,
              ![.merged, .closed].contains(review.observedOutcome.state) else { return false }
        switch action.kind {
        case .merge:
            return true
        case .changesRequested:
            return action.deliveryState != .delivered && action.agentOutcome?.state != .changesRequested
        }
    }
}
