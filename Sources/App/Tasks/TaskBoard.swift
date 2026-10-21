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
    var pullRequest: WorkspacePullRequestLink?
    var pullRequestState: TaskPullRequestState?
    var branch: String?
    var parentTaskID: UUID?
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

    /// The most urgent thing a task space's agents are doing.
    static func agentActivity(_ statuses: [WorkspaceSessionStatus]) -> TaskAgentActivity {
        guard statuses.isEmpty == false else { return .none }
        let kinds = Set(statuses.map(\.status.kind))
        if kinds.contains(.needsApproval) { return .needsInput }
        if kinds.contains(.error) { return .error }
        if kinds.contains(.working) { return .working }
        return .idle
    }

    private static func item(for record: TaskRecord, inputs: Inputs) -> TaskBoardItem {
        let state = inputs.state
        let taskSpaceID = record.taskSpaceWorkspaceID.flatMap { state.workspacesByID[$0] == nil ? nil : $0 }
        let taskSpace = taskSpaceID.flatMap { state.workspacesByID[$0] }
        let statuses = taskSpaceID.map(inputs.statuses) ?? []
        let annotationLink = taskSpace.flatMap(pullRequestLink)
        let link = annotationLink ?? WorkspacePullRequestLink(annotationURL: record.pullRequestURL)
        let pullRequestState = link.flatMap(inputs.pullRequestState)
        let agent = agentActivity(statuses)
        let project = record.workspaceID.flatMap { state.workspacesByID[$0] }
        let root = record.projectRoot ?? project?.rootDirectory
        var facts = TaskStageFacts(record: record)
        // While the task space is open, its done mark is the live answer;
        // the record keeps a copy for after it closes.
        if let taskSpace {
            facts.doneAt = taskSpace.doneAt
        }
        let stage = TaskStage.derive(
            facts,
            live: TaskLiveFacts(
                taskSpaceOpen: taskSpace != nil,
                agent: agent,
                pullRequest: pullRequestState,
                hasPullRequestLink: link != nil
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
            pullRequest: link,
            pullRequestState: pullRequestState,
            branch: record.worktree?.branch,
            parentTaskID: record.parentTaskID,
            activityAt: dates.max() ?? record.createdAt
        )
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
            pullRequest: link,
            pullRequestState: pullRequestState,
            branch: nil,
            parentTaskID: nil,
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

    private weak var store: AppStore?
    private weak var sessionRuntimeStore: SessionRuntimeStore?
    private let now: () -> Date
    private var cancellables: Set<AnyCancellable> = []
    private var storeObserverToken: UUID?
    private var refreshLoop: Task<Void, Never>?
    private var workingTaskSpaceIDs: Set<UUID> = []

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
        sessionRuntimeStore.$sessionRegistry
            .sink { [weak self] _ in
                // The registry publishes before it changes; read it after.
                Task { @MainActor [weak self] in self?.refreshAfterTurnsEnded() }
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
    }

    deinit {
        refreshLoop?.cancel()
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
            config: config
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
            config: config
        ))
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

    /// When the Tasks view opens: read tasks.toml again and ask GitHub.
    func tasksViewDidOpen() {
        reloadConfig()
        refreshOpenPullRequests()
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
                }
                next.doneAt = workspace.doneAt
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

    /// Records a merge on the tasks whose pull request it is. This states
    /// what GitHub reported; it starts no cleanup.
    private func recordAnswer(link: WorkspacePullRequestLink, state: TaskPullRequestState) {
        guard state.state == .merged, let store else { return }
        syncRecords(state: store.state)
    }
}
