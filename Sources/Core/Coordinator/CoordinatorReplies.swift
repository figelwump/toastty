import Foundation

/// The coordinator's replies to messages that `coordinator send` brought
/// from outside a task, and the webhook events that wait to tell of them.
///
/// Such a message gets an ID, which its first line ends with. The
/// coordinator answers the sender with `coordinator reply <message-id>`.
/// Toastty keeps the reply here, the sender reads it with
/// `coordinator replies`, and each webhook that opted in gets a
/// `coordinator.reply` event that names the reply and carries no text.
///
/// One file holds the messages, the replies and the waiting events, so one
/// write saves a reply with its events. The task outbox never holds a reply
/// event, so a build that does not know the event still reads that outbox.
public struct CoordinatorReplies: Codable, Equatable, Sendable {
    /// How long a reply is kept, and a message after Toastty typed it. A
    /// message that still waits in the coordinator's queue is kept.
    public static let keepTime: TimeInterval = 7 * 24 * 3600
    public static let maximumMessages = 500
    public static let maximumReplies = 500
    public static let maximumTextBytes = 16 * 1024

    public struct Message: Codable, Equatable, Sendable {
        public var id: UUID
        /// The name the sender gave itself with `--from`, or `nil`.
        public var from: String?
        public var sentAt: Date
        /// When Toastty typed it into the coordinator. `nil` while it waits.
        public var typedAt: Date?
    }

    public struct Reply: Codable, Equatable, Sendable {
        public var id: UUID
        /// Counts up for the life of the store. A cursor names one.
        public var sequence: Int
        public var messageID: UUID
        /// The name the message's sender gave itself, or `nil`.
        public var from: String?
        public var text: String
        public var repliedAt: Date
    }

    /// A reply event that waits to send to one webhook.
    public struct Event: Codable, Equatable, Sendable {
        public var eventID: UUID
        public var webhookID: UUID
        public var replyID: UUID
        public var createdAt: Date
        /// The encoded payload, kept as sent, so every retry sends the
        /// same bytes.
        public var body: Data
        public var attempts: Int
        public var nextAttemptAt: Date

        public init(eventID: UUID, webhookID: UUID, replyID: UUID, createdAt: Date, body: Data) {
            self.eventID = eventID
            self.webhookID = webhookID
            self.replyID = replyID
            self.createdAt = createdAt
            self.body = body
            self.attempts = 0
            self.nextAttemptAt = createdAt
        }
    }

    /// What `coordinator replies` returns.
    public struct Page: Equatable, Sendable {
        public var replies: [Reply]
        /// Pass it as `since` to get only newer replies.
        public var cursor: String
        /// Replies after `since` were dropped, because they were older than
        /// the keep time or over the limit, or `since` came from another
        /// store. The page then has every reply that is kept.
        public var truncated: Bool
    }

    public var version = 1
    /// Names this store, so a cursor from another one, as after the file
    /// was removed, starts again from the oldest reply.
    public private(set) var storeID: UUID
    public private(set) var messages: [Message] = []
    /// Oldest first.
    public private(set) var replies: [Reply] = []
    /// The sequence of the newest reply ever kept.
    public private(set) var lastSequence = 0
    /// Oldest first. The webhook service sends and removes them.
    public var events: [Event] = []

    public init(storeID: UUID = UUID()) {
        self.storeID = storeID
    }

    // MARK: - Messages

    /// Keeps the ID of a message that `coordinator send` brought, so that
    /// the coordinator can reply to it.
    public mutating func recordMessage(id: UUID, from: String?, at: Date, typed: Bool) {
        messages.removeAll { $0.id == id }
        messages.append(Message(id: id, from: from, sentAt: at, typedAt: typed ? at : nil))
        if messages.count > Self.maximumMessages {
            messages.removeFirst(messages.count - Self.maximumMessages)
        }
    }

    /// Notes that Toastty typed the message, which starts its keep time.
    /// Returns whether anything changed.
    @discardableResult
    public mutating func markTyped(id: UUID, at: Date) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == id }), messages[index].typedAt == nil else { return false }
        messages[index].typedAt = at
        return true
    }

    public func message(id: UUID) -> Message? {
        messages.first { $0.id == id }
    }

    // MARK: - Replies

    /// Keeps the coordinator's reply to a message. Throws, and changes
    /// nothing, for a message that is not kept or a text that is empty or
    /// too long.
    public mutating func addReply(id: UUID = UUID(), messageID: UUID, text: String, at: Date) throws -> Reply {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw CoordinatorReplyError("The reply is empty.")
        }
        guard trimmed.utf8.count <= Self.maximumTextBytes else {
            throw CoordinatorReplyError("The reply is longer than \(Self.maximumTextBytes / 1024) KB. Shorten it, or split it into several replies.")
        }
        guard let message = message(id: messageID) else {
            throw CoordinatorReplyError(
                "No message has ID \(messageID.uuidString), or it is older than 7 days. "
                    + "Only a message from outside a task has an ID: answer a task with task send."
            )
        }
        lastSequence += 1
        let reply = Reply(id: id, sequence: lastSequence, messageID: messageID, from: message.from, text: trimmed, repliedAt: at)
        replies.append(reply)
        if replies.count > Self.maximumReplies {
            replies.removeFirst(replies.count - Self.maximumReplies)
        }
        return reply
    }

    /// The replies after `cursor`, oldest first, or every kept reply
    /// without one. With `messageID`, only the replies to that message.
    public func page(since cursor: String?, messageID: UUID?) throws -> Page {
        var after = 0
        var truncated = false
        if let cursor {
            guard let parsed = Self.parse(cursor) else {
                throw CoordinatorReplyError("since must be a cursor that coordinator replies returned.")
            }
            if parsed.storeID == storeID, parsed.sequence <= lastSequence {
                after = parsed.sequence
                let firstKept = replies.first?.sequence ?? lastSequence + 1
                truncated = after + 1 < firstKept
            } else {
                truncated = true
            }
        }
        let selected = replies.filter { $0.sequence > after && (messageID == nil || $0.messageID == messageID) }
        return Page(replies: selected, cursor: "\(storeID.uuidString):\(lastSequence)", truncated: truncated)
    }

    private static func parse(_ cursor: String) -> (storeID: UUID, sequence: Int)? {
        let parts = cursor.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let storeID = UUID(uuidString: String(parts[0])),
              let sequence = Int(parts[1]), sequence >= 0 else { return nil }
        return (storeID, sequence)
    }

    // MARK: - Keep time

    /// Drops the replies older than the keep time, and the messages typed
    /// longer ago, or sent longer ago and not waiting in the coordinator's
    /// queue. Returns whether anything changed.
    @discardableResult
    public mutating func prune(now: Date, waitingMessageIDs: Set<UUID>) -> Bool {
        let before = (messages.count, replies.count)
        messages.removeAll { message in
            waitingMessageIDs.contains(message.id) == false
                && now.timeIntervalSince(message.typedAt ?? message.sentAt) > Self.keepTime
        }
        replies.removeAll { now.timeIntervalSince($0.repliedAt) > Self.keepTime }
        return before != (messages.count, replies.count)
    }
}

public struct CoordinatorReplyError: Error, Equatable, Sendable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The JSON body of a `coordinator.reply` event. It names the reply, the
/// message it answers and its sender; the receiver reads the text with
/// `toastty coordinator replies`. The text is never in it.
public struct CoordinatorReplyWebhookPayload: Codable, Equatable, Sendable {
    public static let type = "coordinator.reply"

    public struct Reply: Codable, Equatable, Sendable {
        public var id: UUID
        public var messageID: UUID
        public var from: String?

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(messageID, forKey: .messageID)
            // Present as null, so receivers can rely on the key.
            try container.encode(from, forKey: .from)
        }
    }

    public var version: Int
    public var eventID: UUID
    public var type: String
    public var occurredAt: Date
    public var webhook: String
    public var reply: Reply

    public init(eventID: UUID, occurredAt: Date, webhook: String, reply: CoordinatorReplies.Reply) {
        self.version = 1
        self.eventID = eventID
        self.type = Self.type
        self.occurredAt = occurredAt
        self.webhook = webhook
        self.reply = Reply(id: reply.id, messageID: reply.messageID, from: reply.from)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
