import Foundation

/// What waits for the coordinator's next open prompt: the task changes it
/// has not been told about, and its timer.
///
/// Toastty wakes the coordinator for two reasons: a task's stage changed,
/// or its timer came due. Both go into one digest, which Toastty types when
/// the coordinator's prompt is open. This state is saved in the same file
/// as the event detector's baseline, so one write records a change as seen
/// and as waiting, and a quit loses nothing.
///
/// Toastty has no rule about a task that is stuck. A digest only says which
/// tasks changed; the coordinator reads `task list` and decides.
public struct CoordinatorWakeState: Codable, Equatable, Sendable {
    /// How long after the last wake Toastty wakes the coordinator again
    /// when it set no time and a task is open.
    public static let defaultInterval: TimeInterval = 3600
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
    }

    /// The coordinator's next check.
    public struct NextWake: Equatable, Sendable {
        public var at: Date
        /// The coordinator set this time. `false` for the default.
        public var isRequested: Bool

        public init(at: Date, isRequested: Bool) {
            self.at = at
            self.isRequested = isRequested
        }
    }

    /// The coordinator's workspace these wakes are for. A coordinator
    /// opened after that one closed starts with nothing waiting.
    public let workspaceID: UUID
    /// The changes that wait, oldest first, one for each task.
    public private(set) var changes: [TaskChange] = []
    /// The next check the coordinator asked for.
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
    /// of a stage that the detector counts is told, with or without a
    /// webhook event. Nothing leaves the Mac, so none needs approval.
    public mutating func record(_ change: TaskWebhookEventDetector.Change, at: Date) {
        guard isFollowing else { return }
        changes.removeAll { $0.taskID == change.taskID }
        changes.append(TaskChange(
            taskID: change.taskID,
            title: change.state.title,
            group: change.state.key.group,
            attention: change.state.key.attention,
            merged: change.state.key.merged,
            deleted: change.events.contains(.deleted),
            at: at
        ))
    }

    /// Ends the first look at the tasks: changes from here on are told.
    public mutating func startFollowing() {
        isFollowing = true
    }

    /// Sets the coordinator's next check, or with `nil` removes it, so the
    /// default applies again.
    public mutating func setRequestedWake(_ date: Date?) {
        requestedWakeAt = date
    }

    /// The digest was typed. Its changes are told, and the timer starts
    /// again: a time the coordinator set before this wake is gone, whether
    /// it had come or not. The coordinator sets its next check in the turn
    /// this wake starts; until it does, the default applies.
    public mutating func markDelivered(at: Date) {
        changes = []
        requestedWakeAt = nil
        lastWakeAt = at
    }

    /// When the timer wakes the coordinator: at the time it set, or else
    /// `defaultInterval` after the last wake while a task is open. With no
    /// time set and no open task there is no timer.
    public func nextWake(hasOpenTasks: Bool) -> NextWake? {
        if let requestedWakeAt {
            return NextWake(at: requestedWakeAt, isRequested: true)
        }
        guard hasOpenTasks else { return nil }
        return NextWake(at: lastWakeAt.addingTimeInterval(Self.defaultInterval), isRequested: false)
    }

    /// Whether a task in this stage group is open: its work is not over.
    public static func isOpen(group: String) -> Bool {
        group != "done" && group != "archived"
    }

    // MARK: - Digest

    /// The first line of every digest. A reader, such as the coordinator's
    /// chat view, finds Toastty's own messages by `digestPrefix`.
    public static let digestPrefix = "[Toastty] Wake"
    public static let digestHeader = "\(digestPrefix): this message is from Toastty, not from the user."
    public static let digestFooter = "Read `toastty task list` for details."

    /// The message to type now, or `nil` when no change waits and the timer
    /// has not come due. It names tasks and stages only: never an agent's
    /// reply, a prompt, a question or an attachment.
    public func digest(now: Date, hasOpenTasks: Bool) -> String? {
        let dueTimer = nextWake(hasOpenTasks: hasOpenTasks).flatMap { $0.at <= now ? $0 : nil }
        guard changes.isEmpty == false || dueTimer != nil else { return nil }
        var lines = [Self.digestHeader]
        lines += changes.prefix(Self.maximumListedTasks).map(Self.line)
        if changes.count > Self.maximumListedTasks {
            lines.append("- \(changes.count - Self.maximumListedTasks) more tasks changed.")
        }
        if let dueTimer {
            lines.append(dueTimer.isRequested
                ? "- Scheduled check: the time you set, \(Self.timestamp(dueTimer.at)), has come."
                : "- Scheduled check: 1 hour has passed since the last wake, and you set no time.")
        }
        lines.append(Self.digestFooter)
        return lines.joined(separator: "\n")
    }

    /// `- [title](toastty://task/<id>): <group> (<attention>), merged at <time>`.
    /// The stage words are the ones `task list` reports.
    static func line(_ change: TaskChange) -> String {
        var stage = change.deleted ? "deleted" : change.group
        if change.deleted == false, let attention = change.attention {
            stage += " (\(attention))"
        }
        if change.merged {
            stage += ", merged"
        }
        return "- [\(linkText(change.title))](toastty://task/\(change.taskID.uuidString)): \(stage) at \(timestamp(change.at))"
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
