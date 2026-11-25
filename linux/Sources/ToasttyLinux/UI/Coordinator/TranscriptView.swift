#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CGtkShim
@testable import ConversationUI
import Foundation
import RemoteProtocol
@testable import ToasttyAppLogic

/// What the transcript asks of its host (the coordinator chat).
@MainActor
struct TranscriptActions {
    var loadOlder: () -> Void = {}
    var queuedMessageAction: (ToasttyQueuedMessageAction) -> Void = { _ in }
    var editAnswer: (RemotePendingInteraction.ID, ToasttyInteractionAnswerEdit) -> Void = { _, _ in }
    var submitAnswer: (RemotePendingInteraction.ID) -> Void = { _ in }
    var reply: (ToasttyMessageReplyRequest) -> Void = { _ in }
    var copy: (String) -> Void = { _ in }
    var openLink: (URL) -> Void = { _ in }
    var showTerminal: () -> Void = {}
    var linkPresenter: MarkdownWidgets.LinkPresenter?
}

/// The shared transcript (macOS `ToasttyTranscriptView`) in GTK: the
/// conversation's blocks in display order, the turns' work strips, rows of
/// quiet checks, question cards, the messages that wait to be typed and the
/// working line. The layout decisions are `ToasttyTranscriptLayout`'s, as on
/// macOS and iPhone.
///
/// Updates are differential: each display item becomes a `RenderItem`, and
/// only the items after the first one that changed are rebuilt, so a
/// streaming answer redraws its tail and a selection in older messages
/// stays.
@MainActor
final class TranscriptView {
    let root: WidgetPtr
    private let scroller: WidgetPtr
    private let list: WidgetPtr
    private let jumpButton: WidgetPtr
    private let banner: WidgetPtr
    var actions = TranscriptActions()
    var foldsRunningWork = true
    var readOnlyInteractionMessage = CoordinatorChatPresentation.readOnlyInteractionMessage

    private var entries: [(item: RenderItem, widget: GObjectRef)] = []
    private var turnFold = ToasttyTurnFoldState()
    private var quietCheckFold = ToasttyQuietCheckFoldState()
    private var openHostMessages: Set<ToasttyTranscriptRowID> = []
    private var openToolCalls: Set<String> = []
    private var openSenderCards: Set<ToasttyTranscriptRowID> = []
    private var openSubagents: Set<ToasttyTranscriptRowID> = []
    private var lastState: ToasttyConversationPresentationState?
    private var lastInputs: Inputs?
    private var followsLiveEdge = true
    private var lastJumpRequest: UInt64 = 0
    private var elapsedLabels: [(label: WidgetPtr, prefix: String, suffix: String)] = []
    private var elapsedTimer: guint = 0
    private var workingIndicator: ToasttyTranscriptWorkingIndicator?
    private var newMessages: ToasttyNewMessagesMarker?
    private var pendingScroll: ScrollRequest?

    private enum ScrollRequest {
        case liveEdge
        case widget(WidgetPtr)
        case keepDistanceFromBottom(Double)
    }

    struct Inputs: Equatable {
        var state: ToasttyConversationPresentationState
        var answerStates: [RemotePendingInteraction.ID: ToasttyInteractionAnswerState]
        var sessionStatus: ToasttyTranscriptSessionStatus?
        var isWorking: Bool
        var newMessages: ToasttyNewMessagesMarker?
        var chipsRevision: Int
    }

    init() {
        root = gtk_overlay_new()!
        Gtk.addClasses(root, ["transcript"])
        Gtk.expand(root)
        let column = Gtk.vbox()
        banner = Gtk.label("", classes: ["transcript-banner"], xalign: 0.5)
        Gtk.setVisible(banner, false)
        Gtk.append(column, banner)
        list = Gtk.vbox(spacing: 10, classes: ["transcript-list"])
        scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(cast(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(cast(scroller), list)
        Gtk.expand(scroller)
        Gtk.append(column, scroller)
        gtk_overlay_set_child(cast(root), column)

        jumpButton = Gtk.button("Jump to latest", classes: ["transcript-jump", "pill"])
        gtk_widget_set_halign(jumpButton, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(jumpButton, GTK_ALIGN_END)
        gtk_widget_set_margin_bottom(jumpButton, 12)
        Gtk.setVisible(jumpButton, false)
        Gtk.setName(jumpButton, "coordinator.chat.jump")
        gtk_overlay_add_overlay(cast(root), jumpButton)
        Signal.connect(jumpButton, "clicked") { [weak self] in self?.jumpToLiveEdge() }

        if let adjustment = gtk_scrolled_window_get_vadjustment(cast(scroller)) {
            Signal.connect(adjustment, "value-changed") { [weak self] in self?.scrollChanged() }
            Signal.connect(adjustment, "changed") { [weak self] in self?.layoutChanged() }
        }
    }

    func teardown() {
        MainLoop.cancel(elapsedTimer)
        elapsedTimer = 0
    }

    // MARK: - Update

    /// Draws the transcript for this state. `jumpRequest` counts the host's
    /// requests to go to the live edge (after a send).
    func update(
        state: ToasttyConversationPresentationState,
        answerStates: [RemotePendingInteraction.ID: ToasttyInteractionAnswerState],
        sessionStatus: ToasttyTranscriptSessionStatus?,
        workingIndicator: ToasttyTranscriptWorkingIndicator?,
        newMessages: ToasttyNewMessagesMarker?,
        jumpRequest: UInt64,
        chipsRevision: Int
    ) {
        self.workingIndicator = workingIndicator
        let inputs = Inputs(
            state: state, answerStates: answerStates, sessionStatus: sessionStatus,
            isWorking: workingIndicator != nil, newMessages: newMessages, chipsRevision: chipsRevision
        )
        if jumpRequest != lastJumpRequest {
            lastJumpRequest = jumpRequest
            followsLiveEdge = true
            pendingScroll = .liveEdge
        }
        let isFirst = lastState == nil
        let previous = lastState
        if inputs != lastInputs {
            lastInputs = inputs
            reconcileFolds(state: state, sessionStatus: sessionStatus, previous: previous)
            lastState = state
            self.newMessages = newMessages
            rebuild()
        }
        updateBanner(state.phase, truncated: state.historyTruncated)
        if isFirst {
            // The chat opens at the first message the reader has not seen,
            // or at the live edge.
            pendingScroll = newMessagesDivider.map(ScrollRequest.widget) ?? .liveEdge
        }
        if case .prepended = state.revision, let previous, previous.blocks.first?.id != state.blocks.first?.id {
            pendingScroll = pendingScroll ?? .keepDistanceFromBottom(distanceFromBottom)
        }
        if followsLiveEdge, pendingScroll == nil {
            pendingScroll = .liveEdge
        }
        updateElapsedTimer()
        updateJumpButton()
    }

    /// Draws again with the current inputs, after a fold changed.
    private func redraw() {
        guard lastState != nil else { return }
        rebuild()
        updateJumpButton()
    }

    private func reconcileFolds(
        state: ToasttyConversationPresentationState,
        sessionStatus: ToasttyTranscriptSessionStatus?,
        previous: ToasttyConversationPresentationState?
    ) {
        let settled = state.settledTurnIDs(isSessionWorking: sessionStatus?.activity == .working)
        turnFold.reconcile(
            turns: state.turns,
            settledIDs: settled,
            revision: state.revision,
            previousBoundarySequence: previous?.blocks.first?.id.rowID.sequence,
            opensRunningTurns: foldsRunningWork == false
        )
        let liveTurnID = ToasttyTranscriptLayout.liveTurnID(state, isSessionWorking: sessionStatus?.activity == .working)
        quietCheckFold.reconcile(
            runs: ToasttyTranscriptLayout.quietCheckRuns(state, liveTurnID: liveTurnID),
            revision: state.revision,
            expandedTurnIDs: turnFold.expandedIDs
        )
    }

    // MARK: - Render items

    /// One shown item and everything its widget depends on.
    /// What a question card's widgets depend on: not the typed text or
    /// the checked options, which the widgets hold, so typing an answer does
    /// not rebuild the card and take the keyboard from it.
    struct AnswerKey: Equatable {
        var status: ToasttyInteractionAnswerStatus
        var questions: [RemoteInteractionQuestion]
        var connectionIsLive: Bool
        var customTextQuestionIDs: Set<String>
        var canSubmit: Bool

        init(_ state: ToasttyInteractionAnswerState) {
            status = state.status
            questions = state.questions
            connectionIsLive = state.connectionIsLive
            customTextQuestionIDs = Set(state.drafts.filter(\.value.usesCustomText).keys)
            canSubmit = state.canonicalAnswers != nil
        }
    }

    enum RenderItem: Equatable {
        case older(isLoading: Bool)
        case newDivider(count: Int)
        case quietChecks(ToasttyQuietCheckRun, isOpen: Bool)
        case strip(ToasttyTranscriptTurn, isExpanded: Bool, isLive: Bool, isWorking: Bool)
        case block(ToasttyTranscriptBlock, isWork: Bool, open: Set<String>, isWorkingLine: Bool, answer: AnswerKey?, chips: Int)
        case send(ToasttySendPresentationItem, isWorkingLine: Bool)
        case workingRow

        var key: String {
            switch self {
            case .older: "older"
            case .newDivider: "new"
            case .quietChecks(let run, _): "quiet-\(run.id.sequence)"
            case .strip(let turn, _, _, _): "strip-\(turn.id.sequence)"
            case .block(let block, _, _, _, _, _): "block-\(block.id.rowID.sequence)-\(block.id.chunkIndex)"
            case .send(let item, _): "send-\(item.clientRequestID)"
            case .workingRow: "working"
            }
        }
    }

    private func renderItems() -> [RenderItem] {
        guard let state = lastState, let inputs = lastInputs else { return [] }
        let isWorking = inputs.sessionStatus?.activity == .working
        let liveTurnID = ToasttyTranscriptLayout.liveTurnID(state, isSessionWorking: isWorking)
        let runs = ToasttyTranscriptLayout.quietCheckRuns(state, liveTurnID: liveTurnID)
        let workingLine = ToasttyTranscriptLayout.workingLine(
            state, isWorking: inputs.isWorking, foldsRunningWork: foldsRunningWork,
            liveTurnID: liveTurnID, turnFold: turnFold
        )
        let items = ToasttyTranscriptLayout.displayItems(
            state, workingLine: workingLine, turnFold: turnFold, quietCheckFold: quietCheckFold,
            quietCheckRuns: runs, foldsRunningWork: foldsRunningWork
        )
        let dividerTarget = newMessages?.itemID(in: items)
        var result: [RenderItem] = []
        if state.hasOlder || state.isLoadingOlder {
            result.append(.older(isLoading: state.isLoadingOlder))
        }
        for item in items {
            if let dividerTarget, item.id == dividerTarget, let newMessages {
                result.append(.newDivider(count: newMessages.count))
            }
            switch item {
            case .quietChecks(let run):
                result.append(.quietChecks(run, isOpen: quietCheckFold.isOpen(run)))
            case .workStrip(let turn):
                result.append(.strip(
                    turn, isExpanded: turnFold.isExpanded(turn.id), isLive: turn.id == liveTurnID,
                    isWorking: workingLine == .turn(turn.id)
                ))
            case .block(let block, let isWork):
                let rowID = block.id.rowID
                var open: Set<String> = []
                if openHostMessages.contains(rowID) || turnFold.isExpanded(rowID) { open.insert("host") }
                if openSenderCards.contains(rowID) { open.insert("sender") }
                if openSubagents.contains(rowID) { open.insert("subagent") }
                if case .toolBatch(let rows) = block.content {
                    for call in calls(block: block, rows: rows) where openToolCalls.contains(call.id) {
                        open.insert("tool-\(call.id)")
                    }
                }
                var answer: AnswerKey?
                if case .row(let row) = block.content, case .interaction(let presentation) = row.content {
                    answer = inputs.answerStates[presentation.interaction.id].map(AnswerKey.init)
                }
                result.append(.block(
                    block, isWork: isWork, open: open, isWorkingLine: workingLine == .turn(rowID),
                    answer: answer, chips: inputs.chipsRevision
                ))
            }
        }
        for item in state.sendItems {
            result.append(.send(item, isWorkingLine: workingLine == .send(item.clientRequestID)))
        }
        if workingLine == .row {
            result.append(.workingRow)
        }
        return result
    }

    private func calls(block: ToasttyTranscriptBlock, rows: [ToasttyTranscriptRow]) -> [ToasttyToolCall] {
        lastState?.preparedTranscript.toolCallsByBlock[block.id] ?? ToasttyToolCall.calls(in: rows)
    }

    private func rebuild() {
        let items = renderItems()
        var keep = 0
        while keep < entries.count, keep < items.count, entries[keep].item == items[keep] {
            keep += 1
        }
        for entry in entries[keep...] {
            gtk_box_remove(cast(list), entry.widget.widgetPointer)
        }
        entries.removeSubrange(keep...)
        elapsedLabels.removeAll { label in
            gtk_widget_get_parent(label.label) == nil || entries.contains { gtk_widget_is_ancestor(label.label, $0.widget.widgetPointer).bool } == false
        }
        for item in items[keep...] {
            let widget = makeWidget(item)
            gtk_widget_set_name(widget, "transcript.\(item.key)")
            Gtk.append(list, widget)
            entries.append((item, GObjectRef(sinking: widget)))
        }
    }

    private var newMessagesDivider: WidgetPtr? {
        entries.first { if case .newDivider = $0.item { true } else { false } }?.widget.widgetPointer
    }

    // MARK: - Widgets

    private func makeWidget(_ item: RenderItem) -> WidgetPtr {
        switch item {
        case .older(let isLoading):
            let button = Gtk.button(isLoading ? "Loading earlier activity…" : "Load earlier activity", classes: ["flat", "transcript-older"])
            gtk_widget_set_sensitive(button, (isLoading == false).gboolean)
            gtk_widget_set_halign(button, GTK_ALIGN_CENTER)
            Signal.connect(button, "clicked") { [weak self] in self?.loadOlder() }
            return button
        case .newDivider(let count):
            let line = Gtk.hbox(spacing: 8, classes: ["transcript-new"])
            let left = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL)!
            gtk_widget_set_hexpand(left, 1)
            gtk_widget_set_valign(left, GTK_ALIGN_CENTER)
            Gtk.append(line, left)
            let label = Gtk.label("New", classes: ["transcript-new-label"], ellipsize: false)
            gtk_widget_set_tooltip_text(label, count == 1 ? "1 new message" : "\(count) new messages")
            Gtk.append(line, label)
            let right = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL)!
            gtk_widget_set_hexpand(right, 1)
            gtk_widget_set_valign(right, GTK_ALIGN_CENTER)
            Gtk.append(line, right)
            return line
        case .quietChecks(let run, let isOpen):
            let summary = CoordinatorDigestFold.quietChecksSummary(count: run.checks.count, timeRange: run.timeRangeText())
            let button = disclosureLine(summary, isExpanded: isOpen)
            Signal.connect(button, "clicked") { [weak self] in
                self?.quietCheckFold.toggle(run)
                self?.redraw()
            }
            return button
        case .strip(let turn, let isExpanded, let isLive, let isWorking):
            return workStrip(turn, isExpanded: isExpanded, isLive: isLive, isWorking: isWorking)
        case .block(let block, let isWork, let open, let isWorkingLine, _, _):
            var answer: ToasttyInteractionAnswerState?
            if case .row(let row) = block.content, case .interaction(let presentation) = row.content {
                answer = lastInputs?.answerStates[presentation.interaction.id]
            }
            let widget = blockWidget(block, open: open, isWorkingLine: isWorkingLine, answer: answer)
            guard isWork else { return widget }
            let work = Gtk.hbox(classes: ["transcript-work"])
            Gtk.expand(widget, h: true, v: false)
            Gtk.append(work, widget)
            return work
        case .send(let item, let isWorkingLine):
            return sendItemWidget(item, isWorkingLine: isWorkingLine)
        case .workingRow:
            let row = Gtk.hbox(spacing: 8, classes: ["transcript-working"])
            let spinner = gtk_spinner_new()!
            gtk_spinner_start(cast(spinner))
            Gtk.append(row, spinner)
            let label = Gtk.label("working", classes: ["transcript-working-text"], ellipsize: false)
            elapsedLabels.append((label, "working", ""))
            Gtk.append(row, label)
            Gtk.setName(row, "coordinator.chat.working")
            return row
        }
    }

    private func disclosureLine(_ text: String, isExpanded: Bool, spinner: Bool = false) -> WidgetPtr {
        let button = gtk_button_new()!
        Gtk.addClasses(button, ["flat", "transcript-disclosure"])
        let content = Gtk.hbox(spacing: 6)
        gtk_widget_set_halign(content, GTK_ALIGN_CENTER)
        if spinner {
            let spin = gtk_spinner_new()!
            gtk_spinner_start(cast(spin))
            Gtk.append(content, spin)
        }
        let label = Gtk.label(text, classes: ["transcript-disclosure-text"], ellipsize: false)
        Gtk.append(content, label)
        if spinner == false {
            Gtk.append(content, Gtk.image(isExpanded ? "pan-down-symbolic" : "pan-end-symbolic", pixelSize: 10))
        }
        gtk_button_set_child(cast(button), content)
        return button
    }

    private func workStrip(_ turn: ToasttyTranscriptTurn, isExpanded: Bool, isLive: Bool, isWorking: Bool) -> WidgetPtr {
        let chip = Gtk.hbox(spacing: 8, classes: ["transcript-strip"])
        if isWorking {
            let spinner = gtk_spinner_new()!
            gtk_spinner_start(cast(spinner))
            Gtk.append(chip, spinner)
        } else {
            Gtk.append(chip, Gtk.image(isExpanded ? "pan-down-symbolic" : "pan-end-symbolic", pixelSize: 10))
        }
        let text = turn.workSummary(isLive: isLive, showsWorking: isWorking, elapsed: nil)
        let label = Gtk.label(text, classes: ["transcript-strip-text"], ellipsize: false)
        if isWorking {
            let counts = turn.workSummary(isLive: isLive, showsWorking: false, elapsed: nil)
            elapsedLabels.append((label, "working", isLive && counts.hasPrefix("working") == false ? " · " + counts : ""))
        }
        Gtk.append(chip, label)
        guard turn.workBlockIDs.isEmpty == false else {
            gtk_widget_set_halign(chip, GTK_ALIGN_START)
            return chip
        }
        let button = gtk_button_new()!
        Gtk.addClasses(button, ["flat", "transcript-strip-button"])
        gtk_widget_set_halign(button, GTK_ALIGN_START)
        gtk_button_set_child(cast(button), chip)
        gtk_widget_set_tooltip_text(button, isExpanded ? "Collapse the work details" : "Expand the work details")
        Signal.connect(button, "clicked") { [weak self] in
            self?.turnFold.toggle(turn.id)
            self?.redraw()
        }
        return button
    }

    // MARK: - Blocks

    private func blockWidget(
        _ block: ToasttyTranscriptBlock,
        open: Set<String>,
        isWorkingLine: Bool,
        answer: ToasttyInteractionAnswerState?
    ) -> WidgetPtr {
        switch block.content {
        case .row(let row):
            return rowWidget(row, open: open, isWorkingLine: isWorkingLine, answer: answer)
        case .messageChunk(let chunk):
            return assistantChunk(chunk)
        case .toolBatch(let rows):
            return toolCalls(calls(block: block, rows: rows), open: open)
        }
    }

    private func rowWidget(
        _ row: ToasttyTranscriptRow,
        open: Set<String>,
        isWorkingLine: Bool,
        answer: ToasttyInteractionAnswerState?
    ) -> WidgetPtr {
        switch row.content {
        case .userMessage(let text, let origin, let deliveryMode, let quote, let attachments):
            return userBubble(
                text: text, caption: ToasttyUserMessageCaption.text(origin: origin, deliveryMode: deliveryMode),
                quote: quote, attachments: attachments, queued: nil
            )
        case .hostMessage(let presentation):
            return hostMessage(presentation, row: row, open: open, isWorkingLine: isWorkingLine)
        case .assistantMessage(let text, let phase):
            let blocks = ToasttyMarkdownParser.parse(text)
            return assistantBody(blocks: blocks, text: text, row: row, isCommentary: phase == .commentary, showsActions: true)
        case .toolStarted(let callID, let name, let detail):
            return toolLine(name: name, detail: detail, outcome: nil, id: callID, isOpen: open.contains("tool-\(callID)"))
        case .toolFinished(let callID, let name, let outcome, let detail):
            return toolLine(name: name, detail: detail, outcome: outcome, id: callID, isOpen: open.contains("tool-\(callID)"))
        case .interaction(let presentation):
            return InteractionCard.make(
                presentation: presentation, answer: answer,
                readOnlyMessage: readOnlyInteractionMessage,
                edit: { [weak self] edit in self?.actions.editAnswer(presentation.interaction.id, edit) },
                submit: { [weak self] in self?.actions.submitAnswer(presentation.interaction.id) },
                showTerminal: { [weak self] in self?.actions.showTerminal() }
            )
        case .interactionResolved(_, let resolution):
            return Gtk.label(ToasttyTranscriptLabels.resolution(resolution), classes: ["transcript-muted"], xalign: 0.5)
        case .subagentSummary(let name, let phase, let detail):
            let isOpen = open.contains("subagent")
            let line = disclosureLine("\(name) · \(ToasttyTranscriptLabels.subagentPhase(phase))", isExpanded: isOpen)
            Signal.connect(line, "clicked") { [weak self] in
                guard let self else { return }
                if self.openSubagents.remove(row.id) == nil { self.openSubagents.insert(row.id) }
                self.redraw()
            }
            guard isOpen, let detail, detail.isEmpty == false else { return line }
            let column = Gtk.vbox(spacing: 4)
            Gtk.append(column, line)
            Gtk.append(column, selectable(detail, classes: ["transcript-muted"]))
            return column
        case .sessionBindingChanged(let reason):
            return Gtk.label(ToasttyTranscriptLabels.binding(reason), classes: ["transcript-muted"], xalign: 0.5)
        }
    }

    private func selectable(_ text: String, classes: [String]) -> WidgetPtr {
        let label = Gtk.label(text, classes: classes, ellipsize: false)
        gtk_label_set_wrap(cast(label), 1)
        gtk_label_set_wrap_mode(cast(label), PANGO_WRAP_WORD_CHAR)
        gtk_label_set_selectable(cast(label), 1)
        return label
    }

    /// The widest a reply's quote line asks to be, in characters. A short
    /// reply's bubble stays narrow; the line cuts the rest with "…".
    static let quoteMaxWidthChars: Int32 = 48

    /// The user's message, at the right (macOS bubble): a quote line when it
    /// replies, the text, its files and a caption.
    private func userBubble(
        text: String,
        caption: String?,
        quote: ToasttyMessageQuote?,
        attachments: [URL],
        queued: (item: ToasttySendPresentationItem, queued: ToasttyQueuedSendPresentation)?
    ) -> WidgetPtr {
        let column = Gtk.vbox(spacing: 4, classes: ["transcript-user"])
        gtk_widget_set_halign(column, GTK_ALIGN_END)
        let bubble = Gtk.vbox(spacing: 6, classes: ["transcript-bubble"])
        if let quote {
            // One line, cut with "…": the excerpt is the whole quoted
            // message on one line, and a label that cannot cut it would
            // make the chat as wide as the message.
            let quoteText = Gtk.label("↩ \(quote.timeText.map { "\($0) · " } ?? "")\(quote.excerpt)", classes: ["transcript-quote-text"])
            gtk_label_set_single_line_mode(cast(quoteText), 1)
            gtk_label_set_max_width_chars(cast(quoteText), Self.quoteMaxWidthChars)
            let quoteLine = gtk_button_new()!
            Gtk.addClasses(quoteLine, ["flat", "transcript-quote"])
            gtk_button_set_child(cast(quoteLine), quoteText)
            gtk_widget_set_tooltip_text(quoteLine, quote.text)
            if let rowID = quote.sourceRowID {
                Signal.connect(quoteLine, "clicked") { [weak self] in self?.reveal(rowID: rowID) }
            }
            Gtk.append(bubble, quoteLine)
        }
        if text.isEmpty == false {
            Gtk.append(bubble, selectable(text, classes: ["transcript-user-text"]))
        }
        if attachments.isEmpty == false {
            let files = gtk_flow_box_new()!
            gtk_flow_box_set_selection_mode(cast(files), GTK_SELECTION_NONE)
            for url in attachments {
                gtk_flow_box_append(cast(files), AttachmentChipWidget.make(path: url.path, name: url.lastPathComponent, onRemove: nil))
            }
            Gtk.append(bubble, files)
        }
        Gtk.append(column, bubble)
        let footer = Gtk.hbox(spacing: 8)
        gtk_widget_set_halign(footer, GTK_ALIGN_END)
        if let caption {
            Gtk.append(footer, Gtk.label(caption, classes: ["transcript-caption"], ellipsize: false))
        }
        let copy = Gtk.iconButton("edit-copy-symbolic", tooltip: "Copy", classes: ["flat", "transcript-hover-action"])
        Signal.connect(copy, "clicked") { [weak self] in self?.actions.copy(text) }
        Gtk.append(footer, copy)
        Gtk.append(column, footer)
        return column
    }

    /// A message the host typed (a digest, a message from `coordinator
    /// send`): one muted line that opens to the full text, or a sender card.
    private func hostMessage(
        _ presentation: ToasttyHostMessagePresentation,
        row: ToasttyTranscriptRow,
        open: Set<String>,
        isWorkingLine: Bool
    ) -> WidgetPtr {
        switch presentation.style {
        case .disclosure:
            let isOpen = open.contains("host")
            let text = isWorkingLine ? (presentation.title ?? presentation.summary) : presentation.summary
            let line = disclosureLine(text, isExpanded: isOpen, spinner: isWorkingLine)
            if isWorkingLine {
                for child in Gtk.children(gtk_button_get_child(cast(line))!) where isInstance(child, of: gtk_label_get_type()) {
                    elapsedLabels.append((child, text, ""))
                }
            }
            Signal.connect(line, "clicked") { [weak self] in
                guard let self else { return }
                if presentation.foldsTurn {
                    self.turnFold.toggle(row.id)
                } else if self.openHostMessages.remove(row.id) == nil {
                    self.openHostMessages.insert(row.id)
                }
                self.redraw()
            }
            guard isOpen else { return line }
            let column = Gtk.vbox(spacing: 6)
            Gtk.append(column, line)
            Gtk.append(column, selectable(presentation.text, classes: ["transcript-host-text"]))
            return column
        case .sender(let name, let timeText):
            let card = Gtk.vbox(spacing: 6, classes: ["transcript-sender"])
            let header = Gtk.hbox(spacing: 6)
            // A task's title can be long: cut it rather than widen the chat.
            Gtk.append(header, Gtk.label(name, classes: ["transcript-sender-name"]))
            Gtk.append(header, Gtk.label(timeText, classes: ["transcript-caption"], ellipsize: false))
            Gtk.append(card, header)
            let isLong = presentation.text.count > 600
            let isOpen = open.contains("sender")
            let shown = isLong && isOpen == false ? String(presentation.text.prefix(600)) + "…" : presentation.text
            Gtk.append(card, selectable(shown, classes: ["transcript-host-text"]))
            if isLong {
                let toggle = Gtk.button(isOpen ? "Show less" : "Show full message", classes: ["flat", "transcript-link-button"])
                gtk_widget_set_halign(toggle, GTK_ALIGN_START)
                Signal.connect(toggle, "clicked") { [weak self] in
                    guard let self else { return }
                    if self.openSenderCards.remove(row.id) == nil { self.openSenderCards.insert(row.id) }
                    self.redraw()
                }
                Gtk.append(card, toggle)
            }
            return card
        }
    }

    private func assistantChunk(_ chunk: ToasttyTranscriptMessageChunk) -> WidgetPtr {
        guard case .assistantMessage(let text, let phase) = chunk.row.content else {
            return MarkdownWidgets.make(blocks: chunk.blocks, linkPresenter: actions.linkPresenter) { [weak self] url in
                self?.actions.openLink(url)
            }
        }
        return assistantBody(blocks: chunk.blocks, text: text, row: chunk.row, isCommentary: phase == .commentary, showsActions: chunk.isLast)
    }

    /// The agent's text, as markdown, with Copy and Reply under its end.
    private func assistantBody(
        blocks: [ToasttyMarkdownBlock],
        text: String,
        row: ToasttyTranscriptRow,
        isCommentary: Bool,
        showsActions: Bool
    ) -> WidgetPtr {
        let column = Gtk.vbox(spacing: 4, classes: isCommentary ? ["transcript-assistant", "commentary"] : ["transcript-assistant"])
        Gtk.append(column, MarkdownWidgets.make(blocks: blocks, linkPresenter: actions.linkPresenter) { [weak self] url in
            self?.actions.openLink(url)
        })
        guard showsActions, isCommentary == false else { return column }
        let footer = Gtk.hbox(spacing: 4)
        let copy = Gtk.iconButton("edit-copy-symbolic", tooltip: "Copy", classes: ["flat", "transcript-hover-action"])
        Signal.connect(copy, "clicked") { [weak self] in self?.actions.copy(text) }
        Gtk.append(footer, copy)
        let reply = Gtk.iconButton("mail-reply-sender-symbolic", tooltip: "Reply", classes: ["flat", "transcript-hover-action"])
        Gtk.setName(reply, "coordinator.chat.reply")
        Signal.connect(reply, "clicked") { [weak self] in
            self?.actions.reply(ToasttyMessageReplyRequest(rowID: row.id, text: text, timestamp: row.timestamp))
        }
        Gtk.append(footer, reply)
        Gtk.append(column, footer)
        return column
    }

    /// A batch of tool calls as the coordinator folds them: one line each;
    /// a click shows a call's details.
    private func toolCalls(_ calls: [ToasttyToolCall], open: Set<String>) -> WidgetPtr {
        let column = Gtk.vbox(spacing: 2, classes: ["transcript-tools"])
        for call in calls {
            Gtk.append(column, toolLine(name: call.name, detail: call.details.first, outcome: call.outcome, id: call.id,
                                        isOpen: open.contains("tool-\(call.id)"), details: call.details))
        }
        return column
    }

    private func toolLine(
        name: String,
        detail: String?,
        outcome: ConversationToolOutcome?,
        id: String,
        isOpen: Bool,
        details: [String]? = nil
    ) -> WidgetPtr {
        let line = Gtk.hbox(spacing: 6, classes: ["transcript-tool"])
        let mark: String = switch outcome {
        case .succeeded?: "✓"
        case .failed?: "✕"
        case .unknown?: "•"
        case nil: "…"
        }
        Gtk.append(line, Gtk.label(mark, classes: ["transcript-tool-mark", outcome == .failed ? "failed" : "ok"], ellipsize: false))
        Gtk.append(line, Gtk.label(name, classes: ["transcript-tool-name"], ellipsize: false))
        if let detail, detail.isEmpty == false {
            let summary = Gtk.label(detail.split(separator: "\n").first.map(String.init) ?? detail, classes: ["transcript-tool-detail"])
            gtk_widget_set_hexpand(summary, 1)
            Gtk.append(line, summary)
        }
        let all = details ?? [detail].compactMap { $0 }
        guard all.isEmpty == false else { return line }
        let button = gtk_button_new()!
        Gtk.addClasses(button, ["flat", "transcript-tool-button"])
        gtk_button_set_child(cast(button), line)
        Signal.connect(button, "clicked") { [weak self] in
            guard let self else { return }
            if self.openToolCalls.remove(id) == nil { self.openToolCalls.insert(id) }
            self.redraw()
        }
        guard isOpen else { return button }
        let column = Gtk.vbox(spacing: 4)
        Gtk.append(column, button)
        for text in all {
            Gtk.append(column, selectable(text, classes: ["transcript-tool-details"]))
        }
        return column
    }

    // MARK: - Send tail

    /// A message that was typed and has no row yet, waits in the queue, or
    /// failed (macOS `ToasttySendTailItemView`).
    private func sendItemWidget(_ item: ToasttySendPresentationItem, isWorkingLine: Bool) -> WidgetPtr {
        if let host = item.hostMessage {
            let line = disclosureLine(host.title ?? host.summary, isExpanded: false, spinner: isWorkingLine)
            gtk_widget_set_sensitive(line, 0)
            return line
        }
        switch item.content {
        case .optimistic(let response):
            let column = userBubble(text: item.text, caption: item.sentCaption ?? Self.caption(response), quote: item.quote, attachments: item.attachments, queued: nil)
            Gtk.addClasses(column, ["pending"])
            return column
        case .receipt(let receipt):
            let column = userBubble(text: item.text, caption: nil, quote: item.quote, attachments: item.attachments, queued: nil)
            let note = Gtk.label(Self.receiptText(receipt), classes: ["transcript-receipt"], ellipsize: false)
            gtk_label_set_wrap(cast(note), 1)
            gtk_widget_set_halign(note, GTK_ALIGN_END)
            Gtk.append(column, note)
            return column
        case .queued(let queued):
            let column = Gtk.vbox(spacing: 4, classes: ["transcript-queued"])
            gtk_widget_set_halign(column, GTK_ALIGN_END)
            let bubble = userBubble(text: item.text, caption: nil, quote: item.quote, attachments: item.attachments, queued: (item, queued))
            Gtk.addClasses(bubble, ["queued"])
            Gtk.append(column, bubble)
            let footer = Gtk.hbox(spacing: 6)
            gtk_widget_set_halign(footer, GTK_ALIGN_END)
            var caption = ToasttyTranscriptLabels.queuedCaption(queued)
            if queued.attachmentCount > 0 { caption += " · \(queued.attachmentCount) \(queued.attachmentCount == 1 ? "file" : "files")" }
            Gtk.append(footer, Gtk.label(caption, classes: ["transcript-caption"], ellipsize: false))
            let id = item.clientRequestID
            if queued.canEdit {
                let edit = Gtk.button("Edit", classes: ["flat", "transcript-link-button"])
                Gtk.setName(edit, "coordinator.chat.queued.edit")
                Signal.connect(edit, "clicked") { [weak self] in self?.actions.queuedMessageAction(.edit(clientRequestID: id, text: item.text)) }
                Gtk.append(footer, edit)
            }
            if queued.canSteer {
                let steer = Gtk.button("Steer now", classes: ["flat", "transcript-link-button"])
                Gtk.setName(steer, "coordinator.chat.queued.steer")
                Signal.connect(steer, "clicked") { [weak self] in self?.actions.queuedMessageAction(.steer(clientRequestID: id, text: item.text)) }
                Gtk.append(footer, steer)
            }
            if let resume = queued.resumeTitle {
                let button = Gtk.button(resume, classes: ["flat", "transcript-link-button"])
                Gtk.setName(button, "coordinator.chat.queued.resume")
                Signal.connect(button, "clicked") { [weak self] in self?.actions.queuedMessageAction(.resume) }
                Gtk.append(footer, button)
            }
            if queued.canChange {
                let remove = Gtk.button("Remove", classes: ["flat", "transcript-link-button"])
                Gtk.setName(remove, "coordinator.chat.queued.remove")
                Signal.connect(remove, "clicked") { [weak self] in self?.actions.queuedMessageAction(.remove(clientRequestID: id)) }
                Gtk.append(footer, remove)
            }
            Gtk.append(column, footer)
            for warning in [queued.warning, queued.actionFailure].compactMap({ $0 }) {
                let label = Gtk.label(warning, classes: ["transcript-receipt"], ellipsize: false)
                gtk_label_set_wrap(cast(label), 1)
                Gtk.append(column, label)
            }
            return column
        }
    }

    static func caption(_ response: ToasttyPendingSendResponse) -> String? {
        switch response {
        case .awaitingResponse: "Sending…"
        case .accepted, .duplicate: nil
        case .queued(let position): "Queued \(position)"
        }
    }

    static func receiptText(_ receipt: ToasttySendReceiptPresentation) -> String {
        switch receipt.kind {
        case .rejected: "The coordinator did not take this message."
        case .uncertain: "Toastty cannot tell whether the coordinator got this message."
        case .operationFailed: "Toastty could not send this message."
        case .deliveryUnconfirmed: "Toastty typed this message, but the conversation did not show it."
        }
    }

    // MARK: - Banner, scrolling, time

    private func updateBanner(_ phase: ToasttyConversationPresentationPhase, truncated: Bool) {
        let text: String? = switch phase {
        case .loading: "Loading transcript…"
        case .live: truncated ? "Earlier activity is no longer retained." : nil
        case .resyncing: "Catching up…"
        case .stale: "Connection paused. The transcript may be out of date."
        case .failure(let message): message
        }
        Gtk.setLabel(banner, text ?? "")
        Gtk.setVisible(banner, text != nil)
    }

    private var adjustment: OpaquePointer? {
        gtk_scrolled_window_get_vadjustment(cast(scroller)).map { OpaquePointer($0) }
    }

    private var distanceFromBottom: Double {
        guard let adjustment else { return 0 }
        return gtk_adjustment_get_upper(cast(adjustment)) - gtk_adjustment_get_page_size(cast(adjustment)) - gtk_adjustment_get_value(cast(adjustment))
    }

    private var isAtLiveEdge: Bool { distanceFromBottom < 24 }

    private func scrollChanged() {
        if pendingScroll == nil {
            followsLiveEdge = isAtLiveEdge
        }
        updateJumpButton()
    }

    /// The content's height changed: apply a pending scroll, or keep
    /// following the live edge.
    private func layoutChanged() {
        guard let adjustment else { return }
        let upper = gtk_adjustment_get_upper(cast(adjustment))
        let page = gtk_adjustment_get_page_size(cast(adjustment))
        switch pendingScroll {
        case .liveEdge?:
            gtk_adjustment_set_value(cast(adjustment), upper - page)
        case .widget(let widget)?:
            var source = graphene_point_t(x: 0, y: 0)
            var target = graphene_point_t(x: 0, y: 0)
            if gtk_widget_compute_point(widget, list, &source, &target).bool {
                gtk_adjustment_set_value(cast(adjustment), max(0, Double(target.y) - 24))
            }
            followsLiveEdge = false
        case .keepDistanceFromBottom(let distance)?:
            gtk_adjustment_set_value(cast(adjustment), max(0, upper - page - distance))
        case nil:
            if followsLiveEdge { gtk_adjustment_set_value(cast(adjustment), upper - page) }
        }
        if pendingScroll != nil {
            MainLoop.idle { [weak self] in self?.pendingScroll = nil }
        }
        updateJumpButton()
    }

    func jumpToLiveEdge() {
        followsLiveEdge = true
        pendingScroll = .liveEdge
        layoutChanged()
    }

    private func reveal(rowID: ToasttyTranscriptRowID) {
        guard let entry = entries.first(where: { entry in
            if case .block(let block, _, _, _, _, _) = entry.item { return block.id.rowID == rowID }
            return false
        }) else { return }
        pendingScroll = .widget(entry.widget.widgetPointer)
        layoutChanged()
    }

    private func loadOlder() {
        pendingScroll = .keepDistanceFromBottom(distanceFromBottom)
        actions.loadOlder()
    }

    private func updateJumpButton() {
        let shows = isAtLiveEdge == false && entries.isEmpty == false
        if let count = newMessages?.count, count > 0 {
            gtk_button_set_label(cast(jumpButton), count == 1 ? "1 new" : "\(count) new")
        } else {
            gtk_button_set_label(cast(jumpButton), "Jump to latest")
        }
        Gtk.setVisible(jumpButton, shows)
    }

    /// The running turn's time, such as "working · 16s", every second.
    private func updateElapsedTimer() {
        let needsTimer = workingIndicator?.turnElapsed != nil && elapsedLabels.isEmpty == false
        refreshElapsed()
        if needsTimer, elapsedTimer == 0 {
            elapsedTimer = MainLoop.timeout(milliseconds: 1000) { [weak self] in
                guard let self else { return false }
                self.refreshElapsed()
                if self.workingIndicator?.turnElapsed == nil || self.elapsedLabels.isEmpty {
                    self.elapsedTimer = 0
                    return false
                }
                return true
            }
        }
    }

    private func refreshElapsed() {
        let elapsed = workingIndicator?.elapsedLabel(atMonotonicTime: ProcessInfo.processInfo.systemUptime)
        for entry in elapsedLabels {
            Gtk.setLabel(entry.label, [entry.prefix, elapsed].compactMap { $0 }.joined(separator: " · ") + entry.suffix)
        }
    }

    var automationItemKeys: [String] { entries.map(\.item.key) }
}
#endif
