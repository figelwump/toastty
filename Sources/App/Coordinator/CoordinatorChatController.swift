import AppKit
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
        var windowID: UUID? { get }
        var isSummary: Bool { get }
        func receive(_ payload: Data)
        /// Runs a script in the page; true when it returned true.
        func run(_ script: String) async -> Bool
        /// Takes the keyboard, as opening the chat by its shortcut asks.
        func takeKeyboardFocus()
        /// Opens setup controls on the page that received the action.
        func showSetup(taskID: UUID, coordinator: TaskCoordinator) -> Bool
        func inspection() async -> [String: AutomationJSONValue]
        func showTaskMenu(sections: [[TaskBoardPresentation.MenuItem]], rect: CGRect, run: @escaping (TaskBoardPresentation.MenuItem) -> Void) -> Bool
    }

    /// What `automation.coordinator_chat_action` does in the page.
    enum PageAction {
        case click(elementID: String)
        case focus(elementID: String)
        case visible(elementID: String)
        /// Types the text into a field, then submits it as Return would.
        case type(elementID: String, text: String)

        var elementID: String {
            switch self {
            case .click(let elementID), .focus(let elementID), .visible(let elementID), .type(let elementID, _): elementID
            }
        }

        /// True in a page that has the element.
        var probe: String {
            if case .visible = self {
                return "(() => { const e = document.getElementById(\(Self.literal(elementID))); if (!e) return false; const b = e.getBoundingClientRect(); return b.width > 0 && b.height > 0 && getComputedStyle(e).visibility === 'visible'; })()"
            }
            return "document.getElementById(\(Self.literal(elementID))) !== null"
        }

        private static func literal(_ value: String) -> String {
            // A JSON string is a JavaScript string literal.
            String(data: (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
        }

        var script: String {
            let literal = Self.literal
            switch self {
            case .visible:
                return "true"
            case .click(let elementID):
                return "(() => { const e = document.getElementById(\(literal(elementID))); if (!e) return false; if (e.tagName === 'IMG') { const b = e.getBoundingClientRect(); e.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX: b.left + b.width / 2, clientY: b.top + b.height / 2 })); } else e.click(); return true; })()"
            case .focus(let elementID):
                return "(() => { const e = document.getElementById(\(literal(elementID))); if (!e) return false; e.focus({ preventScroll: true }); return document.activeElement === e; })()"
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
        if matching.count == 1 {
            if case .focus = action { matching[0].takeKeyboardFocus() }
            _ = await matching[0].run(action.script)
        }
        return matching.count
    }

    let store: AppStore
    let taskCoordinator: TaskCoordinator
    let session: CoordinatorSessionController
    let conversations: ConversationService?
    let sessionRuntimeStore: SessionRuntimeStore?
    private let loadURLInPanel: (@MainActor (UUID, String) -> Bool)?
    /// Replaces delivery through the coordinator's conversation, for tests.
    private let deliverToCoordinator: (@MainActor (String) async -> SendOutcome)?
    /// Each task's cards, for the sidebar.
    let cardIndex = CoordinatorChatCardIndex()
    private let now: () -> Date

    private var pages: [ObjectIdentifier: WeakPage] = [:]
    private var refreshTask: Task<Void, Never>?
    private var isRefreshing = false
    private var refreshAgain = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var changeTasks: [Task<Void, Never>] = []
    private var boardObservation: AnyCancellable?
    private var dayRefreshTask: Task<Void, Never>?
    private var projectFilters: [UUID: String] = [:]
    private var transcript = CoordinatorChatTranscript()
    private var taskCursors: [UUID: ConversationEventCursor] = [:]
    private var taskConversations: [UUID: RemoteConversationID] = [:]
    private var inFlightQuestions: Set<UUID> = []
    /// Answers that may have reached the coordinator's terminal without a
    /// confirmed submit. The question stays pending, so a second answer is
    /// not sent, until the coordinator's transcript echoes the first one.
    private var uncertainQuestions: Set<UUID> = []
    /// Packet-card replies sent with an uncertain outcome, by reply ID. Once
    /// the transcript echo saves one, it answers that packet's review.
    private var uncertainReviewReplies: [UUID: (taskID: UUID, version: Int)] = [:]
    private var unsavedThreadReplies: [CoordinatorEvent] = []
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
    private var viewRequest: (view: CoordinatorChatPageView, filter: CoordinatorChatPayload.TasksFilter?, token: Int)?
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
        loadURLInPanel: (@MainActor (UUID, String) -> Bool)? = nil,
        deliverToCoordinator: (@MainActor (String) async -> SendOutcome)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.taskCoordinator = taskCoordinator
        self.session = session
        self.conversations = conversations
        self.sessionRuntimeStore = sessionRuntimeStore
        self.loadURLInPanel = loadURLInPanel
        self.deliverToCoordinator = deliverToCoordinator
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
        dayRefreshTask?.cancel()
    }

    // MARK: - Pages

    func attach(_ page: any Page) {
        pages[ObjectIdentifier(page)] = WeakPage(page: page)
        if let lastPayload, let data = try? payload(lastPayload, for: page).encoded() {
            page.receive(data)
        }
        if page.isSummary, dayRefreshTask == nil {
            // Recheck the local date after sleep or a clock/timezone change,
            // too. Only open summary pages need these periodic refreshes.
            dayRefreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled else { return }
                    self?.setNeedsRefresh()
                }
            }
        } else if !page.isSummary {
            ensureSummary(showsTasks: false)
        }
        setNeedsRefresh()
    }

    func detach(_ page: any Page) {
        pages.removeValue(forKey: ObjectIdentifier(page))
        if !pages.values.contains(where: { $0.page?.isSummary == true }) {
            dayRefreshTask?.cancel()
            dayRefreshTask = nil
        }
    }

    private func windowID(for page: (any Page)?) -> UUID? {
        page?.windowID ?? session.workspaceID.flatMap { store.state.workspaceSelection(containingWorkspaceID: $0)?.windowID }
    }

    private func payload(_ payload: CoordinatorChatPayload, for page: any Page) -> CoordinatorChatPayload {
        var result = payload
        result.projectFilter = windowID(for: page).flatMap { projectFilters[$0] }
        // A late page uses this window's current selection, rather than
        // replaying the project from an older footer navigation.
        result.view?.filter?.project = result.projectFilter
        return result
    }

    func inspectPages() async -> [[String: AutomationJSONValue]] {
        var result: [[String: AutomationJSONValue]] = []
        for page in pages.values.compactMap(\.page) { result.append(await page.inspection()) }
        return result
    }

    /// `coordinator.chat.show`: the chat covers the coordinator's terminal,
    /// and with a task, its latest packet card opens.
    func show(taskID: UUID?) -> Bool {
        show(.chat, taskID: taskID)
    }

    /// `coordinator.tasks.show`: All tasks opens beside the chat.
    /// With a filter, as the sidebar's To ship and Done counts ask, it shows
    /// that project with that group open.
    func showTasks(filter: CoordinatorChatPayload.TasksFilter? = nil) -> Bool {
        show(.tasks, taskID: nil, filter: filter)
    }

    private func show(_ view: CoordinatorChatPageView, taskID: UUID?, filter: CoordinatorChatPayload.TasksFilter? = nil) -> Bool {
        guard session.showChat() else {
            // No coordinator workspace yet, as in a dev run that does not
            // start the coordinator at launch: start it, then show.
            return session.startForRequest { [weak self] in
                _ = self?.show(view, taskID: taskID, filter: filter)
            }
        }
        taskCoordinator.board?.chatDidOpen()
        if let filter, let windowID = windowID(for: nil) {
            projectFilters[windowID] = filter.project
        }
        if let taskID, let windowID = windowID(for: nil), let selectedProject = projectFilters[windowID],
           let item = taskCoordinator.board?.items().first(where: { $0.taskID == taskID }),
           CoordinatorAllTasks.projectID(item) != selectedProject {
            // Explicit navigation must reveal the requested card even if
            // another project's filter was selected.
            projectFilters[windowID] = CoordinatorAllTasks.projectID(item)
        }
        ensureSummary(showsTasks: view == .tasks)
        tokenCounter += 1
        viewRequest = (view, filter, tokenCounter)
        pageView = view
        // The page may already show, with the keyboard elsewhere: typing,
        // and the arrow keys on All tasks, should reach it.
        for page in pages.values.compactMap(\.page) where page.isSummary == (view != .chat) { page.takeKeyboardFocus() }
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
            var events = session.files.events()
            captureThreadMessages(events: &events)
            let payload = await buildPayload(events: events)
            lastPayload = payload
            updateCardIndex()
            let projectIDs = Set(payload.projects.map(\.id))
            projectFilters = projectFilters.filter { projectIDs.contains($0.value) }
            if pages.isEmpty == false {
                pages = pages.filter { $0.value.page != nil }
                for page in pages.values.compactMap(\.page) {
                    if let data = try? self.payload(payload, for: page).encoded() { page.receive(data) }
                }
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

    /// Copies the user's task-scoped messages into the durable thread log:
    /// replies from the coordinator's transcript, and answers typed in a
    /// task's terminal. A task agent's own messages stay in its terminal;
    /// cards do not repeat them. Provider event IDs survive projection
    /// rebuilds; sequences do not.
    private func captureThreadMessages(events: inout [CoordinatorEvent]) {
        let taskIDs = Set(events.compactMap(\.taskID))
        var sources = Set(events.compactMap(\.sourceID))
        func save(_ event: CoordinatorEvent) -> Bool {
            if let source = event.sourceID, sources.contains(source) { return true }
            do {
                try session.files.append(event)
                events.append(event)
                if let source = event.sourceID { sources.insert(source) }
                return true
            } catch {
                setNotice("Task thread history could not be saved: \(error.localizedDescription)", isError: true)
                return false
            }
        }
        let retrying = unsavedThreadReplies
        unsavedThreadReplies = []
        for entry in retrying where !save(entry) {
            unsavedThreadReplies.append(entry)
            // Keep the delivered answer visible and block duplicate sends
            // while disk writes are failing. The notice explains the gap.
            events.append(entry)
        }
        for line in transcript.items {
            if line.role == "user", let answer = line.routeAnswer,
               Self.routeQuestion(id: answer.questionID, in: events).map({ $0.text == answer.question && $0.options.contains(answer.answer) }) == true {
                _ = save(Self.routeReply(answer, at: line.at, delivery: .accepted))
                continue
            }
            guard line.role == "user", let taskID = line.aboutTaskID.flatMap(UUID.init(uuidString:)), taskIDs.contains(taskID),
                  let text = line.text, let providerID = line.sourceID else { continue }
            let source = line.replyID.map { "reply:\($0.uuidString)" } ?? "coordinator:\(providerID)"
            _ = save(CoordinatorEvent(id: line.replyID ?? UUID(), at: line.at, kind: .reply, taskID: taskID,
                                      text: text, sessionID: nil, threadRole: .userCoordinator,
                                      questionID: line.questionID, sourceID: source))
        }
        for (replyID, review) in uncertainReviewReplies where events.contains(where: { $0.id == replyID && $0.kind == .reply }) {
            uncertainReviewReplies[replyID] = nil
            // A newer packet started a new review; leave that one in place.
            if taskCoordinator.records.record(id: review.taskID)?.packetVersion == review.version {
                try? taskCoordinator.saveMergeState(taskID: review.taskID) { $0.readyForReviewAt = nil }
            }
        }
        guard let conversations else { return }
        var bindings: [(taskID: UUID, panelID: UUID, sessionID: String?)] = []
        for taskID in taskIDs {
            guard let record = taskCoordinator.records.record(id: taskID),
                  let workspaceID = record.taskSpaceWorkspaceID,
                  let workspace = store.state.workspacesByID[workspaceID], workspace.taskID == taskID else { continue }
            let live = taskCoordinator.liveAgentSession(of: record).flatMap { $0.workspaceID == workspaceID ? $0 : nil }
            // The terminal's saved native transcript remains readable after
            // its agent exits. Do not drop an answer typed at that boundary.
            guard let panelID = live?.panelID ?? record.operation.worktreeSession?.panelID ?? record.operation.taskSpace?.panelID,
                  case .terminal? = workspace.allPanelsByID[panelID] else { continue }
            bindings.append((taskID, panelID, live?.sessionID))
        }
        // Separate read demand preserves the coordinator's local input scope.
        conversations.setTaskPanelIDs(Set(bindings.map(\.panelID)))
        for (taskID, panelID, sessionID) in bindings {
            guard let conversationID = conversations.conversationID(for: panelID) else { continue }
            if taskConversations[taskID] != conversationID {
                taskConversations[taskID] = conversationID
                taskCursors[taskID] = nil
            }
            for pageNumber in 0..<20 {
                switch conversations.events(for: conversationID, after: taskCursors[taskID], limit: 500) {
                case .page(let page):
                    var saved = true
                    for event in page.events {
                        let entry: CoordinatorEvent?
                        switch event.payload {
                        case .userMessage(let message):
                            let raw = message.text.replacing(#/^Review note on packet v[0-9]+: /#, with: "")
                                .replacing(#/^Answer from the task card: /#, with: "")
                            if let ask = CoordinatorTaskAsk(message: raw), ask.taskID == taskID, let id = ask.replyID {
                                entry = CoordinatorEvent(id: id, at: event.timestamp, kind: .reply, taskID: taskID,
                                    text: ask.text, sessionID: sessionID, threadRole: .userTask,
                                    questionID: ask.questionID, sourceID: "reply:\(id.uuidString)")
                            } else if raw == message.text, CoordinatorTaskAsk(message: raw) == nil,
                                      message.text.hasPrefix(TaskCoordinator.watchMessagePrefix) == false,
                                      let questionID = Self.openQuestionID(taskID: taskID, before: event.timestamp, in: events) {
                                // Later input to the task answers its question: the user
                                // typing in its terminal, the coordinator relaying the
                                // user's words, or a Merge or start-work prompt the user
                                // asked for. Chat sends carry a prefix and are saved when
                                // sent; watch notices come without the user.
                                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                                entry = text.isEmpty ? nil : CoordinatorEvent(at: event.timestamp, kind: .reply, taskID: taskID,
                                    text: String(text.prefix(CoordinatorEvent.maximumTextLength)), sessionID: sessionID,
                                    threadRole: .userTask, questionID: questionID,
                                    sourceID: "task:\(taskID.uuidString):\(event.eventID)")
                            } else { entry = nil }
                        default: entry = nil
                        }
                        if let entry, !save(entry) { saved = false; break }
                    }
                    guard saved else { return }
                    guard let last = page.events.last else { break }
                    taskCursors[taskID] = ConversationEventCursor(projectionRunID: page.projectionRunID,
                        projectionGeneration: page.projectionGeneration, afterSequence: last.sequence)
                    if last.sequence < page.latestSequence {
                        if pageNumber == 19 { refreshAgain = true }
                        continue
                    }
                case .resnapshotRequired:
                    taskCursors[taskID] = nil
                    if pageNumber == 19 { refreshAgain = true }
                    continue
                case .invalidRequest:
                    taskCursors[taskID] = nil
                    if pageNumber == 0 { continue }
                case .conversationNotFound: break
                }
                break
            }
        }
    }

    // MARK: - Payload

    private func buildPayload(events: [CoordinatorEvent]) async -> CoordinatorChatPayload {
        let items = taskCoordinator.board?.items() ?? []
        var itemsByTaskID: [UUID: TaskBoardItem] = [:]
        for item in items { if let id = item.taskID { itemsByTaskID[id] = item } }
        let stuckItems = items.filter { $0.stage == .needsYou(.agentError) }
        let taskIDs = Set(events.compactMap(\.taskID)).union(stuckItems.compactMap(\.taskID))
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
        var cards = CoordinatorChatTimeline.cards(events: events, packets: stamps)
        // A failed agent needs a card even if the coordinator never posted
        // one. Its live status time also brings an existing card forward.
        for item in stuckItems {
            guard let taskID = item.taskID else { continue }
            if let index = cards.firstIndex(where: { $0.taskID == taskID }) {
                cards[index].at = max(cards[index].at, item.activityAt)
            } else {
                cards.append(.init(id: "stuck-\(taskID.uuidString)", at: item.activityAt, kind: .taskStarted,
                                   taskID: taskID, text: nil, packetVersion: stamps[taskID]?.last?.version,
                                   packetVersions: (stamps[taskID] ?? []).map(\.version), isCurrent: true))
            }
        }
        // Explicit task replies are shown once in their task thread. Unscoped
        // messages stay in the coordinator transcript.
        var chatItems = transcript.items.filter { line in
            guard let id = line.aboutTaskID.flatMap(UUID.init(uuidString:)) else { return true }
            return !taskIDs.contains(id)
        }.map { CoordinatorChatItem.transcript($0) }
        for card in cards {
            let record = card.taskID.flatMap { taskCoordinator.records.record(id: $0) }
            var task = card.taskID.map { taskID in
                CoordinatorChatTaskView.make(
                    taskID: taskID,
                    record: record,
                    item: itemsByTaskID[taskID],
                    stale: staleByTaskID[taskID] ?? false,
                    config: config,
                    homeDirectoryPath: taskCoordinator.homeDirectoryPath
                )
            }
            if card.taskID != nil, let record {
                if itemsByTaskID[record.id]?.stage == .needsYou(.agentError) {
                    let status = taskCoordinator.liveAgentSession(of: record)?.status
                    let failure = status?.kind == .error
                        ? status?.detail ?? status?.summary
                        : "The agent stopped with an error. Open the task space to inspect its output."
                    task?.failureText = failure.map { String($0.prefix(CoordinatorEvent.maximumTextLength)) }
                }
            }
            let packetView = card.taskID.flatMap { taskID in
                card.packetVersion.flatMap { version in
                    packet(taskID: taskID, version: version).map {
                        CoordinatorChatPacketView(packet: $0, taskID: taskID, latestVersion: stamps[taskID]?.last?.version ?? version)
                    }
                }
            }
            var view = CoordinatorChatCardView(card: card, task: task, packet: packetView)
            if card.kind == .question, card.answer == nil, UUID(uuidString: card.id).map(uncertainQuestions.contains) == true {
                view.answerPending = true
            }
            chatItems.append(.card(view))
        }
        // `sort` is not stable; equal times keep transcript, then timeline order,
        // so a refresh cannot swap them.
        chatItems = chatItems.enumerated().sorted {
            $0.element.at == $1.element.at ? $0.offset < $1.offset : $0.element.at < $1.element.at
        }.map(\.element)
        let board = taskCoordinator.board
        let isTriageConfigured = taskCoordinator.isTriageConfigured
        let cardsByTaskID = CoordinatorChatCardIndex.tasks(from: chatItems)
        let today = CoordinatorAllTasks.today(items, now: now())
        let todayIDs = Set(today.completed.map(\.rowID))
        let shownIDs = Set(CoordinatorAllTasks.shownItems(items).map(\.id))
        let rows = CoordinatorAllTasks.rows(
            items.filter { shownIDs.contains($0.id) || todayIDs.contains(CoordinatorAllTasks.rowID($0)) },
            cards: { cardsByTaskID[$0] },
            canRelease: { board?.canRelease($0) ?? false },
            isTriageConfigured: isTriageConfigured,
            mergePolicy: { [taskCoordinator] item in
                CoordinatorChatTaskView.mergePolicy(record: item.record, config: config, homeDirectoryPath: taskCoordinator.homeDirectoryPath)
            }
        )
        let projects = CoordinatorAllTasks.projects(items)
        let fallbackProjects = composerProjects().map {
            CoordinatorAllTasks.Project(id: $0.root, title: $0.name, rootPath: $0.root)
        }
        let routeValues = Set(chatItems.flatMap { item -> [String] in
            guard case .card(let card) = item, card.task == nil, card.kind == "question" else { return [] }
            return card.options
        })
        let routeProjects = routeValues.sorted().compactMap {
            CoordinatorChatPayload.RouteProject.make(value: $0, projects: projects,
                fallbackProjects: fallbackProjects, homeDirectoryPath: taskCoordinator.homeDirectoryPath)
        }
        return CoordinatorChatPayload(
            coordinator: coordinatorView(items: items),
            items: chatItems,
            focus: focus.map { .init(taskID: $0.taskID.uuidString, token: $0.token, cardID: Self.questionCardID(taskID: $0.taskID, in: chatItems)) },
            notice: notice.map { .init(text: $0.text, isError: $0.isError, token: $0.token) },
            ack: ack.map { .init(token: $0.token, ok: $0.ok) },
            view: viewRequest.map { .init(view: $0.view, filter: $0.filter, token: $0.token) },
            taskGroups: CoordinatorAllTasks.groups(items),
            tasks: rows,
            projects: projects,
            routeProjects: routeProjects,
            projectFilter: windowID(for: nil).flatMap { projectFilters[$0] },
            today: today,
            addresses: composerAddresses(),
            hasUserRequests: transcript.hasUserRequests
        )
    }

    private func composerProjects() -> [(name: String, root: String, workspaceID: UUID?)] {
        let choices = taskCoordinator.workspaceChoices()
        var seen: Set<String> = []
        let projects = choices.open.compactMap { choice -> (String, String, UUID?)? in
            choice.rootDirectory.map { (choice.title, $0, choice.id) }
        } + choices.recent.map { ($0.title, $0.rootDirectory, nil) }
        return projects.compactMap { name, path, id in
            let root = TasksConfigFile.normalizedPath(path, homeDirectoryPath: taskCoordinator.homeDirectoryPath)
            return seen.insert(root).inserted ? (name, root, id) : nil
        }
    }

    private func composerAddresses() -> [CoordinatorComposerAddress] {
        let tasks = taskCoordinator.records.records.map {
            CoordinatorComposerAddress(kind: "task", id: $0.id.uuidString, token: $0.slug, title: $0.title, version: $0.packetVersion)
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return tasks + composerProjects().map {
            CoordinatorComposerAddress(kind: "project", id: $0.root,
                token: URL(filePath: $0.root).lastPathComponent.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.name,
                title: $0.name, version: nil)
        }
    }

    /// The task's newest question posted before `date`, when no reply
    /// answers it yet. Equal times go to the later line.
    static func openQuestionID(taskID: UUID, before date: Date, in events: [CoordinatorEvent]) -> UUID? {
        var newest: CoordinatorEvent?
        for event in events where event.kind == .question && event.taskID == taskID
            && event.at <= date && event.at >= (newest?.at ?? .distantPast) {
            newest = event
        }
        guard let question = newest else { return nil }
        let answered = events.contains {
            $0.kind == .reply && $0.questionID == question.id && $0.taskID == taskID
                && ($0.threadRole == .userTask || $0.threadRole == .userCoordinator)
        }
        return answered ? nil : question.id
    }

    /// The task's newest card, when it is a question.
    static func questionCardID(taskID: UUID, in items: [CoordinatorChatItem]) -> String? {
        let newest = items.last { item in
            if case .card(let card) = item { return card.task?.id == taskID.uuidString }
            return false
        }
        guard case .card(let card)? = newest, card.kind == CoordinatorEvent.Kind.question.rawValue else { return nil }
        return card.id
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

    private func coordinatorView(items: [TaskBoardItem]) -> CoordinatorChatPayload.Coordinator {
        let snapshot = conversationSnapshot()
        let (canSend, hint) = Self.sendState(status: session.status, snapshot: snapshot)
        var detail: String
        switch session.status {
        case .off: detail = "Off. Set [coordinator] agent in tasks.toml, then Reload Configuration."
        case .waitingForWindow: detail = "Waiting for a window"
        case .waitingForRestore: detail = "Resuming its last session"
        case .starting: detail = "Starting"
        case .running:
            let agent = snapshot?.summary.provider.displayName ?? session.agentDisplayName
            let model = snapshot?.summary.executionProfile?.modelIdentifier ?? session.configuredModel ?? "default model"
            let active = items.filter { $0.stage.group != .done && $0.stage.group != .archived }
            let count = active.count
            let projects = CoordinatorAllTasks.projects(active).count
            detail = "\(agent) · \(model) · \(count) \(count == 1 ? "task" : "tasks") in \(projects) \(projects == 1 ? "project" : "projects")"
        case .failed(let reason): detail = "Stopped: \(reason)"
        }
        // The task board reads tasks.toml again each time the chat opens; an
        // error there matters more than the coordinator's own state.
        if let configError = taskCoordinator.board?.configError {
            detail = "tasks.toml: \(configError)"
        }
        let working = Self.isWorking(status: session.status, snapshot: snapshot)
        return .init(title: "Coordinator", detail: detail, canSend: canSend, sendHint: hint, hasTerminal: session.workspaceID != nil,
                     working: working, turnStartedAt: working ? snapshot?.summary.turnStartedAt : nil)
    }

    /// Whether the coordinator's turn runs: the state its sidebar row shows,
    /// else the provider's own state.
    static func isWorking(status: CoordinatorSessionController.Status, snapshot: RemoteConversationSnapshot?) -> Bool {
        guard case .running = status, let summary = snapshot?.summary else { return false }
        if let presentation = summary.presentationStatus { return presentation == .working }
        return summary.state == .working
    }

    private func conversationSnapshot() -> RemoteConversationSnapshot? {
        guard let conversations, let panelID = session.panelID,
              let conversationID = conversations.conversationID(for: panelID) else { return nil }
        return conversations.localSnapshot(for: conversationID, at: now())
    }

    /// What the composer says before the agent can take its first message.
    /// The agent may be at a setup prompt in its hidden terminal, most often
    /// folder trust on a first start, and nothing else shows that.
    static let startingHint = "The coordinator is starting. If its terminal asks whether to trust the folder, answer there."

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
            return (false, startingHint)
        case .unavailable where snapshot.summary.state == .starting:
            // Bound to a session, but the provider has reported nothing yet,
            // as while it waits at folder trust.
            return (false, startingHint)
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
            if page?.isSummary != true { expandedCardIDs = expanded }
            // Background renders from the other surface do not change the
            // command palette's target. Tests without a page keep this path.
            if page == nil { pageView = view }
            if view == .tasks { selectedTaskRowID = selectedRowID }
            updateCardIndex()
            return
        case .projectFilter(let project):
            guard project == nil || lastPayload?.projects.contains(where: { $0.id == project }) == true,
                  let windowID = windowID(for: page) else { return }
            projectFilters[windowID] = project
            focus = nil
            if var request = viewRequest {
                request.filter = nil
                viewRequest = request
            }
        case .showView(let view):
            guard page?.isSummary == true else { return }
            tokenCounter += 1
            viewRequest = (view, nil, tokenCounter)
            pageView = view
        case .activate(let view, let selected):
            guard page == nil || page?.isSummary == (view != .chat) else { return }
            pageView = view
            if view == .tasks { selectedTaskRowID = selected }
            updateCardIndex()
            return
        case .taskAction(let rowID, let actionID):
            runTaskAction(rowID: rowID, actionID: actionID, page: page)
        case .send(let text):
            acknowledge(token, ok: await sendToCoordinator(text) != .failed)
        case .project(let id, let text):
            guard let project = composerProjects().first(where: { $0.root == id }) else {
                setNotice("That project is no longer available. Pick it again before sending.", isError: true)
                acknowledge(token, ok: false)
                break
            }
            let request = CoordinatorProjectRequest(projectName: project.name, projectRoot: project.root, workspaceID: project.workspaceID, text: text)
            acknowledge(token, ok: await sendToCoordinator(request.message) != .failed)
        case .ask(let taskID, let version, let text, let cardID, let questionID):
            acknowledge(token, ok: await sendCardReply(taskID: taskID, version: version, text: text, cardID: cardID, questionID: questionID, toTask: false))
        case .answerRoute(let questionID, let optionIndex):
            acknowledge(token, ok: await answerRoute(questionID: questionID, optionIndex: optionIndex))
        case .archiveTask(let taskID):
            guard let item = taskCoordinator.board?.items().first(where: { $0.taskID == taskID }),
                  item.stage == .needsYou(.agentError), TaskBoardPresentation.detailActions(item).contains(.archive) else {
                setNotice("That task is no longer stuck or cannot be archived.", isError: true)
                break
            }
            TaskActions.archive(taskID: taskID, coordinator: taskCoordinator)
        case .taskMenu(let taskID, let rect):
            guard let item = taskCoordinator.board?.items().first(where: { $0.taskID == taskID }) else {
                setNotice("That task no longer has a menu.", isError: true)
                break
            }
            let sections = TaskBoardPresentation.menuItems(item, isTriageConfigured: taskCoordinator.isTriageConfigured)
            if page?.showTaskMenu(sections: sections, rect: rect, run: { [weak self] item in
                guard let self else { return }
                TaskActions.runFromMenu(item, coordinator: self.taskCoordinator) { self.openWorkspace($0) }
                self.setNeedsRefresh()
            }) != true {
                setNotice("The task menu could not open.", isError: true)
            }
        case .merge(let taskID):
            if perform("Merge", { try TaskActions.run(.merge, taskID: taskID, coordinator: taskCoordinator) }) != nil {
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
        if pageView == .today { return nil }
        if pageView == .tasks {
            return lastPayload?.tasks.first { $0.id == selectedTaskRowID }?.taskID.flatMap(UUID.init(uuidString:))
        }
        return openCardTaskID
    }

    /// The task of the card the page opened last, in the chat.
    private var openCardTaskID: UUID? {
        let cards = (lastPayload?.items ?? []).compactMap { item -> CoordinatorChatCardView? in
            if case .card(let card) = item { return card }
            return nil
        }
        for cardID in expandedCardIDs.reversed() {
            if let id = cards.first(where: { $0.id == cardID })?.task?.id { return UUID(uuidString: id) }
        }
        return nil
    }

    private func updateCardIndex() {
        cardIndex.update(
            tasks: CoordinatorChatCardIndex.tasks(from: lastPayload?.items ?? []),
            openTaskID: pageView == .chat ? openCardTaskID : nil
        )
    }

    /// Whether the chat has a card for the task: one the coordinator posted,
    /// or a packet card the chat adds for a task that has one.
    func hasCards(taskID: UUID) -> Bool {
        // Failed sessions can have a current card before the coordinator
        // posts an event. Summary navigation must open that card too.
        cardIndex.tasks[taskID] != nil || session.files.events().contains { $0.taskID == taskID }
    }

    /// `coordinator.chat.state`, for automation and checks.
    func stateSnapshot() -> [String: AutomationJSONValue] {
        func optional(_ value: String?) -> AutomationJSONValue { value.map(AutomationJSONValue.string) ?? .null }
        let inputState: String
        switch conversationSnapshot()?.summary.inputAvailability {
        case .openPrompt?: inputState = "openPrompt"
        case .unavailable(reason: .working)?: inputState = "working"
        case .pendingInteraction?: inputState = "interaction"
        case .localDraft?: inputState = "draft"
        default: inputState = "unavailable"
        }
        let items: [AutomationJSONValue] = (lastPayload?.items ?? []).map { item in
            switch item {
            case .transcript(let line):
                return .object([
                    "type": .string(line.type.rawValue),
                    "id": .string(line.id),
                    "at": .string(line.at.ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))),
                    "text": optional(line.text ?? line.name),
                    "role": optional(line.role),
                    "aboutTaskID": optional(line.aboutTaskID),
                ])
            case .card(let card):
                return .object([
                    "type": .string("card"),
                    "id": .string(card.id),
                    "at": .string(card.at.ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))),
                    "kind": .string(card.kind),
                    "taskID": optional(card.task?.id),
                    "packetVersion": card.packet.map { .int($0.version) } ?? .null,
                    "superseded": .bool(card.superseded),
                    "isNew": .bool(card.isNew),
                    "isCurrent": .bool(card.isCurrent),
                    "options": .array(card.options.map(AutomationJSONValue.string)),
                    "answer": optional(card.answer),
                    "answerPending": .bool(card.answerPending),
                    "answeredQuestionIDs": .array(card.answeredQuestionIDs.map { .string($0.uuidString) }),
                    "packetVersions": .array(card.packetVersions.map(AutomationJSONValue.int)),
                    "failureText": optional(card.task?.failureText),
                    "canArchive": .bool(card.task?.canArchive ?? false),
                    "thread": .array(card.thread.map { entry in .object([
                        "id": .string(entry.id), "at": .string(entry.at.ISO8601Format()),
                        "role": .string(entry.role.rawValue), "text": .string(entry.text),
                    ]) }),
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
            "sendHint": optional(lastPayload?.coordinator.sendHint),
            "inputState": .string(inputState),
            "working": .bool(lastPayload?.coordinator.working ?? false),
            "hasUserRequests": .bool(lastPayload?.hasUserRequests ?? false),
            "items": .array(items),
            "expandedCardIDs": .array(expandedCardIDs.map(AutomationJSONValue.string)),
            "currentTaskID": optional(currentTaskID?.uuidString),
            "view": .string(pageView.rawValue),
            "selectedRowID": optional(selectedTaskRowID),
            "projectFilter": optional(windowID(for: nil).flatMap { projectFilters[$0] }),
            "projects": .array((lastPayload?.projects ?? []).map { .object(["id": .string($0.id), "title": .string($0.title)]) }),
            "detail": .string(lastPayload?.coordinator.detail ?? ""),
            "today": .array((lastPayload?.today.completed ?? []).map { .object(["rowID": .string($0.rowID), "kind": .string($0.kind)]) }),
            "tasks": .array((lastPayload?.tasks ?? []).map { row in
                .object([
                    "id": .string(row.id),
                    "taskID": optional(row.taskID),
                    "title": .string(row.title),
                    "project": optional(row.project),
                    "projectID": optional(row.projectID),
                    "group": .string(row.group),
                    "stage": .string(row.stageLabel),
                    "hasCard": .bool(row.hasCard),
                    "primary": optional(row.primary?.id),
                    "confirm": optional(row.confirm),
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

    enum SendOutcome { case accepted, uncertain, failed }

    @discardableResult
    private func sendToCoordinator(_ text: String) async -> SendOutcome {
        if let deliverToCoordinator { return await deliverToCoordinator(text) }
        guard let conversations, let panelID = session.panelID,
              let conversationID = conversations.conversationID(for: panelID),
              let snapshot = conversations.localSnapshot(for: conversationID, at: now()) else {
            setNotice("The coordinator is not running.", isError: true)
            return .failed
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
                return .failed
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
            return .accepted
        case .queued:
            setNotice("Queued: the coordinator gets it when its turn ends.", isError: false)
            return .accepted
        case .rejected(let reason):
            setNotice("The coordinator did not take the message (\(reason.rawValue)).", isError: true)
            return .failed
        case .uncertain:
            // The text may be in the terminal; keeping the draft would invite
            // a second copy.
            setNotice("The message may not have reached the coordinator. Check its terminal.", isError: true)
            return .uncertain
        }
    }

    static func routeQuestion(id: UUID, in events: [CoordinatorEvent]) -> CoordinatorEvent? {
        events.first { $0.id == id && $0.kind == .question && $0.taskID == nil && !$0.options.isEmpty }
    }

    /// A rejected attempt can be tried again. An accepted or uncertain one
    /// must not start the same task twice, including after an app relaunch.
    static func canAnswerRoute(questionID: UUID, in events: [CoordinatorEvent]) -> Bool {
        guard let question = routeQuestion(id: questionID, in: events) else { return false }
        var attempts: [UUID: CoordinatorEvent.Delivery] = [:]
        let rank: [CoordinatorEvent.Delivery: Int] = [.pending: 0, .rejected: 1, .accepted: 2]
        for event in events where event.kind == .reply && event.taskID == nil && event.questionID == questionID
            && event.threadRole == .userCoordinator && event.text.map(question.options.contains) == true {
            let delivery = event.delivery ?? .accepted
            if (rank[delivery] ?? 0) > (attempts[event.id].flatMap { rank[$0] } ?? -1) { attempts[event.id] = delivery }
        }
        return !attempts.values.contains { $0 == .accepted || $0 == .pending }
    }

    static func routeReply(_ answer: CoordinatorRouteAnswer, at: Date, delivery: CoordinatorEvent.Delivery) -> CoordinatorEvent {
        CoordinatorEvent(id: answer.replyID, at: at, kind: .reply, taskID: nil, text: answer.answer, sessionID: nil,
                         threadRole: .userCoordinator, questionID: answer.questionID,
                         sourceID: "route-\(delivery.rawValue):\(answer.replyID.uuidString)", delivery: delivery)
    }

    private func answerRoute(questionID: UUID, optionIndex: Int) async -> Bool {
        let events = session.files.events() + unsavedThreadReplies
        guard let question = Self.routeQuestion(id: questionID, in: events), let questionText = question.text,
              question.options.indices.contains(optionIndex),
              Self.canAnswerRoute(questionID: questionID, in: events),
              inFlightQuestions.insert(questionID).inserted else {
            setNotice("That project question was answered or is waiting for delivery confirmation.", isError: true)
            return false
        }
        defer { inFlightQuestions.remove(questionID) }
        let answer = CoordinatorRouteAnswer(questionID: questionID, replyID: UUID(), question: questionText,
                                            answer: question.options[optionIndex])
        guard CoordinatorRouteAnswer(message: answer.message) == answer else {
            setNotice("This project question is too long to answer. Ask the coordinator to shorten it.", isError: true)
            return false
        }
        // Save before sending. If this fails, no message leaves the app.
        do { try session.files.append(Self.routeReply(answer, at: now(), delivery: .pending)) }
        catch {
            setNotice("The project choice could not be saved: \(error.localizedDescription)", isError: true)
            return false
        }
        let outcome = await sendToCoordinator(answer.message)
        if outcome == .uncertain { return true }
        let reply = Self.routeReply(answer, at: now(), delivery: outcome == .failed ? .rejected : .accepted)
        if session.files.events().contains(where: { $0.sourceID == reply.sourceID }) { return outcome != .failed }
        do { try session.files.append(reply) }
        catch {
            unsavedThreadReplies.append(reply)
            setNotice("The project choice's delivery state could not be saved: \(error.localizedDescription)", isError: true)
        }
        return outcome != .failed
    }

    /// Validates the exact card and question again before delivery. A task's
    /// live attention is independent of the answer stored in the chat.
    private func sendCardReply(taskID: UUID, version: Int?, text: String, cardID: String?, questionID: UUID?, toTask: Bool) async -> Bool {
        guard let record = taskCoordinator.records.record(id: taskID) else {
            setNotice("That task is no longer available. Pick it again before sending.", isError: true)
            return false
        }
        // A composer question can refer to a known closed task. Card actions
        // and direct task replies keep their existing open-task requirement.
        let boardItem = taskCoordinator.board?.items().first(where: { $0.taskID == taskID })
        if (toTask || cardID != nil), boardItem?.stage.isFinished == true {
            setNotice("That task is no longer open.", isError: true)
            return false
        }
        // The coordinator passes a card reply on to the task's agent, so the
        // task needs its task space, as the card's canReply says.
        if cardID != nil, boardItem?.taskSpaceWorkspaceID == nil {
            setNotice("The task cannot take replies now.", isError: true)
            return false
        }
        let events = session.files.events() + unsavedThreadReplies
        let normalizedCardID = cardID.map { UUID(uuidString: $0)?.uuidString ?? $0 }
        if let cardID = normalizedCardID {
            let isStoredCard = events.contains {
                $0.id.uuidString == cardID && $0.taskID == taskID && ($0.kind != .reply || $0.canAnchorTaskCard)
            }
            let isPacketCard = lastPayload?.items.contains { item in
                guard case .card(let card) = item else { return false }
                return card.id == cardID && card.task?.id == taskID.uuidString
            } ?? false
            let isEarlierPacket = version.map { version in
                cardID == "packet-\(taskID.uuidString)-v\(version)" && taskCoordinator.packets.versions(taskID: taskID).contains(version)
            } ?? false
            let isRecoveredErrorCard = cardID == "stuck-\(taskID.uuidString)"
            guard isStoredCard || isPacketCard || isEarlierPacket || isRecoveredErrorCard else {
                setNotice("That card no longer belongs to this task.", isError: true)
                return false
            }
        }
        if let questionID {
            guard normalizedCardID == questionID.uuidString,
                  events.contains(where: { $0.id == questionID && $0.kind == .question && $0.taskID == taskID }),
                  !events.contains(where: { $0.kind == .reply && $0.questionID == questionID && $0.taskID == taskID && ($0.threadRole == .userTask || $0.threadRole == .userCoordinator) }),
                  !inFlightQuestions.contains(questionID), !uncertainQuestions.contains(questionID) else {
                setNotice("That question was already answered or changed.", isError: true)
                return false
            }
            inFlightQuestions.insert(questionID)
        }
        defer { if let questionID { inFlightQuestions.remove(questionID) } }
        let replyID = UUID()
        let ask = CoordinatorTaskAsk(taskID: taskID, title: record.title, packetVersion: version, text: text, replyID: replyID, questionID: questionID)
        let accepted: Bool
        if toTask {
            // Only report marks go straight to the task, as a packet note.
            let message = version.map { "Review note on packet v\($0): \(text)" } ?? text
            accepted = perform("Reply", { try taskCoordinator.send(taskID: taskID, text: message) }) != nil
            if accepted {
                try? taskCoordinator.saveMergeState(taskID: taskID) { $0.readyForReviewAt = nil }
                setNotice("Sent to \(record.slug).", isError: false)
            }
        } else {
            let outcome = await sendToCoordinator(ask.message)
            accepted = outcome != .failed
            // Keep the question open until the provider confirms receipt.
            // Its envelope echo carries both references and saves the reply.
            if outcome == .uncertain {
                if let questionID { uncertainQuestions.insert(questionID) }
                if cardID != nil, let version { uncertainReviewReplies[replyID] = (taskID, version) }
                return true
            }
            // A reply on a packet card answers the review, as a direct
            // reply to the task did. The coordinator passes it on.
            if accepted, cardID != nil, version != nil {
                try? taskCoordinator.saveMergeState(taskID: taskID) { $0.readyForReviewAt = nil }
            }
        }
        guard accepted else { return false }
        let event = CoordinatorEvent(id: replyID, at: now(), kind: .reply, taskID: taskID, text: text, sessionID: nil,
                                     threadRole: toTask ? .userTask : .userCoordinator, questionID: questionID,
                                     sourceID: "reply:\(replyID.uuidString)")
        do { try session.files.append(event) }
        catch {
            unsavedThreadReplies.append(event)
            setNotice("The message was sent, but its history could not be saved: \(error.localizedDescription)", isError: true)
        }
        // A delivered message must not remain as a sendable draft, even if
        // disk persistence failed. Its explicit transcript echo can recover it.
        return true
    }

    /// The report bridge supplies structured marks. Only stored screenshot
    /// names from this packet can become a versioned task reply.
    func sendReportMarks(taskID: UUID, version: Int, marks: [CoordinatorReportMark]) async -> CoordinatorReportSendResult {
        guard let record = taskCoordinator.records.record(id: taskID), record.archivedAt == nil, record.doneAt == nil,
              taskCoordinator.board?.items().first(where: { $0.taskID == taskID })?.stage.isFinished != true,
              let packet = packet(taskID: taskID, version: version),
              let text = CoordinatorReportMark.message(marks, screenshotNames: Set(packet.screenshots.map(\.name))) else { return .rejected }
        guard await sendCardReply(taskID: taskID, version: version, text: text, cardID: nil, questionID: nil, toTask: true) else { return .unconfirmed }
        _ = show(taskID: taskID)
        setNeedsRefresh()
        return .sent
    }

    /// Runs an All tasks row's action. The row may be older than the task:
    /// an action the task no longer offers does nothing, and says so.
    private func runTaskAction(rowID: String, actionID: String, page: (any Page)?) {
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
        case .setup(let taskID):
            if page?.showSetup(taskID: taskID, coordinator: taskCoordinator) != true {
                setNotice("Open All tasks to see this task's setup controls.", isError: true)
            }
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
               if case .web(let web) = $0.panelState { return web.definition == .browser && web.restorableURL?.hasPrefix(reusingPrefix) == true }
               return false
           }) {
            // A mounted browser can still report its old URL while SwiftUI
            // applies metadata. Navigate the existing runtime directly, as
            // the address field does, before selecting the report tab.
            if case .web(let web) = tab.panelState, web.restorableURL != url {
                if let loadURLInPanel {
                    guard loadURLInPanel(tab.panelID, url) else {
                        setNotice("The report could not open in its browser tab.", isError: true)
                        return
                    }
                } else {
                    // Model-only controllers used by tests have no browser.
                    _ = store.send(.updateWebPanelMetadata(panelID: tab.panelID, title: nil, url: url))
                }
            }
            _ = store.send(.selectRightAuxPanelTab(workspaceID: workspaceID, tabID: tab.id, focus: true))
            return
        }
        _ = store.createBrowserPanel(
            workspaceID: workspaceID,
            request: BrowserPanelCreateRequest(initialURL: url, placementOverride: .rightPanel)
        )
    }

    /// One live summary tab beside the chat. Ordinary chat navigation does
    /// not select it over a report the user is reading.
    private func ensureSummary(showsTasks: Bool) {
        guard let workspaceID = session.workspaceID, let workspace = store.state.workspacesByID[workspaceID] else { return }
        if let tab = workspace.rightAuxPanel.orderedTabs.first(where: {
            guard case .web(let web) = $0.panelState, let url = web.restorableURL.flatMap(URL.init(string:)) else { return false }
            return CoordinatorSummaryPageBridge.isSummaryURL(url)
        }) {
            if showsTasks { _ = store.send(.selectRightAuxPanelTab(workspaceID: workspaceID, tabID: tab.id, focus: true)) }
            return
        }
        _ = store.createBrowserPanel(
            workspaceID: workspaceID,
            request: BrowserPanelCreateRequest(initialURL: "toastty://coordinator/\(showsTasks ? "tasks" : "today")", placementOverride: .rightPanel)
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

extension CoordinatorChatController.Page {
    var windowID: UUID? { nil }
    var isSummary: Bool { false }
    func inspection() async -> [String: AutomationJSONValue] { [:] }
    func showTaskMenu(sections: [[TaskBoardPresentation.MenuItem]], rect: CGRect, run: @escaping (TaskBoardPresentation.MenuItem) -> Void) -> Bool { false }
}

// MARK: - Report data

extension CoordinatorChatController: ToasttyCoordinatorPageDataSource {
    func packetReportJSON(taskID: UUID, version: Int) -> Data? {
        guard let packet = packet(taskID: taskID, version: version) else { return nil }
        let record = taskCoordinator.records.record(id: taskID)
        let view = CoordinatorChatPacketView(packet: packet, taskID: taskID, latestVersion: record?.packetVersion ?? version)
        let report = CoordinatorChatReport(
            taskID: taskID.uuidString,
            slug: record?.slug ?? "the task",
            canAnnotate: record != nil && record?.archivedAt == nil && record?.doneAt == nil,
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
