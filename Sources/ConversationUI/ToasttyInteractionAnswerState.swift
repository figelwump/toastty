import Foundation
import RemoteProtocol

public struct ToasttyInteractionAnswerKey: Hashable, Sendable {
    public let interactionID: RemotePendingInteraction.ID
    public let responseID: String
    public let inputEpoch: RemoteInputEpoch

    public init(interactionID: RemotePendingInteraction.ID, responseID: String, inputEpoch: RemoteInputEpoch) {
        self.interactionID = interactionID
        self.responseID = responseID
        self.inputEpoch = inputEpoch
    }
}

public struct ToasttyInteractionQuestionDraft: Equatable, Sendable {
    public var selectedOptionIDs: Set<String>
    public var usesCustomText: Bool
    public var customText: String

    public init(selectedOptionIDs: Set<String> = [], usesCustomText: Bool = false, customText: String = "") {
        self.selectedOptionIDs = selectedOptionIDs
        self.usesCustomText = usesCustomText
        self.customText = customText
    }
}

public enum ToasttyInteractionAnswerStatus: Equatable, Sendable {
    case editing
    case submitting
    case awaitingClaude
    case failed(String)
    case unavailable(String)
    case resolved([RemoteInteractionAnswer])
}

public enum ToasttyInteractionAnswerEdit: Equatable, Sendable {
    case toggleOption(questionID: String, optionID: String)
    /// Makes this option the only answer, as a permission decision button does.
    case selectOnly(questionID: String, optionID: String)
    case toggleCustomText(questionID: String)
    case setCustomText(questionID: String, text: String)
}

public struct ToasttyInteractionAnswerState: Equatable, Sendable {
    public let key: ToasttyInteractionAnswerKey
    public let questions: [RemoteInteractionQuestion]
    public var drafts: [String: ToasttyInteractionQuestionDraft]
    public var status: ToasttyInteractionAnswerStatus
    public var connectionIsLive: Bool
    public var retryRequest: RemoteQuestionAnswerRequest?
    /// Set when a phone submission finishes; drives the answer haptic.
    public var lastSubmission: ToasttyOutcomeFeedback?

    public init(
        key: ToasttyInteractionAnswerKey,
        questions: [RemoteInteractionQuestion],
        status: ToasttyInteractionAnswerStatus = .editing,
        connectionIsLive: Bool = true
    ) {
        self.key = key
        self.questions = questions
        drafts = Dictionary(uniqueKeysWithValues: questions.map {
            ($0.id, ToasttyInteractionQuestionDraft())
        })
        self.status = status
        self.connectionIsLive = connectionIsLive
        retryRequest = nil
    }

    public var canonicalAnswers: [RemoteInteractionAnswer]? {
        let answers = questions.map { question in
            let draft = drafts[question.id] ?? ToasttyInteractionQuestionDraft()
            return RemoteInteractionAnswer(
                questionID: question.id,
                selectedOptionIDs: question.options.map(\.id).filter {
                    draft.selectedOptionIDs.contains($0)
                },
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

    public mutating func apply(_ edit: ToasttyInteractionAnswerEdit) {
        guard case .editing = editableStatus else { return }
        switch edit {
        case .toggleOption(let questionID, let optionID):
            guard let question = questions.first(where: { $0.id == questionID }),
                  question.options.contains(where: { $0.id == optionID }) else { return }
            var draft = drafts[questionID] ?? ToasttyInteractionQuestionDraft()
            if draft.selectedOptionIDs.contains(optionID) {
                draft.selectedOptionIDs.remove(optionID)
            } else {
                if question.multiSelect == false {
                    draft.selectedOptionIDs.removeAll()
                    draft.usesCustomText = false
                    draft.customText = ""
                }
                draft.selectedOptionIDs.insert(optionID)
            }
            drafts[questionID] = draft
        case .selectOnly(let questionID, let optionID):
            guard let question = questions.first(where: { $0.id == questionID }),
                  question.options.contains(where: { $0.id == optionID }) else { return }
            drafts[questionID] = ToasttyInteractionQuestionDraft(selectedOptionIDs: [optionID])
        case .toggleCustomText(let questionID):
            guard let question = questions.first(where: { $0.id == questionID }) else { return }
            var draft = drafts[questionID] ?? ToasttyInteractionQuestionDraft()
            draft.usesCustomText.toggle()
            if draft.usesCustomText, question.multiSelect == false {
                draft.selectedOptionIDs.removeAll()
            }
            if draft.usesCustomText == false { draft.customText = "" }
            drafts[questionID] = draft
        case .setCustomText(let questionID, let text):
            guard let question = questions.first(where: { $0.id == questionID }) else { return }
            var draft = drafts[questionID] ?? ToasttyInteractionQuestionDraft()
            draft.usesCustomText = true
            draft.customText = text
            if question.multiSelect == false { draft.selectedOptionIDs.removeAll() }
            drafts[questionID] = draft
        }
        retryRequest = nil
        if case .failed = status { status = .editing }
    }

    private var editableStatus: ToasttyInteractionAnswerStatus {
        if case .failed = status { return .editing }
        return status
    }

    /// The decision this phone sent for a permission request, if any.
    public var sentOptionID: String? {
        retryRequest?.answers.first?.selectedOptionIDs.first
    }
}
