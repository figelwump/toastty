import Foundation

/// What waits for the coordinator's next open prompt: the task changes it
/// has not been told about, and its timer.
///
/// Toastty wakes the coordinator for three reasons: a task's stage changed
/// in a way that may need it, a task got an alert (`TaskAlert`), or the
/// time it set for its next check came. All go into one digest, which
/// Toastty types when the coordinator's prompt is open. A task that only
/// starts running wakes nothing: its line waits and goes into the next
/// digest that something else starts. With no time set, no timer runs.
/// This state is saved in the same file as the event detector's baseline,
/// so one write records a change as seen and as waiting, and a quit loses
/// nothing.
///
/// An alert is a fact with a fixed limit, not a judgment: a digest says
/// which tasks changed and which alerts started; the coordinator reads
/// `task list` and decides.
public struct CoordinatorWakeState: Codable, Equatable, Sendable {
    /// The soonest time the coordinator can ask for, so a timer cannot
    /// become a loop of turns.
    public static let minimumDelay: TimeInterval = 60
    /// The task lines one digest lists. The rest are counted in one line.
    public static let maximumListedTasks = 40

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
        /// Whether the task's stage change wakes the coordinator. `false`
        /// for a task that only starts running: its line waits for a digest
        /// that something else starts. Saved as `wakes`, the key the build
        /// before alerts used for the same fact.
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
            ? Self.wakes(group: key.group, attention: key.attention, merged: key.merged, deleted: deleted)
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
    }

    /// Whether a change into this stage wakes the coordinator. A task that
    /// only starts running, with no attention, not merged and not deleted,
    /// needs nothing from it. Every other change may.
    private static func wakes(group: String, attention: String?, merged: Bool, deleted: Bool) -> Bool {
        group != "\(TaskStage.Group.running)" || attention != nil || merged || deleted
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
    /// wake starts; until it sets one, no timer runs.
    public mutating func markDelivered(at: Date) {
        changes = []
        requestedWakeAt = nil
        lastWakeAt = at
    }

    // MARK: - Digest

    /// The first line of every digest. A reader, such as the coordinator's
    /// chat view, finds Toastty's own messages by `digestPrefix`.
    public static let digestPrefix = "[Toastty] Wake"
    public static let digestHeader = "\(digestPrefix): this message is from Toastty, not from the user."
    public static let digestFooter = "Read `toastty task list` for details."

    /// The message to type now, or `nil` when no change that wakes the
    /// coordinator waits and the time it set has not come. A digest lists
    /// every change that waits, also the ones that wake nothing on their
    /// own. It names tasks, stages and alerts only: never an agent's reply,
    /// a prompt, a question or an attachment.
    public func digest(now: Date) -> String? {
        let dueTimer = requestedWakeAt.flatMap { $0 <= now ? $0 : nil }
        guard changes.contains(where: \.wakes) || dueTimer != nil else { return nil }
        var lines = [Self.digestHeader]
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
        return "- [\(linkText(change.title))](toastty://task/\(change.taskID.uuidString)): \(stage) at \(timestamp(change.at))\(alerts)"
    }

    /// A title as the text of a one-line Markdown link. A title is a
    /// person's or an agent's text and is typed into a terminal, so no
    /// control character goes through: an escape sequence in it could end
    /// the terminal's paste early.
    static func linkText(_ title: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in title.unicodeScalars {
            if scalar.properties.isWhitespace {
                scalars.append(" ")
            } else if scalar.properties.generalCategory != .control {
                scalars.append(scalar)
            }
        }
        let oneLine = String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let shortened = oneLine.count > 80 ? oneLine.prefix(79) + "…" : oneLine[...]
        let escaped = shortened
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return escaped.isEmpty ? "Untitled task" : escaped
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
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
