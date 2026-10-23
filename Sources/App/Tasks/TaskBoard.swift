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
    /// waits on its sub-agents or is resuming is working. An idle session has
    /// finished and waits for a prompt once it has ended a turn. Without an
    /// ended turn it waits too, since turn timing does not survive a relaunch
    /// and a restored session starts idle, except for `launchedSessionID`: the
    /// session the task started with its first prompt, which is only about to
    /// begin its first turn. Without `launchedSessionID`, as for a task space
    /// with no record, an idle session counts only after an ended turn.
    static func agentActivity(_ statuses: [WorkspaceSessionStatus], launchedSessionID: String? = nil) -> TaskAgentActivity {
        guard statuses.isEmpty == false else { return .none }
        let kinds = Set(statuses.map(\.status.kind))
        if kinds.contains(.needsApproval) { return .needsInput }
        if kinds.contains(.error) { return .error }
        if kinds.contains(.working) || statuses.contains(where: { $0.projection != .none }) { return .working }
        let finished = statuses.contains { status in
            switch status.status.kind {
            case .ready: true
            case .idle: status.lastTurnDuration != nil || (launchedSessionID != nil && status.sessionID != launchedSessionID)
            case .working, .needsApproval, .error: false
            }
        }
        return finished ? .finished : .idle
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

    private static func item(for record: TaskRecord, inputs: Inputs) -> TaskBoardItem {
        let state = inputs.state
        let waitingOn = waitingOnTitle(record, records: inputs.records)
        let taskSpaceID = record.taskSpaceWorkspaceID.flatMap { state.workspacesByID[$0] == nil ? nil : $0 }
        let taskSpace = taskSpaceID.flatMap { state.workspacesByID[$0] }
        let statuses = taskSpaceID.map(inputs.statuses) ?? []
        let annotationLink = taskSpace.flatMap(pullRequestLink)
        let link = annotationLink ?? WorkspacePullRequestLink(annotationURL: record.pullRequestURL)
        let pullRequestState = link.flatMap(inputs.pullRequestState)
        let agent = agentActivity(statuses, launchedSessionID: record.operation.agentLaunch?.sessionID)
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
            record.createdAt, record.readyForReviewAt, record.mergedAt, record.shippedAt,
            record.archivedAt, record.doneAt,
        ].compactMap { $0 } + statuses.compactMap(\.statusUpdatedAt)
        return TaskBoardItem(
            id: .task(record.id),
            record: record,
            title: record.title,
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
        let agent = agentActivity(statuses)
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
        let dates = statuses.compactMap(\.statusUpdatedAt) + [workspace.doneAt].compactMap { $0 }
        return TaskBoardItem(
            id: .taskSpace(workspace.id),
            record: nil,
            title: workspace.title,
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
            .sink { [weak self] _ in self?.objectWillChange.send() }
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
                guard let self, self.isTurnCheckScheduled == false else { return }
                self.isTurnCheckScheduled = true
                Task { @MainActor [weak self] in
                    self?.isTurnCheckScheduled = false
                    self?.refreshAfterTurnsEnded()
                }
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

    private func refreshAfterTurnsEnded() {
        guard let pullRequests, let store, let sessionRuntimeStore else { return }
        var working: Set<UUID> = []
        var links: [UUID: WorkspacePullRequestLink] = [:]
        for workspaceID in store.state.subspaceParentIDsByWorkspaceID().keys {
            guard let workspace = store.state.workspacesByID[workspaceID],
                  let link = TaskBoard.pullRequestLink(workspace) else { continue }
            links[workspaceID] = link
            if TaskBoard.agentActivity(sessionRuntimeStore.workspaceStatuses(for: workspaceID)) == .working {
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

    /// Whether the workspace is a task space with a task record, whose
    /// Merge goes through the task.
    func isTaskSpaceWithRecord(workspaceID: UUID) -> Bool {
        guard let coordinator = taskCoordinator,
              let taskID = coordinator.store.state.workspacesByID[workspaceID]?.taskID else { return false }
        return coordinator.records.record(id: taskID) != nil
    }
}
