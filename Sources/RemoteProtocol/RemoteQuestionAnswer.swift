import Foundation

/// One question in a provider's live, structured user-input request.
public struct RemoteInteractionQuestion: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var header: String
    public var question: String
    public var options: [RemotePendingInteraction.Option]
    public var multiSelect: Bool

    public init(
        id: String,
        header: String,
        question: String,
        options: [RemotePendingInteraction.Option],
        multiSelect: Bool = false
    ) {
        self.id = id
        self.header = header
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
    }
}

/// Clients return option identifiers, never replacement labels or questions.
/// Custom text is the only answer content supplied directly by the client.
public struct RemoteInteractionAnswer: Codable, Equatable, Sendable {
    public var questionID: String
    public var selectedOptionIDs: [String]
    public var text: String?

    public init(questionID: String, selectedOptionIDs: [String] = [], text: String? = nil) {
        self.questionID = questionID
        self.selectedOptionIDs = selectedOptionIDs
        self.text = text
    }
}

/// Shared shape checks keep a client from presenting a form the host cannot
/// answer. The host still validates against its own immutable question copy.
public enum RemoteQuestionAnswerValidation {
    public static let maximumTextBytes = 8 * 1024
    public static let maximumEncodedBytes = 48 * 1024

    public static func supports(_ questions: [RemoteInteractionQuestion]) -> Bool {
        guard (1...4).contains(questions.count),
              Set(questions.map(\.id)).count == questions.count,
              Set(questions.map(\.question)).count == questions.count,
              let encoded = try? JSONEncoder().encode(questions),
              encoded.count <= maximumEncodedBytes else { return false }
        return questions.allSatisfy { question in
            nonempty(question.id) && question.id.utf8.count <= 64
                && nonempty(question.header) && question.header.utf8.count <= 256
                && nonempty(question.question)
                && (2...4).contains(question.options.count)
                && Set(question.options.map(\.id)).count == question.options.count
                && Set(question.options.map(\.label)).count == question.options.count
                && question.options.allSatisfy {
                    nonempty($0.id) && $0.id.utf8.count <= 64 && nonempty($0.label)
                }
        }
    }

    /// Returns a complete answer set in question/option order. Invalid IDs,
    /// duplicate selections, and partial answers are rejected, not repaired.
    public static func canonicalAnswers(
        _ answers: [RemoteInteractionAnswer],
        for questions: [RemoteInteractionQuestion]
    ) -> [RemoteInteractionAnswer]? {
        guard supports(questions), answers.count == questions.count,
              Set(answers.map(\.questionID)).count == answers.count else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: answers.map { ($0.questionID, $0) })
        var result: [RemoteInteractionAnswer] = []
        for question in questions {
            guard let answer = byID[question.id],
                  Set(answer.selectedOptionIDs).count == answer.selectedOptionIDs.count else { return nil }
            let selected = Set(answer.selectedOptionIDs)
            guard selected.isSubset(of: Set(question.options.map(\.id))) else { return nil }
            let text = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let customText = text.flatMap { $0.isEmpty ? nil : $0 }
            if let customText {
                guard customText.utf8.count <= maximumTextBytes,
                      customText.unicodeScalars.allSatisfy({
                          $0.properties.generalCategory != .control
                              || $0 == "\n" || $0 == "\r" || $0 == "\t"
                      }) else { return nil }
            }
            let selectionCount = selected.count + (customText == nil ? 0 : 1)
            guard selectionCount > 0, question.multiSelect || selectionCount == 1 else { return nil }
            result.append(RemoteInteractionAnswer(
                questionID: question.id,
                selectedOptionIDs: question.options.map(\.id).filter { selected.contains($0) },
                text: customText
            ))
        }
        guard let encoded = try? JSONEncoder().encode(result),
              encoded.count <= maximumEncodedBytes else { return nil }
        return result
    }

    private static func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct RemoteQuestionAnswerRequest: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var conversationID: RemoteConversationID
    public var interactionID: RemotePendingInteraction.ID
    public var responseID: String
    public var expectedInputEpoch: RemoteInputEpoch
    public var clientRequestID: String
    public var answers: [RemoteInteractionAnswer]

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        conversationID: RemoteConversationID,
        interactionID: RemotePendingInteraction.ID,
        responseID: String,
        expectedInputEpoch: RemoteInputEpoch,
        clientRequestID: String,
        answers: [RemoteInteractionAnswer]
    ) {
        self.protocolVersion = protocolVersion
        self.conversationID = conversationID
        self.interactionID = interactionID
        self.responseID = responseID
        self.expectedInputEpoch = expectedInputEpoch
        self.clientRequestID = clientRequestID
        self.answers = answers
    }
}

public enum RemoteQuestionAnswerRejectionReason: String, Codable, Equatable, Sendable {
    case sendScopeDenied = "send_scope_denied"
    case sessionWritesDisabled = "session_writes_disabled"
    case notBound = "not_bound"
    case epochMismatch = "epoch_mismatch"
    case notPending = "not_pending"
    case expired
    case invalidAnswers = "invalid_answers"
    case alreadySubmitted = "already_submitted"
    case unsupported
}

/// Submission acknowledges handoff to a live hook. Only a later provider
/// completion confirms which answers Claude accepted, including desktop wins.
public enum RemoteQuestionAnswerResult: Equatable, Sendable {
    case submitted
    case duplicate
    case rejected(reason: RemoteQuestionAnswerRejectionReason)
}

extension RemoteQuestionAnswerResult: Codable {
    private enum CodingKeys: String, CodingKey { case status, reason }
    private enum Status: String, Codable { case submitted, duplicate, rejected }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Status.self, forKey: .status) {
        case .submitted: self = .submitted
        case .duplicate: self = .duplicate
        case .rejected:
            self = .rejected(reason: try container.decode(RemoteQuestionAnswerRejectionReason.self, forKey: .reason))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .submitted: try container.encode(Status.submitted, forKey: .status)
        case .duplicate: try container.encode(Status.duplicate, forKey: .status)
        case .rejected(let reason):
            try container.encode(Status.rejected, forKey: .status)
            try container.encode(reason, forKey: .reason)
        }
    }
}
