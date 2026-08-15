import SwiftUI
import ToasttyMobileDomain

struct ToasttyConversationScreen: View {
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
    let onVisibleLiveEdge: (MobileSessionStatus) -> Void

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
        onVisibleLiveEdge: @escaping (MobileSessionStatus) -> Void = { _ in }
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
        self.onVisibleLiveEdge = onVisibleLiveEdge
    }

    var body: some View {
        Group {
            if let conversation = controller.conversation(id: conversationID) {
                VStack(spacing: 0) {
                    header(conversation)
                    ToasttyTranscriptView(
                        state: resolvedPresentation,
                        loadOlder: loadOlder,
                        dismissSendReceipt: dismissSendReceipt,
                        readAcknowledgementEpoch: conversation.state,
                        onVisibleLiveEdge: {
                            onVisibleLiveEdge(conversation.state)
                        }
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
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(ToasttyDesignTokens.elevatedSurface, for: .navigationBar)
        .task(id: composerFocusIsReady) {
            guard composerFocusIsReady, !hasHandledComposerFocusRequest else { return }
            // A focus request during the push transition is dropped by
            // SwiftUI, so wait out the navigation animation first.
            try? await Task.sleep(for: .milliseconds(400))
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
        // Mirrors the home session card hierarchy: status badge on top,
        // prominent title, then a single muted metadata line.
        VStack(alignment: .leading, spacing: 6) {
            ToasttySessionStatusLabel(bucket: conversation.state.bucket)
            Text(conversation.title)
                .font(.headline)
                .foregroundStyle(ToasttyDesignTokens.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("toastty-mobile-conversation-title")
            Text(headerMetadata(conversation))
                .font(.caption2.monospaced())
                .foregroundStyle(ToasttyDesignTokens.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider().overlay(ToasttyDesignTokens.divider) }
    }

    private func headerMetadata(_ conversation: MobileConversation) -> String {
        [conversation.workspaceTitle, conversation.agent.displayName]
            .filter { $0.isEmpty == false }
            .joined(separator: " · ")
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
                composerDisabledStatus(reason)
                    .font(.caption.monospaced())
                    .foregroundStyle(composerStatusColor(reason))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(composerStatusAccessibilityLabel(reason))
                    .accessibilityValue(composerStatusAccessibilityValue(reason))
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

    @ViewBuilder
    private func composerDisabledStatus(
        _ reason: ToasttyComposerDisabledReason
    ) -> some View {
        switch reason {
        case .prompt(.starting):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(ToasttyDesignTokens.amber)
                Text("Session starting…")
            }
        case .prompt(.working):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(ToasttyDesignTokens.amber)
                Text("Agent working…")
            }
        default:
            Label(reason.message, systemImage: reason.systemImage)
        }
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
                        .tint(ToasttyDesignTokens.inkOnAmber)
                        .frame(width: 44)
                } else {
                    Image(systemName: "arrow.up")
                        .frame(width: 44)
                }
            }
            .font(.subheadline.weight(.bold))
            .frame(height: 44)
            .background(ToasttyDesignTokens.amber, in: RoundedRectangle(cornerRadius: 11))
            .foregroundStyle(ToasttyDesignTokens.inkOnAmber)
        }
        .buttonStyle(.plain)
        .disabled(canSubmit(presentation) == false)
        .opacity(canSubmit(presentation) ? 1 : 0.36)
        .sensoryFeedback(.impact(weight: .light), trigger: isSubmitting) { old, new in
            old == false && new
        }
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
        ToasttyComposerPresentation.makeLockedFallback(
            agentDisplayName: conversation.agent.displayName.capitalized,
            inputAvailability: conversation.inputAvailability
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

    private func composerStatusAccessibilityLabel(
        _ reason: ToasttyComposerDisabledReason
    ) -> String {
        switch reason {
        case .prompt(.starting):
            "Session starting. Composer locked."
        case .prompt(.working):
            "Agent working. Composer locked."
        default:
            "Composer locked. \(reason.message)"
        }
    }

    private func composerStatusAccessibilityValue(
        _ reason: ToasttyComposerDisabledReason
    ) -> String {
        switch reason {
        case .prompt(.starting), .prompt(.working): "In progress"
        default: ""
        }
    }
}
