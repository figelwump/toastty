import Foundation

/// What waits for the coordinator's next open prompt: the task changes it
/// has not been told about, and its timer.
///
/// Toastty wakes the coordinator for two reasons: a task's stage changed in
/// a way that may need it, or the time it set for its next check came. Both
/// go into one digest, which Toastty types when the coordinator's prompt is
/// open. A task that only starts running wakes nothing: its line waits and
/// goes into the next digest that something else starts. With no time set,
/// no timer runs. This state is saved in the same file as the event
/// detector's baseline, so one write records a change as seen and as
/// waiting, and a quit loses nothing.
///
/// Toastty has no rule about a task that is stuck. A digest only says which
/// tasks changed; the coordinator reads `task list` and decides.
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
        /// Whether this change wakes the coordinator. `false` for a task
        /// that only starts running: its line waits for a digest that
        /// something else starts.
        public var wakes: Bool
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
    /// of a stage that the detector counts is told, with or without a
    /// webhook event. Nothing leaves the Mac, so none needs approval.
    public mutating func record(_ change: TaskWebhookEventDetector.Change, at: Date) {
        guard isFollowing else { return }
        let key = change.state.key
        let deleted = change.events.contains(.deleted)
        changes.removeAll { $0.taskID == change.taskID }
        changes.append(TaskChange(
            taskID: change.taskID,
            title: change.state.title,
            group: key.group,
            attention: key.attention,
            merged: key.merged,
            deleted: deleted,
            at: at,
            wakes: Self.wakes(group: key.group, attention: key.attention, merged: key.merged, deleted: deleted)
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
    /// own. It names tasks and stages only: never an agent's reply, a
    /// prompt, a question or an attachment.
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

extension CoordinatorWakeState.TaskChange {
    /// A change saved before Toastty marked the changes that wake nothing
    /// has no `wakes`. It counts as waking, as every change did then.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try container.decode(UUID.self, forKey: .taskID)
        title = try container.decode(String.self, forKey: .title)
        group = try container.decode(String.self, forKey: .group)
        attention = try container.decodeIfPresent(String.self, forKey: .attention)
        merged = try container.decode(Bool.self, forKey: .merged)
        deleted = try container.decode(Bool.self, forKey: .deleted)
        at = try container.decode(Date.self, forKey: .at)
        wakes = try container.decodeIfPresent(Bool.self, forKey: .wakes) ?? true
    }
}
