import SwiftUI
import ToasttyMobileDomain

private enum ComposerTouchFocusState: Equatable {
    case idle
    case requested
    case cancelled
}

struct ToasttyConversationScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var isComposerFocused: Bool
    @State private var jumpToLiveEdgeRequest: UInt64 = 0
    @State private var composerTouchFocusState = ComposerTouchFocusState.idle

    let conversationID: UUID
    let controller: HomeScreenController
    let presentation: ToasttyConversationPresentationState?
    let composer: ToasttyComposerPresentation?
    @Binding var draft: String
    let isSubmitting: Bool
    let loadOlder: () -> Void
    let submitDraft: () -> Bool
    let dismissSendReceipt: (String) -> Void
    let onVisibleLiveEdge: (MobileSessionStatus) -> Void

    init(
        conversationID: UUID,
        controller: HomeScreenController,
        presentation: ToasttyConversationPresentationState? = nil,
        composer: ToasttyComposerPresentation? = nil,
        draft: Binding<String> = .constant(""),
        isSubmitting: Bool = false,
        loadOlder: @escaping () -> Void = {},
        submitDraft: @escaping () -> Bool = { false },
        dismissSendReceipt: @escaping (String) -> Void = { _ in },
        onVisibleLiveEdge: @escaping (MobileSessionStatus) -> Void = { _ in }
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
        self.onVisibleLiveEdge = onVisibleLiveEdge
    }

    var body: some View {
        Group {
            if let conversation = controller.conversation(id: conversationID) {
                ToasttyTranscriptView(
                    state: resolvedPresentation,
                    loadOlder: loadOlder,
                    dismissSendReceipt: dismissSendReceipt,
                    readAcknowledgementEpoch: conversation.state,
                    jumpToLiveEdgeRequest: $jumpToLiveEdgeRequest,
                    onVisibleLiveEdge: {
                        onVisibleLiveEdge(conversation.state)
                    }
                )
                .safeAreaInset(edge: .bottom, spacing: 0) {
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(ToasttyDesignTokens.elevatedSurface, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let conversation = controller.conversation(id: conversationID) {
                    navigationBarHeader(conversation)
                }
            }
        }
    }

    private var resolvedPresentation: ToasttyConversationPresentationState {
        if let presentation { return presentation }
        return .loading
    }

    private func navigationBarHeader(_ conversation: MobileConversation) -> some View {
        VStack(spacing: 2) {
            Text(conversation.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ToasttyDesignTokens.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("toastty-mobile-conversation-title")
            HStack(spacing: 5) {
                ToasttySessionStatusLabel(
                    bucket: conversation.state.bucket,
                    freshness: controller.freshness
                )
                .accessibilityIdentifier("toastty-mobile-conversation-status")
                let metadata = headerMetadata(conversation)
                if metadata.isEmpty == false {
                    Text("·")
                        .font(.caption2.monospaced())
                        .foregroundStyle(ToasttyDesignTokens.mutedText)
                    Text(metadata)
                        .font(.caption2.monospaced())
                        .foregroundStyle(ToasttyDesignTokens.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        // The inline navigation bar cannot grow with accessibility type
        // sizes, so cap the header scale to keep both lines legible.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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
            .simultaneousGesture(
                composerFocusGesture(presentation),
                including: isComposerFocused && composerTouchFocusState == .idle
                    ? .subviews
                    : .all
            )
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .textInputAutocapitalization(.sentences)
            .font(.body)
            .foregroundStyle(ToasttyDesignTokens.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(
                ToasttyDesignTokens.raisedSurface,
                in: RoundedRectangle(
                    cornerRadius: ToasttyDesignTokens.controlCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: ToasttyDesignTokens.controlCornerRadius,
                    style: .continuous
                )
                .strokeBorder(
                    isComposerFocused
                        ? ToasttyDesignTokens.amber.opacity(0.55)
                        : ToasttyDesignTokens.border,
                    lineWidth: 1
                )
            }
            .animation(.easeOut(duration: 0.18), value: isComposerFocused)
            .disabled(presentation.gate.allowsInput == false)
            .accessibilityLabel("Message \(presentation.agentDisplayName)")
            .accessibilityHint(
                presentation.gate.allowsInput
                    ? "Enter a message, then use the Send button"
                    : disabledAccessibilityHint(presentation)
            )
            .accessibilityIdentifier("toastty-mobile-composer-input")
    }

    private func composerFocusGesture(
        _ presentation: ToasttyComposerPresentation
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                switch composerTouchFocusState {
                case .idle:
                    guard presentation.gate.allowsInput,
                          isComposerFocused == false
                    else {
                        return
                    }
                    // Start first-responder setup on touch-down so a cold
                    // keyboard cannot postpone editing until tap completion.
                    composerTouchFocusState = .requested
                    isComposerFocused = true
                case .requested:
                    if Self.isCancelledComposerTouch(value.translation) {
                        composerTouchFocusState = .cancelled
                        isComposerFocused = false
                    }
                case .cancelled:
                    break
                }
            }
            .onEnded { value in
                if composerTouchFocusState == .requested,
                   Self.isCancelledComposerTouch(value.translation) {
                    isComposerFocused = false
                }
                composerTouchFocusState = .idle
            }
    }

    private static func isCancelledComposerTouch(_ translation: CGSize) -> Bool {
        max(abs(translation.width), abs(translation.height)) > 10
    }

    private var composerKeyboardClearance: CGFloat {
        isComposerFocused && dynamicTypeSize.isAccessibilitySize ? 32 : 0
    }

    private func sendButton(_ presentation: ToasttyComposerPresentation) -> some View {
        Button(action: sendDraft) {
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
            .background(ToasttyDesignTokens.amber, in: RoundedRectangle(
                cornerRadius: ToasttyDesignTokens.controlCornerRadius,
                style: .continuous
            ))
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

    private func sendDraft() {
        if submitDraft() {
            jumpToLiveEdgeRequest &+= 1
        }
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
