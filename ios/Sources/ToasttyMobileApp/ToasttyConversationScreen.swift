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
    /// Steer is a per-send choice that falls back to queue after each send.
    @State private var steerSelected = false

    let conversationID: UUID
    let controller: HomeScreenController
    let presentation: ToasttyConversationPresentationState?
    let composer: ToasttyComposerPresentation?
    let draft: String
    let draftGeneration: UUID?
    let draftEditRevision: UInt64
    let draftReplacement: ToasttyComposerReplacement?
    let draftDidChange: (String, UInt64) -> Void
    let draftReplacementCompleted: (ToasttyComposerReplacementResult) -> Void
    let isSubmitting: Bool
    let attachments: [RemoteMessageAttachment]
    let supportsAttachments: Bool
    let addAttachments: ([RemoteMessageAttachment]) -> String?
    let removeAttachment: (UUID) -> Void
    let attachmentRecoveryMessage: String?
    let loadOlder: () -> Void
    /// The mode matters only while the agent works; nil at an open prompt.
    let submitDraft: (RemoteMessageDeliveryMode?) -> Bool
    let interrupt: () -> Void
    let dismissSendReceipt: (String) -> Void
    let queuedMessageAction: (ToasttyQueuedMessageAction) -> Void
    let interactionAnswerStates: [RemotePendingInteraction.ID: ToasttyInteractionAnswerState]
    let editInteractionAnswer: (RemotePendingInteraction.ID, ToasttyInteractionAnswerEdit) -> Void
    let submitInteractionAnswer: (RemotePendingInteraction.ID) -> Void
    let onVisibleLiveEdge: (MobileSessionStatus) -> Void

    init(
        conversationID: UUID,
        controller: HomeScreenController,
        presentation: ToasttyConversationPresentationState? = nil,
        composer: ToasttyComposerPresentation? = nil,
        draft: String = "",
        draftGeneration: UUID? = nil,
        draftEditRevision: UInt64 = 0,
        draftReplacement: ToasttyComposerReplacement? = nil,
        draftDidChange: @escaping (String, UInt64) -> Void = { _, _ in },
        draftReplacementCompleted: @escaping (ToasttyComposerReplacementResult) -> Void = { _ in },
        isSubmitting: Bool = false,
        attachments: [RemoteMessageAttachment] = [],
        supportsAttachments: Bool = false,
        addAttachments: @escaping ([RemoteMessageAttachment]) -> String? = { _ in nil },
        removeAttachment: @escaping (UUID) -> Void = { _ in },
        attachmentRecoveryMessage: String? = nil,
        loadOlder: @escaping () -> Void = {},
        submitDraft: @escaping (RemoteMessageDeliveryMode?) -> Bool = { _ in false },
        interrupt: @escaping () -> Void = {},
        dismissSendReceipt: @escaping (String) -> Void = { _ in },
        queuedMessageAction: @escaping (ToasttyQueuedMessageAction) -> Void = { _ in },
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
        self.draft = draft
        self.draftGeneration = draftGeneration
        self.draftEditRevision = draftEditRevision
        self.draftReplacement = draftReplacement
        self.draftDidChange = draftDidChange
        self.draftReplacementCompleted = draftReplacementCompleted
        self.isSubmitting = isSubmitting
        self.attachments = attachments
        self.supportsAttachments = supportsAttachments
        self.addAttachments = addAttachments
        self.removeAttachment = removeAttachment
        self.attachmentRecoveryMessage = attachmentRecoveryMessage
        self.loadOlder = loadOlder
        self.submitDraft = submitDraft
        self.interrupt = interrupt
        self.dismissSendReceipt = dismissSendReceipt
        self.queuedMessageAction = queuedMessageAction
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
                    isSubmitting: isSubmitting,
                    loadOlder: loadOlder,
                    dismissSendReceipt: dismissSendReceipt,
                    queuedMessageAction: queuedMessageAction,
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
            // Next sits rightmost, with Scratchpad just inside it. Each shows
            // only when it has somewhere to go.
            ToolbarItemGroup(placement: .topBarTrailing) {
                scratchpadButton
                nextSessionButton
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

    /// Tap opens the most urgent other session; touch and hold lists them
    /// all. Opening one replaces this conversation, so Back still returns to
    /// the list it came from.
    @ViewBuilder
    private var nextSessionButton: some View {
        let queue = controller.sessionsNeedingAttention(excluding: conversationID)
        if let first = queue.first {
            Menu {
                Section("Need you") {
                    ForEach(queue) { conversation in
                        Button {
                            openNextSession(conversation)
                        } label: {
                            Text(ToasttySessionRowPresentation.title(for: conversation))
                            Text(nextSessionSubtitle(conversation))
                        }
                        .accessibilityIdentifier("toastty-conversation-next-\(conversation.id.uuidString)")
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Text("\(queue.count)")
                        .monospacedDigit()
                    Image(systemName: "chevron.forward")
                        .imageScale(.small)
                }
                .font(.subheadline.weight(.bold))
                // Last-known status while disconnected reads muted, like the
                // rows it came from.
                .foregroundStyle(controller.freshness == .live
                    ? ToasttyDesignTokens.color(for: first.state.bucket)
                    : ToasttyDesignTokens.mutedText)
            } primaryAction: {
                openNextSession(first)
            }
            .accessibilityLabel("Next session")
            .accessibilityValue("\(queue.count) \(queue.count == 1 ? "needs" : "need") you")
            .accessibilityHint(
                "Opens \(ToasttySessionRowPresentation.title(for: first)). Touch and hold to choose another."
            )
            .accessibilityIdentifier("toastty-conversation-next")
        }
    }

    private func nextSessionSubtitle(_ conversation: MobileConversation) -> String {
        let parent = controller.snapshot.parent(of: conversation.workspaceID)
        let workspace = parent.map { "\($0.title) › \(conversation.workspaceTitle)" }
            ?? conversation.workspaceTitle
        return [workspace, conversation.state.bucket.rawValue]
            .filter { $0.isEmpty == false }
            .joined(separator: " · ")
    }

    private func openNextSession(_ conversation: MobileConversation) {
        isComposerFocused = false
        controller.open(conversation)
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
            // The trailing Scratchpad and Next buttons narrow the title area;
            // the agent name goes first when the full line no longer fits.
            ViewThatFits(in: .horizontal) {
                headerStatusLine(conversation, metadata: headerMetadata(conversation))
                headerStatusLine(conversation, metadata: conversation.workspaceTitle)
            }
        }
        // The inline navigation bar cannot grow with accessibility type
        // sizes, so cap the header scale to keep both lines legible.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func headerStatusLine(_ conversation: MobileConversation, metadata: String) -> some View {
        HStack(spacing: 5) {
            ToasttySessionStatusLabel(
                bucket: conversation.state.bucket,
                freshness: controller.freshness
            )
            .accessibilityIdentifier("toastty-mobile-conversation-status")
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

    private func headerMetadata(_ conversation: MobileConversation) -> String {
        [conversation.workspaceTitle, conversation.agent.displayName]
            .filter { $0.isEmpty == false }
            .joined(separator: " · ")
    }

    /// The composer is a one-line field until it has focus or content; then it
    /// grows into a card with a button bar underneath the text. The agent's
    /// working state lives in the transcript, not under the field.
    private func isExpandedComposer(_ presentation: ToasttyComposerPresentation) -> Bool {
        presentation.gate.allowsInput
            && (isComposerFocused || !draft.isEmpty || !attachments.isEmpty)
    }

    private func composerBar(_ conversation: MobileConversation) -> some View {
        let presentation = composer ?? lockedComposerFallback(conversation)
        let allowsAttachmentInput = presentation.gate.allowsInput && !isSubmitting
        let isExpanded = isExpandedComposer(presentation)
        let isWorking = presentation.gate.isWorking
        return VStack(alignment: .leading, spacing: 8) {
            ToasttyComposerMetadataView(
                profile: conversation.executionProfile,
                tabTitle: conversation.workspaceTabTitle,
                isLastReported: controller.freshness != .live
            )
            if ToasttyAttachmentTray.isVisible(
                attachments: attachments,
                supportsAttachments: supportsAttachments,
                allowsInput: allowsAttachmentInput,
                isLoading: isLoadingAttachments
            ) {
                ToasttyAttachmentTray(
                    attachments: attachments,
                    supportsAttachments: supportsAttachments,
                    allowsInput: allowsAttachmentInput,
                    isLoading: isLoadingAttachments,
                    removeAttachment: removeAttachment
                )
            }
            if let attachmentRecoveryMessage {
                Text(attachmentRecoveryMessage)
                    .font(.caption)
                    .foregroundStyle(ToasttyDesignTokens.amberText)
            }
            VStack(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    composerField(presentation, showsAttachmentPicker: !isExpanded)
                        .frame(maxWidth: .infinity)
                    if !isExpanded {
                        if presentation.canInterrupt {
                            stopButton
                        }
                        // While working, Send lives in the bar once the field
                        // opens; the collapsed row shows only Stop.
                        if !isWorking || !presentation.canInterrupt {
                            sendButton(presentation, isWorking: isWorking)
                                .fixedSize(horizontal: true, vertical: true)
                        }
                    }
                }
                if isExpanded {
                    composerButtonBar(presentation, isWorking: isWorking)
                }
            }
            .padding(isExpanded ? 8 : 0)
            .background {
                if isExpanded {
                    RoundedRectangle(cornerRadius: ToasttyDesignTokens.cardCornerRadius, style: .continuous)
                        .fill(ToasttyDesignTokens.raisedSurface)
                        .overlay {
                            RoundedRectangle(cornerRadius: ToasttyDesignTokens.cardCornerRadius, style: .continuous)
                                .strokeBorder(
                                    isComposerFocused
                                        ? ToasttyDesignTokens.amber.opacity(0.55)
                                        : ToasttyDesignTokens.border,
                                    lineWidth: 1
                                )
                        }
                }
            }
            .layoutPriority(usesCompactAttachmentComposer ? 1 : 0)
            .onChange(of: isWorking) { _, nowWorking in
                if !nowWorking { steerSelected = false }
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
        _ presentation: ToasttyComposerPresentation,
        showsAttachmentPicker: Bool
    ) -> some View {
        ToasttyComposerTextView(
            text: draft,
            onTextChange: draftDidChange,
            editRevision: draftEditRevision,
            replacement: draftReplacement,
            onReplacementCompleted: draftReplacementCompleted,
            isFocused: $isComposerFocused,
            placeholder: presentation.placeholder,
            isEnabled: presentation.gate.allowsInput,
            accessibilityLabel: "Message \(presentation.agentDisplayName)",
            accessibilityHint: presentation.gate.allowsInput
                ? "Enter a message, then use the Send button"
                : disabledAccessibilityHint(presentation),
            maximumVisibleLines: usesCompactAttachmentComposer ? 2 : 5
        )
            .id(draftGeneration)
            .id(conversationID)
            // Keep the measured UIKit text height when attachments and the
            // keyboard compete for space; the preview list can shrink instead.
            .fixedSize(horizontal: false, vertical: usesCompactAttachmentComposer)
            .padding(.leading, 12)
            // Reserve the trailing inset for the attach button pinned inside
            // the collapsed field, so text never runs underneath the paperclip.
            .padding(.trailing, showsAttachmentPicker ? ToasttyAttachmentPicker.buttonSize : 12)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(
                showsAttachmentPicker ? ToasttyDesignTokens.raisedSurface : .clear,
                in: RoundedRectangle(
                    cornerRadius: ToasttyDesignTokens.controlCornerRadius,
                    style: .continuous
                )
            )
            .overlay(alignment: .bottomTrailing) {
                if showsAttachmentPicker {
                    attachmentPicker(presentation)
                }
            }
            .overlay {
                if showsAttachmentPicker {
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
            }
            .animation(.easeOut(duration: 0.18), value: isComposerFocused)
            .disabled(presentation.gate.allowsInput == false)
    }

    private func attachmentPicker(_ presentation: ToasttyComposerPresentation) -> some View {
        ToasttyAttachmentPicker(
            attachments: attachments,
            supportsAttachments: supportsAttachments,
            allowsInput: presentation.gate.allowsInput && !isSubmitting,
            isLoading: $isLoadingAttachments,
            addAttachments: addAttachments
        )
        .id(conversationID)
    }

    /// Attach on the left; Stop on the right until there is content, then the
    /// queue/steer choice beside Send.
    private func composerButtonBar(
        _ presentation: ToasttyComposerPresentation,
        isWorking: Bool
    ) -> some View {
        // Stop stays until there is something to send; then Send replaces
        // it, with the mode chip directly to its left so the chip reads as
        // modifying the send. Both are never shown together.
        let hasContent = !draft.isEmpty || !attachments.isEmpty
        return HStack(spacing: 8) {
            attachmentPicker(presentation)
            Spacer(minLength: 0)
            if presentation.canInterrupt && !hasContent && !isSubmitting {
                stopButton
            } else {
                if case .working(let canSteer) = presentation.gate.sendMode {
                    deliveryModeChip(canSteer: canSteer)
                }
                sendButton(presentation, isWorking: isWorking)
            }
        }
    }

    /// The mode Send will use: Steer only while selected and still allowed.
    /// If Mac typing closes steer mid-draft, the chip, the label, and the
    /// send itself all fall back to Queue together.
    private func effectiveDeliveryMode(_ presentation: ToasttyComposerPresentation) -> RemoteMessageDeliveryMode {
        steerSelected && presentation.gate.sendMode == .working(canSteer: true) ? .steer : .queue
    }

    /// Queue is the default; the chip takes the accent only in Steer, so
    /// color always marks the non-default choice.
    private func deliveryModeChip(canSteer: Bool) -> some View {
        let isSteer = steerSelected && canSteer
        return Menu {
            Button {
                steerSelected = false
            } label: {
                Label("Queue", systemImage: "text.append")
                Text("Sends after this turn")
            }
            .accessibilityIdentifier("toastty-mobile-composer-mode-queue")
            Button {
                steerSelected = true
            } label: {
                Label("Steer", systemImage: "arrow.triangle.merge")
                Text("Adds to the running turn")
            }
            .disabled(!canSteer)
            .accessibilityIdentifier("toastty-mobile-composer-mode-steer")
        } label: {
            HStack(spacing: 4) {
                if isSteer {
                    Image(systemName: "arrow.triangle.merge")
                        .imageScale(.small)
                }
                Text(isSteer ? "Steer" : "Queue")
                Image(systemName: "chevron.down")
                    .imageScale(.small)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(isSteer ? ToasttyDesignTokens.amberText : ToasttyDesignTokens.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                isSteer ? ToasttyDesignTokens.amber.opacity(0.14) : ToasttyDesignTokens.chipSurface,
                in: Capsule()
            )
        }
        .accessibilityLabel(isSteer ? "Steer selected" : "Queue selected")
        .accessibilityHint("Choose whether Send queues the message or steers the running turn")
        .accessibilityIdentifier("toastty-mobile-composer-mode")
    }

    /// Neutral on purpose: Send is the only accent control in the composer.
    private var stopButton: some View {
        Button {
            interrupt()
        } label: {
            Image(systemName: "stop.fill")
                .font(.caption.weight(.bold))
                .frame(width: 38, height: 38)
                .background(ToasttyDesignTokens.raisedSurface, in: RoundedRectangle(
                    cornerRadius: ToasttyDesignTokens.controlCornerRadius,
                    style: .continuous
                ))
                .overlay {
                    RoundedRectangle(cornerRadius: ToasttyDesignTokens.controlCornerRadius, style: .continuous)
                        .strokeBorder(ToasttyDesignTokens.border, lineWidth: 1)
                }
                .foregroundStyle(ToasttyDesignTokens.primaryText)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: false)
        .accessibilityLabel("Stop the agent")
        .accessibilityHint("Interrupts the running turn")
        .accessibilityIdentifier("toastty-mobile-composer-stop")
    }

    private var usesCompactAttachmentComposer: Bool {
        dynamicTypeSize.isAccessibilitySize && !attachments.isEmpty
    }

    private var composerKeyboardClearance: CGFloat {
        isComposerFocused && dynamicTypeSize.isAccessibilitySize ? 32 : 0
    }

    private func sendButton(
        _ presentation: ToasttyComposerPresentation,
        isWorking: Bool
    ) -> some View {
        let size: CGFloat = isExpandedComposer(presentation) ? 38 : 44
        let steers = isWorking && effectiveDeliveryMode(presentation) == .steer
        return Button {
            sendDraft(presentation, isWorking: isWorking)
        } label: {
            Group {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(ToasttyDesignTokens.inkOnAmber)
                        .frame(width: size)
                } else {
                    Image(systemName: "arrow.up")
                        .frame(width: size)
                }
            }
            .font(.subheadline.weight(.bold))
            .frame(height: size)
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
        .accessibilityLabel(
            isSubmitting ? "Sending message" : (steers ? "Steer message" : (isWorking ? "Queue message" : "Send message"))
        )
        .accessibilityValue(isSubmitting ? "In progress" : "")
        .accessibilityIdentifier("toastty-mobile-composer-send")
    }

    private func sendDraft(_ presentation: ToasttyComposerPresentation, isWorking: Bool) {
        let mode: RemoteMessageDeliveryMode? = isWorking ? effectiveDeliveryMode(presentation) : nil
        if submitDraft(mode) {
            steerSelected = false
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
