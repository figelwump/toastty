import SwiftUI
import ToasttyMobileDomain

struct ToasttyConversationSheet: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var isComposerFocused: Bool
    @State private var hasHandledComposerFocusRequest = false

    let conversationID: UUID
    let requestsComposerFocus: Bool
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
        requestsComposerFocus: Bool = false,
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
        self.requestsComposerFocus = requestsComposerFocus
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
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        composerBar(conversation)
                    }
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
        .task(id: composerFocusIsReady) {
            guard composerFocusIsReady, !hasHandledComposerFocusRequest else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            hasHandledComposerFocusRequest = true
            isComposerFocused = true
        }
    }

    private var composerFocusIsReady: Bool {
        guard requestsComposerFocus,
              let conversation = controller.conversation(id: conversationID)
        else {
            return false
        }
        return (composer ?? lockedComposerFallback(conversation)).gate.allowsInput
    }

    private var resolvedPresentation: ToasttyConversationPresentationState {
        if let presentation { return presentation }
        return .loading
    }

    private func header(_ conversation: MobileConversation) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top) {
                Text(conversation.title)
                    .font(.headline)
                    .foregroundStyle(ToasttyDesignTokens.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("toastty-mobile-conversation-title")
                Spacer(minLength: 12)
                closeButton
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    conversationMetadata(conversation)
                }
                compactConversationMetadata(conversation)
            }
            .font(.caption2.monospaced())
            .foregroundStyle(ToasttyDesignTokens.mutedText)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .padding(.top, dynamicTypeSize.isAccessibilitySize ? 32 : 0)
        .overlay(alignment: .bottom) { Divider().overlay(ToasttyDesignTokens.divider) }
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .frame(width: 48, height: 48)
                .background(ToasttyDesignTokens.border, in: Circle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 48, minHeight: 48)
        .fixedSize(horizontal: true, vertical: true)
        .contentShape(Rectangle())
        .foregroundStyle(ToasttyDesignTokens.secondaryText)
        .accessibilityLabel("Close conversation")
        .accessibilityIdentifier("toastty-mobile-conversation-close")
    }

    @ViewBuilder
    private func conversationMetadata(_ conversation: MobileConversation) -> some View {
        Text(conversation.workspaceTitle)
        Text("·")
        Text(conversation.agent.displayName)
        Text("·")
        ToasttyStatusLabel(bucket: conversation.state.bucket, compact: true)
    }

    private func compactConversationMetadata(_ conversation: MobileConversation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(conversation.workspaceTitle) · \(conversation.agent.displayName)")
                .fixedSize(horizontal: false, vertical: true)
            ToasttyStatusLabel(bucket: conversation.state.bucket, compact: true)
        }
    }

    private func composerBar(_ conversation: MobileConversation) -> some View {
        let presentation = composer ?? lockedComposerFallback(conversation)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                composerField(presentation)
                    .frame(maxWidth: .infinity)
                sendButton(presentation)
                    .fixedSize(horizontal: true, vertical: true)
            }

            if case .disabled(let reason) = presentation.gate {
                Label(reason.message, systemImage: reason.systemImage)
                    .font(.caption.monospaced())
                    .foregroundStyle(composerStatusColor(reason))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Composer locked. \(reason.message)")
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityIdentifier("toastty-mobile-composer-status")
            } else if let feedback = presentation.inlineFeedback {
                Label(feedback, systemImage: "exclamationmark.circle")
                    .font(.caption.monospaced())
                    .foregroundStyle(ToasttyDesignTokens.amberText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Composer notice. \(feedback)")
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityIdentifier("toastty-mobile-composer-status")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .padding(.bottom, composerKeyboardClearance)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ToasttyDesignTokens.elevatedSurface)
        .overlay(alignment: .top) { Divider().overlay(ToasttyDesignTokens.divider) }
    }

    private func composerField(
        _ presentation: ToasttyComposerPresentation
    ) -> some View {
        TextField(presentation.placeholder, text: $draft, axis: .vertical)
            .focused($isComposerFocused)
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

    private var composerKeyboardClearance: CGFloat {
        isComposerFocused && dynamicTypeSize.isAccessibilitySize ? 32 : 0
    }

    private func sendButton(_ presentation: ToasttyComposerPresentation) -> some View {
        Button(action: submitDraft) {
            Group {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color(red: 22 / 255, green: 16 / 255, blue: 6 / 255))
                        .frame(width: 44)
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
