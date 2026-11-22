import Foundation

/// What GitHub says about merging an open pull request now: its
/// `mergeStateStatus`, its `reviewDecision`, and a summary of the head
/// commit's checks.
public struct PullRequestMergeability: Equatable, Sendable {
    /// GitHub's `mergeStateStatus`.
    public enum MergeState: String, Equatable, Sendable {
        case clean
        case hasHooks = "has_hooks"
        /// Mergeable, but a check that is not required fails or still runs.
        case unstable
        /// A required check or review, or a branch rule, holds it.
        case blocked
        case behind
        /// Merge conflicts.
        case dirty
        case draft
        /// GitHub is still working it out, for example after a push.
        case unknown
    }

    /// The head commit's checks taken together.
    public enum Checks: Equatable, Sendable {
        case passing
        case running
        case failing
    }

    /// GitHub's `reviewDecision`.
    public enum ReviewDecision: String, Equatable, Sendable {
        case approved
        case changesRequested = "changes_requested"
        case reviewRequired = "review_required"
    }

    public var mergeState: MergeState
    /// `nil` when the head commit has no checks.
    public var checks: Checks?
    /// `nil` when the repository requires no review.
    public var reviewDecision: ReviewDecision?

    public init(mergeState: MergeState, checks: Checks? = nil, reviewDecision: ReviewDecision? = nil) {
        self.mergeState = mergeState
        self.checks = checks
        self.reviewDecision = reviewDecision
    }

    /// Whether GitHub had worked out the merge state.
    public var isKnown: Bool { mergeState != .unknown }
}

/// Why an open pull request is not ready to merge.
public enum PullRequestMergeBlocker: Equatable, Sendable {
    case draft
    case conflicts
    case behindBase
    case checksFailing
    case checksRunning
    case changesRequested
    case reviewRequired
    /// Blocked for a reason the answer does not name, such as a branch rule.
    case blocked

    public var label: String {
        switch self {
        case .draft: return "Draft"
        case .conflicts: return "Merge conflicts"
        case .behindBase: return "Behind base"
        case .checksFailing: return "Checks failing"
        case .checksRunning: return "Checks running"
        case .changesRequested: return "Changes requested"
        case .reviewRequired: return "Review required"
        case .blocked: return "Blocked"
        }
    }
}

extension TaskPullRequestState {
    /// Why GitHub would not merge this open pull request yet. `nil` when it
    /// is ready to merge, is not open, or GitHub has not worked it out.
    public var mergeBlocker: PullRequestMergeBlocker? {
        guard state == .open else { return nil }
        if isDraft { return .draft }
        guard let mergeability else { return nil }
        switch mergeability.mergeState {
        case .clean, .hasHooks, .unknown:
            return nil
        case .draft:
            return .draft
        case .dirty:
            return .conflicts
        case .behind:
            return .behindBase
        case .unstable:
            return mergeability.checks == .running ? .checksRunning : .checksFailing
        case .blocked:
            // A failing check needs work first; a review holds the pull
            // request longer than checks that are still running.
            if mergeability.checks == .failing { return .checksFailing }
            switch mergeability.reviewDecision {
            case .changesRequested?: return .changesRequested
            case .reviewRequired?: return .reviewRequired
            case .approved?, nil: break
            }
            return mergeability.checks == .running ? .checksRunning : .blocked
        }
    }
}
