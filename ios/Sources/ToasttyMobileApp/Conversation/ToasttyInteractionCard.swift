import ConversationUI
import RemoteProtocol
import SwiftUI

struct ToasttyInteractionAnswerKey: Hashable, Sendable {
    let interactionID: RemotePendingInteraction.ID
    let responseID: String
    let inputEpoch: RemoteInputEpoch
}

typealias ToasttyInteractionQuestionDraft = ConversationInteractionQuestionDraft
typealias ToasttyInteractionAnswerStatus = ConversationInteractionAnswerStatus
typealias ToasttyInteractionAnswerEdit = ConversationInteractionAnswerEdit

struct ToasttyInteractionAnswerState: Equatable, Sendable {
    let key: ToasttyInteractionAnswerKey
    let questions: [RemoteInteractionQuestion]
    var drafts: [String: ToasttyInteractionQuestionDraft]
    var status: ToasttyInteractionAnswerStatus
    var connectionIsLive: Bool
    var retryRequest: RemoteQuestionAnswerRequest?
    /// Set when a phone submission finishes; drives the answer haptic.
    var lastSubmission: ToasttyOutcomeFeedback?

    init(
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

    var canonicalAnswers: [RemoteInteractionAnswer]? {
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

    var canSubmit: Bool {
        guard connectionIsLive, canonicalAnswers != nil else { return false }
        return switch status {
        case .editing, .failed: true
        case .submitting, .awaitingClaude, .unavailable, .resolved: false
        }
    }

    mutating func apply(_ edit: ToasttyInteractionAnswerEdit) {
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
    var sentOptionID: String? {
        retryRequest?.answers.first?.selectedOptionIDs.first
    }
}

struct ToasttyInteractionCard: View {
    let presentation: ToasttyInteractionPresentation
    let answerState: ToasttyInteractionAnswerState?
    let onEdit: (ToasttyInteractionAnswerEdit) -> Void
    let onSubmit: () -> Void

    var body: some View {
        ConversationInteractionCard(
            interaction: presentation.interaction,
            responseClosedReason: presentation.responseClosedReason,
            answerState: answerState?.renderingState,
            onEdit: onEdit,
            onSubmit: onSubmit
        )
        .sensoryFeedback(trigger: answerState) { old, new in
            ToasttyHapticFeedback.interactionAnswer(from: old, to: new)
        }
    }
}

extension ToasttyInteractionAnswerState {
    var renderingState: ConversationInteractionAnswerState {
        .init(questions: questions, drafts: drafts, status: status,
              connectionIsLive: connectionIsLive, sentOptionID: sentOptionID)
    }
}
