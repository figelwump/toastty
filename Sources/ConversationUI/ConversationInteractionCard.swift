import RemoteProtocol
import SwiftUI

public struct ConversationInteractionCard: View {
    let interaction: RemotePendingInteraction
    let responseClosedReason: RemoteQuestionAnswerRejectionReason?
    let answerState: ConversationInteractionAnswerState?
    let copy: ConversationInteractionCopy
    let theme: ConversationTheme
    let onEdit: (ConversationInteractionAnswerEdit) -> Void
    let onSubmit: () -> Void

    /// Permission buttons apply `onEdit` and then call `onSubmit`. The host
    /// must apply the edit before `onEdit` returns so submission sees that choice.
    public init(interaction: RemotePendingInteraction,
                responseClosedReason: RemoteQuestionAnswerRejectionReason? = nil,
                answerState: ConversationInteractionAnswerState? = nil,
                copy: ConversationInteractionCopy = .init(),
                theme: ConversationTheme = .toastty,
                onEdit: @escaping (ConversationInteractionAnswerEdit) -> Void = { _ in },
                onSubmit: @escaping () -> Void = {}) {
        self.interaction = interaction
        self.responseClosedReason = responseClosedReason
        self.answerState = answerState
        self.copy = copy
        self.theme = theme
        self.onEdit = onEdit
        self.onSubmit = onSubmit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if interaction.kind == .permission, let permission = interaction.permission,
               let decision = interaction.questions?.first {
                ConversationPermissionRequestContent(
                    interaction: interaction,
                    permission: permission,
                    decision: decision,
                    answerState: interaction.state == .pending && responseClosedReason == nil
                        ? answerState : nil,
                    sentOptionID: answerState?.sentOptionID,
                    readOnlyMessage: readOnlyMessage,
                    copy: copy,
                    theme: theme,
                    onChoose: { optionID in
                        onEdit(.selectOnly(questionID: decision.id, optionID: optionID))
                        onSubmit()
                    }
                )
            } else {
                standardContent
            }
        }
        .padding(14)
        .background(theme.interactionSurface)
        .overlay {
            RoundedRectangle(
                cornerRadius: theme.cardCornerRadius,
                style: .continuous
            )
            .stroke(accentColor.opacity(0.35))
        }
        .clipShape(RoundedRectangle(
            cornerRadius: theme.cardCornerRadius,
            style: .continuous
        ))
        .accessibilityElement(children: answerState == nil ? .combine : .contain)
    }

    @ViewBuilder
    private var standardContent: some View {
        if interaction.questions == nil {
            Text(interaction.prompt)
                .font(.body)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }

        if interaction.state == .resolved, let answers = interaction.answers {
            resolvedAnswers(answers)
        } else if let answerState,
                  interaction.state == .pending,
                  responseClosedReason == nil {
            questionForm(answerState)
        } else {
            readOnlyContent
        }
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

    private func questionForm(_ state: ConversationInteractionAnswerState) -> some View {
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
            .tint(theme.amber)
            .disabled(state.canSubmit == false)
            .accessibilityIdentifier("toastty-mobile-interaction-submit-\(interaction.id.rawValue)")

            if let message = copy.answerElsewhere {
                Label(message, systemImage: "desktopcomputer")
                    .font(.caption)
                    .foregroundStyle(theme.mutedText)
            }
        }
    }

    private func questionView(
        _ question: RemoteInteractionQuestion,
        state: ConversationInteractionAnswerState
    ) -> some View {
        let draft = state.drafts[question.id] ?? ConversationInteractionQuestionDraft()
        return VStack(alignment: .leading, spacing: 8) {
            Text(question.header)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(theme.amberText)
            Text(question.question)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.primaryText)
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
                        .foregroundStyle(theme.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.raisedSurface)
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
                .foregroundStyle(selected ? theme.amberText : theme.mutedText)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                if let detail, detail.isEmpty == false {
                    Text(detail).font(.caption).foregroundStyle(theme.mutedText)
                }
            }
            .foregroundStyle(theme.secondaryText)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
    }

    @ViewBuilder
    private func statusView(_ state: ConversationInteractionAnswerState) -> some View {
        switch state.status {
        case .editing where state.connectionIsLive == false:
            Label(copy.reconnectToAnswer, systemImage: "wifi.slash")
                .foregroundStyle(theme.mutedText)
        case .editing where state.canonicalAnswers == nil:
            Text("Answer every question to continue")
                .foregroundStyle(theme.mutedText)
        case .submitting:
            Text("Sending answer…").foregroundStyle(theme.mutedText)
        case .awaitingClaude:
            Label("Answer sent · waiting for \(copy.providerName)", systemImage: "hourglass")
                .foregroundStyle(theme.amberText)
        case .failed(let message), .unavailable(let message):
            Label(message, systemImage: "exclamationmark.circle")
                .foregroundStyle(theme.amberText)
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
                    .foregroundStyle(theme.amberText)
            }
        }
    }

    private func resolvedAnswers(_ answers: [RemoteInteractionAnswer]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(copy.providerName) accepted", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.green)
            ForEach(answers, id: \.questionID) { answer in
                let question = interaction.questions?.first { $0.id == answer.questionID }
                let labels = question?.options.filter {
                    answer.selectedOptionIDs.contains($0.id)
                }.map(\.label) ?? answer.selectedOptionIDs
                VStack(alignment: .leading, spacing: 4) {
                    if let question {
                        Text(question.header)
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(theme.amberText)
                        Text(question.question)
                            .font(.caption)
                            .foregroundStyle(theme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(([labels.joined(separator: ", "), answer.text]
                        .compactMap { $0 }
                        .filter { $0.isEmpty == false }
                        .joined(separator: ", ")))
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier("toastty-mobile-interaction-accepted-\(interaction.id.rawValue)")
    }

    private var readOnlyMessage: String {
        guard let reason = responseClosedReason else { return copy.readOnlyMessage }
        return switch reason {
        case .expired: copy.expiredMessage
        default: copy.unavailableMessage
        }
    }

    private func submitTitle(_ status: ConversationInteractionAnswerStatus) -> String {
        if case .failed = status { return "Retry answer" }
        return "Submit answer"
    }

    private func isEditingDisabled(_ status: ConversationInteractionAnswerStatus) -> Bool {
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
        case .structuredChoice: copy.structuredChoiceLabel
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
        interaction.state == .pending ? theme.amber : theme.secondaryText
    }

    private var stateColor: Color {
        switch interaction.state {
        case .pending: theme.amberText
        case .resolved: theme.green
        case .superseded: theme.mutedText
        }
    }
}
