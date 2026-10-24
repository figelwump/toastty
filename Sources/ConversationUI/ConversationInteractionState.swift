import RemoteProtocol

public struct ConversationInteractionQuestionDraft: Equatable, Sendable {
    public var selectedOptionIDs: Set<String>
    public var usesCustomText: Bool
    public var customText: String

    public init(selectedOptionIDs: Set<String> = [], usesCustomText: Bool = false, customText: String = "") {
        self.selectedOptionIDs = selectedOptionIDs
        self.usesCustomText = usesCustomText
        self.customText = customText
    }
}

public enum ConversationInteractionAnswerStatus: Equatable, Sendable {
    case editing
    case submitting
    case awaitingClaude
    case failed(String)
    case unavailable(String)
    case resolved([RemoteInteractionAnswer])
}

public enum ConversationInteractionAnswerEdit: Equatable, Sendable {
    case toggleOption(questionID: String, optionID: String)
    /// Makes this option the only answer, as a permission decision button does.
    case selectOnly(questionID: String, optionID: String)
    case toggleCustomText(questionID: String)
    case setCustomText(questionID: String, text: String)
}

/// Rendering state only. Each host retains its own submission identity,
/// transport, retry handling and outcome feedback.
public struct ConversationInteractionAnswerState: Equatable, Sendable {
    public var questions: [RemoteInteractionQuestion]
    public var drafts: [String: ConversationInteractionQuestionDraft]
    public var status: ConversationInteractionAnswerStatus
    public var connectionIsLive: Bool
    public var sentOptionID: String?

    public init(questions: [RemoteInteractionQuestion],
                drafts: [String: ConversationInteractionQuestionDraft] = [:],
                status: ConversationInteractionAnswerStatus = .editing,
                connectionIsLive: Bool = true, sentOptionID: String? = nil) {
        self.questions = questions
        self.drafts = drafts
        self.status = status
        self.connectionIsLive = connectionIsLive
        self.sentOptionID = sentOptionID
    }

    public var canonicalAnswers: [RemoteInteractionAnswer]? {
        let answers = questions.map { question in
            let draft = drafts[question.id] ?? ConversationInteractionQuestionDraft()
            return RemoteInteractionAnswer(
                questionID: question.id,
                selectedOptionIDs: question.options.map(\.id).filter { draft.selectedOptionIDs.contains($0) },
                text: draft.usesCustomText ? draft.customText : nil
            )
        }
        return RemoteQuestionAnswerValidation.canonicalAnswers(answers, for: questions)
    }

    public var canSubmit: Bool {
        guard connectionIsLive, canonicalAnswers != nil else { return false }
        return switch status {
        case .editing, .failed: true
        case .submitting, .awaitingClaude, .unavailable, .resolved: false
        }
    }
}

/// Host-specific instructions. Defaults preserve the iPhone strings.
public struct ConversationInteractionCopy {
    public var providerName: String
    public var answerElsewhere: String?
    public var respondElsewhere: String?
    public var reconnectToAnswer: String
    public var reconnectToRespond: String
    public var readOnlyMessage: String
    public var expiredMessage: String
    public var unavailableMessage: String
    public var shortenedPreviewMessage: String
    public var sentOrigin: String
    public var sentOriginIcon: String
    public var structuredChoiceLabel: String

    public init(providerName: String = "Claude",
                answerElsewhere: String? = "You can also answer on the desktop",
                respondElsewhere: String? = "You can also respond on the desktop",
                reconnectToAnswer: String = "Reconnect to your Mac to answer",
                reconnectToRespond: String = "Reconnect to your Mac to respond",
                readOnlyMessage: String = "Respond on the desktop",
                expiredMessage: String = "Answer window closed on iPhone · respond on the desktop",
                unavailableMessage: String = "This answer is no longer available on iPhone · respond on the desktop",
                shortenedPreviewMessage: String = "Preview shortened. Check the desktop for the full request.",
                sentOrigin: String = "Sent from iPhone", sentOriginIcon: String = "iphone",
                structuredChoiceLabel: String = "Choose on Mac") {
        self.providerName = providerName
        self.answerElsewhere = answerElsewhere
        self.respondElsewhere = respondElsewhere
        self.reconnectToAnswer = reconnectToAnswer
        self.reconnectToRespond = reconnectToRespond
        self.readOnlyMessage = readOnlyMessage
        self.expiredMessage = expiredMessage
        self.unavailableMessage = unavailableMessage
        self.shortenedPreviewMessage = shortenedPreviewMessage
        self.sentOrigin = sentOrigin
        self.sentOriginIcon = sentOriginIcon
        self.structuredChoiceLabel = structuredChoiceLabel
    }
}
