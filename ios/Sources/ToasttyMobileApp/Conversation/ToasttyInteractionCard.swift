import RemoteProtocol
import SwiftUI

struct ToasttyInteractionAnswerKey: Hashable, Sendable {
    let interactionID: RemotePendingInteraction.ID
    let responseID: String
    let inputEpoch: RemoteInputEpoch
}

struct ToasttyInteractionQuestionDraft: Equatable, Sendable {
    var selectedOptionIDs: Set<String> = []
    var usesCustomText = false
    var customText = ""
}

enum ToasttyInteractionAnswerStatus: Equatable, Sendable {
    case editing
    case submitting
    case awaitingClaude
    case failed(String)
    case unavailable(String)
    case resolved([RemoteInteractionAnswer])
}

enum ToasttyInteractionAnswerEdit: Equatable, Sendable {
    case toggleOption(questionID: String, optionID: String)
    case toggleCustomText(questionID: String)
    case setCustomText(questionID: String, text: String)
}

struct ToasttyInteractionAnswerState: Equatable, Sendable {
    let key: ToasttyInteractionAnswerKey
    let questions: [RemoteInteractionQuestion]
    var drafts: [String: ToasttyInteractionQuestionDraft]
    var status: ToasttyInteractionAnswerStatus
    var connectionIsLive: Bool
    var retryRequest: RemoteQuestionAnswerRequest?

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
}

struct ToasttyInteractionCard: View {
    let presentation: ToasttyInteractionPresentation
    let answerState: ToasttyInteractionAnswerState?
    let onEdit: (ToasttyInteractionAnswerEdit) -> Void
    let onSubmit: () -> Void

    private var interaction: RemotePendingInteraction { presentation.interaction }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if interaction.questions == nil {
                Text(interaction.prompt)
                    .font(.body)
                    .foregroundStyle(ToasttyDesignTokens.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if interaction.state == .resolved, let answers = interaction.answers {
                resolvedAnswers(answers)
            } else if let answerState,
                      interaction.state == .pending,
                      presentation.responseClosedReason == nil {
                questionForm(answerState)
            } else {
                readOnlyContent
            }
        }
        .padding(14)
        .background(ToasttyDesignTokens.interactionSurface)
        .overlay {
            RoundedRectangle(
                cornerRadius: ToasttyDesignTokens.cardCornerRadius,
                style: .continuous
            )
            .stroke(accentColor.opacity(0.35))
        }
        .clipShape(RoundedRectangle(
            cornerRadius: ToasttyDesignTokens.cardCornerRadius,
            style: .continuous
        ))
        .accessibilityElement(children: answerState == nil ? .combine : .contain)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Label(kindLabel, systemImage: kindIcon)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(accentColor)
            Spacer(minLength: 6)
            Text(interaction.state.rawValue)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(stateColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(stateColor.opacity(0.12), in: Capsule())
        }
    }

    private func questionForm(_ state: ToasttyInteractionAnswerState) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(state.questions) { question in
                questionView(question, state: state)
            }

            statusView(state)

            Button(action: onSubmit) {
                HStack(spacing: 8) {
                    if state.status == .submitting { ProgressView().controlSize(.small) }
                    Text(submitTitle(state.status))
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(ToasttyDesignTokens.amber)
            .disabled(state.canSubmit == false)
            .accessibilityIdentifier("toastty-mobile-interaction-submit-\(interaction.id.rawValue)")

            Label("You can also answer on the desktop", systemImage: "desktopcomputer")
                .font(.caption)
                .foregroundStyle(ToasttyDesignTokens.mutedText)
        }
    }

    private func questionView(
        _ question: RemoteInteractionQuestion,
        state: ToasttyInteractionAnswerState
    ) -> some View {
        let draft = state.drafts[question.id] ?? ToasttyInteractionQuestionDraft()
        return VStack(alignment: .leading, spacing: 8) {
            Text(question.header)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(ToasttyDesignTokens.amberText)
            Text(question.question)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ToasttyDesignTokens.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(question.options, id: \.id) { option in
                optionButton(option, question: question, selected: draft.selectedOptionIDs.contains(option.id))
            }

            Button {
                onEdit(.toggleCustomText(questionID: question.id))
            } label: {
                answerChoiceLabel(
                    title: "Other",
                    detail: "Enter a custom answer",
                    selected: draft.usesCustomText,
                    multiSelect: question.multiSelect
                )
            }
            .buttonStyle(.plain)
            .disabled(isEditingDisabled(state.status))
            .accessibilityValue(draft.usesCustomText ? "Selected" : "Not selected")
            .accessibilityIdentifier(questionID(question, suffix: "custom"))

            if draft.usesCustomText {
                TextField(
                    "Custom answer",
                    text: Binding(
                        get: { draft.customText },
                        set: { onEdit(.setCustomText(questionID: question.id, text: $0)) }
                    ),
                    axis: .vertical
                )
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .disabled(isEditingDisabled(state.status))
                .accessibilityIdentifier(questionID(question, suffix: "custom-text"))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(questionID(question, suffix: "question"))
    }

    private func optionButton(
        _ option: RemotePendingInteraction.Option,
        question: RemoteInteractionQuestion,
        selected: Bool
    ) -> some View {
        Button {
            onEdit(.toggleOption(questionID: question.id, optionID: option.id))
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                answerChoiceLabel(
                    title: option.label,
                    detail: option.detail,
                    selected: selected,
                    multiSelect: question.multiSelect
                )
                if let preview = option.preview, preview.isEmpty == false {
                    Text(preview)
                        .font(.caption.monospaced())
                        .foregroundStyle(ToasttyDesignTokens.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ToasttyDesignTokens.raisedSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(answerState.map { isEditingDisabled($0.status) } ?? true)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityIdentifier(questionID(question, suffix: "option-\(option.id)"))
    }

    private func answerChoiceLabel(
        title: String,
        detail: String?,
        selected: Bool,
        multiSelect: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: multiSelect
                ? (selected ? "checkmark.square.fill" : "square")
                : (selected ? "largecircle.fill.circle" : "circle"))
                .foregroundStyle(selected ? ToasttyDesignTokens.amberText : ToasttyDesignTokens.mutedText)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                if let detail, detail.isEmpty == false {
                    Text(detail).font(.caption).foregroundStyle(ToasttyDesignTokens.mutedText)
                }
            }
            .foregroundStyle(ToasttyDesignTokens.secondaryText)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
    }

    @ViewBuilder
    private func statusView(_ state: ToasttyInteractionAnswerState) -> some View {
        switch state.status {
        case .editing where state.connectionIsLive == false:
            Label("Reconnect to your Mac to answer", systemImage: "wifi.slash")
                .foregroundStyle(ToasttyDesignTokens.mutedText)
        case .editing where state.canonicalAnswers == nil:
            Text("Answer every question to continue")
                .foregroundStyle(ToasttyDesignTokens.mutedText)
        case .submitting:
            Text("Sending answer…").foregroundStyle(ToasttyDesignTokens.mutedText)
        case .awaitingClaude:
            Label("Answer sent · waiting for Claude", systemImage: "hourglass")
                .foregroundStyle(ToasttyDesignTokens.amberText)
        case .failed(let message), .unavailable(let message):
            Label(message, systemImage: "exclamationmark.circle")
                .foregroundStyle(ToasttyDesignTokens.amberText)
        case .editing, .resolved:
            EmptyView()
        }
    }

    private var readOnlyContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let questions = interaction.questions {
                ForEach(questions) { question in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(question.header).font(.caption.monospaced().weight(.semibold))
                        Text(question.question).font(.subheadline)
                        ForEach(question.options, id: \.id) { option in
                            Text("• \(option.label)").font(.caption)
                        }
                    }
                }
            } else if interaction.options.isEmpty == false {
                ForEach(interaction.options, id: \.id) { option in
                    Text(option.label).font(.subheadline.weight(.medium))
                }
            }
            if interaction.state == .pending {
                Label(readOnlyMessage, systemImage: "desktopcomputer")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ToasttyDesignTokens.amberText)
            }
        }
    }

    private func resolvedAnswers(_ answers: [RemoteInteractionAnswer]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Claude accepted", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ToasttyDesignTokens.green)
            ForEach(answers, id: \.questionID) { answer in
                let question = interaction.questions?.first { $0.id == answer.questionID }
                let labels = question?.options.filter {
                    answer.selectedOptionIDs.contains($0.id)
                }.map(\.label) ?? answer.selectedOptionIDs
                VStack(alignment: .leading, spacing: 4) {
                    if let question {
                        Text(question.header)
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(ToasttyDesignTokens.amberText)
                        Text(question.question)
                            .font(.caption)
                            .foregroundStyle(ToasttyDesignTokens.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(([labels.joined(separator: ", "), answer.text]
                        .compactMap { $0 }
                        .filter { $0.isEmpty == false }
                        .joined(separator: ", ")))
                        .font(.subheadline)
                        .foregroundStyle(ToasttyDesignTokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier("toastty-mobile-interaction-accepted-\(interaction.id.rawValue)")
    }

    private var readOnlyMessage: String {
        guard let reason = presentation.responseClosedReason else { return "Respond on the desktop" }
        return switch reason {
        case .expired: "Answer window closed on iPhone · respond on the desktop"
        default: "This answer is no longer available on iPhone · respond on the desktop"
        }
    }

    private func submitTitle(_ status: ToasttyInteractionAnswerStatus) -> String {
        if case .failed = status { return "Retry answer" }
        return "Submit answer"
    }

    private func isEditingDisabled(_ status: ToasttyInteractionAnswerStatus) -> Bool {
        switch status {
        case .editing, .failed: false
        case .submitting, .awaitingClaude, .unavailable, .resolved: true
        }
    }

    private func questionID(_ question: RemoteInteractionQuestion, suffix: String) -> String {
        "toastty-mobile-interaction-\(interaction.id.rawValue)-question-\(question.id)-\(suffix)"
    }

    private var kindLabel: String {
        switch interaction.kind {
        case .permission: "Permission request"
        case .question: "Question"
        case .structuredChoice: "Choose on Mac"
        case .freeForm: "Response requested"
        }
    }

    private var kindIcon: String {
        switch interaction.kind {
        case .permission: "lock.shield"
        case .question: "questionmark.bubble"
        case .structuredChoice: "list.bullet.circle"
        case .freeForm: "text.bubble"
        }
    }

    private var accentColor: Color {
        interaction.state == .pending ? ToasttyDesignTokens.amber : ToasttyDesignTokens.secondaryText
    }

    private var stateColor: Color {
        switch interaction.state {
        case .pending: ToasttyDesignTokens.amberText
        case .resolved: ToasttyDesignTokens.green
        case .superseded: ToasttyDesignTokens.mutedText
        }
    }
}
