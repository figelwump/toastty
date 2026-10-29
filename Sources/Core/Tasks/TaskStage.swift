import Foundation

/// Where a task stands: worked out from its record and from what Toastty
/// sees now, never stored, so it cannot go stale. The rules are checked in
/// order and the first match wins: a stopped cleanup, Archived, Done, To
/// ship, Needs you, Starting, Running, Idle. Needs you comes before
/// Starting, so a task whose setup failed counts toward the Needs you badge.
public enum TaskStage: Equatable, Sendable {
    /// Setup, triage, or a move into a worktree is under way. Lists show it
    /// with Running.
    case starting
    case needsYou(Attention)
    case running
    /// Nothing is under way and nothing waits for the user: the agent is at
    /// the prompt with its last turn read, or no agent runs.
    case idle
    case toShip
    case done
    case archived

    /// Why a task needs the user.
    public enum Attention: Equatable, Sendable {
        /// Triage could not place the task; the user picks a workspace.
        case pickWorkspace(reason: String)
        case setupFailed(reason: String)
        /// The move into a worktree failed.
        case moveFailed(reason: String)
        /// The task space closed before the task finished.
        case taskSpaceClosed
        /// The agent asked a question or wants an approval.
        case agentNeedsInput
        case agentError
        /// The pull request is open and the agent is idle.
        case review
        /// The agent marked work without a pull request ready.
        case readyForReview
        /// The agent finished a turn the user has not read yet and waits
        /// for the next prompt.
        case agentFinished
        /// Closing the task space or removing the worktree stopped, after a
        /// merge, an archive or a release: "Merged · clean up?".
        case cleanupStopped(reason: String)

        /// Whether the task has not reached its task space yet: setup or
        /// the move into a worktree failed.
        public var isBeforeStart: Bool {
            switch self {
            case .pickWorkspace, .setupFailed, .moveFailed: true
            case .taskSpaceClosed, .agentNeedsInput, .agentError, .review, .readyForReview, .agentFinished, .cleanupStopped: false
            }
        }
    }

    /// The groups lists show, in their order.
    public enum Group: Int, CaseIterable, Comparable, Sendable {
        case needsYou
        case running
        case idle
        case toShip
        case done
        case archived

        public static func < (lhs: Group, rhs: Group) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// The group a list shows the task in. A task that is starting lists
    /// with Running, and one whose start failed with Needs you.
    public var group: Group {
        switch self {
        case .needsYou: .needsYou
        case .starting, .running: .running
        case .idle: .idle
        case .toShip: .toShip
        case .done: .done
        case .archived: .archived
        }
    }

    /// Whether the task counts toward the Needs you badge.
    public var needsUser: Bool {
        if case .needsYou = self { return true }
        return false
    }

    /// Whether the task's work is over: it shipped, finished, or was
    /// archived. A merged task waiting for a release is not finished: its
    /// task space stays open until the release ships.
    public var isFinished: Bool {
        switch self {
        case .done, .archived: true
        case .starting, .needsYou, .running, .idle, .toShip: false
        }
    }

    /// Whether the task has not reached its task space yet, or is still
    /// moving into its worktree: setup, triage or the move is under way, or
    /// one of them failed.
    public var isBeforeStart: Bool {
        switch self {
        case .starting: true
        case .needsYou(let attention): attention.isBeforeStart
        case .running, .idle, .toShip, .done, .archived: false
        }
    }

    public static func derive(_ facts: TaskStageFacts, live: TaskLiveFacts, releaseTagsConfigured: Bool) -> TaskStage {
        // A cleanup that stopped leaves a task space or a worktree behind,
        // whatever the task's stage would be without it.
        if let problem = live.cleanupProblem ?? facts.cleanupProblem {
            return .needsYou(.cleanupStopped(reason: problem))
        }
        if facts.archivedAt != nil {
            return .archived
        }
        if facts.doneAt != nil || facts.shippedAt != nil {
            return .done
        }
        if facts.mergedAt != nil || live.pullRequest?.state == .merged {
            return releaseTagsConfigured ? .toShip : .done
        }
        switch facts.setup {
        case .needsWorkspace(let reason):
            return .needsYou(.pickWorkspace(reason: reason))
        case .setupFailed(let reason):
            return .needsYou(.setupFailed(reason: reason))
        case .routing, .settingUp:
            return .starting
        case .started:
            break
        }
        switch facts.startWork {
        case .failed(let reason)?:
            return .needsYou(.moveFailed(reason: reason))
        case .running?:
            return .starting
        case .finished?, nil:
            break
        }
        if facts.hasTaskSpace, live.taskSpaceOpen == false {
            return .needsYou(.taskSpaceClosed)
        }
        switch live.agent {
        case .needsInput:
            return .needsYou(.agentNeedsInput)
        case .error:
            return .needsYou(.agentError)
        case .working:
            return .running
        case .finished, .idle, .none:
            break
        }
        // An accepted merge that is still under way is not waiting for a
        // review. A merge skill that stopped on a blocker ended its turn, so
        // its activity is gone and the task falls to Review below.
        if live.merge != nil {
            return .running
        }
        if let pullRequest = live.pullRequest {
            if pullRequest.state == .open, pullRequest.isDraft == false {
                return .needsYou(.review)
            }
        } else if live.hasPullRequestLink {
            // Without an answer from GitHub, a linked pull request and an
            // idle agent are the best sign that the work waits for review.
            return .needsYou(.review)
        }
        if facts.readyForReviewAt != nil {
            return .needsYou(.readyForReview)
        }
        // An agent that ended its turn to wait for another task is still
        // running. Otherwise a finished turn that is unread makes the next
        // step the user's, and once the user reads it the task is idle.
        if live.waitsOnTask {
            return .running
        }
        if live.agent == .finished {
            return .needsYou(.agentFinished)
        }
        return .idle
    }
}

/// The parts of a task the stage depends on: its record, or for a task
/// space without one, the little Toastty knows about it.
public struct TaskStageFacts: Equatable, Sendable {
    public var setup: TaskSetupState
    public var startWork: TaskStartWorkState?
    /// Whether setup made a task space, which may have closed since.
    public var hasTaskSpace: Bool
    public var readyForReviewAt: Date?
    public var mergedAt: Date?
    public var shippedAt: Date?
    public var archivedAt: Date?
    public var doneAt: Date?
    /// Why the record's cleanup stopped, if it did.
    public var cleanupProblem: String?

    public init(
        setup: TaskSetupState,
        startWork: TaskStartWorkState? = nil,
        hasTaskSpace: Bool,
        readyForReviewAt: Date? = nil,
        mergedAt: Date? = nil,
        shippedAt: Date? = nil,
        archivedAt: Date? = nil,
        doneAt: Date? = nil,
        cleanupProblem: String? = nil
    ) {
        self.setup = setup
        self.startWork = startWork
        self.hasTaskSpace = hasTaskSpace
        self.readyForReviewAt = readyForReviewAt
        self.mergedAt = mergedAt
        self.shippedAt = shippedAt
        self.archivedAt = archivedAt
        self.doneAt = doneAt
        self.cleanupProblem = cleanupProblem
    }

    public init(record: TaskRecord) {
        self.init(
            setup: record.setup,
            startWork: record.startWork?.state,
            hasTaskSpace: record.operation.taskSpace != nil,
            readyForReviewAt: record.readyForReviewAt,
            mergedAt: record.mergedAt,
            shippedAt: record.shippedAt,
            archivedAt: record.archivedAt,
            doneAt: record.doneAt,
            cleanupProblem: record.cleanup?.problem
        )
    }

    /// A task space with no record. Toastty only watches it: its done mark
    /// counts as done, and the mark clears when its work starts again.
    public static func observed(doneAt: Date?) -> TaskStageFacts {
        TaskStageFacts(setup: .started, hasTaskSpace: true, doneAt: doneAt)
    }
}

/// What the agents in a task space are doing, the most urgent first.
public enum TaskAgentActivity: Equatable, Sendable {
    /// No agent session in the task space.
    case none
    /// At the prompt with no unread turn: just started or restored, or the
    /// user has read the turn it finished.
    case idle
    /// Finished a turn the user has not read yet, and waits for a prompt.
    case finished
    case working
    case needsInput
    case error
}

/// An accepted merge that has not finished.
public enum TaskMergeActivity: Equatable, Sendable {
    /// The agent is checking the pull request with the merge skill.
    case checking
    /// Toastty is merging it.
    case merging
    /// Toastty waits for GitHub's checks or a required review, then merges.
    case waitingForChecks
    /// The pull request merged; Toastty closes the task space and removes
    /// the worktree.
    case cleaningUp
}

/// GitHub's last answer about a pull request.
public struct TaskPullRequestState: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case open
        case closed
        case merged
    }

    public var state: State
    public var isDraft: Bool
    public var headSHA: String?
    public var mergeCommit: String?
    /// Whether GitHub would merge it now, and why not. `nil` when the
    /// answer did not say.
    public var mergeability: PullRequestMergeability?

    public init(
        state: State,
        isDraft: Bool = false,
        headSHA: String? = nil,
        mergeCommit: String? = nil,
        mergeability: PullRequestMergeability? = nil
    ) {
        self.state = state
        self.isDraft = isDraft
        self.headSHA = headSHA
        self.mergeCommit = mergeCommit
        self.mergeability = mergeability
    }
}

/// What Toastty sees now, from caches only, so working out a stage never
/// waits on `gh` or `git`.
public struct TaskLiveFacts: Equatable, Sendable {
    public var taskSpaceOpen: Bool
    public var agent: TaskAgentActivity
    /// `nil` until GitHub answered, or when `gh` is unavailable.
    public var pullRequest: TaskPullRequestState?
    /// Whether the task has a pull request link at all.
    public var hasPullRequestLink: Bool
    public var merge: TaskMergeActivity?
    /// Why the merge's cleanup stopped, while Toastty still holds it.
    public var cleanupProblem: String?
    /// Whether the task holds a pending watch on another task: its agent
    /// ended its turn to wait, so the task is still running.
    public var waitsOnTask: Bool

    public init(
        taskSpaceOpen: Bool,
        agent: TaskAgentActivity = .none,
        pullRequest: TaskPullRequestState? = nil,
        hasPullRequestLink: Bool = false,
        merge: TaskMergeActivity? = nil,
        cleanupProblem: String? = nil,
        waitsOnTask: Bool = false
    ) {
        self.taskSpaceOpen = taskSpaceOpen
        self.agent = agent
        self.pullRequest = pullRequest
        self.hasPullRequestLink = hasPullRequestLink
        self.merge = merge
        self.cleanupProblem = cleanupProblem
        self.waitsOnTask = waitsOnTask
    }
}
