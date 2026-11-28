#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CGtkShim
@testable import ConversationUI
import CoreState
import Foundation
import OpenCombine
import RemoteProtocol
@testable import ToasttyAppLogic

/// The coordinator's chat (macOS `CoordinatorChatView`): the transcript,
/// what blocks sending, and the composer. One shows over the coordinator's
/// terminal (`.panel`, the full view) and one in the dock (`.dock`); both
/// read the one `CoordinatorChatModel`, which reads the conversation while a
/// view is on screen.
@MainActor
final class CoordinatorChatView {
    let root: WidgetPtr
    /// The chat moves in and out of the panel's cover; this keeps it alive
    /// while no container holds it.
    private let rootRef: GObjectRef
    let host: CoordinatorChatModel.Host
    private let ui: TasksUI
    private let windowID: UUID
    private let transcript: TranscriptView
    private let introduction: WidgetPtr
    private let noticeBar: WidgetPtr
    private let noticeLabel: WidgetPtr
    private let noticeButtons: WidgetPtr
    let composer: CoordinatorComposer
    private let scaleProvider: OpaquePointer
    private let scaleClass: String
    private var subscriptions: [AnyCancellable] = []
    private var shownPanelID: UUID?
    private lazy var renderScheduler = RenderScheduler("coordinator-chat") { [weak self] in self?.render() }
    private var lastNotice: CoordinatorChatModel.Notice??
    private var lastScale: Double = 0
    private static var nextScaleID = 0

    init(ui: TasksUI, windowID: UUID, host: CoordinatorChatModel.Host) {
        self.ui = ui
        self.windowID = windowID
        self.host = host
        root = Gtk.vbox(classes: ["coordinator-chat"])
        rootRef = GObjectRef(sinking: root)
        Gtk.setName(root, "coordinator.chat.\(host == .dock ? "dock" : "panel")")
        Gtk.expand(root)
        Self.nextScaleID += 1
        scaleClass = "coordinator-chat-scale-\(Self.nextScaleID)"
        Gtk.addClasses(root, [scaleClass])
        scaleProvider = OpaquePointer(gtk_css_provider_new()!)
        if let display = gdk_display_get_default() {
            gtk_style_context_add_provider_for_display(display, cast(scaleProvider), guint(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1))
        }

        let stack = gtk_overlay_new()!
        Gtk.expand(stack)
        transcript = TranscriptView()
        transcript.foldsRunningWork = true
        gtk_overlay_set_child(cast(stack), transcript.root)
        introduction = Gtk.vbox(spacing: 8, classes: ["coordinator-intro"])
        gtk_widget_set_halign(introduction, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(introduction, GTK_ALIGN_CENTER)
        Gtk.append(introduction, Gtk.image(LinuxAppController.applicationID, pixelSize: 56))
        Gtk.append(introduction, Gtk.label(CoordinatorChatPresentation.introductionTitle, classes: ["title-2"], xalign: 0.5))
        let introText = Gtk.label(CoordinatorChatPresentation.introductionText, classes: ["dim-label"], xalign: 0.5, ellipsize: false)
        gtk_label_set_wrap(cast(introText), 1)
        gtk_label_set_max_width_chars(cast(introText), 40)
        gtk_label_set_justify(cast(introText), GTK_JUSTIFY_CENTER)
        Gtk.append(introduction, introText)
        gtk_widget_set_can_target(introduction, 0)
        Gtk.setVisible(introduction, false)
        gtk_overlay_add_overlay(cast(stack), introduction)
        Gtk.append(root, stack)

        noticeBar = Gtk.hbox(spacing: 10, classes: ["coordinator-notice"])
        Gtk.setName(noticeBar, "coordinator.chat.notice")
        noticeLabel = Gtk.label("", classes: ["coordinator-notice-text"], ellipsize: false)
        gtk_label_set_wrap(cast(noticeLabel), 1)
        gtk_widget_set_hexpand(noticeLabel, 1)
        Gtk.append(noticeBar, noticeLabel)
        noticeButtons = Gtk.hbox(spacing: 6)
        gtk_widget_set_valign(noticeButtons, GTK_ALIGN_CENTER)
        Gtk.append(noticeBar, noticeButtons)
        Gtk.setVisible(noticeBar, false)
        Gtk.append(root, noticeBar)

        composer = CoordinatorComposer(host: host) { [weak ui] in
            CoordinatorMentionCandidate.linuxCandidates(from: ui?.board.items() ?? [])
        }
        Gtk.append(root, composer.root)

        transcript.actions = TranscriptActions(
            loadOlder: { [weak self] in self?.model?.loadOlder() },
            queuedMessageAction: { [weak self] action in self?.model?.perform(action) },
            editAnswer: { [weak self] id, edit in self?.model?.editQuestionAnswer(id, edit) },
            submitAnswer: { [weak self] id in self?.model?.submitQuestionAnswer(id) },
            reply: { [weak self] request in self?.model?.reply(to: request) },
            copy: { text in
                if let display = gdk_display_get_default(), let clipboard = gdk_display_get_clipboard(display) {
                    gdk_clipboard_set_text(clipboard, text)
                }
            },
            openLink: { [weak self] url in self?.open(url) },
            showTerminal: { [weak self] in self?.showTerminal() },
            linkPresenter: nil
        )

        Signal.connect(root, "map") { [weak self] in self?.mapped() }
        Signal.connect(root, "unmap") { [weak self] in self?.unmapped() }
        installDrop()
        if let model {
            attach(model)
        }
    }

    func teardown() {
        unmapped()
        transcript.teardown()
        composer.teardown()
        if let display = gdk_display_get_default() {
            gtk_style_context_remove_provider_for_display(display, cast(scaleProvider))
        }
    }

    private var controller: CoordinatorController? { ui.tasks.coordinatorController }
    private var model: CoordinatorChatModel? { controller?.chat }

    private func attach(_ model: CoordinatorChatModel) {
        composer.attach(to: model)
        subscriptions.append(model.objectWillChange.sink { [weak self] _ in self?.scheduleRender() })
        subscriptions.append(ui.board.objectWillChange.sink { [weak self] _ in self?.scheduleRender() })
        composer.onShowTerminal = { [weak self] in self?.showTerminal() }
    }

    // MARK: - On screen

    /// While the view is on screen the model reads the conversation for it.
    private func mapped() {
        guard let model, let panelID = controller?.location?.panelID else { return }
        shownPanelID = panelID
        model.show(panelID: panelID, host: host)
        scheduleRender()
    }

    private func unmapped() {
        guard let panelID = shownPanelID else { return }
        shownPanelID = nil
        model?.hide(panelID: panelID, host: host)
    }

    /// After a restart the coordinator has a new terminal: read that one.
    func followCoordinatorPanel() {
        guard gtk_widget_get_mapped(root).bool, let panelID = controller?.location?.panelID, panelID != shownPanelID else { return }
        unmapped()
        mapped()
    }

    // MARK: - Render

    func scheduleRender() {
        renderScheduler.schedule()
    }

    func render() {
        guard let model else { return }
        let items = ui.board.items()
        let chips = TaskChipColors.chips(items)
        var actions = transcript.actions
        actions.linkPresenter = { url in ConversationLinkPresenter.taskLinkPresentation(for: url, chips: chips) }
        transcript.actions = actions
        transcript.update(
            state: model.presentation,
            answerStates: model.interactionAnswerStates,
            sessionStatus: model.sessionStatus,
            workingIndicator: model.workingIndicator,
            newMessages: model.newMessages,
            jumpRequest: model.jumpToLiveEdgeRequest,
            chipsRevision: chips.hashValue
        )
        Gtk.setVisible(introduction, model.showsIntroduction)
        renderNotice(model.notice)
        composer.render(placeholderText: CoordinatorChatPresentation.composerPlaceholder(quickEntryShortcut: ui.board.newTaskShortcut))
        if model.textScale != lastScale {
            lastScale = model.textScale
            let css = ".\(scaleClass) .transcript, .\(scaleClass) .composer-text { font-size: \(Int((model.textScale * 100).rounded()))%; }"
            gtk_css_provider_load_from_string(cast(scaleProvider), css)
        }
    }

    private func renderNotice(_ notice: CoordinatorChatModel.Notice?) {
        guard lastNotice != .some(notice) else { return }
        lastNotice = .some(notice)
        Gtk.removeAllChildren(noticeButtons)
        guard let notice else {
            Gtk.setVisible(noticeBar, false)
            return
        }
        Gtk.setLabel(noticeLabel, CoordinatorChatPresentation.text(for: notice))
        func button(_ title: String, _ name: String, _ action: @escaping @MainActor () -> Void) {
            let button = Gtk.button(title, classes: ["flat", "coordinator-notice-button"])
            Gtk.setName(button, "coordinator.chat.notice.\(name)")
            Signal.connect(button, "clicked") { action() }
            Gtk.append(noticeButtons, button)
        }
        switch notice {
        case .agentNotRunning:
            button("Restart", "restart") { [weak self] in self?.restart() }
        case .agentStarting, .startWaitsInTerminal, .awaitingAnswerInTerminal, .typingInterrupted:
            button("Show Terminal", "show-terminal") { [weak self] in self?.showTerminal() }
        case .directAgentStarting, .awaitingAnswerOutsideChat:
            break
        case .terminalDraft:
            button("Show Terminal", "show-terminal") { [weak self] in self?.showTerminal() }
            button("Send Anyway", "send-anyway") { [weak self] in self?.model?.sendPastTerminalDraft() }
        case .deliveryNotConfirmed:
            button("Show Terminal", "show-terminal") { [weak self] in self?.showTerminal() }
            button("Dismiss", "dismiss") { [weak self] in self?.model?.dismissNotice() }
        case .instructionsMayBeCut:
            button("Restart", "restart") { [weak self] in self?.restart() }
            button("Don't Show Again", "hide") { [weak self] in self?.controller?.hideInstructionsNotice() }
        case .failure:
            button("Dismiss", "dismiss") { [weak self] in self?.model?.dismissNotice() }
        }
        Gtk.setVisible(noticeBar, true)
    }

    // MARK: - Actions

    /// Show Terminal: the full view shows its terminal; the dock opens the
    /// full view with the terminal, since the terminal cannot move into it.
    func showTerminal() {
        guard let controller else { return }
        switch host {
        case .panel: controller.showTerminal()
        case .dock: controller.openFullView(showingTerminal: true)
        }
    }

    private func restart() {
        controller?.perform(.restart, windowID: windowID)
    }

    /// A click on a link in the coordinator's text: a task's space, the
    /// Tasks view for a task whose space is closed, or a web page. Nothing
    /// else opens.
    private func open(_ url: URL) {
        guard let controller else { return }
        let store = ui.store
        let board = ui.board
        let showsTasksView = store.state.window(id: windowID)?.showsTasksView == true
        switch CoordinatorChatLinks.action(
            for: url,
            webPagesOpenInSystemBrowser: showsTasksView,
            taskTarget: { taskID in
                guard let record = board.coordinator?.records.record(id: taskID) else { return nil }
                if let workspaceID = record.taskSpaceWorkspaceID, store.state.workspacesByID[workspaceID] != nil {
                    return .taskSpace(workspaceID: workspaceID)
                }
                return .tasksView
            }
        ) {
        case .openTaskSpace(let workspaceID):
            controller.openTaskSpaceFromChat(workspaceID: workspaceID, fallbackWindowID: windowID)
        case .showInTasksView(let taskID):
            board.showTasksView(windowID: windowID, selecting: .task(taskID), store: store, source: .ui("coordinator_task_link"))
        case .openWebPageInToastty:
            let result = AppURLRouter.openResult(url, preferredWindowID: windowID, appStore: store)
            if result.openedRightPanelInToastty,
               let workspaceID = store.state.workspaceSelection(in: windowID)?.workspaceID {
                store.send(.exitFocusedPanelMode(workspaceID: workspaceID))
            }
        case .openWebPageInSystemBrowser:
            _ = DesktopLauncher.open(url, parent: gtk_widget_get_root(root).map { widget($0) })
        case .ignore:
            break
        }
    }

    /// Files dropped anywhere on the chat are attached, and the field takes
    /// the keyboard.
    private func installDrop() {
        let target = gtk_drop_target_new(gdk_file_list_get_type(), GDK_ACTION_COPY)!
        Signal.connectDrop(target) { [weak self] value, _, _ in
            guard let self, let model = self.model, let value,
                  let list = g_value_get_boxed(value.assumingMemoryBound(to: GValue.self)) else { return false }
            var urls: [URL] = []
            let head = gdk_file_list_get_files(OpaquePointer(list))
            var node = head
            while let current = node {
                if let file = current.pointee.data, let path = g_file_get_path(OpaquePointer(file)) {
                    urls.append(URL(fileURLWithPath: String(cString: path)))
                    g_free(path)
                }
                node = current.pointee.next
            }
            g_slist_free(head)
            guard urls.isEmpty == false, model.attachmentDraft.canEdit else { return false }
            model.attachmentDraft.attachFiles(urls)
            model.takeKeyboardAfterDrop(host: self.host)
            return true
        }
        gtk_widget_add_controller(root, cast(target))
    }

    // MARK: - Automation

    var automationTranscriptKeys: [String] { transcript.automationItemKeys }
    var automationLatestVisible: Bool { transcript.automationLatestVisible }
    func automationScrollToTop() { transcript.automationScrollToTop() }
    var automationComposerText: String { composer.text }
}
#endif
