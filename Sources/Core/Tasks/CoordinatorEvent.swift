import Foundation

/// A card or thread reply saved in `coordinator/events.jsonl`.
public struct CoordinatorEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// A task published a review packet.
        case packet
        /// The coordinator started a task.
        case taskStarted = "task-started"
        /// A task, or the coordinator itself, needs an answer from the user.
        case question
        case note
        /// An internal record of a reply delivered through the chat.
        case reply

        public static var postingKinds: [Kind] { allCases.filter { $0 != .reply } }

        /// Questions can ask the user to pick a project before a task exists.
        public var requiresTask: Bool { self != .note && self != .question }
        /// A question or a note says something; the other kinds come from
        /// the task.
        public var requiresText: Bool { self == .question || self == .note }
    }

    public enum ThreadRole: String, Codable, Sendable {
        case userTask = "user-task"
        case userCoordinator = "user-coordinator"
        case coordinator
        case agent
    }

    /// Route answers are saved before delivery, so an uncertain send cannot
    /// offer the same project choice again after a relaunch.
    public enum Delivery: String, Codable, Sendable {
        case pending, accepted, rejected
    }

    public static let maximumTextLength = 4000
    public static let maximumOptionCount = 6
    public static let maximumOptionLength = 120

    public var id: UUID
    public var at: Date
    public var kind: Kind
    public var taskID: UUID?
    public var text: String?
    /// The managed session that posted it.
    public var sessionID: String?
    public var options: [String]
    public var threadRole: ThreadRole?
    /// The question answered by this reply, when the user replied to one.
    public var questionID: UUID?
    /// The source message's stable identity, used when importing a reply again.
    public var sourceID: String?
    public var delivery: Delivery?

    /// A scoped note or ordinary accepted reply can introduce a task's card
    /// before the coordinator posts one. Its ID stays a valid draft context
    /// after a later packet replaces that card.
    public var canAnchorTaskCard: Bool {
        guard taskID != nil, let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if kind == .note { return true }
        return kind == .reply && questionID == nil && threadRole != nil
            && (delivery == nil || delivery == .accepted)
    }

    public init(
        id: UUID = UUID(), at: Date, kind: Kind, taskID: UUID?, text: String?, sessionID: String?,
        options: [String] = [], threadRole: ThreadRole? = nil, questionID: UUID? = nil, sourceID: String? = nil,
        delivery: Delivery? = nil
    ) {
        self.id = id
        self.at = at
        self.kind = kind
        self.taskID = taskID
        self.text = text
        self.sessionID = sessionID
        self.options = options
        self.threadRole = threadRole
        self.questionID = questionID
        self.sourceID = sourceID
        self.delivery = delivery
    }

    private enum CodingKeys: String, CodingKey {
        case id, at, kind, taskID, text, sessionID, options, threadRole, questionID, sourceID, delivery
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        at = try container.decode(Date.self, forKey: .at)
        kind = try container.decode(Kind.self, forKey: .kind)
        taskID = try container.decodeIfPresent(UUID.self, forKey: .taskID)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        // Old or hand-edited logs must not lose a whole question because its
        // choices are malformed. New posts use the strict validation below.
        let storedOptions = (try? container.decode([String].self, forKey: .options)) ?? []
        var seen = Set<String>()
        options = []
        for rawOption in storedOptions {
            let option = rawOption.trimmingCharacters(in: .whitespacesAndNewlines)
            guard option.isEmpty == false, option.count <= Self.maximumOptionLength, seen.insert(option).inserted else { continue }
            options.append(option)
            if options.count == Self.maximumOptionCount { break }
        }
        threadRole = try container.decodeIfPresent(ThreadRole.self, forKey: .threadRole)
        questionID = try container.decodeIfPresent(UUID.self, forKey: .questionID)
        sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID)
        delivery = try container.decodeIfPresent(Delivery.self, forKey: .delivery)
    }

    /// Checks what the kind requires and trims the text.
    public static func validated(
        kind rawKind: String,
        taskID: UUID?,
        text rawText: String?,
        sessionID: String?,
        at: Date,
        options rawOptions: [String] = []
    ) throws -> CoordinatorEvent {
        guard let kind = Kind(rawValue: rawKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
              Kind.postingKinds.contains(kind) else {
            let kinds = Kind.postingKinds.map(\.rawValue).joined(separator: ", ")
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
        if kind != .question, rawOptions.isEmpty == false {
            throw CoordinatorEventError("Only a question card accepts options.")
        }
        if rawOptions.count > maximumOptionCount {
            throw CoordinatorEventError("A question has at most \(maximumOptionCount) options.")
        }
        let options = rawOptions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if options.contains(where: \.isEmpty) {
            throw CoordinatorEventError("A question's options cannot be empty.")
        }
        if options.contains(where: { $0.count > maximumOptionLength }) {
            throw CoordinatorEventError("A question's option is at most \(maximumOptionLength) characters.")
        }
        if Set(options).count != options.count {
            throw CoordinatorEventError("A question's options must be different.")
        }
        if kind == .question, taskID == nil, options.isEmpty {
            throw CoordinatorEventError("A question without a task needs project choices with --option <project>.")
        }
        return CoordinatorEvent(at: at, kind: kind, taskID: taskID, text: nonEmptyText, sessionID: sessionID, options: options)
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
