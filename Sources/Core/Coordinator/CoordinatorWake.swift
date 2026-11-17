import CryptoKit
import Foundation
import RemoteProtocol

/// What waits for the coordinator's next open prompt: the task changes it
/// has not been told about, and its timer.
///
/// Toastty wakes the coordinator only when something may need it:
/// - a task moves into Needs you;
/// - a task gets an alert (`TaskAlert`);
/// - a task merges and something waits for that merge: the coordinator
///   watches the task or its project, or the user asked for a release
///   right after the merge;
/// - a task the coordinator watches ends: Done, archived or deleted;
/// - the time the coordinator set for its next check comes.
///
/// Every other change, such as a task that starts running, goes idle, or
/// is Done after the user merged it, wakes nothing: its line waits and goes
/// into the next digest that something else starts. All go into one
/// digest, which Toastty types when the coordinator's prompt is open. With
/// no time set, no timer runs. This state is saved in the same file as the
/// event detector's baseline, so one write records a change as seen and as
/// waiting, and a quit loses nothing.
///
/// An alert is a fact with a fixed limit, not a judgment: a digest says
/// which tasks changed and which alerts started; the coordinator reads
/// `task list` and decides.
///
/// The state also keeps which digests started a quiet turn: a turn in
/// which the coordinator found nothing for the user and said so with
/// `coordinator wake --quiet`. The chat folds such a turn, and its end
/// alerts nobody.
///
/// A digest whose turn ends with an error, such as an API error or a sleep
/// of the Mac in the middle of the turn, is told again: its changes wait
/// as if it was never typed (`tellAgain`), and the next digest says that
/// the turn failed. The app decides which turn a digest started and how
/// many times in a row it tells one again.
public struct CoordinatorWakeState: Codable, Equatable, Sendable {
    /// The soonest time the coordinator can ask for, so a timer cannot
    /// become a loop of turns.
    public static let minimumDelay: TimeInterval = 60
    /// How long a digest whose turn failed waits before it is typed again.
    /// The error can come at the moment the Mac wakes, before its network
    /// is back, and a rate limit refuses a turn at once.
    public static let failedTurnRetryDelay: TimeInterval = 60
    /// The task lines one digest lists. The rest are counted in one line.
    public static let maximumListedTasks = 40
    /// The tasks and the projects the coordinator can watch, each.
    public static let maximumWatches = 100
    /// The quiet turns the state remembers. The oldest is forgotten first,
    /// and the chat then shows that turn whole again.
    public static let maximumQuietDigests = 200

    /// One line of the digest: where a task stands now.
    public struct TaskChange: Codable, Equatable, Sendable {
        public var taskID: UUID
        public var title: String
        /// `TaskStage.Group`'s name, as `task list` reports it.
        public var group: String
        public var attention: String?
        public var merged: Bool
        public var deleted: Bool
        /// When Toastty counted the change.
        public var at: Date
        /// Whether the task's stage change wakes the coordinator; see
        /// `CoordinatorWakeState`. `false` for a change that may need
        /// nothing, such as a task that starts running or is Done: its line
        /// waits for a digest that something else starts. Saved as `wakes`,
        /// the key the build before alerts used for the same fact.
        public var stageWakes: Bool
        /// The task's alerts now.
        public var alerts: [TaskAlert]
        /// The alerts that started since the coordinator was last told.
        /// Each wakes it once.
        public var newAlerts: [TaskAlert]

        /// Whether this line wakes the coordinator.
        public var wakes: Bool { stageWakes || newAlerts.isEmpty == false }

        enum CodingKeys: String, CodingKey {
            case taskID, title, group, attention, merged, deleted, at, alerts, newAlerts
            case stageWakes = "wakes"
        }
    }

    /// The coordinator's workspace these wakes are for. A coordinator
    /// opened after that one closed starts with nothing waiting.
    public let workspaceID: UUID
    /// The changes that wait, oldest first, one for each task.
    public private(set) var changes: [TaskChange] = []
    /// The next check the coordinator asked for. The timer runs only for
    /// this time.
    public private(set) var requestedWakeAt: Date?
    /// When Toastty last typed a digest. Before the first one, when it
    /// started to follow tasks for this coordinator.
    public private(set) var lastWakeAt: Date
    /// The first look at the tasks after this coordinator appeared is over.
    /// That look only records where the tasks stand, as the detector's own
    /// first look does: a change from before the coordinator existed is
    /// not told, also when a webhook kept the detector running.
    public private(set) var isFollowing = false
    /// The tasks whose merge or end the coordinator waits for, such as a
    /// task that another task depends on. A watch ends when its task
    /// merges or ends.
    public private(set) var watchedTaskIDs: [UUID] = []
    /// The projects where every merge may need the coordinator, such as a
    /// project that releases on merge. Each is a project root as
    /// `TasksConfigFile.normalizedPath` writes it.
    public private(set) var watchedProjectRoots: [String] = []
    /// `digestKey` of the digest Toastty typed last. `nil` before the first.
    public private(set) var lastDigestKey: String?
    /// `digestKey` of each digest whose turn the coordinator marked quiet,
    /// oldest first.
    public private(set) var quietDigestKeys: [String] = []
    /// When the turn of the digest typed last ended with an error. Its
    /// changes wait again, the next digest says so, and it is not typed
    /// before `failedTurnRetryDelay` has passed. `nil` once a digest is
    /// typed.
    public private(set) var failedTurnAt: Date?

    /// What a typed digest told the coordinator: its changes, and the time
    /// the coordinator set that had come. The app keeps it until the turn
    /// the digest started ends, so that a turn that fails can tell it
    /// again.
    public struct Delivered: Equatable, Sendable {
        public var changes: [TaskChange]
        public var scheduledCheck: Date?
    }

    public init(workspaceID: UUID, startedAt: Date) {
        self.workspaceID = workspaceID
        self.lastWakeAt = startedAt
    }

    /// Adds a change to the digest that waits. A task has one line: its
    /// newest change replaces an older one that still waits. Every change
    /// of a stage or of the alerts that the detector counts is told, with
    /// or without a webhook event. Nothing leaves the Mac, so none needs
    /// approval.
    ///
    /// The line wakes the coordinator for what it was not told yet and
    /// still holds: a stage change that may need it, and each alert that
    /// started. A change of only the alerts keeps what the waiting line
    /// says about the stage, and an alert that clears wakes nothing.
    public mutating func record(_ change: TaskWebhookEventDetector.Change, at: Date) {
        guard isFollowing else { return }
        let key = change.state.key
        let deleted = change.events.contains(.deleted)
        let waiting = changes.first { $0.taskID == change.taskID }
        changes.removeAll { $0.taskID == change.taskID }
        let stageChanged = deleted || change.previous.map { $0.hasSameStage(as: key) == false } ?? true
        let stageWakes = stageChanged
            ? wakes(change, deleted: deleted) || Self.holdsEventWake(waiting)
            : waiting?.stageWakes ?? false
        let alerts = deleted ? [] : key.alerts
        let newAlerts = alerts.filter { alert in
            change.previous?.alerts.contains(alert) != true || waiting?.newAlerts.contains(alert) == true
        }
        changes.append(TaskChange(
            taskID: change.taskID,
            title: change.state.title,
            group: key.group,
            attention: key.attention,
            merged: key.merged,
            deleted: deleted,
            at: at,
            stageWakes: stageWakes,
            alerts: alerts,
            newAlerts: newAlerts
        ))
        // The watch waited for this task's merge or end, and it came.
        if stageChanged, key.merged || Self.ends(group: key.group, deleted: deleted) {
            watchedTaskIDs.removeAll { $0 == change.taskID }
        }
    }

    /// Whether a change of the task's stage wakes the coordinator; see the
    /// type's comment for the rules.
    private func wakes(_ change: TaskWebhookEventDetector.Change, deleted: Bool) -> Bool {
        let key = change.state.key
        if deleted == false, key.group == "\(TaskStage.Group.needsYou)" { return true }
        let watched = watchedTaskIDs.contains(change.taskID)
        if watched, Self.ends(group: key.group, deleted: deleted) { return true }
        guard key.merged, change.previous?.merged != true else { return false }
        return watched || change.state.releaseAfterMerge || watches(projectRoot: change.state.projectRoot)
    }

    /// Whether a waiting line wakes for something that happened, a merge or
    /// a task's end, and not for a stage the task can leave. A later change
    /// of that task keeps the wake until the digest is typed: a watched
    /// task that ends and is then archived still wakes the coordinator. A
    /// task that needed something and runs again needs nothing now.
    private static func holdsEventWake(_ waiting: TaskChange?) -> Bool {
        guard let waiting, waiting.stageWakes else { return false }
        return waiting.deleted || waiting.group != "\(TaskStage.Group.needsYou)"
    }

    private static func ends(group: String, deleted: Bool) -> Bool {
        deleted || group == "\(TaskStage.Group.done)" || group == "\(TaskStage.Group.archived)"
    }

    /// Whether the coordinator watches the project with this root. The
    /// root is written out only when a project is watched, because that
    /// reads the file system.
    private func watches(projectRoot: String?) -> Bool {
        guard let projectRoot, watchedProjectRoots.isEmpty == false else { return false }
        return watchedProjectRoots.contains(TasksConfigFile.normalizedPath(projectRoot))
    }

    /// Ends the first look at the tasks: changes from here on are told.
    public mutating func startFollowing() {
        isFollowing = true
    }

    /// Sets the coordinator's next check, or with `nil` removes it: then no
    /// timer runs.
    public mutating func setRequestedWake(_ date: Date?) {
        requestedWakeAt = date
    }

    /// The digest was typed. Its changes are told, and a time the
    /// coordinator set before this wake is gone, whether it had come or
    /// not. The coordinator sets or clears its next check in the turn this
    /// wake starts; until it sets one, no timer runs. Returns what the
    /// digest told, for `tellAgain`.
    @discardableResult
    public mutating func markDelivered(_ digest: String, at: Date) -> Delivered {
        let delivered = Delivered(changes: changes, scheduledCheck: requestedWakeAt.flatMap { $0 <= at ? $0 : nil })
        changes = []
        requestedWakeAt = nil
        failedTurnAt = nil
        lastWakeAt = at
        lastDigestKey = Self.digestKey(digest)
        return delivered
    }

    /// The turn that a digest started ended with an error, so the
    /// coordinator may not have acted on it. What it told waits again, as
    /// if it was never typed: its changes, and its scheduled check unless
    /// the coordinator set a new time. The app leaves the check out of
    /// `delivered` when the coordinator cleared its time in that turn. A
    /// task that changed since keeps its
    /// newer line, which also wakes for what the told line said and still
    /// holds, as a newer change of a waiting line does in `record`. The
    /// next digest says that the turn failed, and is not typed before
    /// `failedTurnRetryDelay` has passed.
    public mutating func tellAgain(_ delivered: Delivered, failedAt: Date) {
        var restored: [TaskChange] = []
        for told in delivered.changes {
            guard let index = changes.firstIndex(where: { $0.taskID == told.taskID }) else {
                restored.append(told)
                continue
            }
            let newer = changes[index]
            changes[index].stageWakes = newer.stageWakes || Self.stillWakes(told, newer: newer)
            changes[index].newAlerts = newer.alerts.filter { newer.newAlerts.contains($0) || told.newAlerts.contains($0) }
        }
        // The told lines are older than every line recorded since.
        changes = restored + changes
        if requestedWakeAt == nil {
            requestedWakeAt = delivered.scheduledCheck
        }
        failedTurnAt = failedAt
    }

    /// Whether a told line's stage wake still holds for the task's newer
    /// line: the stage is the same, or the line woke for something that
    /// happened, such as a merge (`holdsEventWake`).
    private static func stillWakes(_ told: TaskChange, newer: TaskChange) -> Bool {
        guard told.stageWakes else { return false }
        let sameStage = told.group == newer.group && told.attention == newer.attention
            && told.merged == newer.merged && told.deleted == newer.deleted
        return sameStage || holdsEventWake(told)
    }

    // MARK: - Watches

    /// Watches a task: its merge, or its end without a merge, wakes the
    /// coordinator once. `false` when the coordinator watches too many.
    @discardableResult
    public mutating func watch(taskID: UUID) -> Bool {
        guard watchedTaskIDs.contains(taskID) == false else { return true }
        guard watchedTaskIDs.count < Self.maximumWatches else { return false }
        watchedTaskIDs.append(taskID)
        return true
    }

    public mutating func unwatch(taskID: UUID) {
        watchedTaskIDs.removeAll { $0 == taskID }
    }

    /// Watches a project, by its root as `TasksConfigFile.normalizedPath`
    /// writes it: every merge of its tasks wakes the coordinator. `false`
    /// when the coordinator watches too many.
    @discardableResult
    public mutating func watch(projectRoot: String) -> Bool {
        guard watchedProjectRoots.contains(projectRoot) == false else { return true }
        guard watchedProjectRoots.count < Self.maximumWatches else { return false }
        watchedProjectRoots.append(projectRoot)
        return true
    }

    public mutating func unwatch(projectRoot: String) {
        watchedProjectRoots.removeAll { $0 == projectRoot }
    }

    // MARK: - Quiet turns

    /// Records that the turn the last digest started needs nothing from
    /// the user. The caller checks that this turn runs now and that no
    /// other message came in it. `false` before the first digest.
    @discardableResult
    public mutating func markLastDigestQuiet() -> Bool {
        guard let lastDigestKey else { return false }
        guard quietDigestKeys.contains(lastDigestKey) == false else { return true }
        quietDigestKeys.append(lastDigestKey)
        if quietDigestKeys.count > Self.maximumQuietDigests {
            quietDigestKeys.removeFirst(quietDigestKeys.count - Self.maximumQuietDigests)
        }
        return true
    }

    /// Removes the quiet mark of the turn the last digest started, such as
    /// when the coordinator ran `coordinator wake` again without `--quiet`
    /// in that turn. The caller checks that this turn runs now.
    public mutating func unmarkLastDigestQuiet() {
        guard let lastDigestKey else { return }
        quietDigestKeys.removeAll { $0 == lastDigestKey }
    }

    /// Whether the message is a digest whose turn the coordinator marked
    /// quiet.
    public func isQuietDigest(_ text: String) -> Bool {
        quietDigestKeys.isEmpty == false && quietDigestKeys.contains(Self.digestKey(text))
    }

    /// Names a digest by its text: the SHA-256 of the text without leading
    /// and trailing white space, in hex. The agent's transcript keeps the
    /// text Toastty typed, so the key survives a relaunch, which forgets
    /// which message Toastty sent. Every digest names the time of each
    /// change it lists, so two digests do not share a text. A paired iPhone
    /// computes the same key from the text it receives
    /// (`CoordinatorChatTranscript.digestKey`).
    public static func digestKey(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256.hash(data: Data(trimmed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Digest

    /// The first line of every digest. A reader, such as the coordinator's
    /// chat view, finds Toastty's own messages by `digestPrefix`.
    public static let digestPrefix = CoordinatorMessageHeader.digestPrefix
    public static let digestHeader = "\(digestPrefix): this message is from Toastty, not from the user."
    public static let digestFooter = "Read `toastty task list` for details."

    /// The message to type now, or `nil` when no change that wakes the
    /// coordinator waits and the time it set has not come, or while a
    /// digest whose turn failed waits for `failedTurnRetryDelay`. A digest
    /// lists every change that waits, also the ones that wake nothing on
    /// their own. It names tasks, stages and alerts only: never an agent's
    /// reply, a prompt, a question or an attachment.
    public func digest(now: Date) -> String? {
        if let failedTurnAt, now < failedTurnAt.addingTimeInterval(Self.failedTurnRetryDelay) { return nil }
        let dueTimer = requestedWakeAt.flatMap { $0 <= now ? $0 : nil }
        guard changes.contains(where: \.wakes) || dueTimer != nil else { return nil }
        var lines = [Self.digestHeader]
        if let failedTurnAt {
            lines.append("- Your turn for Toastty's last wake ended with an error at \(Self.timestamp(failedTurnAt)). Its changes are listed again.")
        }
        lines += changes.prefix(Self.maximumListedTasks).map(Self.line)
        if changes.count > Self.maximumListedTasks {
            lines.append("- \(changes.count - Self.maximumListedTasks) more tasks changed.")
        }
        if let dueTimer {
            lines.append("- Scheduled check: the time you set, \(Self.timestamp(dueTimer)), has come.")
        }
        lines.append(Self.digestFooter)
        return lines.joined(separator: "\n")
    }

    /// `- [title](toastty://task/<id>): <group> (<attention>), merged at <time>`,
    /// then `; <alert>` for each alert the task has. The stage words are the
    /// ones `task list` reports.
    static func line(_ change: TaskChange) -> String {
        var stage = change.deleted ? "deleted" : change.group
        if change.deleted == false, let attention = change.attention {
            stage += " (\(attention))"
        }
        if change.merged {
            stage += ", merged"
        }
        let alerts = change.alerts.map { "; \($0.digestText)" }.joined()
        return "- [\(CoordinatorTaskLink.linkText(change.title))](toastty://task/\(change.taskID.uuidString)): \(stage) at \(timestamp(change.at))\(alerts)"
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}

extension CoordinatorWakeState {
    /// A state saved before watches, quiet turns and failed turns has none
    /// of them.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try container.decode(UUID.self, forKey: .workspaceID)
        changes = try container.decodeIfPresent([TaskChange].self, forKey: .changes) ?? []
        requestedWakeAt = try container.decodeIfPresent(Date.self, forKey: .requestedWakeAt)
        lastWakeAt = try container.decode(Date.self, forKey: .lastWakeAt)
        isFollowing = try container.decodeIfPresent(Bool.self, forKey: .isFollowing) ?? false
        watchedTaskIDs = try container.decodeIfPresent([UUID].self, forKey: .watchedTaskIDs) ?? []
        watchedProjectRoots = try container.decodeIfPresent([String].self, forKey: .watchedProjectRoots) ?? []
        lastDigestKey = try container.decodeIfPresent(String.self, forKey: .lastDigestKey)
        quietDigestKeys = try container.decodeIfPresent([String].self, forKey: .quietDigestKeys) ?? []
        failedTurnAt = try container.decodeIfPresent(Date.self, forKey: .failedTurnAt)
    }
}

extension CoordinatorWakeState.TaskChange {
    /// A change saved before Toastty marked the changes that wake nothing
    /// has no `wakes`. It counts as waking, as every change did then.
    /// A change saved before Toastty had alerts has none. An alert this
    /// build does not know is left out.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try container.decode(UUID.self, forKey: .taskID)
        title = try container.decode(String.self, forKey: .title)
        group = try container.decode(String.self, forKey: .group)
        attention = try container.decodeIfPresent(String.self, forKey: .attention)
        merged = try container.decode(Bool.self, forKey: .merged)
        deleted = try container.decode(Bool.self, forKey: .deleted)
        at = try container.decode(Date.self, forKey: .at)
        stageWakes = try container.decodeIfPresent(Bool.self, forKey: .stageWakes) ?? true
        func decodeAlerts(_ key: CodingKeys) throws -> [TaskAlert] {
            try container.decodeIfPresent([String].self, forKey: key)?.compactMap(TaskAlert.init(rawValue:)) ?? []
        }
        alerts = try decodeAlerts(.alerts)
        newAlerts = try decodeAlerts(.newAlerts)
    }
}

/// A condition of a task that changes no stage but may need the
/// coordinator. Toastty raises it at a fixed limit, so the coordinator does
/// not have to poll for it. Each alert wakes the coordinator once when it
/// starts, and again only after it cleared and came back.
public enum TaskAlert: String, Codable, CaseIterable, Sendable {
    /// The task's agent is busy, and its transcript has not changed for
    /// `limit`.
    case silent
    /// The checks of the task's open pull request fail.
    case checksFailing
    /// The checks of the task's open pull request have been pending for
    /// `limit` on the same commit.
    case checksSlow
    /// A quit or a crash cut off the agent's turn, and the agent now waits
    /// at its prompt: `task get` reports `interruptedAtQuit`. It clears
    /// when the agent starts its next turn.
    case interrupted

    public static let limit: TimeInterval = 30 * 60

    /// What a digest line says about the alert.
    public var digestText: String {
        let minutes = Int(Self.limit / 60)
        switch self {
        case .silent: return "busy, no output for \(minutes) minutes"
        case .checksFailing: return "pull request checks failing"
        case .checksSlow: return "pull request checks pending for \(minutes) minutes"
        case .interrupted: return "interrupted by the quit"
        }
    }
}

/// What Toastty reads about a task to find its alerts.
public struct TaskAlertFacts: Equatable, Sendable {
    public enum Checks: Equatable, Sendable {
        /// No open pull request, or GitHub's answer has no checks.
        case none
        /// Toastty has no answer from GitHub yet, as after a launch.
        case unknown
        case passing
        case failing
        /// Pending since that time on the head commit; `nil` when Toastty
        /// has no time for this commit yet.
        case pending(since: Date?)
    }

    /// The task's agent is in a turn and not waiting for an approval.
    public var agentBusy: Bool
    /// When the agent's transcript last changed; `nil` when Toastty does
    /// not know.
    public var lastOutputAt: Date?
    public var checks: Checks
    /// A quit or a crash cut off the agent's turn, and the agent is idle
    /// at its prompt.
    public var interruptedAtQuit: Bool

    public init(agentBusy: Bool, lastOutputAt: Date?, checks: Checks, interruptedAtQuit: Bool = false) {
        self.agentBusy = agentBusy
        self.lastOutputAt = lastOutputAt
        self.checks = checks
        self.interruptedAtQuit = interruptedAtQuit
    }

    /// The task's alerts at `now`, in `TaskAlert.allCases` order. While the
    /// checks are unknown, the check alerts in `previous`, the ones last
    /// counted, stay: a relaunch does not clear them and tell them again
    /// when GitHub answers.
    public func alerts(now: Date, previous: [TaskAlert]) -> [TaskAlert] {
        TaskAlert.allCases.filter { alert in
            switch (alert, checks) {
            case (.silent, _):
                guard agentBusy, let lastOutputAt else { return false }
                return now.timeIntervalSince(lastOutputAt) >= TaskAlert.limit
            case (.checksFailing, .failing):
                return true
            case (.checksSlow, .pending(let since?)):
                return now.timeIntervalSince(since) >= TaskAlert.limit
            case (.interrupted, _):
                return interruptedAtQuit
            case (_, .unknown):
                return previous.contains(alert)
            default:
                return false
            }
        }
    }
}

extension RemoteCoordinatorQuietDigests {
    /// The quiet digests with these keys, oldest first, and their revision.
    public init(keys: [String]) {
        self.init(revision: Self.revision(of: keys), keys: keys)
    }

    /// The first 16 hex digits of the SHA-256 of the keys, one per line.
    /// The same keys give the same revision, also after a relaunch, so a
    /// device reads them again only when they change.
    public static func revision(of keys: [String]) -> String {
        let digest = SHA256.hash(data: Data(keys.joined(separator: "\n").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
