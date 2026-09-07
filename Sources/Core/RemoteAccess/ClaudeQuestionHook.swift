import Foundation
import RemoteProtocol

/// The bounded local socket contract between a launch-scoped hook and Toastty.
/// The original provider input stays in the CLI and is never supplied by iOS.
public struct ClaudeQuestionHookEvent: Codable, Equatable, Sendable {
    public enum EventName: String, Codable, Sendable {
        case preToolUse = "PreToolUse"
        case permissionRequest = "PermissionRequest"
        case postToolUse = "PostToolUse"
        case postToolUseFailure = "PostToolUseFailure"
        case userPromptSubmit = "UserPromptSubmit"
        case stop = "Stop"
        case sessionEnd = "SessionEnd"
    }

    public var eventName: EventName
    public var nativeSessionID: String
    public var promptID: String?
    public var transcriptPath: String?
    public var providerCallID: String?
    public var questions: [RemoteInteractionQuestion]?
    public var answers: [String: String]?
    public var subagentID: String?
    public var timestamp: Date

    public init(
        eventName: EventName,
        nativeSessionID: String,
        promptID: String? = nil,
        transcriptPath: String? = nil,
        providerCallID: String? = nil,
        questions: [RemoteInteractionQuestion]? = nil,
        answers: [String: String]? = nil,
        subagentID: String? = nil,
        timestamp: Date = Date()
    ) {
        self.eventName = eventName
        self.nativeSessionID = nativeSessionID
        self.promptID = promptID
        self.transcriptPath = transcriptPath
        self.providerCallID = providerCallID
        self.questions = questions
        self.answers = answers
        self.subagentID = subagentID
        self.timestamp = timestamp
    }
}

public struct ClaudeQuestionHookRequest: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case observe, begin, poll, end }
    public var phase: Phase
    public var sessionID: String
    public var panelID: UUID
    public var event: ClaudeQuestionHookEvent?
    public var responseID: String?

    public init(
        phase: Phase,
        sessionID: String,
        panelID: UUID,
        event: ClaudeQuestionHookEvent? = nil,
        responseID: String? = nil
    ) {
        self.phase = phase
        self.sessionID = sessionID
        self.panelID = panelID
        self.event = event
        self.responseID = responseID
    }
}

public struct ClaudeQuestionHookReply: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case observed, pending, answer, finished, unavailable }
    public var status: Status
    public var responseID: String?
    public var providerCallID: String?
    public var answers: [RemoteInteractionAnswer]?
    public var expiresAt: Date?

    public init(
        status: Status,
        responseID: String? = nil,
        providerCallID: String? = nil,
        answers: [RemoteInteractionAnswer]? = nil,
        expiresAt: Date? = nil
    ) {
        self.status = status
        self.responseID = responseID
        self.providerCallID = providerCallID
        self.answers = answers
        self.expiresAt = expiresAt
    }
}

public enum ClaudeQuestionValidation {
    public static let maximumWaitSeconds: TimeInterval = 300
    public static let leaseSeconds: TimeInterval = 10
    public static let pollIntervalSeconds: TimeInterval = 1

    public static func validateQuestions(_ questions: [RemoteInteractionQuestion]) -> Bool {
        RemoteQuestionAnswerValidation.supports(questions)
    }

    public static func canonicalAnswers(
        _ answers: [RemoteInteractionAnswer],
        for questions: [RemoteInteractionQuestion]
    ) -> [RemoteInteractionAnswer]? {
        RemoteQuestionAnswerValidation.canonicalAnswers(answers, for: questions)
    }

    /// Claude requires labels joined with commas for multiple selections. Only
    /// this adapter performs that conversion; mobile clients send opaque IDs.
    public static func providerAnswers(
        _ answers: [RemoteInteractionAnswer],
        for questions: [RemoteInteractionQuestion]
    ) -> [String: String]? {
        guard let canonical = canonicalAnswers(answers, for: questions) else { return nil }
        var result: [String: String] = [:]
        for (question, answer) in zip(questions, canonical) {
            let selected = Set(answer.selectedOptionIDs)
            var parts = question.options.filter { selected.contains($0.id) }.map(\.label)
            if let text = answer.text { parts.append(text) }
            result[question.question] = parts.joined(separator: ", ")
        }
        return result
    }

    /// A provider completion's answer string is authoritative. Recognize exact
    /// option combinations, preserving all other content as custom text rather
    /// than splitting arbitrary user text or comma-containing labels.
    public static func answersFromProvider(
        _ answers: [String: String],
        for questions: [RemoteInteractionQuestion]
    ) -> [RemoteInteractionAnswer]? {
        guard validateQuestions(questions),
              Set(answers.keys) == Set(questions.map(\.question)) else { return nil }
        return questions.map { question in
            let text = answers[question.question]!
            let combinations = question.multiSelect
                ? (1..<(1 << question.options.count)).map { mask in
                    question.options.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
                }
                : question.options.map { [$0] }
            let matching = combinations.filter { $0.map(\.label).joined(separator: ", ") == text }
            if matching.count == 1 {
                return RemoteInteractionAnswer(questionID: question.id, selectedOptionIDs: matching[0].map(\.id))
            }
            return RemoteInteractionAnswer(questionID: question.id, text: text)
        }
    }
}
