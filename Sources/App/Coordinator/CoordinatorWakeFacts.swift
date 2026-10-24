import CoreState
import Foundation

/// Only task facts belong in the wake identity. Brief edits, transcript
/// revisions, UI state, and observation timestamps must not trigger a reply.
struct CoordinatorWakeFacts: Codable, Equatable {
    enum Stage: String, Codable {
        case inbox, running, toShip, done, archived
        case pickWorkspace, setupFailed, moveFailed, taskSpaceClosed
        case agentNeedsInput, agentError, review, readyForReview, agentFinished, cleanupStopped

        var needsAttention: Bool {
            switch self {
            case .inbox, .running, .done, .archived: false
            default: true
            }
        }

        var isOutcome: Bool { self == .toShip || self == .done || self == .archived }
    }

    var taskID: UUID
    var stage: Stage
    var attentionDetail: String?
    var pullRequestURL: String?
    var headSHA: String?
    var baseRefName: String?
    var pullRequestState: String?
    var isDraft: Bool?
    var reportedIntentID: UUID?
    var reportedOutcome: String?
    var reportedDetail: String?

    init(taskID: UUID, stage: TaskStage, pullRequestURL: String? = nil,
         pullRequestState: TaskPullRequestState? = nil,
         action: CoordinatorReviewAction? = nil) {
        self.taskID = taskID
        switch stage {
        case .inbox: self.stage = .inbox
        case .running: self.stage = .running
        case .toShip: self.stage = .toShip
        case .done: self.stage = .done
        case .archived: self.stage = .archived
        case .needsYou(let attention):
            switch attention {
            case .pickWorkspace(let reason): self.stage = .pickWorkspace; attentionDetail = reason
            case .setupFailed(let reason): self.stage = .setupFailed; attentionDetail = reason
            case .moveFailed(let reason): self.stage = .moveFailed; attentionDetail = reason
            case .cleanupStopped(let reason): self.stage = .cleanupStopped; attentionDetail = reason
            case .taskSpaceClosed: self.stage = .taskSpaceClosed
            case .agentNeedsInput: self.stage = .agentNeedsInput
            case .agentError: self.stage = .agentError
            case .review: self.stage = .review
            case .readyForReview: self.stage = .readyForReview
            case .agentFinished: self.stage = .agentFinished
            }
        }
        self.pullRequestURL = pullRequestURL
        headSHA = pullRequestState?.headSHA?.lowercased()
        baseRefName = pullRequestState?.baseRefName
        self.pullRequestState = pullRequestState?.state.rawValue
        isDraft = pullRequestState?.isDraft
        // User intent delivery is the task action's responsibility. Only a
        // task-agent outcome is a new fact for this notification path.
        if let report = action?.agentOutcome {
            reportedIntentID = action?.intentID
            reportedOutcome = report.state.rawValue
            reportedDetail = report.message
        }
    }
}

struct CoordinatorWakeCandidate {
    var facts: CoordinatorWakeFacts
    var hasCurrentBrief: Bool
    /// PR cache state is runtime-only. Absence after relaunch is not a new head
    /// and cannot establish that the stored brief is missing or stale.
    var hasKnownIdentity = true

    static func reconcile(items: [TaskBoardItem], reviews: [CoordinatorReviewItem]) -> [Self] {
        var seen: Set<UUID> = []
        return items.compactMap { item in
            guard let taskID = item.taskID, seen.insert(taskID).inserted else { return nil }
            let url = item.pullRequest?.url ?? item.record?.pullRequestURL
            let head = item.pullRequestState?.headSHA
            let base = item.pullRequestState?.baseRefName
            var pullRequestState = item.pullRequestState
            // A recorded merge remains authoritative after task cleanup, when
            // the board no longer refreshes the PR cache for this finished task.
            if pullRequestState == nil, item.record?.mergedAt != nil {
                pullRequestState = .init(state: .merged)
            }
            let matching = reviews.filter { $0.taskID == taskID && $0.pullRequestURL == url }
            let current = matching.first {
                $0.headSHA.lowercased() == item.pullRequestState?.headSHA?.lowercased()
                    && base != nil && $0.baseRefName == base
                    && $0.observedOutcome.state != .headChanged
            }
            return Self(facts: CoordinatorWakeFacts(taskID: taskID, stage: item.stage,
                pullRequestURL: url, pullRequestState: pullRequestState, action: current?.userAction),
                hasCurrentBrief: current != nil,
                hasKnownIdentity: url == nil || (head.map(CoordinatorReviewItem.isValidCommitID) == true
                    && base?.isEmpty == false))
        }
    }
}

struct CoordinatorWakeState: Codable, Equatable {
    var version = 1
    var automaticStartAttempted = false
    /// A fact is handled either because it needs no wake, or because a delivery
    /// was attempted. Keeping that decision before send prevents crash replay.
    var handled: [String: CoordinatorWakeFacts] = [:]

    mutating func plan(_ candidates: [CoordinatorWakeCandidate]) -> [CoordinatorWakeFacts] {
        var pending: [CoordinatorWakeFacts] = []
        var seen: Set<UUID> = []
        for candidate in candidates {
            var fact = candidate.facts
            guard seen.insert(fact.taskID).inserted else { continue }
            let key = fact.taskID.uuidString
            let previous = handled[key]
            if !candidate.hasKnownIdentity {
                guard let previous, fact.pullRequestURL == previous.pullRequestURL else { continue }
                // Retain known PR facts only for comparison. A changed task
                // stage still wakes; the agent must reread current records.
                fact.headSHA = fact.headSHA ?? previous.headSHA
                fact.baseRefName = fact.baseRefName ?? previous.baseRefName
                fact.pullRequestState = fact.pullRequestState ?? previous.pullRequestState
                fact.isDraft = fact.isDraft ?? previous.isDraft
                fact.reportedIntentID = previous.reportedIntentID
                fact.reportedOutcome = previous.reportedOutcome
                fact.reportedDetail = previous.reportedDetail
            }
            guard previous != fact else { continue }
            let missingBrief = candidate.hasKnownIdentity && fact.stage.needsAttention
                && !fact.stage.isOutcome && !candidate.hasCurrentBrief
            let changedOutcome = previous != nil && (fact.stage.needsAttention || fact.stage.isOutcome)
            if missingBrief || changedOutcome {
                pending.append(fact)
            } else {
                // Establish a baseline for already-reviewed and old completed
                // tasks. Later stage/head changes remain visible to the planner.
                handled[key] = fact
            }
        }
        return pending
    }
}
