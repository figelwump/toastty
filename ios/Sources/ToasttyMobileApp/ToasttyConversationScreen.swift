import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain

struct ToasttyConversationScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var isLoadingAttachments = false
    @State private var selectedPreview: ToasttyPreviewSelection?
    @State private var isComposerFocused = false
    @State private var composerFocusLifecycle = ToasttyComposerFocusLifecyclePolicy()
    @State private var jumpToLiveEdgeRequest: UInt64 = 0

    let conversationID: UUID
    let controller: HomeScreenController
    let presentation: ToasttyConversationPresentationState?
    let composer: ToasttyComposerPresentation?
    @Binding var draft: String
    let isSubmitting: Bool
    let attachments: [RemoteMessageAttachment]
    let supportsAttachments: Bool
    let addAttachments: ([RemoteMessageAttachment]) -> String?
    let removeAttachment: (UUID) -> Void
    let attachmentRecoveryMessage: String?
    let loadOlder: () -> Void
    let submitDraft: () -> Bool
    let dismissSendReceipt: (String) -> Void
    let interactionAnswerStates: [RemotePendingInteraction.ID: ToasttyInteractionAnswerState]
    let editInteractionAnswer: (RemotePendingInteraction.ID, ToasttyInteractionAnswerEdit) -> Void
    let submitInteractionAnswer: (RemotePendingInteraction.ID) -> Void
    let onVisibleLiveEdge: (MobileSessionStatus) -> Void

    init(
        conversationID: UUID,
        controller: HomeScreenController,
        presentation: ToasttyConversationPresentationState? = nil,
        composer: ToasttyComposerPresentation? = nil,
        draft: Binding<String> = .constant(""),
        isSubmitting: Bool = false,
        attachments: [RemoteMessageAttachment] = [],
        supportsAttachments: Bool = false,
        addAttachments: @escaping ([RemoteMessageAttachment]) -> String? = { _ in nil },
        removeAttachment: @escaping (UUID) -> Void = { _ in },
        attachmentRecoveryMessage: String? = nil,
        loadOlder: @escaping () -> Void = {},
        submitDraft: @escaping () -> Bool = { false },
        dismissSendReceipt: @escaping (String) -> Void = { _ in },
        interactionAnswerStates: [RemotePendingInteraction.ID: ToasttyInteractionAnswerState] = [:],
        editInteractionAnswer: @escaping (
            RemotePendingInteraction.ID,
            ToasttyInteractionAnswerEdit
        ) -> Void = { _, _ in },
        submitInteractionAnswer: @escaping (RemotePendingInteraction.ID) -> Void = { _ in },
        onVisibleLiveEdge: @escaping (MobileSessionStatus) -> Void = { _ in }
    ) {
        self.conversationID = conversationID
        self.controller = controller
        self.presentation = presentation
        self.composer = composer
        _draft = draft
        self.isSubmitting = isSubmitting
        self.attachments = attachments
        self.supportsAttachments = supportsAttachments
        self.addAttachments = addAttachments
        self.removeAttachment = removeAttachment
        self.attachmentRecoveryMessage = attachmentRecoveryMessage
        self.loadOlder = loadOlder
        self.submitDraft = submitDraft
        self.dismissSendReceipt = dismissSendReceipt
        self.interactionAnswerStates = interactionAnswerStates
        self.editInteractionAnswer = editInteractionAnswer
        self.submitInteractionAnswer = submitInteractionAnswer
        self.onVisibleLiveEdge = onVisibleLiveEdge
    }

    var body: some View {
        Group {
            if let conversation = controller.conversation(id: conversationID) {
                ToasttyTranscriptView(
                    state: resolvedPresentation,
                    loadOlder: loadOlder,
                    dismissSendReceipt: dismissSendReceipt,
                    interactionAnswerStates: interactionAnswerStates,
                    editInteractionAnswer: editInteractionAnswer,
                    submitInteractionAnswer: submitInteractionAnswer,
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
        .environment(\.openURL, OpenURLAction { url in
            guard let reference = ToasttyPreviewURLPolicy.localFileReference(url) else { return .systemAction }
            selectedPreview = ToasttyPreviewSelection(
                target: .conversationFile(conversationID: RemoteConversationID(rawValue: conversationID), fileReference: reference),
                title: (reference as NSString).lastPathComponent)
            return .handled
        })
        .sheet(item: $selectedPreview) { selection in
            ToasttyPreviewSheet(selection: selection, detents: previewDetents(for: selection))
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
            ToolbarItem(placement: .topBarTrailing) {
                scratchpadButton
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
    }

    private var resolvedPresentation: ToasttyConversationPresentationState {
        if let presentation { return presentation }
        return .loading
    }

    @ViewBuilder
    private var scratchpadButton: some View {
        let panels = ToasttySessionScratchpads.panels(in: controller.snapshot, for: conversationID)
        if panels.count == 1, let panel = panels.first {
            Button { openScratchpad(panel) } label: {
                Label("Scratchpad", systemImage: "square.on.square")
            }
            .accessibilityIdentifier("toastty-conversation-scratchpad")
        } else if panels.count > 1 {
            Menu {
                ForEach(panels) { panel in
                    Button(panel.menuTitle) { openScratchpad(panel) }
                }
            } label: {
                Label("Scratchpads", systemImage: "square.on.square")
            }
            .accessibilityIdentifier("toastty-conversation-scratchpad")
        }
    }

    private func openScratchpad(_ panel: ToasttySessionScratchpad) {
        guard selectedPreview == nil,
              let current = ToasttySessionScratchpads.panels(in: controller.snapshot, for: conversationID)
                .first(where: { $0.workspaceID == panel.workspaceID && $0.id == panel.id }) else { return }
        isComposerFocused = false
        selectedPreview = current.selection
    }

    private func previewDetents(for selection: ToasttyPreviewSelection) -> Set<PresentationDetent> {
        switch selection.target {
        case .panel: [.large]
        case .conversationFile: [.medium, .large]
        }
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
            if let profile = ToasttySessionExecutionProfilePresentation(
                profile: conversation.executionProfile,
                isLastReported: controller.freshness != .live
            ) {
                ToasttySessionExecutionProfileView(presentation: profile)
            }
            ToasttyAttachmentPicker(
                attachments: attachments,
                supportsAttachments: supportsAttachments,
                allowsInput: presentation.gate.allowsInput && !isSubmitting,
                isLoading: $isLoadingAttachments,
                addAttachments: addAttachments,
                removeAttachment: removeAttachment
            )
            .id(conversationID)
            if let attachmentRecoveryMessage {
                Text(attachmentRecoveryMessage)
                    .font(.caption)
                    .foregroundStyle(ToasttyDesignTokens.amberText)
            }
            HStack(alignment: .bottom, spacing: 8) {
                composerField(presentation)
                    .frame(maxWidth: .infinity)
                sendButton(presentation)
                    .fixedSize(horizontal: true, vertical: true)
            }
            .layoutPriority(usesCompactAttachmentComposer ? 1 : 0)

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
        ToasttyComposerTextView(
            text: $draft,
            isFocused: $isComposerFocused,
            placeholder: presentation.placeholder,
            isEnabled: presentation.gate.allowsInput,
            accessibilityLabel: "Message \(presentation.agentDisplayName)",
            accessibilityHint: presentation.gate.allowsInput
                ? "Enter a message, then use the Send button"
                : disabledAccessibilityHint(presentation),
            maximumVisibleLines: usesCompactAttachmentComposer ? 2 : 5
        )
            // Keep the measured UIKit text height when attachments and the
            // keyboard compete for space; the preview list can shrink instead.
            .fixedSize(horizontal: false, vertical: usesCompactAttachmentComposer)
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
    }

    private var usesCompactAttachmentComposer: Bool {
        dynamicTypeSize.isAccessibilitySize && !attachments.isEmpty
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

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        var lifecycle = composerFocusLifecycle
        isComposerFocused = lifecycle.focus(
            afterTransitionTo: newPhase,
            currentFocus: isComposerFocused
        )
        composerFocusLifecycle = lifecycle
    }

    private func canSubmit(_ presentation: ToasttyComposerPresentation) -> Bool {
        isSubmitting == false && isLoadingAttachments == false
            && (attachments.isEmpty || supportsAttachments)
            && presentation.canSubmit(draft: draft, attachments: attachments)
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

struct ToasttyComposerFocusLifecyclePolicy: Equatable {
    private(set) var isAwaitingActivationAfterBackground = false

    mutating func focus(
        afterTransitionTo scenePhase: ScenePhase,
        currentFocus: Bool
    ) -> Bool {
        switch scenePhase {
        case .background:
            isAwaitingActivationAfterBackground = true
            return false
        case .active where isAwaitingActivationAfterBackground:
            isAwaitingActivationAfterBackground = false
            return false
        case .active, .inactive:
            return currentFocus
        @unknown default:
            return currentFocus
        }
    }
}
