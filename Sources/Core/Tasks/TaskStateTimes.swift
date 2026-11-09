import Foundation

/// The times Toastty observed for a task, so `task get` and `task list` can
/// say how long the task has been in its current state. Toastty only
/// reports them; a coordinator decides what counts as too long.
public struct TaskStateTimes: Codable, Equatable, Sendable {
    public var stage: TaskStageClock?
    /// The app launch that saw the task's agent start the turn it is in.
    /// It is saved at once when the turn starts, so a crash keeps it, and
    /// removed when the turn ends. A mark from an earlier launch is a turn
    /// that a quit or a crash cut off.
    public var turnLaunchID: String?
    public var checksPending: TaskChecksPending?
    /// When the user last typed into a terminal in the task space, or sent
    /// its agent a message from Toastty Mobile. Saved about once a minute,
    /// so after a relaunch it can be up to a minute early.
    public var lastUserInputAt: Date?

    public init() {}

    /// How far the saved `lastUserInputAt` may lag the live value.
    public static let userInputSaveInterval: TimeInterval = 60
}

/// The pull request's checks were pending when Toastty last asked GitHub.
public struct TaskChecksPending: Codable, Equatable, Sendable {
    /// When Toastty first saw them pending for `headSHA`.
    public var since: Date
    public var headSHA: String?

    public init(since: Date, headSHA: String?) {
        self.since = since
        self.headSHA = headSHA
    }
}

/// When a task entered its current stage. The stage is worked out, not
/// stored, so Toastty keeps this clock on the record and moves it each time
/// it sees the stage's group or attention change.
///
/// A stage the live agent decides must hold for the settle interval before
/// it replaces the settled one, as for webhook events
/// (`TaskWebhookEventDetector`): when a status flickers at a tool boundary
/// and the stage returns, the earlier time stays. While a new stage waits
/// to settle, `since` already reports when it first appeared, so the time
/// always belongs to the stage reported with it.
public struct TaskStageClock: Codable, Equatable, Sendable {
    public struct Key: Codable, Equatable, Sendable {
        /// `TaskStage.Group`'s name.
        public var group: String
        /// Why the task needs the user, inside needsYou.
        public var attention: String?

        public init(group: String, attention: String? = nil) {
            self.group = group
            self.attention = attention
        }

        public init(_ stage: TaskStage) {
            group = "\(stage.group)"
            if case .needsYou(let attention) = stage {
                self.attention = attention.name
            }
        }

        /// A stage the record decides: it cannot flicker, so it counts at
        /// once.
        var isSettledByRecord: Bool {
            TaskWebhookTaskState.Key(group: group).isSettledByRecord
        }
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var key: Key
        public var since: Date
    }

    public private(set) var settled: Entry
    /// A newer stage that has not held for the settle interval yet.
    public private(set) var pending: Entry?

    public init(key: Key, since: Date) {
        settled = Entry(key: key, since: since)
    }

    /// Records the stage seen at `now`. Call it on every change of what the
    /// stage depends on: a pending stage that lasted the settle interval
    /// counts as settled even when the stage has already moved on.
    ///
    /// `afterRelaunch` is true for the first stage seen in an app launch.
    /// Toastty did not run in between, so the stage it saw last had ended
    /// and a different stage now is no flicker: both count at once. The
    /// same stage keeps its time.
    public mutating func observe(
        _ key: Key,
        now: Date,
        afterRelaunch: Bool = false,
        settleInterval: TimeInterval = TaskWebhookEventDetector.defaultSettleInterval
    ) {
        if let waiting = pending, afterRelaunch || now.timeIntervalSince(waiting.since) >= settleInterval {
            settled = waiting
            pending = nil
        }
        if key == settled.key {
            pending = nil
        } else if key.isSettledByRecord || afterRelaunch {
            settled = Entry(key: key, since: now)
            pending = nil
        } else if pending?.key != key {
            pending = Entry(key: key, since: now)
        }
    }

    /// When the task entered `key`, the stage it is in now; `nil` when the
    /// clock has not seen that stage. Ask after `observe` with the same key.
    public func since(_ key: Key) -> Date? {
        if let pending, pending.key == key { return pending.since }
        return settled.key == key ? settled.since : nil
    }
}
