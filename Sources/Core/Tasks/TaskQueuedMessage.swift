import Foundation

/// A message that `task send --queue` left for a task's agent. Toastty
/// types it at the agent's next open prompt, never into a running turn, a
/// permission prompt, a question or text that someone typed at the prompt.
///
/// It is saved on the record of the task it is for, as a watch is saved on
/// the record of the task it notifies. So it waits across an agent restart
/// and an app relaunch, and goes to the agent that works on the task when
/// the prompt opens. After it leaves the queue, the record keeps it for a
/// while without its text, so that its sender can read the outcome with
/// `task get`.
public struct TaskQueuedMessage: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// What Toastty types: the sender's line, then the sender's text.
    /// Empty after the message leaves the queue.
    public var text: String
    /// The sender, as `task get` names it.
    public var from: String
    public var queuedAt: Date
    /// `nil` while the message waits.
    public var outcome: Outcome?

    public struct Outcome: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// Typed and submitted at an open prompt.
            case sent
            /// Typed, but the terminal did not confirm the Return key. It
            /// is not typed again: a second copy would land in the same
            /// prompt.
            case sentUnconfirmed
            /// Never typed: the task finished first.
            case dropped
        }

        public var kind: Kind
        public var at: Date
        /// The agent session it was typed into.
        public var sessionID: String?
        /// Why it was dropped.
        public var reason: String?

        public init(kind: Kind, at: Date, sessionID: String? = nil, reason: String? = nil) {
            self.kind = kind
            self.at = at
            self.sessionID = sessionID
            self.reason = reason
        }
    }

    public init(id: UUID = UUID(), text: String, from: String, queuedAt: Date, outcome: Outcome? = nil) {
        self.id = id
        self.text = text
        self.from = from
        self.queuedAt = queuedAt
        self.outcome = outcome
    }

    public var isWaiting: Bool { outcome == nil }

    /// The message after it left the queue, without its text.
    public func settled(_ outcome: Outcome) -> TaskQueuedMessage {
        var settled = self
        settled.text = ""
        settled.outcome = outcome
        return settled
    }
}

extension TaskRecord {
    /// The most messages that can wait for a task's agent at one time.
    public static let maximumWaitingMessages = 10

    /// The messages that wait for the agent's next open prompt, oldest
    /// first.
    public var waitingMessages: [TaskQueuedMessage] {
        (queuedMessages ?? []).filter(\.isWaiting)
    }

    /// Drops the waiting messages, with the reason, and keeps them as
    /// dropped for their senders to read.
    public mutating func dropWaitingMessages(reason: String, at: Date) {
        queuedMessages = queuedMessages?.map { message in
            message.isWaiting ? message.settled(.init(kind: .dropped, at: at, reason: reason)) : message
        }
    }

    /// Keeps every waiting message. Of the messages that left the queue,
    /// drops the oldest beyond `keep` and any older than `maximumAge`, as
    /// `pruneFiredWatches` does for watches.
    public mutating func pruneSettledMessages(now: Date, keep: Int = 20, maximumAge: TimeInterval = 24 * 3600) {
        guard let all = queuedMessages else { return }
        let settledNewestFirst = all.compactMap { message -> (UUID, Date)? in
            message.outcome.map { (message.id, $0.at) }
        }.sorted { $0.1 > $1.1 }
        var drop = Set<UUID>()
        for (rank, entry) in settledNewestFirst.enumerated()
        where rank >= keep || now.timeIntervalSince(entry.1) > maximumAge {
            drop.insert(entry.0)
        }
        let kept = all.filter { drop.contains($0.id) == false }
        queuedMessages = kept.isEmpty ? nil : kept
    }
}
