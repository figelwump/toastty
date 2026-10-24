import Foundation

/// A card the coordinator posts to its chat with `toastty coordinator post`.
/// Toastty appends each one to `coordinator/events.jsonl`; the chat renders
/// a card from the live task, so an event holds only what names the card.
public struct CoordinatorEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// A task published a review packet.
        case packet
        /// The coordinator started a task.
        case taskStarted = "task-started"
        /// A task, or the coordinator itself, needs an answer from the user.
        case question
        case note

        /// Every kind except a note is about one task.
        public var requiresTask: Bool { self != .note }
        /// A question or a note says something; the other kinds come from
        /// the task.
        public var requiresText: Bool { self == .question || self == .note }
    }

    public static let maximumTextLength = 4000

    public var id: UUID
    public var at: Date
    public var kind: Kind
    public var taskID: UUID?
    public var text: String?
    /// The managed session that posted it.
    public var sessionID: String?

    public init(id: UUID = UUID(), at: Date, kind: Kind, taskID: UUID?, text: String?, sessionID: String?) {
        self.id = id
        self.at = at
        self.kind = kind
        self.taskID = taskID
        self.text = text
        self.sessionID = sessionID
    }

    /// Checks what the kind requires and trims the text.
    public static func validated(
        kind rawKind: String,
        taskID: UUID?,
        text rawText: String?,
        sessionID: String?,
        at: Date
    ) throws -> CoordinatorEvent {
        guard let kind = Kind(rawValue: rawKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            let kinds = Kind.allCases.map(\.rawValue).joined(separator: ", ")
            throw CoordinatorEventError("Unknown kind \"\(rawKind)\". Use one of: \(kinds).")
        }
        if kind.requiresTask, taskID == nil {
            throw CoordinatorEventError("A \(kind.rawValue) card names its task with --task <task-id>.")
        }
        let text = rawText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonEmptyText = text?.isEmpty == false ? text : nil
        if kind.requiresText, nonEmptyText == nil {
            throw CoordinatorEventError("A \(kind.rawValue) card needs text.")
        }
        if let nonEmptyText, nonEmptyText.count > maximumTextLength {
            throw CoordinatorEventError("A card's text is at most \(maximumTextLength) characters.")
        }
        return CoordinatorEvent(at: at, kind: kind, taskID: taskID, text: nonEmptyText, sessionID: sessionID)
    }

    /// One line of `events.jsonl`, without its line break.
    public func jsonLine() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// The events in a log, oldest first. A line that does not decode, such
    /// as one cut short by a crash, is skipped.
    public static func decodeLog(_ data: Data) -> [CoordinatorEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            try? decoder.decode(CoordinatorEvent.self, from: Data(line))
        }
    }
}

public struct CoordinatorEventError: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
