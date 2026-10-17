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
    /// Tool identity for permission correlation. PreToolUse carries the call
    /// ID; PermissionRequest does not, so the host matches the two by tool
    /// name and a digest of the tool input. The input itself stays local.
    public var toolName: String?
    public var toolInputDigest: String?
    /// Present only on a PermissionRequest for a tool other than a question.
    public var permission: ClaudePermissionHookPresentation?
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
        toolName: String? = nil,
        toolInputDigest: String? = nil,
        permission: ClaudePermissionHookPresentation? = nil,
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
        self.toolName = toolName
        self.toolInputDigest = toolInputDigest
        self.permission = permission
        self.timestamp = timestamp
    }
}

/// The phone-facing form of a Claude tool permission request. The decision is
/// one single-select question whose option IDs the hook maps back to Claude's
/// decision; Claude's raw permission suggestions never leave the hook.
public struct ClaudePermissionHookPresentation: Codable, Equatable, Sendable {
    /// Claude-style one-line summary, such as "Approve Running ls".
    public var summary: String
    public var detail: RemotePermissionRequestDetail
    public var decision: RemoteInteractionQuestion

    public init(summary: String, detail: RemotePermissionRequestDetail, decision: RemoteInteractionQuestion) {
        self.summary = summary
        self.detail = detail
        self.decision = decision
    }
}

public struct ClaudeQuestionHookRequest: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case observe, begin, poll, end }
    public var phase: Phase
    public var sessionID: String
    public var panelID: UUID
    public var event: ClaudeQuestionHookEvent?
    public var responseID: String?
    /// Only a runner that exhausted its own deadline supplies `.expired`.
    /// Omitted by older helpers and by cleanup after other failures.
    public var endReason: RemoteQuestionAnswerRejectionReason?

    public init(
        phase: Phase,
        sessionID: String,
        panelID: UUID,
        event: ClaudeQuestionHookEvent? = nil,
        responseID: String? = nil,
        endReason: RemoteQuestionAnswerRejectionReason? = nil
    ) {
        self.phase = phase
        self.sessionID = sessionID
        self.panelID = panelID
        self.event = event
        self.responseID = responseID
        self.endReason = endReason
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
    // Human replies may arrive hours after the question, while the hook must
    // still have a finite lifetime and renew its short liveness lease.
    public static let maximumWaitSeconds: TimeInterval = 24 * 60 * 60
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

/// The choices a phone can make on a Claude permission request, encoded as
/// option IDs of the request's single decision question.
public enum ClaudePermissionDecision: Equatable, Sendable {
    case allowOnce
    /// Allow and apply Claude's own suggestion at this index of the request's
    /// `permission_suggestions` array.
    case alwaysAllow(suggestionIndex: Int)
    case deny

    public static let questionID = "decision"
    private static let alwaysPrefix = "always:"

    public var optionID: String {
        switch self {
        case .allowOnce: "allow"
        case .alwaysAllow(let index): "\(Self.alwaysPrefix)\(index)"
        case .deny: "deny"
        }
    }

    public init?(optionID: String) {
        switch optionID {
        case "allow": self = .allowOnce
        case "deny": self = .deny
        default:
            guard optionID.hasPrefix(Self.alwaysPrefix),
                  let index = Int(optionID.dropFirst(Self.alwaysPrefix.count)),
                  index >= 0, Self.alwaysAllow(suggestionIndex: index).optionID == optionID else { return nil }
            self = .alwaysAllow(suggestionIndex: index)
        }
    }

    /// Accepts exactly one offered option and no custom text. A permission has
    /// no free-form answer, so text is rejected rather than ignored.
    public static func decision(
        from answers: [RemoteInteractionAnswer],
        for question: RemoteInteractionQuestion
    ) -> ClaudePermissionDecision? {
        guard question.id == questionID, question.multiSelect == false,
              answers.count == 1, let answer = answers.first,
              answer.questionID == questionID, answer.text == nil,
              answer.selectedOptionIDs.count == 1,
              let optionID = answer.selectedOptionIDs.first,
              question.options.contains(where: { $0.id == optionID }) else { return nil }
        return ClaudePermissionDecision(optionID: optionID)
    }
}
