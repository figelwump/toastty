import Foundation

/// A request to be told when another task reaches a condition. It fires
/// once, and Toastty then sends a message to the agent of the task that
/// holds the watch.
///
/// A watch is saved on the record of the task it notifies, not the task it
/// watches, so it survives a relaunch and also outlives the watched task:
/// a deleted target fires it with that reason. `toastty task watch --wait`
/// keeps its watch in memory instead, since the waiting caller cannot
/// outlive the app either.
public struct TaskWatch: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// The task being watched.
    public var targetTaskID: UUID
    public var condition: TaskWatchCondition
    public var createdAt: Date
    public var state: TaskWatchState

    public init(
        id: UUID = UUID(),
        targetTaskID: UUID,
        condition: TaskWatchCondition,
        createdAt: Date,
        state: TaskWatchState = .pending
    ) {
        self.id = id
        self.targetTaskID = targetTaskID
        self.condition = condition
        self.createdAt = createdAt
        self.state = state
    }

    public var isPending: Bool {
        if case .pending = state { return true }
        return false
    }
}

public enum TaskWatchCondition: String, Codable, CaseIterable, Equatable, Sendable {
    /// The agent finished a turn after the watch was made and waits for a
    /// prompt. A turn that ended before the watch does not count, so a
    /// caller can send a request and then watch for its answer.
    case idle
    /// The agent waits for an approval or an answer to a question.
    case waiting
    case readyForReview = "ready-for-review"
    case merged
    case toShip = "to-ship"
    case done
    case archived

    /// Conditions that read the task's stage rather than its agent.
    public var isStageCondition: Bool {
        switch self {
        case .idle, .waiting: false
        case .readyForReview, .merged, .toShip, .done, .archived: true
        }
    }

    /// The words used in messages: "is now idle".
    public var phrase: String {
        switch self {
        case .idle: "is idle"
        case .waiting: "is waiting for input"
        case .readyForReview: "is ready for review"
        case .merged: "is merged"
        case .toShip: "is waiting to ship"
        case .done: "is done"
        case .archived: "is archived"
        }
    }
}

public enum TaskWatchState: Codable, Equatable, Sendable {
    case pending
    /// The condition held, or the watch could never fire (`impossible`).
    /// `delivered` stays false until the message reached the agent of the
    /// task that holds the watch; a `--wait` watch counts as delivered.
    case fired(at: Date, reason: String, impossible: Bool, delivered: Bool)

    private enum CodingKeys: String, CodingKey {
        case state
        case at
        case reason
        case impossible
        case delivered
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .state) {
        case "pending":
            self = .pending
        case "fired":
            self = .fired(
                at: try container.decode(Date.self, forKey: .at),
                reason: try container.decode(String.self, forKey: .reason),
                impossible: try container.decodeIfPresent(Bool.self, forKey: .impossible) ?? false,
                delivered: try container.decodeIfPresent(Bool.self, forKey: .delivered) ?? false
            )
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .state, in: container, debugDescription: "unknown watch state \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pending:
            try container.encode("pending", forKey: .state)
        case .fired(let at, let reason, let impossible, let delivered):
            try container.encode("fired", forKey: .state)
            try container.encode(at, forKey: .at)
            try container.encode(reason, forKey: .reason)
            try container.encode(impossible, forKey: .impossible)
            try container.encode(delivered, forKey: .delivered)
        }
    }
}

/// What a task's agent is doing, as a coordinator sees it.
public enum TaskAgentState: String, Codable, Equatable, Sendable {
    /// No managed agent session runs for the task.
    case notRunning
    case busy
    /// Waiting for an approval or an answer to a question.
    case waiting
    /// At its prompt, waiting for the next message.
    case idle
    case error
}

/// The facts a watch reads, gathered by the app from the live session and
/// the task's stage.
public struct TaskWatchFacts: Equatable, Sendable {
    public var activity: TaskAgentState
    /// When the agent's status last changed.
    public var activityChangedAt: Date?
    /// When the agent last finished a turn in this app run. A session
    /// restored after a relaunch has none until it finishes one.
    public var turnEndedAt: Date?
    /// The stage conditions the task meets now; see
    /// `TaskWatchEvaluation.stageConditions(stage:merged:)`.
    public var stages: Set<TaskWatchCondition>

    public init(
        activity: TaskAgentState,
        activityChangedAt: Date?,
        turnEndedAt: Date? = nil,
        stages: Set<TaskWatchCondition> = []
    ) {
        self.activity = activity
        self.activityChangedAt = activityChangedAt
        self.turnEndedAt = turnEndedAt
        self.stages = stages
    }
}

public enum TaskWatchEvaluation {
    /// Whether `condition` holds for a watch made at `createdAt`.
    public static func holds(_ condition: TaskWatchCondition, createdAt: Date, facts: TaskWatchFacts) -> Bool {
        switch condition {
        case .idle:
            // Only a turn that ended after the watch was made: an agent that
            // was idle all along, or was just restored, has not answered
            // anything yet.
            guard facts.activity == .idle, let endedAt = facts.turnEndedAt else { return false }
            return endedAt > createdAt
        case .waiting:
            return facts.activity == .waiting
        case .readyForReview, .merged, .toShip, .done, .archived:
            return facts.stages.contains(condition)
        }
    }

    /// The stage conditions a task in `stage` meets. A condition still holds
    /// after the task moves past it, in the order ready-for-review, merged,
    /// to-ship, done, so a watch fires even when the task skips a stage or
    /// moves on between two checks: a pull request can merge before Toastty
    /// sees it open, and a merge in a project without release tags goes
    /// straight to Done. `merged` says whether the pull request merged, which
    /// a Done stage alone does not tell.
    public static func stageConditions(stage: TaskStage, merged: Bool) -> Set<TaskWatchCondition> {
        switch stage {
        case .archived:
            return [.archived]
        case .done:
            return merged ? [.readyForReview, .merged, .toShip, .done] : [.readyForReview, .done]
        case .toShip:
            return [.readyForReview, .merged, .toShip]
        case .needsYou(.review), .needsYou(.readyForReview):
            return [.readyForReview]
        case .needsYou(.cleanupStopped):
            // "Merged · clean up?": the cleanup after the merge stopped, but
            // the merge happened.
            return merged ? [.readyForReview, .merged] : []
        case .starting, .needsYou, .running, .idle:
            return []
        }
    }

    /// What a fired watch says about its task. For a stage condition it is
    /// the furthest stage the task has reached, which can be past the one
    /// watched for; `merged` stays "is merged", which is true at every later
    /// stage.
    public static func reason(_ condition: TaskWatchCondition, facts: TaskWatchFacts) -> String {
        guard condition.isStageCondition, condition != .merged, condition != .archived else { return condition.phrase }
        let furthest = [TaskWatchCondition.done, .toShip, .readyForReview].first { facts.stages.contains($0) }
        return (furthest ?? condition).phrase
    }

    /// Why a watch can never fire now, if so: its task is archived and the
    /// watch waits for something else.
    public static func impossibility(_ condition: TaskWatchCondition, facts: TaskWatchFacts) -> String? {
        guard facts.stages.contains(.archived), condition != .archived else { return nil }
        return "was archived"
    }
}

extension TaskRecord {
    /// Watches whose message has not gone out yet: pending ones, and fired
    /// ones not yet delivered.
    public var activeWatches: [TaskWatch] {
        (watches ?? []).filter { watch in
            if case .fired(_, _, _, true) = watch.state { return false }
            return true
        }
    }

    /// Fired watches are kept for a while, so `task watch --wait` and
    /// `task.watches` can read the outcome; this drops the oldest beyond
    /// `keep` and any older than `maximumAge`.
    public mutating func pruneFiredWatches(now: Date, keep: Int = 20, maximumAge: TimeInterval = 24 * 3600) {
        guard var all = watches else { return }
        let fired = all.enumerated().compactMap { index, watch -> (Int, Date, Bool)? in
            guard case .fired(let at, _, _, let delivered) = watch.state else { return nil }
            return (index, at, delivered)
        }
        let byAge = fired.sorted { $0.1 > $1.1 }
        var drop = Set<Int>()
        for (rank, entry) in byAge.enumerated() {
            // An undelivered watch stays until its message goes out.
            guard entry.2 else { continue }
            if rank >= keep || now.timeIntervalSince(entry.1) > maximumAge {
                drop.insert(entry.0)
            }
        }
        guard drop.isEmpty == false else { return }
        all = all.enumerated().filter { drop.contains($0.offset) == false }.map(\.element)
        watches = all.isEmpty ? nil : all
    }
}
