import AppKit
import ConversationUI
import CoreState
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

    /// The size of the notice's text before the text scale: the caption
    /// style's size on macOS.
    static let captionSize = NSFont.preferredFont(forTextStyle: .caption1).pointSize

    /// Lines of text stay readable in a wide panel.
    static let maximumContentWidth: CGFloat = 760
    static let transcriptOptions = ToasttyTranscriptOptions(
        maximumContentWidth: maximumContentWidth,
        readOnlyInteractionMessage: "Answer in the terminal",
        shortenedPreviewMessage: "Preview shortened. The terminal shows the full request.",
        showsMessageCopyButton: true
    )

    var body: some View {
        let items = board.items()
        let chips = CoordinatorTaskChips(items: items)
        VStack(spacing: 0) {
            ToasttyTranscriptView(
                state: model.presentation,
                isSubmitting: false,
                loadOlder: { model.loadOlder() },
                queuedMessageAction: { model.perform($0) },
                readAcknowledgementEpoch: model.sessionStatus,
                workingIndicator: model.workingIndicator,
                jumpToLiveEdgeRequest: $model.jumpToLiveEdgeRequest,
                canAcknowledgeRead: false,
                options: Self.transcriptOptions,
                replyToMessage: { model.reply(to: $0) }
            )
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
            AttachmentDropArea(dropTarget: model.attachmentDropTarget)
                .accessibilityHidden(true)
        }
        .background(ConversationDesignTokens.background)
        .environment(\.conversationLinkPresenter, chips.presenter)
        .environment(\.conversationTextScale, model.textScale)
        .environment(\.openURL, OpenURLAction { url in open(url, chips: chips) })
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

    static let introductionTitle = "Hi, I'm Toasty."
    static let introductionText = "I follow your tasks, keep them moving, and tell you what needs you. Say hi to get started."

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
                dropTarget: model.attachmentDropTarget,
                onTextView: { [host] in model.setComposerTextView($0, host: host) },
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
            switch host {
            case .panel: controller.showsTerminal = true
            case .dock: controller.openFullView(showingTerminal: true)
            }
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
        let placeholder = "Message Toasty…"
        guard let quickEntryShortcut, quickEntryShortcut.isGlobal else { return placeholder }
        return "\(placeholder)  \(quickEntryShortcut.label) from anywhere"
    }

    static func text(for notice: CoordinatorChatModel.Notice) -> String {
        switch notice {
        case .agentNotRunning(let reason):
            reason ?? "The coordinator's agent is not running. A message you send waits for it."
        case .agentStarting:
            "The agent is starting. If this takes long, it may wait for you in the terminal."
        case .startWaitsInTerminal:
            "The coordinator's agent has not started yet. It may wait for your answer in the terminal, for example to a login or a folder-trust question."
        case .awaitingAnswerInTerminal:
            "The coordinator waits for your answer in the terminal."
        case .terminalDraft:
"You typed in the coordinator's terminal, and that text may still be in its prompt. Messages wait until you send it there. If you only answered a question there, choose Send Anyway."
        case .deliveryNotConfirmed:
            "Toastty typed your message, but the conversation did not show it. Check the terminal before you send it again."
        case .typingInterrupted:
            "Toastty quit while it typed a message, so the coordinator may have it already. Check the conversation, then choose Send next or Remove on the paused message."
        case .failure(let message):
            message
        }
    }

    /// A click on a link in the coordinator's text. The text is an agent's,
    /// so only three things can happen: a task's space opens, the Tasks
    /// view shows a task whose space is closed, or a web page opens in a
    /// browser. Nothing else is opened and nothing is run.
    private func open(_ url: URL, chips: CoordinatorTaskChips) -> OpenURLAction.Result {
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

/// What a click on a link in the coordinator's text does.
enum CoordinatorChatLinks {
    enum Action: Equatable {
        case openTaskSpace(workspaceID: UUID)
        /// A task whose space is closed, such as a done or archived one:
        /// the Tasks view, with the task selected.
        case showInTasksView(taskID: UUID)
        /// An `http` or `https` page, in a Toastty browser.
        case openWebPageInToastty
        /// An `http` or `https` page, in the system browser: the click held
        /// Shift, as for a link in a terminal, or the Tasks view covers the
        /// window's workspace, so a Toastty browser could not be seen.
        case openWebPageInSystemBrowser
        case ignore
    }

    /// Where a link to a task that exists leads.
    enum TaskTarget: Equatable {
        /// The task's space is open.
        case taskSpace(workspaceID: UUID)
        /// The task's space is closed or was never made.
        case tasksView
    }

    /// `taskTarget` answers for a task that exists, or `nil` for any other
    /// task ID. `webPagesOpenInSystemBrowser` changes only web links.
    static func action(
        for url: URL,
        webPagesOpenInSystemBrowser: Bool = false,
        taskTarget: (UUID) -> TaskTarget?
    ) -> Action {
        if CoordinatorTaskLink.isToasttyURL(url) {
            guard let taskID = CoordinatorTaskLink.taskID(in: url),
                  let target = taskTarget(taskID) else { return .ignore }
            switch target {
            case .taskSpace(let workspaceID): return .openTaskSpace(workspaceID: workspaceID)
            case .tasksView: return .showInTasksView(taskID: taskID)
            }
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return .ignore }
        return webPagesOpenInSystemBrowser ? .openWebPageInSystemBrowser : .openWebPageInToastty
    }
}

/// The chips for the tasks that exist now: a `toastty://task/<id>` link to
/// one of them is drawn with the task's stage color, live title and pull
/// request number. A `toastty:` link to anything else is plain text.
struct CoordinatorTaskChips {
    let chips: [UUID: ConversationLinkChip]

    static let maximumTitleLength = 60

    init(items: [TaskBoardItem]) {
        var chips: [UUID: ConversationLinkChip] = [:]
        for item in items {
            guard case .task(let taskID) = item.id else { continue }
            chips[taskID] = ConversationLinkChip(
                markColor: Self.chipColor(Self.markColor(for: item)),
                title: Self.shortened(item.title),
                detail: item.pullRequest.map { "#\($0.number)" },
                showsActivity: Self.showsActivity(for: item)
            )
        }
        self.chips = chips
    }

    var presenter: ConversationLinkPresenter {
        let chips = chips
        return ConversationLinkPresenter(revision: chips.hashValue) { url in
            Self.presentation(for: url, chips: chips)
        }
    }

    /// `nil` for a link that is not Toastty's: the transcript draws it as
    /// any link.
    static func presentation(for url: URL, chips: [UUID: ConversationLinkChip]) -> ConversationLinkPresentation? {
        guard CoordinatorTaskLink.isToasttyURL(url) else { return nil }
        guard let taskID = CoordinatorTaskLink.taskID(in: url), let chip = chips[taskID] else {
            return .plainText
        }
        return .chip(chip)
    }

    static func shortened(_ title: String) -> String {
        let oneLine = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard oneLine.isEmpty == false else { return "Untitled task" }
        return oneLine.count > maximumTitleLength ? oneLine.prefix(maximumTitleLength - 1) + "…" : oneLine
    }

    /// A spinner in place of the dot while the task's agent works, as the
    /// Tasks view draws it.
    static func showsActivity(for item: TaskBoardItem) -> Bool {
        switch item.stage {
        case .running, .idle: item.agent == .working
        default: false
        }
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
                 .agentNeedsInput, .taskSpaceClosed, .cleanupStopped: ToastyTheme.sessionNeedsApprovalText
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
