import SwiftUI
import ToasttyMobileDomain

struct ToasttyConversationSheet: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let conversationID: UUID
    let controller: HomeScreenController
    let presentation: ToasttyConversationPresentationState?
    let composer: ToasttyComposerPresentation?
    @Binding var draft: String
    let isSubmitting: Bool
    let loadOlder: () -> Void
    let submitDraft: () -> Void
    let dismissSendReceipt: (String) -> Void
    let onDismiss: () -> Void

    init(
        conversationID: UUID,
        controller: HomeScreenController,
        presentation: ToasttyConversationPresentationState? = nil,
        composer: ToasttyComposerPresentation? = nil,
        draft: Binding<String> = .constant(""),
        isSubmitting: Bool = false,
        loadOlder: @escaping () -> Void = {},
        submitDraft: @escaping () -> Void = {},
        dismissSendReceipt: @escaping (String) -> Void = { _ in },
        onDismiss: @escaping () -> Void
    ) {
        self.conversationID = conversationID
        self.controller = controller
        self.presentation = presentation
        self.composer = composer
        _draft = draft
        self.isSubmitting = isSubmitting
        self.loadOlder = loadOlder
        self.submitDraft = submitDraft
        self.dismissSendReceipt = dismissSendReceipt
        self.onDismiss = onDismiss
    }

    var body: some View {
        Group {
            if let conversation = controller.conversation(id: conversationID) {
                VStack(spacing: 0) {
                    header(conversation)
                    ToasttyTranscriptView(
                        state: resolvedPresentation,
                        loadOlder: loadOlder,
                        dismissSendReceipt: dismissSendReceipt
                    )
                    composerBar(conversation)
                }
            } else {
                ContentUnavailableView(
                    "Conversation no longer available",
                    systemImage: "bubble.left.and.exclamationmark.bubble.right",
                    description: Text("It was removed from Toastty on your Mac.")
                )
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
            }
        }
        .background(ToasttyDesignTokens.elevatedSurface)
    }

    private var resolvedPresentation: ToasttyConversationPresentationState {
        if let presentation { return presentation }
#if DEBUG
        if controller.runtimeMode == .fixture {
            return ToasttyConversationFixture.presentation(for: conversationID)
        }
#endif
        return .loading
    }

    private func header(_ conversation: MobileConversation) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(conversation.title)
                        .font(.headline)
                        .foregroundStyle(ToasttyDesignTokens.primaryText)
                        .accessibilityIdentifier("toastty-mobile-conversation-title")
                    HStack(spacing: 6) {
                        Text(conversation.workspaceTitle)
                        Text("·")
                        Text(conversation.agent.displayName)
                        Text("·")
                        ToasttyStatusLabel(bucket: conversation.state.bucket, compact: true)
                    }
                    .font(.caption2.monospaced())
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                }
                Spacer(minLength: 12)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 30, height: 30)
                        .background(ToasttyDesignTokens.border, in: Circle())
                }
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .accessibilityLabel("Close conversation")
                .accessibilityIdentifier("toastty-mobile-conversation-close")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider().overlay(ToasttyDesignTokens.divider) }
    }

    private func composerBar(_ conversation: MobileConversation) -> some View {
        let presentation = composer ?? lockedComposerFallback(conversation)
        return VStack(alignment: .leading, spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    composerField(presentation)
                    sendButton(presentation, expands: true)
                }
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    composerField(presentation)
                    sendButton(presentation, expands: false)
                }
            }

            if case .disabled(let reason) = presentation.gate {
                Label(reason.message, systemImage: reason.systemImage)
                    .font(.caption.monospaced())
                    .foregroundStyle(composerStatusColor(reason))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("toastty-mobile-composer-status")
            } else if let feedback = presentation.inlineFeedback {
                Label(feedback, systemImage: "exclamationmark.circle")
                    .font(.caption.monospaced())
                    .foregroundStyle(ToasttyDesignTokens.amberText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("toastty-mobile-composer-status")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ToasttyDesignTokens.elevatedSurface)
        .overlay(alignment: .top) { Divider().overlay(ToasttyDesignTokens.divider) }
    }

    private func composerField(
        _ presentation: ToasttyComposerPresentation
    ) -> some View {
        TextField(presentation.placeholder, text: $draft, axis: .vertical)
            .lineLimit(1...5)
            .textInputAutocapitalization(.sentences)
            .font(.body)
            .foregroundStyle(ToasttyDesignTokens.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(ToasttyDesignTokens.raisedSurface)
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(ToasttyDesignTokens.border)
            }
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .disabled(presentation.gate.allowsInput == false)
            .accessibilityLabel("Message \(presentation.agentDisplayName)")
            .accessibilityHint(
                presentation.gate.allowsInput
                    ? "Enter a message, then use the Send button"
                    : disabledAccessibilityHint(presentation)
            )
            .accessibilityIdentifier("toastty-mobile-composer-input")
    }

    private func sendButton(
        _ presentation: ToasttyComposerPresentation,
        expands: Bool
    ) -> some View {
        Button(action: submitDraft) {
            Group {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color(red: 22 / 255, green: 16 / 255, blue: 6 / 255))
                        .frame(maxWidth: expands ? .infinity : nil)
                        .frame(width: expands ? nil : 44)
                } else if expands {
                    Label("Send", systemImage: "arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                } else {
                    Image(systemName: "arrow.up")
                        .frame(width: 44)
                }
            }
            .font(.subheadline.weight(.bold))
            .frame(height: 44)
            .background(ToasttyDesignTokens.amber, in: RoundedRectangle(cornerRadius: 11))
            .foregroundStyle(Color(red: 22 / 255, green: 16 / 255, blue: 6 / 255))
        }
        .buttonStyle(.plain)
        .disabled(canSubmit(presentation) == false)
        .opacity(canSubmit(presentation) ? 1 : 0.36)
        .accessibilityLabel(isSubmitting ? "Sending message" : "Send message")
        .accessibilityValue(isSubmitting ? "In progress" : "")
        .accessibilityIdentifier("toastty-mobile-composer-send")
    }

    private func canSubmit(_ presentation: ToasttyComposerPresentation) -> Bool {
        isSubmitting == false && presentation.canSubmit(draft: draft)
    }

    private func lockedComposerFallback(
        _ conversation: MobileConversation
    ) -> ToasttyComposerPresentation {
        let reason: ToasttyComposerDisabledReason = switch conversation.inputAvailability {
        case .localDraft:
            .localDraft
        case .pendingInteraction:
            .pendingInteraction
        case .unavailable(let reason) where reason == "offline" || reason == "ended":
            .prompt(.offline)
        case .openPrompt, .unavailable:
            .connection(.catchingUp)
        }
        return ToasttyComposerPresentation(
            agentDisplayName: conversation.agent.displayName.capitalized,
            gate: .disabled(reason)
        )
    }

    private func composerStatusColor(
        _ reason: ToasttyComposerDisabledReason
    ) -> Color {
        switch reason {
        case .localDraft, .pendingInteraction, .sessionWrites, .deviceScope:
            ToasttyDesignTokens.amberText
        case .connection, .prompt:
            ToasttyDesignTokens.mutedText
        }
    }

    private func disabledAccessibilityHint(
        _ presentation: ToasttyComposerPresentation
    ) -> String {
        guard case .disabled(let reason) = presentation.gate else { return "" }
        return reason.message
    }
}
