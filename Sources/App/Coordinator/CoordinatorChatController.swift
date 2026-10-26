import Combine
import CoreState
import Foundation
import RemoteProtocol

/// Feeds the coordinator chat. It follows the coordinator's transcript in
/// the shared `ConversationService`, the cards in `events.jsonl`, and each
/// task's live state, and pushes one state object to every open chat page.
/// It also runs what the page asks for, through the same paths the sidebar
/// and the CLI use: `task send`, Merge, and the right panel.
@MainActor
final class CoordinatorChatController {
    /// The app's one controller, for the views that show the chat. Set once
    /// at launch; `nil` in tests and without the task system.
    static weak var shared: CoordinatorChatController?

    /// One open chat page.
    @MainActor
    protocol Page: AnyObject {
        func receive(_ payload: Data)
        /// Runs a script in the page; true when it returned true.
        func run(_ script: String) async -> Bool
        /// Takes the keyboard, as opening the chat by its shortcut asks.
        func takeKeyboardFocus()
    }

    /// What `automation.coordinator_chat_action` does in the page.
    enum PageAction {
        case click(elementID: String)
        /// Types the text into a field, then submits it as Return would.
        case type(elementID: String, text: String)

        var elementID: String {
            switch self {
            case .click(let elementID), .type(let elementID, _): elementID
            }
        }

        /// True in a page that has the element.
        var probe: String {
            "document.getElementById(\(Self.literal(elementID))) !== null"
        }

        private static func literal(_ value: String) -> String {
            // A JSON string is a JavaScript string literal.
            String(data: (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
        }

        var script: String {
            let literal = Self.literal
            switch self {
            case .click(let elementID):
                return "(() => { const e = document.getElementById(\(literal(elementID))); if (!e) return false; e.click(); return true; })()"
            case .type(let elementID, let text):
                return """
                (() => {
                  const e = document.getElementById(\(literal(elementID)));
                  if (!e) return false;
                  e.focus();
                  e.value = \(literal(text));
                  e.dispatchEvent(new Event("input", { bubbles: true }));
                  e.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
                  const form = e.closest("form");
                  if (form && form.id !== "composer") form.requestSubmit();
                  return true;
                })()
                """
            }
        }
    }

    /// Runs the action in the one open page that has the element. Returns
    /// how many pages have it; the action runs only when that is one, so a
    /// second chat page, in another window or tab, never acts twice.
    func performPageAction(_ action: PageAction) async -> Int {
        var matching: [any Page] = []
        for page in pages.values.compactMap(\.page) where await page.run(action.probe) {
            matching.append(page)
        }
        if matching.count == 1 { _ = await matching[0].run(action.script) }
        return matching.count
    }

    let store: AppStore
    let taskCoordinator: TaskCoordinator
    let session: CoordinatorSessionController
    let conversations: ConversationService?
    let sessionRuntimeStore: SessionRuntimeStore?
    private let now: () -> Date

    private var pages: [ObjectIdentifier: WeakPage] = [:]
    private var refreshTask: Task<Void, Never>?
    private var isRefreshing = false
    private var refreshAgain = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var changeTasks: [Task<Void, Never>] = []
    private var boardObservation: AnyCancellable?
    private var transcript = CoordinatorChatTranscript()
    private var packetCache: [String: TaskPacket] = [:]
    private var staleByTaskID: [UUID: Bool] = [:]
    /// When staleness was last read with git, and for which packet version:
    /// refreshes come often, and git runs at most this often per task.
    private var staleCheckedAt: [UUID: (version: Int, at: Date)] = [:]
    static let staleCheckInterval: TimeInterval = 15
    private var focus: (taskID: UUID, token: Int)?
    private var notice: (text: String, isError: Bool, token: Int)?
    private var ack: (token: Int, ok: Bool)?
    private var tokenCounter = 0
    private var viewRequest: (view: CoordinatorChatPageView, token: Int)?
    private(set) var lastPayload: CoordinatorChatPayload?
    /// The cards an open page last reported expanded.
    private(set) var expandedCardIDs: [String] = []
    /// What an open page last reported it shows, and its selected All tasks row.
    private(set) var pageView: CoordinatorChatPageView = .chat
    private(set) var selectedTaskRowID: String?

    init(
        store: AppStore,
        taskCoordinator: TaskCoordinator,
        session: CoordinatorSessionController,
        conversations: ConversationService?,
        sessionRuntimeStore: SessionRuntimeStore?,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.taskCoordinator = taskCoordinator
        self.session = session
        self.conversations = conversations
        self.sessionRuntimeStore = sessionRuntimeStore
        self.now = now
        if let conversations {
            let changes = conversations.changes()
            changeTasks.append(Task { [weak self] in
                for await _ in changes { self?.setNeedsRefresh() }
            })
        }
        boardObservation = taskCoordinator.board?.objectWillChange.sink { [weak self] _ in
            self?.setNeedsRefresh()
        }
    }

    deinit {
        for task in changeTasks { task.cancel() }
        refreshTask?.cancel()
    }

    // MARK: - Pages

    func attach(_ page: any Page) {
        pages[ObjectIdentifier(page)] = WeakPage(page: page)
        if let lastPayload, let data = try? lastPayload.encoded() {
            page.receive(data)
        }
        setNeedsRefresh()
    }

    func detach(_ page: any Page) {
        pages.removeValue(forKey: ObjectIdentifier(page))
    }

    /// `coordinator.chat.show`: the chat covers the coordinator's terminal,
    /// and with a task, its latest packet card opens.
    func show(taskID: UUID?) -> Bool {
        show(.chat, taskID: taskID)
    }

    /// `coordinator.tasks.show`: the page shows All tasks instead of the chat.
    func showTasks() -> Bool {
        show(.tasks, taskID: nil)
    }

    private func show(_ view: CoordinatorChatPageView, taskID: UUID?) -> Bool {
        guard session.showChat() else {
            // No coordinator workspace yet, as in a dev run that does not
            // start the coordinator at launch: start it, then show.
            return session.startForRequest { [weak self] in
                _ = self?.show(view, taskID: taskID)
            }
        }
        taskCoordinator.board?.chatDidOpen()
        tokenCounter += 1
        viewRequest = (view, tokenCounter)
        // The page may already show, with the keyboard elsewhere: typing,
        // and the arrow keys on All tasks, should reach it.
        for page in pages.values.compactMap(\.page) { page.takeKeyboardFocus() }
        if let taskID {
            tokenCounter += 1
            focus = (taskID, tokenCounter)
        }
        setNeedsRefresh()
        return true
    }

    /// Something the chat shows changed: a card was posted, a task moved.
    func setNeedsRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            await self?.refresh()
        }
    }

    /// Builds and pushes the state. Refreshes run one at a time: a refresh
    /// asked for while one runs makes it run again, and the caller waits for
    /// that, so an older state never replaces a newer one.
    func refresh() async {
        if isRefreshing {
            refreshAgain = true
            await withCheckedContinuation { refreshWaiters.append($0) }
            return
        }
        isRefreshing = true
        repeat {
            refreshAgain = false
            refreshTask = nil
            if readTranscript() == false { refreshAgain = true }
            let events = session.files.events()
            let payload = await buildPayload(events: events)
            lastPayload = payload
            if pages.isEmpty == false, let data = try? payload.encoded() {
                pages = pages.filter { $0.value.page != nil }
                for page in pages.values.compactMap(\.page) { page.receive(data) }
            }
        } while refreshAgain
        isRefreshing = false
        let waiters = refreshWaiters
        refreshWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    // MARK: - Transcript

    /// Reads the conversation's new events, a bounded number of pages at a
    /// time. Returns false when more are left, so the refresh reads again.
    private func readTranscript() -> Bool {
        guard let conversations, let panelID = session.panelID,
              let conversationID = conversations.conversationID(for: panelID) else { return true }
        transcript.follow(conversationID)
        for _ in 0..<20 {
            switch conversations.events(for: conversationID, after: transcript.cursor, limit: 500) {
            case .page(let page):
                transcript.apply(page)
                guard let last = page.events.last, last.sequence < page.latestSequence else { return true }
            case .resnapshotRequired:
                transcript.reset()
            case .conversationNotFound, .invalidRequest:
                return true
            }
        }
        return false
    }

    // MARK: - Payload

    private func buildPayload(events: [CoordinatorEvent]) async -> CoordinatorChatPayload {
        let items = taskCoordinator.board?.items() ?? []
        var itemsByTaskID: [UUID: TaskBoardItem] = [:]
        for item in items { if let id = item.taskID { itemsByTaskID[id] = item } }
        let taskIDs = Set(events.compactMap(\.taskID))
        var stamps: [UUID: [CoordinatorChatTimeline.PacketStamp]] = [:]
        for taskID in taskIDs {
            stamps[taskID] = taskCoordinator.packets.versions(taskID: taskID).compactMap { version in
                packet(taskID: taskID, version: version).map {
                    CoordinatorChatTimeline.PacketStamp(version: version, createdAt: $0.createdAt ?? .distantPast)
                }
            }
        }
        await refreshStaleness(taskIDs: taskIDs)
        let config = taskCoordinator.board?.config
        let cards = CoordinatorChatTimeline.cards(events: events, packets: stamps)
        var chatItems = transcript.items.map { CoordinatorChatItem.transcript($0) }
        for card in cards {
            let record = card.taskID.flatMap { taskCoordinator.records.record(id: $0) }
            let task = card.taskID.map { taskID in
                CoordinatorChatTaskView.make(
                    taskID: taskID,
                    record: record,
                    item: itemsByTaskID[taskID],
                    stale: staleByTaskID[taskID] ?? false,
                    config: config,
                    homeDirectoryPath: taskCoordinator.homeDirectoryPath
                )
            }
            let packetView = card.taskID.flatMap { taskID in
                card.packetVersion.flatMap { version in
                    packet(taskID: taskID, version: version).map {
                        CoordinatorChatPacketView(packet: $0, taskID: taskID, latestVersion: stamps[taskID]?.last?.version ?? version)
                    }
                }
            }
            chatItems.append(.card(CoordinatorChatCardView(card: card, task: task, packet: packetView)))
        }
        chatItems.sort { $0.at < $1.at }
        let board = taskCoordinator.board
        let isTriageConfigured = taskCoordinator.isTriageConfigured
        let rows = CoordinatorAllTasks.rows(
            CoordinatorAllTasks.shownItems(items),
            hasCard: { taskIDs.contains($0) },
            canRelease: { board?.canRelease($0) ?? false },
            isTriageConfigured: isTriageConfigured,
            mergePolicy: { [taskCoordinator] item in
                CoordinatorChatTaskView.mergePolicy(record: item.record, config: config, homeDirectoryPath: taskCoordinator.homeDirectoryPath)
            }
        )
        return CoordinatorChatPayload(
            coordinator: coordinatorView(),
            items: chatItems,
            focus: focus.map { .init(taskID: $0.taskID.uuidString, token: $0.token) },
            notice: notice.map { .init(text: $0.text, isError: $0.isError, token: $0.token) },
            ack: ack.map { .init(token: $0.token, ok: $0.ok) },
            view: viewRequest.map { .init(view: $0.view, token: $0.token) },
            taskGroups: CoordinatorAllTasks.groups(items),
            tasks: rows
        )
    }

    private func packet(taskID: UUID, version: Int) -> TaskPacket? {
        // A stored version never changes, so it is read once.
        let key = "\(taskID.uuidString)/\(version)"
        if let cached = packetCache[key] { return cached }
        guard let read = try? taskCoordinator.packets.read(taskID: taskID, version: version) else { return nil }
        packetCache[key] = read
        return read
    }

    private func refreshStaleness(taskIDs: Set<UUID>) async {
        for taskID in taskIDs {
            guard let version = taskCoordinator.records.record(id: taskID)?.packetVersion else { continue }
            if let checked = staleCheckedAt[taskID], checked.version == version,
               now().timeIntervalSince(checked.at) < Self.staleCheckInterval { continue }
            staleCheckedAt[taskID] = (version, now())
            if let reading = try? await taskCoordinator.packet(taskID: taskID, version: nil) {
                staleByTaskID[taskID] = reading.stale
            }
        }
    }

    private func coordinatorView() -> CoordinatorChatPayload.Coordinator {
        let snapshot = conversationSnapshot()
        let (canSend, hint) = Self.sendState(status: session.status, snapshot: snapshot)
        var detail: String
        switch session.status {
        case .off: detail = "Off. Set [coordinator] agent in tasks.toml, then Reload Configuration."
        case .waitingForWindow: detail = "Waiting for a window"
        case .waitingForRestore: detail = "Resuming its last session"
        case .starting: detail = "Starting"
        case .running: detail = snapshot.map { "\($0.summary.provider.displayName) · running" } ?? "Running"
        case .failed(let reason): detail = "Stopped: \(reason)"
        }
        // The task board reads tasks.toml again each time the chat opens; an
        // error there matters more than the coordinator's own state.
        if let configError = taskCoordinator.board?.configError {
            detail = "tasks.toml: \(configError)"
        }
        return .init(title: "Coordinator", detail: detail, canSend: canSend, sendHint: hint, hasTerminal: session.workspaceID != nil)
    }

    private func conversationSnapshot() -> RemoteConversationSnapshot? {
        guard let conversations, let panelID = session.panelID,
              let conversationID = conversations.conversationID(for: panelID) else { return nil }
        return conversations.localSnapshot(for: conversationID, at: now())
    }

    /// Whether the composer can send now, and what it says when it cannot,
    /// or when a message waits for the agent's turn to end.
    static func sendState(
        status: CoordinatorSessionController.Status,
        snapshot: RemoteConversationSnapshot?
    ) -> (canSend: Bool, hint: String?) {
        guard case .running = status else { return (false, "The coordinator is not running") }
        guard let snapshot else { return (false, "Waiting for the coordinator's conversation") }
        switch snapshot.summary.inputAvailability {
        case .openPrompt:
            return (true, nil)
        case .pendingInteraction:
            return (false, "The coordinator waits for an answer in its terminal")
        case .localDraft:
            return (false, "Text is typed in the coordinator's terminal")
        case .unavailable(reason: .starting):
            return (false, "The coordinator is starting. Check its terminal for setup.")
        case .unavailable:
            // A message queues behind a running turn. Just after a turn ends
            // there is none to queue behind, and the prompt is not open yet.
            if let control = snapshot.summary.inputControl, control.canQueue {
                return control.turnEpoch == nil ? (false, "Waiting for the coordinator's prompt") : (true, "Sends when its turn ends")
            }
            return (false, "The coordinator cannot take a message now")
        }
    }

    // MARK: - Actions

    func handle(_ event: CoordinatorChatPageEvent, token: Int? = nil, from page: (any Page)?) async {
        switch event {
        case .ready:
            if let page { attach(page) }
        case .rendered(let expanded, let view, let selectedRowID):
            expandedCardIDs = expanded
            pageView = view
            selectedTaskRowID = selectedRowID
            return
        case .taskAction(let rowID, let actionID):
            runTaskAction(rowID: rowID, actionID: actionID)
        case .send(let text):
            acknowledge(token, ok: await sendToCoordinator(text))
        case .reply(let taskID, let version, let text):
            acknowledge(token, ok: reply(taskID: taskID, version: version, text: text))
        case .ask(let taskID, let version, let text):
            let title = taskCoordinator.records.record(id: taskID)?.title ?? taskID.uuidString
            let packet = version.map { ", packet v\($0)" } ?? ""
            acknowledge(token, ok: await sendToCoordinator("About task \"\(title)\" (task ID \(taskID.uuidString)\(packet)): \(text)"))
        case .merge(let taskID):
            if perform("Merge", { try taskCoordinator.requestMerge(taskID: taskID) }) != nil {
                setNotice("Merge requested. It follows the project's merge policy.", isError: false)
            }
        case .openTaskSpace(let taskID):
            openTaskSpace(taskID)
        case .openURL(let url):
            openInRightPanel(url)
        case .openReport(let taskID, let version, let screenshot):
            openInRightPanel(Self.reportURL(taskID: taskID, version: version, screenshot: screenshot), reusingPrefix: "toastty://coordinator/report/\(taskID.uuidString)/")
        case .openRouting:
            openRouting()
        case .openTerminal:
            _ = session.showTerminal()
        }
        setNeedsRefresh()
    }

    /// The task the command palette acts on while the chat shows: on All
    /// tasks, the selected row's; in the chat, the task of the card the page
    /// opened last. `nil` while neither is there.
    var currentTaskID: UUID? {
        if pageView == .tasks {
            return lastPayload?.tasks.first { $0.id == selectedTaskRowID }?.taskID.flatMap(UUID.init(uuidString:))
        }
        let cards = (lastPayload?.items ?? []).compactMap { item -> CoordinatorChatCardView? in
            if case .card(let card) = item { return card }
            return nil
        }
        for cardID in expandedCardIDs.reversed() {
            if let id = cards.first(where: { $0.id == cardID })?.task?.id { return UUID(uuidString: id) }
        }
        return nil
    }

    /// Whether the chat has a card for the task: one the coordinator posted,
    /// or a packet card the chat adds for a task that has one.
    func hasCards(taskID: UUID) -> Bool {
        session.files.events().contains { $0.taskID == taskID }
    }

    /// `coordinator.chat.state`, for automation and checks.
    func stateSnapshot() -> [String: AutomationJSONValue] {
        func optional(_ value: String?) -> AutomationJSONValue { value.map(AutomationJSONValue.string) ?? .null }
        let items: [AutomationJSONValue] = (lastPayload?.items ?? []).map { item in
            switch item {
            case .transcript(let line):
                return .object(["type": .string(line.type.rawValue), "id": .string(line.id), "text": optional(line.text ?? line.name)])
            case .card(let card):
                return .object([
                    "type": .string("card"),
                    "id": .string(card.id),
                    "kind": .string(card.kind),
                    "taskID": optional(card.task?.id),
                    "packetVersion": card.packet.map { .int($0.version) } ?? .null,
                    "superseded": .bool(card.superseded),
                    "isNew": .bool(card.isNew),
                    "stage": optional(card.task?.stageLabel),
                    "canMerge": .bool(card.task?.canMerge ?? false),
                    "mergePolicy": optional(card.task?.mergePolicy),
                    "pullRequestURL": optional(card.task?.pullRequestURL),
                ])
            }
        }
        return [
            "pages": .int(pages.values.filter { $0.page != nil }.count),
            "canSend": .bool(lastPayload?.coordinator.canSend ?? false),
            "items": .array(items),
            "expandedCardIDs": .array(expandedCardIDs.map(AutomationJSONValue.string)),
            "currentTaskID": optional(currentTaskID?.uuidString),
            "view": .string(pageView.rawValue),
            "selectedRowID": optional(selectedTaskRowID),
            "tasks": .array((lastPayload?.tasks ?? []).map { row in
                .object([
                    "id": .string(row.id),
                    "taskID": optional(row.taskID),
                    "title": .string(row.title),
                    "group": .string(row.group),
                    "stage": .string(row.stageLabel),
                    "hasCard": .bool(row.hasCard),
                    "primary": optional(row.primary?.id),
                    "menu": .array(row.menu.joined().map { .string($0.id) }),
                ])
            }),
            "notice": notice.map { .object(["text": .string($0.text), "isError": .bool($0.isError)]) } ?? .null,
        ]
    }

    static func reportURL(taskID: UUID, version: Int, screenshot: String?) -> String {
        var url = "toastty://coordinator/report/\(taskID.uuidString)/\(version)"
        if let screenshot, TaskPacket.isValidScreenshotName(screenshot) { url += "?shot=\(screenshot)" }
        return url
    }

    private func acknowledge(_ token: Int?, ok: Bool) {
        guard let token else { return }
        ack = (token, ok)
    }

    @discardableResult
    private func sendToCoordinator(_ text: String) async -> Bool {
        guard let conversations, let panelID = session.panelID,
              let conversationID = conversations.conversationID(for: panelID),
              let snapshot = conversations.localSnapshot(for: conversationID, at: now()) else {
            setNotice("The coordinator is not running.", isError: true)
            return false
        }
        let epoch: RemoteInputEpoch
        let mode: RemoteMessageDeliveryMode
        switch snapshot.summary.inputAvailability {
        case .openPrompt(let open):
            epoch = open
            mode = .prompt
        default:
            guard snapshot.summary.inputControl?.canQueue == true, let turn = snapshot.summary.inputControl?.turnEpoch else {
                setNotice(Self.sendState(status: session.status, snapshot: snapshot).hint ?? "The coordinator cannot take a message now.", isError: true)
                return false
            }
            epoch = turn
            mode = .queue
        }
        let request = RemoteMessageSendRequest(
            conversationID: conversationID,
            clientRequestID: "coordinator-chat-\(UUID().uuidString)",
            expectedInputEpoch: epoch,
            text: text,
            deliveryMode: mode
        )
        switch await conversations.sendLocal(request) {
        case .accepted, .duplicate:
            return true
        case .queued:
            setNotice("Queued: the coordinator gets it when its turn ends.", isError: false)
            return true
        case .rejected(let reason):
            setNotice("The coordinator did not take the message (\(reason.rawValue)).", isError: true)
            return false
        case .uncertain:
            // The text may be in the terminal; keeping the draft would invite
            // a second copy.
            setNotice("The message may not have reached the coordinator. Check its terminal.", isError: true)
            return true
        }
    }

    /// Sends a review note to the task's agent. The task leaves Needs you:
    /// its agent works on the note, and its next packet asks again.
    private func reply(taskID: UUID, version: Int, text: String) -> Bool {
        let sent = perform("Reply") { try taskCoordinator.send(taskID: taskID, text: "Review note on packet v\(version): \(text)") }
        guard sent != nil else { return false }
        try? taskCoordinator.saveMergeState(taskID: taskID) { $0.readyForReviewAt = nil }
        let slug = taskCoordinator.records.record(id: taskID)?.slug ?? "the task"
        setNotice("Sent to \(slug).", isError: false)
        return true
    }

    /// Runs an All tasks row's action. The row may be older than the task:
    /// an action the task no longer offers does nothing, and says so.
    private func runTaskAction(rowID: String, actionID: String) {
        guard let board = taskCoordinator.board,
              let resolved = CoordinatorAllTasks.resolve(
                  rowID: rowID,
                  actionID: actionID,
                  items: board.items(),
                  canRelease: board.canRelease,
                  isTriageConfigured: taskCoordinator.isTriageConfigured
              ) else {
            setNotice("That task changed; its row now shows what it offers.", isError: true)
            return
        }
        switch resolved {
        case .open(let item):
            if let taskID = item.taskID, hasCards(taskID: taskID) {
                _ = show(taskID: taskID)
            } else if let workspaceID = item.taskSpaceWorkspaceID {
                openWorkspace(workspaceID)
            } else {
                setNotice("This task has no card in the chat and no open task space.", isError: true)
            }
        case .release(let projectWorkspaceID):
            if perform("Release", { try taskCoordinator.release(workspaceID: projectWorkspaceID, caller: .unmanaged) }) != nil {
                setNotice("Release started.", isError: false)
            }
        case .menu(.openPullRequest(_, let url)):
            openInRightPanel(url.absoluteString)
        case .menu(let item):
            let ran = perform(item.title) {
                try TaskActions.run(item, coordinator: taskCoordinator) { openWorkspace($0) }
            }
            if ran != nil, case .action(.merge, _, _) = item {
                setNotice("Merge requested. It follows the project's merge policy.", isError: false)
            }
        }
    }

    private func openTaskSpace(_ taskID: UUID) {
        guard let workspaceID = taskCoordinator.records.record(id: taskID)?.taskSpaceWorkspaceID else {
            setNotice("The task space is closed.", isError: true)
            return
        }
        openWorkspace(workspaceID)
    }

    private func openWorkspace(_ workspaceID: UUID) {
        guard store.state.workspacesByID[workspaceID] != nil,
              let windowID = store.state.workspaceSelection(containingWorkspaceID: workspaceID)?.windowID
                ?? store.state.selectedWindowID else {
            setNotice("The task space is closed.", isError: true)
            return
        }
        if let sessionRuntimeStore {
            TaskActions.openTaskSpace(workspaceID: workspaceID, fallbackWindowID: windowID, store: store, sessionRuntimeStore: sessionRuntimeStore)
        } else {
            _ = store.sendNavigation(.selectWorkspace(windowID: windowID, workspaceID: workspaceID))
        }
    }

    /// Opens a page in the coordinator workspace's right panel, which shows
    /// beside the chat. A report for the same task reuses its tab.
    private func openInRightPanel(_ url: String, reusingPrefix: String? = nil) {
        guard let workspaceID = session.workspaceID, let workspace = store.state.workspacesByID[workspaceID] else {
            setNotice("The coordinator workspace is not open.", isError: true)
            return
        }
        let isAllowed = url.hasPrefix("https://") || url.hasPrefix("http://") || url.hasPrefix("toastty://coordinator/")
        guard isAllowed else { return }
        if let reusingPrefix,
           let tab = workspace.rightAuxPanel.orderedTabs.first(where: {
               if case .web(let web) = $0.panelState { return web.restorableURL?.hasPrefix(reusingPrefix) == true }
               return false
           }) {
            _ = store.send(.updateWebPanelMetadata(panelID: tab.panelID, title: nil, url: url))
            _ = store.send(.selectRightAuxPanelTab(workspaceID: workspaceID, tabID: tab.id, focus: true))
            return
        }
        _ = store.createBrowserPanel(
            workspaceID: workspaceID,
            request: BrowserPanelCreateRequest(initialURL: url, placementOverride: .rightPanel)
        )
    }

    private func openRouting() {
        guard let workspaceID = session.workspaceID else {
            setNotice("The coordinator workspace is not open.", isError: true)
            return
        }
        try? session.files.prepare()
        let opened = store.createLocalDocumentPanel(
            workspaceID: workspaceID,
            request: LocalDocumentPanelCreateRequest(filePath: session.files.routingFileURL.path, placementOverride: .rightPanel)
        )
        if opened == false { setNotice("Could not open routing.md.", isError: true) }
    }

    @discardableResult
    private func perform<T>(_ action: String, _ body: () throws -> T) -> T? {
        do {
            return try body()
        } catch let error as TaskError {
            setNotice(error.message, isError: true)
        } catch {
            setNotice("\(action) failed: \(error.localizedDescription)", isError: true)
        }
        return nil
    }

    private func setNotice(_ text: String, isError: Bool) {
        tokenCounter += 1
        notice = (text, isError, tokenCounter)
    }

    private struct WeakPage {
        weak var page: (any Page)?
    }
}

// MARK: - Report data

extension CoordinatorChatController: ToasttyCoordinatorPageDataSource {
    func packetReportJSON(taskID: UUID, version: Int) -> Data? {
        guard let packet = packet(taskID: taskID, version: version) else { return nil }
        let record = taskCoordinator.records.record(id: taskID)
        let view = CoordinatorChatPacketView(packet: packet, taskID: taskID, latestVersion: record?.packetVersion ?? version)
        let report = CoordinatorChatReport(
            taskID: taskID.uuidString,
            title: record?.title ?? "Task",
            version: view.version,
            latestVersion: view.latestVersion,
            summary: view.summary,
            lookAt: view.lookAt,
            checks: view.checks,
            notVerified: view.notVerified,
            screenshots: view.screenshots,
            headCommit: packet.headCommit,
            createdAt: packet.createdAt.map { ISO8601DateFormatter().string(from: $0) }
        )
        return try? JSONEncoder().encode(report)
    }

    func packetFileURL(taskID: UUID, version: Int, fileName: String) -> URL? {
        guard let packet = packet(taskID: taskID, version: version),
              packet.screenshots.contains(where: { $0.file == fileName }) else { return nil }
        return taskCoordinator.packets.versionDirectoryURL(taskID: taskID, version: version)
            .appending(path: fileName, directoryHint: .notDirectory)
    }
}
