import Combine
import CoreState
import Foundation

/// One task on the board: a task with a record, or a task space without one
/// that Toastty only watches until someone adopts it.
struct TaskBoardItem: Identifiable, Equatable {
    enum Subject: Hashable {
        case task(UUID)
        case taskSpace(UUID)
    }

    let id: Subject
    var record: TaskRecord?
    var title: String
    /// The task space while it is open.
    var taskSpaceWorkspaceID: UUID?
    /// The top-level workspace the task belongs to, while it is open.
    var projectWorkspaceID: UUID?
    var projectTitle: String?
    var stage: TaskStage
    var agent: TaskAgentActivity
    /// A finished turn the user has not looked at yet, as the sidebar marks.
    var hasUnreadTurn = false
    /// The task this one's agent waits on through a pending watch.
    var waitingOnTitle: String?
    var pullRequest: WorkspacePullRequestLink?
    var pullRequestState: TaskPullRequestState?
    var branch: String?
    var parentTaskID: UUID?
    /// An accepted merge that is still under way.
    var merge: TaskMergeActivity?
    /// The latest change Toastty knows of, for ordering within a group.
    var activityAt: Date

    var taskID: UUID? { record?.id }
}

/// Builds the board from what Toastty already holds: task records, the
/// workspace tree, live session statuses, and cached pull request answers.
/// Nothing here runs `gh` or `git`.
@MainActor
enum TaskBoard {
    struct Inputs {
        var state: AppState
        var records: [TaskRecord]
        var statuses: (UUID) -> [WorkspaceSessionStatus]
        var pullRequestState: (WorkspacePullRequestLink) -> TaskPullRequestState?
        var config: TasksConfig?
        var homeDirectory: String = NSHomeDirectory()
        var sessionRegistry = SessionRegistry()
        /// The merge Toastty runs for a task space, if any.
        var mergeRequest: (UUID) -> WorkspaceMergeRequest? = { _ in nil }
    }

    static func items(_ inputs: Inputs) -> [TaskBoardItem] {
        let state = inputs.state
        let recordsByID = Dictionary(inputs.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var items = inputs.records.map { record in
            item(for: record, inputs: inputs)
        }
        // Task spaces without a record, and those whose record is gone.
        for (workspaceID, parentID) in state.subspaceParentIDsByWorkspaceID() {
            guard let workspace = state.workspacesByID[workspaceID] else { continue }
            if let taskID = workspace.taskID, recordsByID[taskID] != nil { continue }
            items.append(observedItem(workspace: workspace, parentID: parentID, inputs: inputs))
        }
        return items.sorted { lhs, rhs in
            lhs.activityAt != rhs.activityAt ? lhs.activityAt > rhs.activityAt : lhs.title < rhs.title
        }
    }

    /// The items a window's sidebar shows: those whose task space, or else
    /// whose project, is in the window. A task with neither open anywhere
    /// shows in every window.
    static func items(_ items: [TaskBoardItem], in windowID: UUID, state: AppState) -> [TaskBoardItem] {
        guard let window = state.windows.first(where: { $0.id == windowID }) else { return [] }
        let here = Set(window.workspaceIDs)
        let anywhere = Set(state.windows.flatMap(\.workspaceIDs))
        return items.filter { item in
            if let taskSpace = item.taskSpaceWorkspaceID, anywhere.contains(taskSpace) {
                return here.contains(taskSpace)
            }
            if let project = item.projectWorkspaceID, anywhere.contains(project) {
                return here.contains(project)
            }
            return true
        }
    }

    /// The item for one open task space: its task's, or a watched one's.
    static func item(taskSpace workspace: WorkspaceState, record: TaskRecord?, inputs: Inputs) -> TaskBoardItem {
        if let record {
            return item(for: record, inputs: inputs)
        }
        return observedItem(workspace: workspace, parentID: workspace.parentWorkspaceID ?? workspace.id, inputs: inputs)
    }

    /// Children first appear under the task that started them, so a parent
    /// can show how many of them have merged.
    static func childProgress(of taskID: UUID, items: [TaskBoardItem]) -> (merged: Int, total: Int)? {
        let children = items.filter { $0.parentTaskID == taskID && $0.stage != .archived }
        guard children.isEmpty == false else { return nil }
        let merged = children.filter { $0.stage == .toShip || $0.stage == .done }.count
        return (merged, children.count)
    }

    /// The most urgent thing a task space's agents are doing. A session that
    /// waits on its sub-agents or is resuming is working. Only a finished
    /// turn the user has not read counts as finished, as the sidebar's ready
    /// mark shows it: once the user reads it, or after a relaunch, which
    /// restores every session idle, the agent is idle.
    static func agentActivity(_ statuses: [WorkspaceSessionStatus], in workspace: WorkspaceState?) -> TaskAgentActivity {
        guard statuses.isEmpty == false else { return .none }
        let kinds = Set(statuses.map(\.status.kind))
        if kinds.contains(.needsApproval) { return .needsInput }
        if kinds.contains(.error) { return .error }
        if kinds.contains(.working) || statuses.contains(where: { $0.projection != .none }) { return .working }
        return hasUnreadTurn(statuses, in: workspace) ? .finished : .idle
    }

    /// Whether a session in the task space ended a turn whose panel is still
    /// unread.
    static func hasUnreadTurn(_ statuses: [WorkspaceSessionStatus], in workspace: WorkspaceState?) -> Bool {
        guard let workspace else { return false }
        return statuses.contains { status in
            guard status.status.kind == .ready, let tabID = workspace.tabID(containingPanelID: status.panelID) else {
                return false
            }
            return workspace.tab(id: tabID)?.unreadPanelIDs.contains(status.panelID) == true
        }
    }

    /// The title of the first task `record` waits on through a pending watch.
    /// A watch made with `--wait` holds the agent's turn open, so the agent
    /// shows as working instead and needs no entry here.
    static func waitingOnTitle(_ record: TaskRecord, records: [TaskRecord]) -> String? {
        guard let watch = record.watches?.first(where: \.isPending) else { return nil }
        return records.first { $0.id == watch.targetTaskID }?.title ?? "another task"
    }

    /// Uses the task's own pane, including a session restored there under a
    /// new ID. Stopped entries keep the name if a session exits before the
    /// board copies it. Other agents in a recorded task cannot rename it.
    static func sessionTitle(record: TaskRecord?, workspaceID: UUID?, registry: SessionRegistry) -> String? {
        guard record?.titleSetByUser != true, let workspaceID else { return nil }
        func session(panelID: UUID?, sessionID: String?) -> SessionRecord? {
            func eligible(_ candidate: SessionRecord?) -> SessionRecord? {
                guard let candidate, candidate.workspaceID == workspaceID, candidate.agent != .processWatch else { return nil }
                return candidate
            }
            if let active = panelID.flatMap({ registry.activeSession(for: $0) }).flatMap(eligible) { return active }
            // A restored session can receive a name and exit before the
            // deferred sync. Its saved task may still name the old ID.
            if let panelID, let last = registry.sessionOrder.reversed().lazy.compactMap({ registry.sessionsByID[$0] }).first(where: {
                $0.panelID == panelID && eligible($0) != nil
            }) { return last }
            return sessionID.flatMap { eligible(registry.sessionsByID[$0]) }
        }
        func title(_ owner: SessionRecord?) -> String? {
            [owner?.displayTitleOverride, owner?.providerSessionName].compactMap { value in
                value.flatMap { taskNonEmpty($0) }
            }.first
        }
        if let record {
            let owner = record.operation.worktreeSession.flatMap { session(panelID: $0.panelID, sessionID: $0.sessionID) }
                ?? session(panelID: record.operation.taskSpace?.panelID, sessionID: record.operation.agentLaunch?.sessionID)
            return title(owner)
        }
        // Older task spaces have no saved owner. Use the first named
        // agent's pane in registry order, which is stable across turns.
        return registry.sessionOrder.lazy.compactMap { registry.sessionsByID[$0] }.filter {
            $0.workspaceID == workspaceID && $0.agent != .processWatch
        }.compactMap {
            title(session(panelID: $0.panelID, sessionID: $0.sessionID))
        }.first
    }

    private static func item(for record: TaskRecord, inputs: Inputs) -> TaskBoardItem {
        let state = inputs.state
        let waitingOn = waitingOnTitle(record, records: inputs.records)
        let taskSpaceID = record.taskSpaceWorkspaceID.flatMap { state.workspacesByID[$0] == nil ? nil : $0 }
        let taskSpace = taskSpaceID.flatMap { state.workspacesByID[$0] }
        let statuses = taskSpaceID.map(inputs.statuses) ?? []
        let annotationLink = taskSpace.flatMap(pullRequestLink)
        let link = annotationLink ?? WorkspacePullRequestLink(annotationURL: record.pullRequestURL)
        let pullRequestState = link.flatMap(inputs.pullRequestState)
        let agent = agentActivity(statuses, in: taskSpace)
        let project = record.workspaceID.flatMap { state.workspacesByID[$0] }
        let root = record.projectRoot ?? project?.rootDirectory
        var facts = TaskStageFacts(record: record)
        let request = taskSpaceID.flatMap(inputs.mergeRequest)
        // While the task space is open, its done mark is the live answer;
        // the record keeps a copy for after it closes. A merge sets the mark
        // too, as the user's acceptance; that is not the work being done.
        if let taskSpace, isInMergeFlow(record, request: request) == false {
            facts.doneAt = taskSpace.doneAt
        }
        var cleanupProblem: String?
        if case .failed(let reason)? = request?.phase {
            cleanupProblem = reason
        }
        let merge = mergeActivity(
            record: record,
            request: request,
            pullRequestState: pullRequestState,
            agent: agent,
            statuses: statuses
        )
        let stage = TaskStage.derive(
            facts,
            live: TaskLiveFacts(
                taskSpaceOpen: taskSpace != nil,
                agent: agent,
                pullRequest: pullRequestState,
                hasPullRequestLink: link != nil,
                merge: merge,
                cleanupProblem: cleanupProblem,
                waitsOnTask: waitingOn != nil
            ),
            releaseTagsConfigured: releaseTagsConfigured(root: root, inputs: inputs)
        )
        let dates = [
            record.createdAt, record.readyForReviewAt, record.replyRequest?.askedAt, record.mergedAt,
            record.shippedAt, record.archivedAt, record.doneAt,
        ].compactMap { $0 } + statuses.compactMap(Self.agentActivityAt)
        return TaskBoardItem(
            id: .task(record.id),
            record: record,
            title: sessionTitle(record: record, workspaceID: taskSpaceID, registry: inputs.sessionRegistry) ?? record.title,
            taskSpaceWorkspaceID: taskSpaceID,
            projectWorkspaceID: project?.id,
            projectTitle: project?.title ?? root.map { ($0 as NSString).lastPathComponent },
            stage: stage,
            agent: agent,
            hasUnreadTurn: hasUnreadTurn(statuses, in: taskSpace),
            waitingOnTitle: waitingOn,
            pullRequest: link,
            pullRequestState: pullRequestState,
            branch: record.worktree.flatMap { $0.isDetached ? nil : $0.branch },
            parentTaskID: record.parentTaskID,
            merge: merge,
            activityAt: dates.max() ?? record.createdAt
        )
    }

    /// Whether the task's done mark records a merge's acceptance rather
    /// than finished work.
    static func isInMergeFlow(_ record: TaskRecord, request: WorkspaceMergeRequest?) -> Bool {
        record.mergeRequestedAt != nil || record.mergedAt != nil || request != nil
    }

    /// Where an accepted merge stands. The merge coordinator's request says
    /// what Toastty itself does. Before that, a task whose Merge sent the
    /// merge prompt is checking while its agent works on it, or has not yet
    /// reacted: its last status is older than the request. Once the agent
    /// reports a status after the request and is idle, the skill stopped.
    static func mergeActivity(
        record: TaskRecord,
        request: WorkspaceMergeRequest?,
        pullRequestState: TaskPullRequestState?,
        agent: TaskAgentActivity,
        statuses: [WorkspaceSessionStatus]
    ) -> TaskMergeActivity? {
        switch request?.phase {
        case .merging?, .closing?: return .merging
        case .awaitingChecks?: return .waitingForChecks
        case .awaitingMerge?, .cleaningUp?: return .cleaningUp
        case .failed?: return nil
        case nil: break
        }
        guard let requestedAt = record.mergeRequestedAt,
              record.mergedAt == nil,
              pullRequestState?.state != .merged else { return nil }
        switch agent {
        case .working:
            return .checking
        case .idle, .finished:
            let lastStatus = statuses.compactMap(\.statusUpdatedAt).max() ?? .distantPast
            return lastStatus < requestedAt ? .checking : nil
        case .none, .needsInput, .error:
            return nil
        }
    }

    private static func observedItem(workspace: WorkspaceState, parentID: UUID, inputs: Inputs) -> TaskBoardItem {
        let statuses = inputs.statuses(workspace.id)
        let link = pullRequestLink(workspace)
        let pullRequestState = link.flatMap(inputs.pullRequestState)
        let agent = agentActivity(statuses, in: workspace)
        let project = inputs.state.workspacesByID[parentID]
        let stage = TaskStage.derive(
            .observed(doneAt: workspace.doneAt),
            live: TaskLiveFacts(
                taskSpaceOpen: true,
                agent: agent,
                pullRequest: pullRequestState,
                hasPullRequestLink: link != nil
            ),
            releaseTagsConfigured: releaseTagsConfigured(root: project?.rootDirectory, inputs: inputs)
        )
        let dates = statuses.compactMap(Self.agentActivityAt) + [workspace.doneAt].compactMap { $0 }
        return TaskBoardItem(
            id: .taskSpace(workspace.id),
            record: nil,
            title: sessionTitle(record: nil, workspaceID: workspace.id, registry: inputs.sessionRegistry) ?? workspace.title,
            taskSpaceWorkspaceID: workspace.id,
            projectWorkspaceID: parentID,
            projectTitle: project?.title,
            stage: stage,
            agent: agent,
            hasUnreadTurn: hasUnreadTurn(statuses, in: workspace),
            pullRequest: link,
            pullRequestState: pullRequestState,
            branch: nil,
            parentTaskID: nil,
            merge: nil,
            activityAt: dates.max() ?? .distantPast
        )
    }

    /// When a session's agent last reported, for ordering: reading its turn
    /// is not activity, so a task the user clicks keeps its place.
    static func agentActivityAt(_ status: WorkspaceSessionStatus) -> Date? {
        status.agentStatusUpdatedAt ?? status.statusUpdatedAt
    }

    static func pullRequestLink(_ workspace: WorkspaceState) -> WorkspacePullRequestLink? {
        WorkspacePullRequestLink(annotationURL: workspace.annotations[SidebarSubspacePresentation.annotationKeyPullRequest]?.url)
    }

    private static func releaseTagsConfigured(root: String?, inputs: Inputs) -> Bool {
        guard let root, let config = inputs.config else { return false }
        return config.workspace(forProjectRoot: root, homeDirectoryPath: inputs.homeDirectory)?.releaseTags != nil
    }
}

/// Keeps the inputs of the board current and tells views when they change:
/// task records, pull request answers, and tasks.toml. It also asks GitHub
/// about open task pull requests every two minutes, when an agent's turn
/// ends in a task space, and when the Tasks view opens, and copies what it
/// learns onto the records: the pull request link, and the merge.
@MainActor
final class TaskBoardStore: ObservableObject {
    static let pullRequestRefreshInterval: Duration = .seconds(120)

    let coordinator: TaskCoordinator?
    let pullRequests: PullRequestStateCache?
    @Published private(set) var config: TasksConfig?
    /// Why tasks.toml could not be read; shown in the Tasks view.
    @Published private(set) var configError: String?
    /// The task each window's Tasks view shows in its detail pane.
    @Published var selectionByWindowID: [UUID: TaskBoardItem.Subject] = [:]
    /// The rows each window's Tasks view showed last, in order; see
    /// `tasksViewListDidChange`.
    var tasksViewListByWindowID: [UUID: [TaskBoardItem.Subject]] = [:]
    /// A group each window's Tasks view should show next, set by the
    /// sidebar's To ship and Done counts. The view scrolls to it, expands
    /// Done, and then clears the request.
    @Published var revealGroupByWindowID: [UUID: TaskStage.Group] = [:]
    /// Opens the quick entry panel, for the sidebar's ＋ and the Tasks
    /// view's New Task. `nil` hides them.
    var newTask: (@MainActor () -> Void)?
    /// The quick entry shortcut, such as "⌥⇧T", shown on New Task.
    var newTaskShortcutLabel: @MainActor () -> String? = { nil }

    private weak var store: AppStore?
    private weak var sessionRuntimeStore: SessionRuntimeStore?
    private let now: () -> Date
    private var cancellables: Set<AnyCancellable> = []
    private var storeObserverToken: UUID?
    private var refreshLoop: Task<Void, Never>?
    private var releaseLoop: Task<Void, Never>?
    private var workingTaskSpaceIDs: Set<UUID> = []
    private var isTurnCheckScheduled = false

    /// A board with no task system, for windows and tests without one.
    static let disabled = TaskBoardStore()

    var isEnabled: Bool { coordinator != nil }

    private init() {
        coordinator = nil
        pullRequests = nil
        now = Date.init
    }

    init(
        coordinator: TaskCoordinator,
        store: AppStore,
        sessionRuntimeStore: SessionRuntimeStore,
        pullRequests: PullRequestStateCache,
        refreshInterval: Duration? = TaskBoardStore.pullRequestRefreshInterval,
        releaseCheckInterval: Duration? = TaskCoordinator.releaseCheckInterval,
        now: @escaping () -> Date = Date.init
    ) {
        self.coordinator = coordinator
        self.pullRequests = pullRequests
        self.store = store
        self.sessionRuntimeStore = sessionRuntimeStore
        self.now = now
        coordinator.records.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.scheduleSessionCheck()
            }
            .store(in: &cancellables)
        pullRequests.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        sessionRuntimeStore.$workspaceMergeRequests
            .removeDuplicates()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        sessionRuntimeStore.$sessionRegistry
            .sink { [weak self] _ in
                // The registry publishes before it changes; read it after,
                // once for a burst of changes.
                self?.scheduleSessionCheck()
            }
            .store(in: &cancellables)
        pullRequests.answerObserver = { [weak self] link, state in
            self?.recordAnswer(link: link, state: state)
        }
        storeObserverToken = store.addActionAppliedObserver { [weak self] _, _, nextState in
            self?.syncRecords(state: nextState)
        }
        reloadConfig()
        syncRecords(state: store.state)
        syncSessionTitles()
        coordinator.removeExpiredAttachments()
        if let refreshInterval {
            refreshLoop = Task { [weak self] in
                while Task.isCancelled == false {
                    try? await Task.sleep(for: refreshInterval)
                    guard let self else { return }
                    self.reloadConfig()
                    self.refreshOpenPullRequests()
                }
            }
        }
        if let releaseCheckInterval {
            releaseLoop = Task { [weak self] in
                while Task.isCancelled == false {
                    try? await Task.sleep(for: releaseCheckInterval)
                    await self?.coordinator?.checkReleases()
                    self?.coordinator?.removeExpiredAttachments()
                }
            }
        }
    }

    deinit {
        refreshLoop?.cancel()
        releaseLoop?.cancel()
    }

    /// Every item, or those a window's sidebar shows.
    func items(windowID: UUID? = nil) -> [TaskBoardItem] {
        guard let coordinator, let store else { return [] }
        let all = TaskBoard.items(TaskBoard.Inputs(
            state: store.state,
            records: coordinator.records.records,
            statuses: { [weak sessionRuntimeStore] workspaceID in
                sessionRuntimeStore?.workspaceStatuses(for: workspaceID) ?? []
            },
            pullRequestState: { [weak pullRequests] link in pullRequests?.state(for: link) },
            config: config,
            sessionRegistry: sessionRuntimeStore?.sessionRegistry ?? SessionRegistry(),
            mergeRequest: { [weak sessionRuntimeStore] workspaceID in
                sessionRuntimeStore?.workspaceMergeRequests[workspaceID]
            }
        ))
        guard let windowID else { return all }
        return TaskBoard.items(all, in: windowID, state: store.state)
    }

    /// The item for one open task space, given the statuses the caller
    /// already read. `nil` when the task system is off.
    func item(taskSpace workspace: WorkspaceState, statuses: [WorkspaceSessionStatus]) -> TaskBoardItem? {
        guard let coordinator, let store else { return nil }
        let record = workspace.taskID.flatMap(coordinator.records.record(id:))
        return TaskBoard.item(taskSpace: workspace, record: record, inputs: TaskBoard.Inputs(
            state: store.state,
            records: [],
            statuses: { _ in statuses },
            pullRequestState: { [weak pullRequests] link in pullRequests?.state(for: link) },
            config: config,
            sessionRegistry: sessionRuntimeStore?.sessionRegistry ?? SessionRegistry(),
            mergeRequest: { [weak sessionRuntimeStore] workspaceID in
                sessionRuntimeStore?.workspaceMergeRequests[workspaceID]
            }
        ))
    }

    /// A task's merge that is under way. Only a task whose task space is
    /// open can have one.
    func mergeActivity(taskID: UUID) -> TaskMergeActivity? {
        guard let coordinator, let store,
              let workspaceID = coordinator.records.record(id: taskID)?.taskSpaceWorkspaceID,
              let workspace = store.state.workspacesByID[workspaceID] else { return nil }
        return item(taskSpace: workspace, statuses: sessionRuntimeStore?.workspaceStatuses(for: workspaceID) ?? [])?.merge
    }

    /// Whether Release can start a release for the item's project: the
    /// project is open and tasks.toml gives it a release skill or a
    /// `release_prompt`.
    func canRelease(_ item: TaskBoardItem) -> Bool {
        guard item.projectWorkspaceID != nil,
              let root = item.record?.projectRoot,
              let config else { return false }
        return config.canRelease(projectRoot: root)
    }

    func reloadConfig() {
        guard let coordinator else { return }
        do {
            let loaded = try coordinator.configLoader()
            if config != loaded { config = loaded }
            if configError != nil { configError = nil }
        } catch {
            let message = error.localizedDescription
            if configError != message { configError = message }
        }
    }

    /// Asks GitHub about every pull request whose task is not finished.
    func refreshOpenPullRequests() {
        guard let pullRequests else { return }
        for item in items() where item.stage.isFinished == false {
            // A closed pull request can be reopened, so only a merge stops
            // the checks.
            guard let link = item.pullRequest, item.pullRequestState?.state != .merged else { continue }
            pullRequests.refresh(link)
        }
    }

    /// When the Tasks view opens: read tasks.toml again, ask GitHub, and
    /// look for release tags.
    func tasksViewDidOpen() {
        reloadConfig()
        refreshOpenPullRequests()
        Task { [weak coordinator] in
            await coordinator?.checkReleases()
        }
    }

    private func scheduleSessionCheck() {
        guard isTurnCheckScheduled == false else { return }
        isTurnCheckScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isTurnCheckScheduled = false
            self.syncSessionTitles()
            self.refreshAfterTurnsEnded()
            self.objectWillChange.send()
        }
    }

    private func syncSessionTitles() {
        guard let coordinator, let sessionRuntimeStore else { return }
        for record in coordinator.records.records {
            guard let workspaceID = record.taskSpaceWorkspaceID,
                  let title = TaskBoard.sessionTitle(record: record, workspaceID: workspaceID, registry: sessionRuntimeStore.sessionRegistry),
                  title != record.title else { continue }
            _ = coordinator.records.update(id: record.id) { $0.title = title }
        }
    }

    private func refreshAfterTurnsEnded() {
        guard let pullRequests, let store, let sessionRuntimeStore else { return }
        var working: Set<UUID> = []
        var links: [UUID: WorkspacePullRequestLink] = [:]
        for workspaceID in store.state.subspaceParentIDsByWorkspaceID().keys {
            guard let workspace = store.state.workspacesByID[workspaceID],
                  let link = TaskBoard.pullRequestLink(workspace) else { continue }
            links[workspaceID] = link
            if TaskBoard.agentActivity(sessionRuntimeStore.workspaceStatuses(for: workspaceID), in: workspace) == .working {
                working.insert(workspaceID)
            }
        }
        for workspaceID in workingTaskSpaceIDs.subtracting(working) {
            if let link = links[workspaceID] {
                pullRequests.refresh(link)
            }
        }
        workingTaskSpaceIDs = working
    }

    /// Copies what an open task space shows onto its record, so the task
    /// keeps it after the task space closes: the pull request link, and the
    /// done mark. A new link drops the old pull request's merge, and a merge
    /// GitHub already reported for the link is recorded at once.
    private func syncRecords(state: AppState) {
        guard let records = coordinator?.records else { return }
        for record in records.records {
            var next = record
            if let workspaceID = record.taskSpaceWorkspaceID,
               let workspace = state.workspacesByID[workspaceID] {
                if let link = TaskBoard.pullRequestLink(workspace), next.pullRequestURL != link.url {
                    next.pullRequestURL = link.url
                    next.mergedAt = nil
                    next.mergeCommit = nil
                    next.mergeRequestedAt = nil
                }
                let request = sessionRuntimeStore?.workspaceMergeRequests[workspaceID]
                if TaskBoard.isInMergeFlow(next, request: request) == false {
                    next.doneAt = workspace.doneAt
                }
            }
            if next.mergedAt == nil,
               let link = WorkspacePullRequestLink(annotationURL: next.pullRequestURL),
               let answer = pullRequests?.state(for: link), answer.state == .merged {
                next.mergedAt = now()
                next.mergeCommit = answer.mergeCommit
            }
            if next != record {
                _ = records.update(id: record.id) { $0 = next }
            }
        }
    }

    /// Records a merge on the tasks whose pull request it is, then has the
    /// coordinator clean up those that merged on GitHub, where it is safe.
    /// A merge Toastty ran cleans up through its own request.
    private func recordAnswer(link: WorkspacePullRequestLink, state: TaskPullRequestState) {
        guard state.state == .merged, let store, let coordinator else { return }
        syncRecords(state: store.state)
        let merged = coordinator.records.records
            .filter { $0.pullRequestURL == link.url }
            .map(\.id)
        coordinator.cleanUpMergedTasks(merged)
    }
}

extension SessionRuntimeStore {
    /// Whether a task space's task has a merge its agent is checking, which
    /// the Merge button shows as under way.
    func isCheckingTaskMerge(workspaceID: UUID) -> Bool {
        guard let board = taskCoordinator?.board,
              let workspace = taskCoordinator?.store.state.workspacesByID[workspaceID],
              workspace.taskID != nil else { return false }
        return board.item(taskSpace: workspace, statuses: workspaceStatuses(for: workspaceID))?.merge == .checking
    }

    /// Whether a task space's task has merged, through Toastty or on
    /// GitHub. Its Merge button then shows the merge as done instead of
    /// offering it again while the task space stays open.
    func isTaskMerged(workspaceID: UUID) -> Bool {
        guard let coordinator = taskCoordinator,
              let taskID = coordinator.store.state.workspacesByID[workspaceID]?.taskID else { return false }
        return coordinator.records.record(id: taskID)?.mergedAt != nil
    }

    /// Whether the workspace is a task space with a task record, whose
    /// Merge goes through the task.
    func isTaskSpaceWithRecord(workspaceID: UUID) -> Bool {
        guard let coordinator = taskCoordinator,
              let taskID = coordinator.store.state.workspacesByID[workspaceID]?.taskID else { return false }
        return coordinator.records.record(id: taskID) != nil
    }
}
