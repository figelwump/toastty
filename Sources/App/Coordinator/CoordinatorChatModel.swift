import AppKit
import Combine
import ConversationUI
import CoreState
import Foundation
import RemoteProtocol

/// What the coordinator's chat shows: the conversation of the coordinator's
/// agent, read through `LocalConversationAccess`, and the messages that wait
/// to be typed.
///
/// The model reads. Every write goes through `CoordinatorController`, which
/// is the one sender into the coordinator.
///
/// The model reads the conversation only while the chat shows:
/// `show(panelID:host:)` takes a subscription and the last `hide` ends it.
/// The rows stay, so the chat does not blink when it shows again. The
/// controller holds its own subscription, for sending.
///
/// Two views can show the chat: the cover over the coordinator's terminal
/// and the dock beside the workspace. Only one is on screen at a time, but
/// while the window switches between them both can be, so each says which
/// one it is.
@MainActor
final class CoordinatorChatModel: ObservableObject {
    /// Where a view of the chat is.
    enum Host: Hashable {
        /// Over the coordinator's terminal, in its workspace: the full view.
        case panel
        /// In the dock beside the selected workspace.
        case dock
    }

    /// A message that was typed and is not in the conversation yet.
    private struct PendingSend: Equatable {
        let id: String
        let text: String
        let typedAt: Date
        let steered: Bool
    }

    /// A typed message that the newest page does not show after this time
    /// is not waited for: the conversation moved past it while the chat
    /// was hidden.
    static let pendingSendLifetime: TimeInterval = 120

    /// What the chat says above the composer, in place of sending.
    enum Notice: Equatable {
        /// No agent runs in the coordinator's terminal.
        case agentNotRunning(reason: String?)
        case agentStarting
        /// The agent's process has run for `startGrace` and the agent has
        /// not reported its session. It most likely waits for an answer
        /// that only its terminal can take: a login or a folder-trust
        /// question comes before the agent reports anything.
        case startWaitsInTerminal
        /// The agent asked a question or for a permission. The chat cannot
        /// answer it.
        case awaitingAnswerInTerminal
        /// Text typed in the terminal may be in the agent's prompt. Messages
        /// and Toastty's digests wait for it. Keys that answered a question
        /// of the agent's start, before the agent reported its session, look
        /// the same to Toastty.
        case terminalDraft
        /// A message was typed but the conversation never showed it.
        case deliveryNotConfirmed
        /// Toastty quit while it typed a message. The message waits,
        /// paused, until the user sends it again or removes it.
        case typingInterrupted
        case failure(String)
    }

    @Published private(set) var presentation = ToasttyConversationPresentationState(
        rows: [], phase: .live, revision: .initial, historyTruncated: false
    )
    /// The conversation's summary, or `nil` while Toastty reads none.
    @Published private(set) var summary: RemoteConversationSummary?
    /// The composer's text. It is kept here so that it survives a switch to
    /// the terminal and back.
    @Published var draft = ""
    /// The coordinator's message that the composer's message answers, set
    /// by Reply on that message. It is kept with the text.
    @Published private(set) var replyTarget: CoordinatorReplyTarget?
    /// The files attached to the composer's message, kept here with the
    /// text. Their changes are the model's changes.
    let attachmentDraft: DraftAttachments
    /// Takes files dropped on the chat or on the composer's field.
    let attachmentDropTarget: AttachmentDropTarget
    /// A message with files is being sent: Toastty copies its files into
    /// the coordinator's folder. The composer waits until it is done.
    @Published private(set) var isSendingFiles = false
    /// The turn in which the user chose Queue on the chip. Steer is the
    /// default: the choice ends with a send, and with its turn.
    @Published private var queueChosenInTurn: RemoteInputEpoch?
    @Published var jumpToLiveEdgeRequest: UInt64 = 0
    /// Counts up each time the composer should take the keyboard.
    @Published private(set) var composerFocusRequest = 0
    /// A notice that an action left, until the next action or a dismiss.
    @Published private var transientNotice: Notice?
    /// Multiplies the size of all text in the chat. Saved, so that it
    /// survives a relaunch. See `changeTextScale`.
    @Published private(set) var textScale: Double

    /// The composer's text view of the view that showed last, so that
    /// keyboard focus meant for the terminal under the chat can go to it.
    var composerTextView: NSTextView? {
        get {
            if let activeHost, let view = composerTextViews[activeHost]?.view { return view }
            return composerTextViews.values.lazy.compactMap(\.view).first
        }
        set { setComposerTextView(newValue, host: .panel) }
    }

    /// Each view's composer text view, held weakly.
    private var composerTextViews: [Host: WeakTextView] = [:]
    /// The views on screen now, with the panel each reads.
    private var viewers: [Host: UUID] = [:]
    /// The view that showed last. Its composer takes the keyboard.
    private(set) var activeHost: Host?
    /// The view whose composer takes the keyboard when it shows.
    private var focusOnShow: Host?

    static let pageSize = 200

    private weak var controller: CoordinatorController?
    private let access: any LocalConversationAccess
    private let now: () -> Date
    /// Where the text size is saved, or `nil` for a run that saves no
    /// preferences, such as an automation run.
    private let defaults: UserDefaults?
    private var subscription: (any LocalConversationSubscription)?
    private var observer: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private var events: [ConversationEvent] = []
    private var loaded: LoadedPage?
    private var loadedTranscriptReadID: UUID?
    private var pendingSends: [PendingSend] = []
    private var lastJumpRequest: UInt64 = 0
    /// How long the agent's process may run without a report of its session
    /// before the chat says that it may wait in the terminal. Claude Code
    /// reports within a few seconds of its start.
    static let startGrace: TimeInterval = 8
    /// Shows the notice again once `startGrace` is over for this session.
    private var startGraceWake: (sessionID: String, task: Task<Void, Never>)?

    /// The sequence space the loaded events belong to.
    fileprivate struct LoadedPage: Equatable {
        var conversationID: RemoteConversationID
        var projectionRunID: RemoteProjectionRunID
        var projectionGeneration: UInt64
        var firstAvailableSequence: UInt64
    }

    init(
        controller: CoordinatorController,
        access: any LocalConversationAccess,
        defaults: UserDefaults? = nil,
        now: @escaping () -> Date = Date.init,
        attachmentStagingURL: URL = FileManager.default.temporaryDirectory
            .appending(path: "toastty-coordinator-composer/\(UUID().uuidString)", directoryHint: .isDirectory)
    ) {
        self.controller = controller
        self.access = access
        self.defaults = defaults
        self.now = now
        textScale = (defaults?.object(forKey: Self.textScaleDefaultsKey) as? Double)
            .map(Self.normalizedTextScale) ?? Self.defaultTextScale
        let attachmentDraft = DraftAttachments(stagingDirectoryURL: attachmentStagingURL)
        self.attachmentDraft = attachmentDraft
        attachmentDropTarget = AttachmentDropTarget(attachments: attachmentDraft)
        attachmentDraft.isEditable = { [weak self] in self?.isSendingFiles == false }
        attachmentDraft.onError = { [weak self] message in
            self?.transientNotice = .failure(message)
            self?.publishMetadata()
        }
        attachmentDraft.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // The draft's own copies go with the app. Files that a waiting
        // message holds are the controller's.
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak attachmentDraft] _ in
                MainActor.assumeIsolated { attachmentDraft?.removeStagingDirectoryNow() }
            }
            .store(in: &cancellables)
        // What waits, and why, changes the tail of the chat and the notice.
        // `sink` runs before the new value is stored.
        controller.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.publishMetadata() }
            }
            .store(in: &cancellables)
        controller.typedEntries
            .sink { [weak self] entry in self?.noteTyped(entry) }
            .store(in: &cancellables)
    }

    deinit {
        observer?.cancel()
        startGraceWake?.task.cancel()
    }

    // MARK: - Lifetime

    /// The panel whose conversation the model reads now.
    var shownPanelID: UUID? { subscription?.panelID }

    /// Starts to read the conversation in `panelID`, the coordinator's
    /// terminal, for the view at `host`. Call it while that view is on
    /// screen.
    func show(panelID: UUID, host: Host = .panel) {
        viewers[host] = panelID
        activeHost = host
        subscribe(to: panelID)
        if let focusOnShow {
            self.focusOnShow = nil
            if focusOnShow == host { requestComposerFocus() }
        }
    }

    /// Stops reading the conversation in `panelID` for the view at `host`.
    /// After a restart the coordinator has a new terminal, and the view of
    /// the old one goes away after the view of the new one showed: it must
    /// not end the new view's reading. While another view shows, the model
    /// reads on for that view.
    func hide(panelID: UUID, host: Host = .panel) {
        guard viewers[host] == panelID else { return }
        viewers[host] = nil
        if activeHost == host {
            activeHost = viewers.keys.first
        }
        if let activeHost, let shownPanelID = viewers[activeHost] {
            subscribe(to: shownPanelID)
        } else {
            endSubscription()
        }
    }

    /// Stops reading, for every view. The rows stay as they are, and so do
    /// the messages that wait for their echo: the next `show` reads on from
    /// here.
    func hide() {
        viewers.removeAll()
        activeHost = nil
        endSubscription()
    }

    /// The composer's text view of the view at `host`.
    func setComposerTextView(_ textView: NSTextView?, host: Host) {
        composerTextViews[host] = textView.map(WeakTextView.init)
    }

    /// Whether the composer of the view at `host` has the keyboard in its
    /// window.
    func composerHasKeyboard(host: Host) -> Bool {
        guard let view = composerTextViews[host]?.view, let window = view.window else { return false }
        return window.firstResponder === view
    }

    private func subscribe(to panelID: UUID) {
        guard subscription?.panelID != panelID else { return }
        endSubscription()
        let subscription = access.subscribeToConversation(inPanel: panelID)
        self.subscription = subscription
        let changes = subscription.changes
        observer = Task { @MainActor [weak self] in
            for await _ in changes {
                self?.refresh()
            }
        }
        refresh()
    }

    private func endSubscription() {
        observer?.cancel()
        observer = nil
        subscription?.cancel()
        subscription = nil
    }

    // MARK: - Reading

    private func refresh() {
        guard let subscription else { return }
        let snapshot = subscription.snapshot(at: now())
        // A new event leaves the summary as it was; publish it only when it
        // changed, so the chat does not draw again for an equal value.
        if summary != snapshot?.summary {
            summary = snapshot?.summary
        }
        // Replay batches are historical output, not new live messages.
        // Wait for the reader's boundary instead of guessing from a pause;
        // a long transcript can take seconds and have gaps between batches.
        guard subscription.isReadingInitialTranscript == false else {
            if presentation.rows.isEmpty, presentation.phase != .loading {
                presentation = ToasttyConversationPresentationState(
                    rows: [], sendItems: sendItems(), phase: .loading, revision: .initial, historyTruncated: false
                )
            }
            return
        }
        guard let summary = snapshot?.summary else {
            // No agent conversation in the terminal: none started yet, or
            // Toastty cannot read this agent's.
            if events.isEmpty == false || loaded != nil || presentation.rows.isEmpty == false
                || presentation.phase != .live {
                events = []
                loaded = nil
                pendingSends.removeAll()
                publishRows(revision: .rebuilt)
            } else {
                publishMetadata()
            }
            return
        }
        if let loaded, loaded.conversationID == summary.conversationID,
           loadedTranscriptReadID == subscription.transcriptReadID {
            appendNewEvents(from: subscription, loaded: loaded)
        } else {
            loadNewestPage(from: subscription)
        }
    }

    private func loadNewestPage(from subscription: any LocalConversationSubscription) {
        loadedTranscriptReadID = subscription.transcriptReadID
        let wasEmpty = presentation.rows.isEmpty
        guard case .page(let page) = subscription.events(before: nil, limit: Self.pageSize) else {
            events = []
            loaded = nil
            publishRows(revision: .rebuilt)
            return
        }
        events = page.events
        loaded = LoadedPage(page)
        reconcilePendingSends(with: page.events)
        let oldest = now().addingTimeInterval(-Self.pendingSendLifetime)
        pendingSends.removeAll { $0.typedAt < oldest }
        publishRows(revision: wasEmpty ? .initial : .rebuilt)
    }

    private func appendNewEvents(from subscription: any LocalConversationSubscription, loaded: LoadedPage) {
        var appended: [ConversationEvent] = []
        var afterSequence = events.last?.sequence ?? 0
        // Bounded, so a conversation that grows faster than it is read
        // cannot hold the main actor. The next change continues.
        for _ in 0 ..< 20 {
            let cursor = ConversationEventCursor(
                projectionRunID: loaded.projectionRunID,
                projectionGeneration: loaded.projectionGeneration,
                afterSequence: afterSequence
            )
            guard case .page(let page) = subscription.events(after: cursor, limit: Self.pageSize) else {
                // The event sequence restarted: read the conversation anew.
                pendingSends.removeAll()
                loadNewestPage(from: subscription)
                return
            }
            self.loaded?.firstAvailableSequence = page.firstAvailableSequence ?? loaded.firstAvailableSequence
            guard let last = page.events.last else { break }
            appended.append(contentsOf: page.events)
            afterSequence = last.sequence
            if last.sequence >= page.latestSequence { break }
        }
        guard appended.isEmpty == false else {
            publishMetadata()
            return
        }
        events.append(contentsOf: appended)
        reconcilePendingSends(with: appended)
        publishRows(revision: .appended)
    }

    /// Reads the page before the oldest loaded event.
    func loadOlder() {
        guard let subscription, subscription.isReadingInitialTranscript == false,
              let loaded, let first = events.first else { return }
        let cursor = ConversationEventBackwardCursor(
            projectionRunID: loaded.projectionRunID,
            projectionGeneration: loaded.projectionGeneration,
            beforeSequence: first.sequence
        )
        guard case .page(let page) = subscription.events(before: cursor, limit: Self.pageSize) else {
            refresh()
            return
        }
        self.loaded?.firstAvailableSequence = page.firstAvailableSequence ?? loaded.firstAvailableSequence
        guard page.events.isEmpty == false else {
            publishMetadata()
            return
        }
        let anchor = presentation.rows.first?.id
        events.insert(contentsOf: page.events, at: 0)
        publishRows(revision: .prepended, prependAnchorID: anchor)
    }

    private var hasOlder: Bool {
        guard let loaded, let first = events.first else { return false }
        return first.sequence > loaded.firstAvailableSequence
    }

    /// Toastty keeps a bounded number of events. Say so once the reader
    /// reached the oldest one it has.
    private var historyTruncated: Bool {
        guard let loaded else { return false }
        return hasOlder == false && loaded.firstAvailableSequence > 1
    }

    // MARK: - Publishing

    private func publishRows(revision: ToasttyTranscriptRevision, prependAnchorID: ToasttyTranscriptRowID? = nil) {
        let rows: [ToasttyTranscriptRow]
        if let loaded {
            rows = CoordinatorChatTranscript.rows(
                from: events,
                projectionRunID: loaded.projectionRunID,
                projectionGeneration: loaded.projectionGeneration,
                isSentFromThisMac: { [weak controller] id in controller?.didType(messageID: id) ?? false },
                isQuietDigest: { [weak controller] text in controller?.isQuietDigest(text) ?? false },
                timeText: { $0.formatted(date: .omitted, time: .shortened) }
            )
        } else {
            rows = []
        }
        presentation = ToasttyConversationPresentationState(
            rows: rows,
            sendItems: sendItems(),
            phase: .live,
            revision: revision,
            historyTruncated: historyTruncated,
            hasOlder: hasOlder,
            prependAnchorID: prependAnchorID
        )
    }

    /// Publishes what changed around the rows: the waiting messages and the
    /// notice.
    private func publishMetadata() {
        let next = presentation.updatingMetadata(
            sendItems: sendItems(),
            phase: presentation.phase,
            revision: .metadataOnly,
            historyTruncated: historyTruncated,
            hasOlder: hasOlder,
            isLoadingOlder: false,
            prependAnchorID: nil
        )
        if next != presentation { presentation = next }
    }

    /// The tail of the chat: messages typed but not shown yet, then the
    /// messages that wait, in the order they will be typed.
    private func sendItems() -> [ToasttySendPresentationItem] {
        // A waiting message shows as its row will: a quick entry message
        // without Toastty's first line.
        var items = pendingSends.map { pending in
            let parts = CoordinatorMessageHeader.displayParts(of: pending.text)
            return ToasttySendPresentationItem(
                clientRequestID: pending.id,
                text: parts.text,
                content: .optimistic(response: .accepted),
                // The caption its row will show, so the bubble keeps its
                // size when the row replaces it.
                sentCaption: pending.steered
                    ? ToasttyUserMessageCaption.text(origin: .local, deliveryMode: .steer)
                    : nil,
                quote: Self.quote(of: pending.text),
                attachments: parts.attachmentPaths.map { URL(fileURLWithPath: $0) }
            )
        }
        guard let controller else { return items }
        // Only a message the user wrote in the chat can go into the running
        // turn.
        let turnTakesSteer = controller.canSteer
        for (index, entry) in controller.pausedEntries.enumerated() {
            items.append(ToasttySendPresentationItem(
                clientRequestID: entry.id,
                text: CoordinatorMessageHeader.displayText(of: entry.text),
                content: .queued(ToasttyQueuedSendPresentation(
                    position: index + 1,
                    attachmentCount: Self.attachmentCount(of: entry.text),
                    isPaused: true,
                    canSteer: turnTakesSteer && entry.canBeSteered
                )),
                quote: Self.quote(of: entry.text)
            ))
        }
        // A phone's queue is in the conversation. Its messages go first:
        // Toastty types them as the prompt opens, before the controller
        // looks. The chat cannot change them.
        var position = 0
        let control = summary?.inputControl
        for message in control?.queuedMessages ?? [] {
            position += 1
            items.append(ToasttySendPresentationItem(
                clientRequestID: message.clientRequestID,
                text: message.text,
                content: .queued(ToasttyQueuedSendPresentation(
                    position: position,
                    attachmentCount: message.attachmentCount,
                    isPaused: control?.isQueuePaused ?? false,
                    canSteer: false,
                    canChange: false
                ))
            ))
        }
        if control?.isQueuePaused == true { position = 0 }
        for entry in controller.queuedEntries {
            position += 1
            items.append(ToasttySendPresentationItem(
                clientRequestID: entry.id,
                text: CoordinatorMessageHeader.displayText(of: entry.text),
                content: .queued(ToasttyQueuedSendPresentation(
                    position: position,
                    attachmentCount: Self.attachmentCount(of: entry.text),
                    isPaused: false,
                    canSteer: turnTakesSteer && entry.canBeSteered,
                    waitingCaption: Self.waitingCaption(position: position, hold: controller.hold)
                )),
                quote: Self.quote(of: entry.text)
            ))
        }
        return items
    }

    /// The quote that a reply's bubble shows, from the text as Toastty
    /// types it. A waiting message's quote does not open its message.
    static func quote(of text: String) -> ToasttyMessageQuote? {
        guard case .reply(let quote, let time, _, _) = CoordinatorMessageHeader.kind(of: text) else { return nil }
        return ToasttyMessageQuote(text: quote, timeText: time)
    }

    /// The files that a waiting message names, as Toastty wrote them.
    static func attachmentCount(of text: String) -> Int {
        CoordinatorMessageHeader.attachedFiles(in: text)?.paths.count ?? 0
    }

    /// Why a message waits, when that is not the running turn.
    static func waitingCaption(position: Int, hold: CoordinatorSendHold?) -> String? {
        switch hold {
        case .busy, .awaitingTurn, .settling, nil:
            nil
        case .noSession:
            "Queued \(position) · waits for the agent"
        case .agentStarting:
            "Queued \(position) · waits for the agent to start"
        case .userDraft:
            "Queued \(position) · waits for the text in the terminal"
        case .terminalUnavailable, .promptNotOpen:
            "Queued \(position) · waits for the prompt"
        case .notSaved:
            "Queued \(position) · Toastty could not save it, and tries again"
        }
    }

    /// The chat shows Toasty's introduction in place of an empty
    /// transcript while the conversation is new and has no message: for a
    /// new coordinator, and after Restart. A conversation that a relaunch
    /// resumes never shows it, so it cannot show while that one loads.
    var showsIntroduction: Bool {
        guard controller?.hasNewConversation == true, presentation.sendItems.isEmpty else { return false }
        switch presentation.phase {
        case .live, .loading: break
        case .resyncing, .stale, .failure: return false
        }
        // A new conversation starts with the marker of its binding to the
        // terminal, which is no message.
        return presentation.rows.allSatisfy { row in
            if case .sessionBindingChanged = row.content { return true }
            return false
        }
    }

    /// What the chat says above the composer now. It reads the session's
    /// state, so a view that shows it also observes the session store.
    var notice: Notice? {
        transientNotice ?? standingNotice()
    }

    private func standingNotice() -> Notice? {
        guard let controller, let status = controller.status else { return nil }
        switch status.agentState {
        case .notRunning:
            return .agentNotRunning(reason: status.startFailure)
        case .starting:
            return .agentStarting
        case .running:
            break
        }
        if status.session?.status?.kind == .needsApproval {
            return .awaitingAnswerInTerminal
        }
        // The agent's process runs, but the agent has not reported its
        // session. Toastty then has no conversation of its to read, or only
        // the one Toastty made when it launched the agent, which stays in
        // `starting` until the agent's first report. A login or a
        // folder-trust prompt in the terminal looks like this. An agent
        // that Toastty does not follow reports nothing, so its state says
        // nothing about its start.
        guard let summary else {
            return startNotice(for: status.session)
        }
        if summary.state == .starting, ProviderTranscriptSupport.isManagedProvider(summary.provider) {
            return startNotice(for: status.session)
        }
        switch summary.inputAvailability {
        case .pendingInteraction:
            return .awaitingAnswerInTerminal
        case .localDraft:
            return .terminalDraft
        default:
            return controller.hasInterruptedEntry ? .typingInterrupted : nil
        }
    }

    /// What the chat says while the agent's process runs and the agent has
    /// not reported its session: that it starts, and after `startGrace`
    /// that it may wait in the terminal.
    private func startNotice(for session: SessionRecord?) -> Notice {
        guard let session else { return .agentStarting }
        let remaining = session.startedAt.addingTimeInterval(Self.startGrace).timeIntervalSince(now())
        guard remaining > 0 else { return .startWaitsInTerminal }
        // Nothing changes when the time is over, so the model says that
        // the notice changed.
        if startGraceWake?.sessionID != session.sessionID {
            startGraceWake?.task.cancel()
            startGraceWake = (session.sessionID, Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(remaining))
                } catch {
                    return
                }
                self?.objectWillChange.send()
            })
        }
        return .agentStarting
    }

    // MARK: - Messages that were typed

    private func noteTyped(_ entry: CoordinatorController.TypedEntry) {
        // Without the conversation there is no echo to wait for.
        guard entry.echoesInConversation, subscription != nil else { return }
        guard events.contains(where: { Self.echoedRequestID($0) == entry.id }) == false else { return }
        pendingSends.append(PendingSend(id: entry.id, text: entry.text, typedAt: now(), steered: entry.steered))
        publishMetadata()
    }

    /// Drops each pending message that the conversation now shows, and
    /// reports each one that the conversation gave up on.
    private func reconcilePendingSends(with newEvents: [ConversationEvent]) {
        guard pendingSends.isEmpty == false else { return }
        for event in newEvents {
            if let id = Self.echoedRequestID(event) {
                pendingSends.removeAll { $0.id == id }
            } else if case .sendDeliveryUnconfirmed(let payload) = event.payload,
                      pendingSends.contains(where: { $0.id == payload.clientRequestID }) {
                pendingSends.removeAll { $0.id == payload.clientRequestID }
                transientNotice = .deliveryNotConfirmed
            }
        }
    }

    private static func echoedRequestID(_ event: ConversationEvent) -> String? {
        guard case .userMessage(let payload) = event.payload else { return nil }
        return payload.clientRequestID
    }

    // MARK: - The composer's actions

    /// The composer has text or files, and no file is still being copied.
    var canSend: Bool {
        isSendingFiles == false
            && attachmentDraft.pendingCount == 0
            && (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                || attachmentDraft.attachments.isEmpty == false)
    }

    /// A turn runs that Stop can end.
    var canStop: Bool {
        summary?.inputControl?.canInterrupt == true
    }

    /// While a turn runs, what Send does with the composer's text: Steer
    /// when the turn can take it and the user did not choose Queue, Queue
    /// otherwise. `nil` while no turn runs: Send then types at the open
    /// prompt, or the message waits as before.
    var delivery: CoordinatorComposerDelivery? {
        guard let controller else { return nil }
        let turnIsUnderWay = summary.map(Self.turnIsUnderWay)
            // Toastty reads no conversation of this agent: the status it
            // reports says whether it works.
            ?? (controller.session?.status?.kind == .working)
        guard turnIsUnderWay else { return nil }
        let canSteer = controller.canSteer
        return CoordinatorComposerDelivery(steers: canSteer && queueSelected == false, canSteer: canSteer)
    }

    /// The user chose Queue on the chip in the turn that runs now.
    var queueSelected: Bool {
        get {
            guard let queueChosenInTurn else { return false }
            return queueChosenInTurn == summary?.inputControl?.turnEpoch
        }
        set {
            queueChosenInTurn = newValue ? summary?.inputControl?.turnEpoch : nil
        }
    }

    /// A turn runs, or waits within itself for the user's answer to a
    /// question or a permission. The answer belongs in the terminal, so a
    /// message then queues.
    private static func turnIsUnderWay(_ summary: RemoteConversationSummary) -> Bool {
        if case .pendingInteraction = summary.inputAvailability { return true }
        return summary.inputControl?.turnEpoch != nil
    }

    /// Sends the composer's text as the user's message, with its files.
    /// While a turn runs it goes into that turn, unless the user chose
    /// Queue or `queueing` is set (Command-Return), or the turn cannot take
    /// it when Toastty types it.
    func send(queueing: Bool = false) {
        guard canSend, let controller else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let steering = queueing == false && queueSelected == false
        let reply = replyTarget
        guard attachmentDraft.attachments.isEmpty == false else {
            do {
                try controller.sendUserText(reply?.message(text: text) ?? text, steering: steering)
                draft = ""
                replyTarget = nil
                didSend()
            } catch {
                transientNotice = .failure(error.localizedDescription)
            }
            publishMetadata()
            return
        }
        // Files that a waiting message holds are in the coordinator's
        // folder already. The draft's own copies are copied there first.
        let attachments = attachmentDraft.attachments
        let message = CoordinatorUserMessage(
            text: text,
            files: attachments.filter(\.isDraftCopy).map(\.url),
            stagedFiles: attachments.filter { $0.isDraftCopy == false }.map(\.url),
            reply: reply
        )
        isSendingFiles = true
        Task { @MainActor [weak self] in
            do {
                _ = try await controller.sendUserMessage(message, steering: steering)
                guard let self else { return }
                isSendingFiles = false
                draft = ""
                if replyTarget == reply { replyTarget = nil }
                attachmentDraft.clear()
                didSend()
            } catch {
                self?.isSendingFiles = false
                self?.transientNotice = .failure(error.localizedDescription)
            }
            self?.publishMetadata()
        }
    }

    private func didSend() {
        // The next message steers again, as the default.
        queueSelected = false
        transientNotice = nil
        lastJumpRequest &+= 1
        jumpToLiveEdgeRequest = lastJumpRequest
    }

    /// **Files…** in the composer's ＋ menu.
    func chooseFiles() {
        guard attachmentDraft.canEdit, attachmentDraft.canAttachMore else { return }
        let openPanel = DraftAttachments.makeOpenPanel()
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                if response == .OK {
                    self.attachmentDraft.attachFiles(openPanel.urls)
                }
                self.requestComposerFocus()
            }
        }
        if let window = composerTextView?.window {
            openPanel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            openPanel.begin(completionHandler: finish)
        }
    }

    /// Reply on one of the coordinator's messages: the composer's message
    /// answers it, and the composer takes the keyboard. A second Reply
    /// replaces the first.
    func reply(to request: ToasttyMessageReplyRequest) {
        guard isSendingFiles == false else { return }
        // The field holds another sender's message, taken back with Edit.
        // As a reply it would read as the user's.
        guard Self.hasOtherHeader(draft) == false else {
            transientNotice = .failure(Self.otherHeaderReplyRefusal)
            return
        }
        replyTarget = CoordinatorReplyTarget(
            text: request.text,
            // As the reply's first line writes it, so a waiting reply that
            // comes back with Edit is the same reply.
            time: CoordinatorMessageHeader.replyTime(request.timestamp.formatted(date: .omitted, time: .shortened))
        )
        requestComposerFocus()
    }

    static let otherHeaderReplyRefusal =
        "The message you are writing starts with Toastty's line for another sender, so it cannot be a reply. "
            + "Send or clear it first."

    /// The text starts with Toastty's line for a digest, another sender or
    /// the quick entry panel. A reply puts its own line first, which would
    /// change whose message it is.
    static func hasOtherHeader(_ text: String) -> Bool {
        switch CoordinatorMessageHeader.kind(of: text) {
        case .digest, .fromSender, .quickEntry: true
        case .reply, .plain: false
        }
    }

    /// The composer's message answers no message anymore.
    func cancelReply() {
        guard isSendingFiles == false else { return }
        replyTarget = nil
    }

    func stop() {
        do {
            try controller?.stopTurn()
            transientNotice = nil
        } catch {
            transientNotice = .failure(error.localizedDescription)
        }
        publishMetadata()
    }

    /// The user said that the terminal holds none of their text.
    func sendPastTerminalDraft() {
        controller?.releaseUserDraft()
        publishMetadata()
    }

    func dismissNotice() {
        transientNotice = nil
    }

    func perform(_ action: ToasttyQueuedMessageAction) {
        switch action {
        case .edit(let id, _):
            // Back into the composer, in front of what is there. It is the
            // text as it would be typed, so a quick entry message keeps
            // Toastty's first line. Its files come back as attachments and
            // stay in their folder; when one cannot, the text keeps every
            // path instead.
            guard isSendingFiles == false, let controller,
                  let entry = (controller.queuedEntries + controller.pausedEntries).first(where: { $0.id == id }) else { return }
            // A reply comes back as a reply. The composer answers one
            // message at most.
            let reply = CoordinatorMessageHeader.replyParts(of: entry.text)
            let entryTarget = reply.map { CoordinatorReplyTarget(text: $0.quote, time: $0.time) }
            if let entryTarget, let replyTarget, entryTarget != replyTarget {
                transientNotice = .failure(
                    "This message is a reply, and the message you are writing replies to another message. "
                        + "Remove that reply first."
                )
                break
            }
            if replyTarget != nil, Self.hasOtherHeader(entry.text) {
                transientNotice = .failure(
                    "This message starts with Toastty's line for another sender, and the message you are writing "
                        + "is a reply. Remove the reply first."
                )
                break
            }
            // Its files must fit next to the composer's: a message has at
            // most 10. Otherwise the message keeps waiting as it is.
            let room = TaskRecord.maximumAttachmentCount - attachmentDraft.attachments.count - attachmentDraft.pendingCount
            if let count = CoordinatorMessageHeader.attachedFiles(in: entry.text)?.paths.count, count > room {
                transientNotice = .failure(
                    "This message has \(count) files, and a message can have at most \(TaskRecord.maximumAttachmentCount). "
                        + "Remove files from the message you are writing first."
                )
                break
            }
            guard let removed = controller.removeQueuedEntry(id: id) else { return }
            let body = CoordinatorMessageHeader.replyParts(of: removed.text)?.body ?? removed.text
            var text = body
            if let parts = Self.editParts(of: body, attachments: controller.attachments, room: room) {
                text = parts.text
                attachmentDraft.restore(parts.files)
            }
            if let entryTarget {
                replyTarget = entryTarget
            }
            draft = draft.isEmpty ? text : (text.isEmpty ? draft : text + "\n" + draft)
            composerFocusRequest += 1
        case .remove(let id):
            controller?.removeQueuedEntry(id: id, discardingAttachments: true)
        case .resume:
            controller?.resumeQueue()
        case .steer(let id, _):
            do {
                try controller?.steerQueuedEntry(id: id)
                transientNotice = nil
                lastJumpRequest &+= 1
                jumpToLiveEdgeRequest = lastJumpRequest
            } catch {
                transientNotice = .failure(error.localizedDescription)
            }
        }
        publishMetadata()
    }

    func requestComposerFocus() {
        composerFocusRequest += 1
    }

    /// Gives the keyboard to the composer of the view at `host`. A view
    /// that is not on screen yet takes it when it shows.
    func requestComposerFocus(host: Host) {
        if viewers[host] != nil {
            focusOnShow = nil
            requestComposerFocus()
        } else {
            focusOnShow = host
        }
    }

    /// A waiting message's text without its list of files, and the files,
    /// for Edit. `nil` when the files cannot come back as attachments: a
    /// file that is not a copy in the coordinator's folder anymore, or more
    /// files than `room`. The text then keeps its paths.
    static func editParts(
        of text: String,
        attachments: CoordinatorAttachments,
        room: Int
    ) -> (text: String, files: [URL])? {
        guard let (rest, paths) = CoordinatorMessageHeader.attachedFiles(in: text), paths.count <= room else {
            return nil
        }
        let files = paths.map { URL(filePath: $0) }
        guard files.allSatisfy(attachments.isStagedCopy) else { return nil }
        return (rest, files)
    }

    // MARK: - Text size

    static let textScaleDefaultsKey = "toastty.coordinator.chatTextScale"
    static let defaultTextScale: Double = 1
    static let minimumTextScale: Double = 0.8
    static let maximumTextScale: Double = 2
    static let textScaleStep: Double = 0.1

    /// Increases, decreases or resets the chat's text size. The menu items
    /// and Command-plus, Command-minus and Command-zero call it while the
    /// chat covers the coordinator's terminal.
    func changeTextScale(_ change: TextScaleChange) {
        let next = Self.textScale(after: change, from: textScale)
        guard next != textScale else { return }
        textScale = next
        if next == Self.defaultTextScale {
            defaults?.removeObject(forKey: Self.textScaleDefaultsKey)
        } else {
            defaults?.set(next, forKey: Self.textScaleDefaultsKey)
        }
    }

    enum TextScaleChange: Equatable {
        case increase
        case decrease
        case reset
    }

    /// The scale after one change, kept in range and on whole steps.
    static func textScale(after change: TextScaleChange, from scale: Double) -> Double {
        switch change {
        case .reset:
            return defaultTextScale
        case .increase:
            return normalizedTextScale(scale + textScaleStep)
        case .decrease:
            return normalizedTextScale(scale - textScaleStep)
        }
    }

    static func normalizedTextScale(_ scale: Double) -> Double {
        guard scale.isFinite else { return defaultTextScale }
        let stepped = (scale / textScaleStep).rounded() * textScaleStep
        let clamped = min(max(stepped, minimumTextScale), maximumTextScale)
        // One decimal, so that ten steps up and ten down end at 1 exactly.
        return (clamped * 10).rounded() / 10
    }

    // MARK: - The keyboard

    /// Gives the composer the keyboard, in place of the terminal under the
    /// chat. Returns whether the chat has the keyboard now. A reader who
    /// selects text in the transcript keeps the keyboard there, so that
    /// Copy still copies the selection.
    @discardableResult
    func focusComposer() -> Bool {
        guard let composerTextView, let window = composerTextView.window else { return false }
        if window.firstResponder === composerTextView || window.firstResponder is ToasttyTranscriptTextView {
            return true
        }
        return window.makeFirstResponder(composerTextView)
    }

    // MARK: - What the transcript needs about the session

    var sessionStatus: ToasttyTranscriptSessionStatus? {
        guard let summary else { return nil }
        switch summary.state {
        case .working: return .working
        case .ready: return .ready
        default: return ToasttyTranscriptSessionStatus(activity: .other, epoch: summary.state.rawValue)
        }
    }

    var workingIndicator: ToasttyTranscriptWorkingIndicator? {
        guard let summary, summary.state == .working else { return nil }
        return ToasttyTranscriptWorkingIndicator(turnElapsed: summary.turnStartedAt.map { startedAt in
            ToasttyTranscriptWorkingIndicator.TurnElapsed(
                secondsAtReceipt: Int(max(0, now().timeIntervalSince(startedAt))),
                receivedAtMonotonicTime: ProcessInfo.processInfo.systemUptime
            )
        })
    }
}

/// A text view held weakly, so a view that goes away takes its composer
/// with it.
private struct WeakTextView {
    weak var view: NSTextView?
}

private extension CoordinatorChatModel.LoadedPage {
    init(_ page: ConversationEventPage) {
        self.init(
            conversationID: page.conversationID,
            projectionRunID: page.projectionRunID,
            projectionGeneration: page.projectionGeneration,
            firstAvailableSequence: page.firstAvailableSequence ?? 1
        )
    }
}
