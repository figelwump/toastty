import AppKit
import ConversationUI
import CoreState
import RemoteProtocol
import SwiftUI

/// The coordinator's conversation as a chat: the shared transcript that the
/// iPhone draws, a composer, and one line above the composer when the chat
/// cannot do what the user needs.
///
/// It shows in two places: over the coordinator's terminal, which keeps
/// running under it (the full view), and in the dock beside another
/// workspace.
@available(macOS 15.0, *)
struct CoordinatorChatView: View {
    @ObservedObject var model: CoordinatorChatModel
    @ObservedObject var controller: CoordinatorController
    /// Observed: the agent's status decides the notice.
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore
    /// Observed: a chip follows its task's record.
    @ObservedObject var board: TaskBoardStore
    let store: AppStore
    let panelID: UUID
    let windowID: UUID
    /// The chat is on screen: its workspace and tab are the selected ones.
    let isOnScreen: Bool
    /// The coordinator's terminal is the panel that has the keyboard.
    let hasPanelFocus: Bool
    /// Where this view of the chat is.
    var host: CoordinatorChatModel.Host = .panel
    var settledDockWidth: CGFloat?
    @StateObject private var linkOpener = CoordinatorChatLinkOpener()

    /// The size of the notice's text before the text scale: the caption
    /// style's size on macOS.
    static let captionSize = NSFont.preferredFont(forTextStyle: .caption1).pointSize

    /// Lines of text stay readable in a wide panel.
    static let maximumContentWidth: CGFloat = 760
    static let transcriptOptions = ToasttyTranscriptOptions(
        maximumContentWidth: maximumContentWidth,
        readOnlyInteractionMessage: "Answer in the terminal",
        shortenedPreviewMessage: "Preview shortened. The terminal shows the full request.",
        showsMessageCopyButton: true,
        foldsRunningWork: true
    )

    var body: some View {
        let items = board.items()
        let chips = CoordinatorTaskChips(items: items)
        // The handler of this pass, for the one action the text views hold.
        // It takes what it needs and not the view, which holds the opener.
        linkOpener.open = { [board, store, controller, windowID] url in
            Self.open(url, chips: chips, board: board, store: store, controller: controller, windowID: windowID)
        }
        return VStack(spacing: 0) {
            CoordinatorChatTranscriptPane(
                model: model,
                presentation: model.presentation,
                sessionStatus: model.sessionStatus,
                workingIndicator: model.workingIndicator,
                jumpToLiveEdgeRequest: model.jumpToLiveEdgeRequest,
                newMessages: model.newMessages,
                answerStates: model.interactionAnswerStates
            )
            .equatable()
            .modifier(TranscriptViewport(settledDockWidth: settledDockWidth))
            .overlay {
                if model.showsIntroduction {
                    introduction
                }
            }
            composerArea(mentionCandidates: CoordinatorMentionCandidate.candidates(from: items))
        }
        // Files and images dropped anywhere on the chat are attached to the
        // composer's message. The terminal under the chat takes none.
        .background {
            AttachmentDropArea(dropTarget: model.attachmentDropTarget(host: host))
                .accessibilityHidden(true)
        }
        .background(ConversationDesignTokens.background)
        .environment(\.conversationLinkPresenter, chips.presenter)
        .environment(\.conversationTextScale, model.textScale)
        .environment(\.openURL, linkOpener.action)
        .environment(\.showQuestionTerminal, { [controller, host] in
            Self.showTerminal(using: controller, from: host)
        })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coordinator.chat")
        // Read the conversation only while the chat is on screen.
        .onChange(of: isOnScreen, initial: true) { _, onScreen in
            if onScreen {
                model.show(panelID: panelID, host: host)
            } else {
                model.hide(panelID: panelID, host: host)
            }
        }
        .onChange(of: panelID) { previous, panelID in
            model.hide(panelID: previous, host: host)
            if isOnScreen { model.show(panelID: panelID, host: host) }
        }
        .onDisappear { model.hide(panelID: panelID, host: host) }
        .onChange(of: isOnScreen && hasPanelFocus, initial: true) { _, takesKeyboard in
            if takesKeyboard { model.requestComposerFocus() }
        }
    }

    private struct TranscriptViewport: ViewModifier {
        let settledDockWidth: CGFloat?

        func body(content: Content) -> some View {
            if let settledDockWidth {
                // Move the dock edge and composer live, without asking every
                // message to wrap at each intermediate width.
                content.frame(width: settledDockWidth)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .clipped()
                    .contentShape(Rectangle())
            } else {
                content
            }
        }
    }

    static let introductionTitle = CoordinatorChatPresentation.introductionTitle
    static let introductionText = CoordinatorChatPresentation.introductionText

    /// Toasty introduces itself while the conversation has no message. It
    /// covers the empty transcript, also while that loads.
    private var introduction: some View {
        let scale = model.textScale
        return VStack(spacing: 10 * scale) {
            ToastyIcon(style: .golden, size: 52 * scale, badgeRingColor: ConversationDesignTokens.background)
            Text(Self.introductionTitle)
                .font(.system(size: 17 * scale, weight: .semibold))
                .foregroundStyle(ConversationDesignTokens.primaryText)
            Text(Self.introductionText)
                .font(.system(size: 13 * scale))
                .foregroundStyle(ConversationDesignTokens.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300 * scale)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ConversationDesignTokens.background)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("coordinator.chat.introduction")
    }

    private func composerArea(mentionCandidates: [CoordinatorMentionCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = model.notice {
                noticeRow(notice)
            }
            CoordinatorComposerView(
                text: $model.draft,
                attachments: model.attachmentDraft,
                reply: model.replyTarget,
                onCancelReply: { model.cancelReply() },
                // The dock is narrow: its hint leaves out the shortcut.
                placeholder: Self.composerPlaceholder(
                    quickEntryShortcut: host == .panel ? board.newTaskShortcut : nil
                ),
                canStop: model.canStop,
                isEditable: model.isSendingFiles == false,
                delivery: model.delivery,
                focusRequestID: model.composerFocusRequest,
                fontSize: CoordinatorComposerTextEditor.defaultFontSize * model.textScale,
                onSend: { model.send() },
                onQueue: { model.send(queueing: true) },
                onChooseQueue: { model.queueSelected = $0 },
                onStop: { model.stop() },
                onChooseFiles: { model.chooseFiles() },
                dropTarget: model.attachmentDropTarget(host: host),
                onTextView: { [host, panelID] textView in
                    model.setComposerTextView(textView, host: host)
                    (textView as? CoordinatorComposerTextView)?.canApplyFocusRequest = { [weak controller] in
                        controller?.presentsComposer(at: host, panelID: panelID) == true
                    }
                },
                mentionCandidates: mentionCandidates
            )
        }
        .frame(maxWidth: Self.maximumContentWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func noticeRow(_ notice: CoordinatorChatModel.Notice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Self.text(for: notice))
                .font(.system(size: Self.captionSize * model.textScale))
                .foregroundStyle(ConversationDesignTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch notice {
            case .agentNotRunning:
                noticeButton("Restart Coordinator", identifier: "coordinator.chat.notice.restart") {
                    controller.perform(.restart)
                }
            case .agentStarting, .startWaitsInTerminal, .awaitingAnswerInTerminal:
                showTerminalButton
            case .terminalDraft:
                showTerminalButton
                noticeButton("Send Anyway", identifier: "coordinator.chat.notice.send-anyway") {
                    model.sendPastTerminalDraft()
                }
            case .deliveryNotConfirmed:
                showTerminalButton
                dismissButton
            case .typingInterrupted:
                showTerminalButton
            case .instructionsMayBeCut:
                noticeButton("Restart Coordinator", identifier: "coordinator.chat.notice.restart") {
                    controller.perform(.restart)
                }
                noticeButton("Don't Show Again", identifier: "coordinator.chat.notice.hide") {
                    controller.hideInstructionsNotice()
                }
            case .failure:
                dismissButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(ConversationDesignTokens.raisedSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coordinator.chat.notice")
    }

    /// The terminal cannot move into the dock: there, Show Terminal opens
    /// the full view with its terminal.
    private var showTerminalButton: some View {
        noticeButton("Show Terminal", identifier: "coordinator.chat.notice.show-terminal") {
            Self.showTerminal(using: controller, from: host)
        }
    }

    private static func showTerminal(using controller: CoordinatorController, from host: CoordinatorChatModel.Host) {
        switch host {
        case .panel: controller.showTerminal()
        case .dock: controller.openFullView(showingTerminal: true)
        }
    }

    private var dismissButton: some View {
        noticeButton("Dismiss", identifier: "coordinator.chat.notice.dismiss") {
            model.dismissNotice()
        }
    }

    private func noticeButton(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: Self.captionSize * model.textScale, weight: .semibold))
            .foregroundStyle(ConversationDesignTokens.amberText)
            .accessibilityIdentifier(identifier)
    }

    /// The field's hint also names the quick entry shortcut, which sends to
    /// the coordinator from any app. It names none when the shortcut is off
    /// or another app holds its keys.
    static func composerPlaceholder(quickEntryShortcut: NewTaskShortcutHint?) -> String {
        CoordinatorChatPresentation.composerPlaceholder(quickEntryShortcut: quickEntryShortcut)
    }

    static func text(for notice: CoordinatorChatModel.Notice) -> String {
        CoordinatorChatPresentation.text(for: notice)
    }

    /// A click on a link in the coordinator's text. The text is an agent's,
    /// so only three things can happen: a task's space opens, the Tasks
    /// view shows a task whose space is closed, or a web page opens in a
    /// browser. Nothing else is opened and nothing is run.
    private static func open(
        _ url: URL,
        chips: CoordinatorTaskChips,
        board: TaskBoardStore,
        store: AppStore,
        controller: CoordinatorController,
        windowID: UUID
    ) -> OpenURLAction.Result {
        // The link's click is the current event: the text view calls this
        // while it handles the click.
        let holdsShift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        let showsTasksView = store.state.window(id: windowID)?.showsTasksView == true
        switch CoordinatorChatLinks.action(
            for: url,
            webPagesOpenInSystemBrowser: holdsShift || showsTasksView,
            taskTarget: { taskID in
                guard chips.chips[taskID] != nil, let record = board.coordinator?.records.record(id: taskID) else { return nil }
                if let workspaceID = record.taskSpaceWorkspaceID, store.state.workspacesByID[workspaceID] != nil {
                    return .taskSpace(workspaceID: workspaceID)
                }
                return .tasksView
            }
        ) {
        case .openTaskSpace(let workspaceID):
            // The chat stays beside the task, in the dock.
            controller.openTaskSpaceFromChat(workspaceID: workspaceID, fallbackWindowID: windowID)
            return .handled
        case .showInTasksView(let taskID):
            // The Tasks view covers this window's workspace; Esc returns to
            // the chat.
            board.showTasksView(
                windowID: windowID,
                selecting: .task(taskID),
                store: store,
                source: .ui("coordinator_task_link")
            )
            return .handled
        case .openWebPageInToastty:
            // The same router as every other link in the app: a Toastty
            // browser in the right panel of the workspace on screen (in the
            // full view, the coordinator's own; beside the dock, that
            // workspace's), unless the user's settings send web links to
            // the system browser.
            let result = AppURLRouter.openResult(url, preferredWindowID: windowID, appStore: store)
            // Focus mode gives the right panel no width, so it ends, as
            // for a link in a terminal.
            if result.openedRightPanelInToastty,
               let workspaceID = store.state.workspaceSelection(in: windowID)?.workspaceID {
                store.send(.exitFocusedPanelMode(workspaceID: workspaceID))
            }
            return .handled
        case .openWebPageInSystemBrowser:
            return .systemAction
        case .ignore:
            return .discarded
        }
    }
}

/// The transcript of the chat. The chat view draws again for every change of
/// the session store and the task board, most of which leave the
/// conversation as it is. This view compares what the transcript shows, so
/// SwiftUI works through the rows again only when that changed. The
/// transcript's actions all go to the model, which stays the same object.
@available(macOS 15.0, *)
private struct CoordinatorChatTranscriptPane: View, Equatable {
    let model: CoordinatorChatModel
    let presentation: ToasttyConversationPresentationState
    let sessionStatus: ToasttyTranscriptSessionStatus?
    let workingIndicator: ToasttyTranscriptWorkingIndicator?
    let jumpToLiveEdgeRequest: UInt64
    let newMessages: ToasttyNewMessagesMarker?
    let answerStates: [RemotePendingInteraction.ID: ToasttyInteractionAnswerState]

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model
            && lhs.presentation == rhs.presentation
            && lhs.sessionStatus == rhs.sessionStatus
            && lhs.workingIndicator == rhs.workingIndicator
            && lhs.jumpToLiveEdgeRequest == rhs.jumpToLiveEdgeRequest
            && lhs.newMessages == rhs.newMessages
            && lhs.answerStates == rhs.answerStates
    }

    var body: some View {
        ToasttyTranscriptView(
            state: presentation,
            isSubmitting: false,
            loadOlder: { model.loadOlder() },
            queuedMessageAction: { model.perform($0) },
            interactionAnswerStates: answerStates,
            editInteractionAnswer: { model.editQuestionAnswer($0, $1) },
            submitInteractionAnswer: { model.submitQuestionAnswer($0) },
            readAcknowledgementEpoch: sessionStatus,
            workingIndicator: workingIndicator,
            jumpToLiveEdgeRequest: Binding(
                get: { model.jumpToLiveEdgeRequest },
                set: { model.jumpToLiveEdgeRequest = $0 }
            ),
            canAcknowledgeRead: false,
            options: CoordinatorChatView.transcriptOptions,
            replyToMessage: { model.reply(to: $0) },
            newMessages: newMessages
        )
    }
}

/// Holds one `OpenURLAction` for a chat view's lifetime. An action made in
/// the view's body is a new value on every pass, and the environment then
/// tells every text view in the transcript that its link action changed.
/// This action stays the same value and calls the handler of the latest
/// pass.
@MainActor
final class CoordinatorChatLinkOpener: ObservableObject {
    var open: (URL) -> OpenURLAction.Result = { _ in .discarded }
    private(set) lazy var action = OpenURLAction { [weak self] url in
        self?.open(url) ?? .discarded
    }
}

/// The chips for the tasks that exist now: a `toastty://task/<id>` link to
/// one of them is drawn with the task's stage color, live title and pull
/// request number. A `toastty:` link to anything else is plain text.
struct CoordinatorTaskChips {
    let chips: [UUID: ConversationLinkChip]

    init(items: [TaskBoardItem]) {
        var chips: [UUID: ConversationLinkChip] = [:]
        for item in items {
            guard case .task(let taskID) = item.id else { continue }
            chips[taskID] = ConversationLinkChip(
                markColor: Self.chipColor(Self.markColor(for: item)),
                title: ConversationLinkChip.taskTitle(item.title),
                detail: item.pullRequest.map { "#\($0.number)" },
                showsActivity: Self.showsActivity(for: item)
            )
        }
        self.chips = chips
    }

    var presenter: ConversationLinkPresenter {
        .taskChips(chips)
    }

    /// A spinner in place of the dot while the task's agent works, as the
    /// Tasks view draws it.
    static func showsActivity(for item: TaskBoardItem) -> Bool {
        CoordinatorChatPresentation.chipShowsActivity(for: item)
    }

    /// The color of the task's stage mark, as the Tasks view draws it.
    static func markColor(for item: TaskBoardItem) -> Color {
        switch item.stage {
        case .starting:
            ToastyTheme.sidebarTaskStartingMark
        case .needsYou(let attention):
            switch attention {
            case .review, .readyForReview: ToastyTheme.sidebarTaskReviewMark
            case .awaitingReply, .pickWorkspace, .setupFailed, .moveFailed,
                 .agentNeedsInput, .startWaitsInTerminal, .taskSpaceClosed, .cleanupStopped: ToastyTheme.sessionNeedsApprovalText
            case .agentError: ToastyTheme.sessionErrorText
            case .agentFinished: ToastyTheme.sessionReadyText
            }
        case .running, .idle:
            item.agent == .working ? ToastyTheme.accent : ToastyTheme.sidebarSubspaceQuietMark
        case .toShip:
            ToastyTheme.sidebarTaskToShipMark
        case .done:
            ToastyTheme.sidebarSubspaceDoneMark
        case .archived:
            ToastyTheme.sidebarSubspaceQuietMark
        }
    }

    static func chipColor(_ color: Color) -> ConversationChipColor {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        return ConversationChipColor(
            red: Double(resolved.redComponent),
            green: Double(resolved.greenComponent),
            blue: Double(resolved.blueComponent)
        )
    }
}
