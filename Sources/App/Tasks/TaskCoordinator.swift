import CoreState
import Darwin
import Foundation
import RemoteProtocol

/// The part of the agent launcher a task start uses. A protocol so tests
/// can run setup without terminals.
@MainActor
protocol TaskAgentLaunching: AnyObject {
    func launchProfileSummaries() -> [AgentLaunchProfileSummary]
    /// Launches into the given terminal without moving focus. The session
    /// gets `scopedWorkspaceIDs` as its workspace scope; `nil` leaves it
    /// unscoped. With `forkFromSessionID`, the new session continues a copy
    /// of that session's conversation.
    /// `beforeDispatch` runs directly before the command is sent; a throw
    /// there cancels the launch.
    func launchTask(
        profileID: String,
        workspaceID: UUID,
        panelID: UUID,
        cwd: String,
        model: String?,
        reasoningEffort: String?,
        initialPrompt: String,
        parentSessionID: String?,
        forkFromSessionID: String?,
        scopedWorkspaceIDs: Set<UUID>?,
        beforeDispatch: @escaping @MainActor () throws -> Void
    ) async throws -> AgentLaunchResult
}

extension AgentLaunchService: TaskAgentLaunching {
    func launchTask(
        profileID: String,
        workspaceID: UUID,
        panelID: UUID,
        cwd: String,
        model: String?,
        reasoningEffort: String?,
        initialPrompt: String,
        parentSessionID: String?,
        forkFromSessionID: String?,
        scopedWorkspaceIDs: Set<UUID>?,
        beforeDispatch: @escaping @MainActor () throws -> Void
    ) async throws -> AgentLaunchResult {
        try await launchAsync(
            profileID: profileID,
            workspaceID: workspaceID,
            panelID: panelID,
            cwd: cwd,
            model: model,
            reasoningEffort: reasoningEffort,
            initialPrompt: initialPrompt,
            forkFromSessionID: forkFromSessionID,
            inheritedScopedWorkspaceIDs: scopedWorkspaceIDs,
            parentSessionID: parentSessionID,
            focusPolicy: .preserveFirstResponder,
            beforeDispatch: beforeDispatch
        )
    }
}

/// What a task needs to know about a managed agent session.
struct TaskSessionInfo: Equatable {
    var sessionID: String
    var agent: AgentKind
    var panelID: UUID
    var workspaceID: UUID
    var cwd: String?
    var isActive: Bool
    /// Working, or waiting for an approval.
    var isInTurn: Bool
    /// The provider conversation Toastty confirmed for the session.
    var nativeConversationID: String?
    var title: String?
    var status: SessionStatus? = nil
    var statusUpdatedAt: Date? = nil
    var lastTurnEndedAt: Date? = nil
    /// When the current turn started, while the session works.
    var turnStartedAt: Date? = nil
    /// The provider transcript Toastty confirmed for the session.
    var transcriptPath: String? = nil
}

/// The session side of moving a task into its worktree. A protocol so tests
/// can move tasks without agents.
@MainActor
protocol TaskSessionProviding: AnyObject {
    func session(_ sessionID: String) -> TaskSessionInfo?
    /// The managed session running in the panel now, if any.
    func activeSession(panelID: UUID) -> TaskSessionInfo?
    /// Whether a person typed into the panel, or a phone message reached
    /// it, after `date`.
    func hasInput(panelID: UUID, since date: Date) -> Bool
    /// Closes the pane of a session whose conversation moved. When the pane
    /// is its workspace's last, types the agent's native exit instead, so
    /// the workspace and its shell stay.
    func closeMovedSessionPane(panelID: UUID, agent: AgentKind) -> TaskOperation.SourceOutcome
    /// The managed agent sessions running in a workspace now.
    func activeSessions(workspaceID: UUID) -> [TaskSessionInfo]
    /// Types `text` into the panel and submits it, as `terminal.send-text`
    /// does. A busy agent queues it as typed input.
    func deliver(_ text: String, panelID: UUID) -> TerminalInputDeliveryResult
    /// The session's latest agent message, read from its transcript.
    func lastReply(sessionID: String) -> TaskAgentReply?
    /// The managed session's workspace scope; `nil` when it is unscoped or
    /// not a running managed session.
    func scope(sessionID: String) -> Set<UUID>?
}

extension TaskSessionProviding {
    func activeSessions(workspaceID: UUID) -> [TaskSessionInfo] { [] }
    func deliver(_ text: String, panelID: UUID) -> TerminalInputDeliveryResult { .unavailable }
    func lastReply(sessionID: String) -> TaskAgentReply? { nil }
    func scope(sessionID: String) -> Set<UUID>? { nil }
}

/// What a caller asked for in `task.create`. Every field except the text is
/// optional; the coordinator fills the rest.
struct TaskCreateRequest: Equatable {
    var text: String
    /// Absolute paths of files to attach.
    var files: [String] = []
    var clientRequestID: String?
    var title: String?
    var slug: String?
    var workspaceID: UUID?
    var agent: String?
    var model: String?
    var effort: String?
    var prompt: String?
    /// Make a git worktree during setup and start the agent there.
    var startWork = false
    /// For `startWork`: the branch or commit to start from.
    var base: String?
    /// For `startWork`: the first part of the branch name.
    var branchPrefix: String?
}

/// Who sent a `task.create`, captured before any asynchronous step.
struct TaskCaller: Equatable {
    /// The calling managed agent session, if any.
    var sessionID: String?
    /// That session's workspace.
    var workspaceID: UUID?
    /// The quick entry panel, rather than the CLI.
    var isQuickEntry = false

    static let unmanaged = TaskCaller()
    static let quickEntry = TaskCaller(isQuickEntry: true)

    var source: TaskSource {
        if let sessionID { return .agent(sessionID: sessionID) }
        return isQuickEntry ? .quickEntry : .cli
    }
}

/// A checked `task.create` request, ready for its files to be copied.
struct TaskCreatePreparation {
    fileprivate var record: TaskRecord
    /// Source file (symbolic links resolved) to destination path.
    fileprivate var copies: [(source: String, destination: String)]
    fileprivate var saveRootDirectory: Bool
    /// A repeated request: the task it already made.
    fileprivate var existing: TaskRecord?
}

struct TaskError: LocalizedError, Equatable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

/// Creates tasks, runs their setup, and recovers them after a restart.
///
/// Setup makes the task space and starts the agent in it. Each step is
/// saved in the record's operation before and after it changes anything
/// outside the record, so Retry continues from the last finished step.
@MainActor
final class TaskCoordinator {
    static let maximumAttachmentBytes = 50 * 1024 * 1024

    let records: TaskRecordStore
    let store: AppStore
    weak var launcher: (any TaskAgentLaunching)?
    let configLoader: () throws -> TasksConfig
    private let attachmentsDirectoryURL: URL
    private let hasActiveSession: (UUID) -> Bool
    /// Adds a task space to a session's workspace scope when that session
    /// is scoped; does nothing for an unscoped session.
    private let grantScope: (String, UUID) -> Void
    let worktreeCreator: TaskWorktreeCreator
    let fileManager: FileManager
    let now: () -> Date
    let terminalReadinessTimeout: Duration
    let timing: StartWorkTiming

    /// How long a move into a worktree waits; shorter in tests.
    struct StartWorkTiming {
        /// For the moving session to finish the turn that asked for it.
        var sourceTurnTimeout: Duration = .seconds(600)
        /// For the forked agent to report its new conversation.
        var forkConfirmationTimeout: Duration = .seconds(60)
        /// For Toastty to identify the moving session's conversation, which
        /// a fork needs. A move asked for in a session's first seconds can
        /// arrive before that.
        var sourceDiscoveryTimeout: Duration = .seconds(60)
        var pollInterval: Duration = .milliseconds(250)
    }
    /// Runs `[triage] command`; `nil` turns triage off.
    let triageRunner: (any TaskTriageRunning)?
    /// The closed workspaces a task can reopen.
    let recentWorkspaces: RecentWorkspacesStore?
    let homeDirectoryPath: String

    /// One per running setup; a newer attempt or a delete makes an older
    /// one stop at its next check.
    var setupAttempts: [UUID: UUID] = [:]
    var setupTasks: [UUID: Task<Void, Never>] = [:]
    /// The same for moves into a worktree.
    var startWorkAttempts: [UUID: UUID] = [:]
    var startWorkTasks: [UUID: Task<Void, Never>] = [:]

    /// Saves the workspace layout at once. Setup calls it after it makes or
    /// unlinks a task space, so the layout on disk never lags a record that
    /// depends on it. Set once layout persistence exists.
    var flushLayout: () -> Void = {}
    /// Set once the session store exists. Without it, tasks cannot move.
    var sessions: (any TaskSessionProviding)?
    /// The live view of every task's stage, for queries that report it and
    /// for stage watches.
    weak var board: TaskBoardStore?
    /// The one owner of merges and their cleanup. Set once it exists.
    weak var merges: WorkspaceMergeCoordinator?
    /// Unsaved local documents in a workspace, which closing it would lose.
    var unsavedDocumentCount: (UUID) -> Int = { _ in 0 }
    /// Merge prompts waiting for a busy agent's turn to end.
    var mergeDeliveryTasks: [UUID: Task<Void, Never>] = [:]
    /// Archives and release cleanups running in the background.
    var cleanupTasks: [UUID: Task<Void, Never>] = [:]
    var isCheckingReleases = false
    /// `toastty task watch --wait` watches, which only last while the app runs.
    var waitWatches: [UUID: TaskWaitWatch] = [:]
    var watchMonitor: Task<Void, Never>?
    /// The change cursor behind `task.list changedSince`.
    let changeFeed = TaskChangeFeed()

    init(
        records: TaskRecordStore,
        store: AppStore,
        launcher: (any TaskAgentLaunching)?,
        configLoader: @escaping () throws -> TasksConfig,
        attachmentsDirectoryURL: URL,
        hasActiveSession: @escaping (UUID) -> Bool,
        grantScope: @escaping (String, UUID) -> Void,
        worktreeCreator: TaskWorktreeCreator = TaskWorktreeCreator(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        terminalReadinessTimeout: Duration = .seconds(10),
        timing: StartWorkTiming = StartWorkTiming(),
        triageRunner: (any TaskTriageRunning)? = nil,
        recentWorkspaces: RecentWorkspacesStore? = nil,
        homeDirectoryPath: String = NSHomeDirectory()
    ) {
        self.records = records
        self.store = store
        self.launcher = launcher
        self.configLoader = configLoader
        self.attachmentsDirectoryURL = attachmentsDirectoryURL
        self.hasActiveSession = hasActiveSession
        self.grantScope = grantScope
        self.worktreeCreator = worktreeCreator
        self.fileManager = fileManager
        self.now = now
        self.terminalReadinessTimeout = terminalReadinessTimeout
        self.timing = timing
        self.triageRunner = triageRunner
        self.recentWorkspaces = recentWorkspaces
        self.homeDirectoryPath = homeDirectoryPath
    }

    // MARK: - Create

    /// Checks the request, copies the files, saves the record and starts
    /// setup. Returns as soon as the record is saved; setup continues in the
    /// background.
    @discardableResult
    func create(_ request: TaskCreateRequest, caller: TaskCaller = .unmanaged) async throws -> TaskRecord {
        try await finishCreate(try prepareCreate(request, caller: caller))
    }

    /// Every check that needs app state, done before any file is copied.
    func prepareCreate(_ request: TaskCreateRequest, caller: TaskCaller = .unmanaged) throws -> TaskCreatePreparation {
        let source = caller.source
        let clientRequestID = try validatedClientRequestID(request.clientRequestID)
        // Request IDs belong to their caller, so one caller cannot read
        // another's task by reusing its ID.
        if let clientRequestID, let existing = records.record(clientRequestID: clientRequestID, source: source) {
            return TaskCreatePreparation(record: existing, copies: [], saveRootDirectory: false, existing: existing)
        }

        // The text is kept exactly as written; only the checks trim it.
        let text = request.text
        let prompt = request.prompt.flatMap(taskNonEmpty)
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || prompt != nil else {
            throw TaskError("A task needs text or a prompt.")
        }
        guard request.files.count <= TaskRecord.maximumAttachmentCount else {
            throw TaskError("Attach at most \(TaskRecord.maximumAttachmentCount) files.")
        }
        let sources = try request.files.map(attachableFile)

        let workspaceID = try resolvedWorkspaceID(request.workspaceID, caller: caller)
        let projectRoot = try workspaceID.map(resolvedProjectRoot)
        let config: TasksConfig
        do {
            config = try configLoader()
        } catch {
            throw TaskError(error.localizedDescription)
        }
        let pinnedTitle = request.title.flatMap(taskNonEmpty)
        let pinnedSlug = request.slug.flatMap(taskNonEmpty)
        let pinned = TaskFields(
            workspaceID: request.workspaceID,
            agent: request.agent.flatMap(taskNonEmpty),
            model: request.model.flatMap(taskNonEmpty),
            effort: request.effort.flatMap(taskNonEmpty),
            prompt: prompt,
            title: pinnedTitle,
            slug: pinnedSlug
        )
        // A value the caller set that cannot work fails the request now,
        // whether or not triage runs.
        let pinnedProfile = try checkedPinnedFields(pinned)

        // Triage runs only for what the caller left out. Without triage,
        // `[defaults]` fills the agent, and a task with no workspace waits
        // for the user to pick one.
        let setup: TaskSetupState
        var resolved: TaskFields?
        let missing = TaskTriage.missingFields(
            pinned: pinned,
            workspaceID: workspaceID,
            pinnedAgent: pinnedProfile.map(Self.triageAgent)
        )
        if missing.isEmpty == false, isTriageEnabled(config) {
            setup = .routing
        } else if let workspaceID {
            resolved = try resolvedFields(pinned: pinned, workspaceID: workspaceID, defaults: config.defaults)
            setup = .settingUp
        } else {
            // The agent and its settings are known now, so they are checked
            // now rather than after the user picks a workspace.
            _ = try resolvedFields(pinned: pinned, workspaceID: nil, defaults: config.defaults)
            setup = .needsWorkspace(reason: "No workspace was named, and triage is off. Pick a workspace for this task.")
        }

        var startWork: TaskStartWork?
        if request.startWork {
            // The worktree belongs to the project, so it needs the workspace
            // now; an agent caller always has its own.
            guard let projectRoot else {
                throw TaskError("--start-work needs a workspace: pass --workspace, or create the task from an agent session.")
            }
            startWork = try newStartWork(
                branchPrefix: request.branchPrefix,
                base: request.base,
                source: nil,
                projectRoot: projectRoot.path,
                config: config
            )
        } else if request.base != nil || request.branchPrefix != nil {
            throw TaskError("--base and --branch-prefix need --start-work.")
        }

        let (title, slug) = try titleAndSlug(
            pinnedTitle: pinnedTitle,
            pinnedSlug: pinnedSlug,
            fallbacks: [text, prompt ?? ""]
        )

        let taskID = UUID()
        let directoryURL = attachmentsDirectoryURL.appending(path: taskID.uuidString, directoryHint: .isDirectory)
        var usedNames: Set<String> = []
        var copies: [(source: String, destination: String)] = []
        var attachments: [TaskAttachment] = []
        for (requestedPath, resolvedPath) in zip(request.files, sources) {
            let originalName = (requestedPath as NSString).lastPathComponent
            let name = Self.uniqueFileName(originalName, taken: usedNames)
            usedNames.insert(name)
            let destination = directoryURL.appending(path: name, directoryHint: .notDirectory).path(percentEncoded: false)
            copies.append((resolvedPath, destination))
            attachments.append(TaskAttachment(path: destination, displayName: originalName))
        }
        // The launcher refuses a first message it cannot pass, and every
        // retry would fail the same way, so the request fails now.
        let firstMessage = TaskPrompt.compose(firstPrompt: prompt, text: text, attachmentPaths: attachments.map(\.path))
        guard firstMessage.utf8.count <= AgentLaunchService.maximumInitialPromptUTF8Count else {
            throw TaskError("The task, prompt and file paths are too long for an agent's first message (at most \(AgentLaunchService.maximumInitialPromptUTF8Count / 1024) KB).")
        }
        guard firstMessage.contains("\u{0}") == false else {
            throw TaskError("The task or prompt contains a NUL character.")
        }

        let record = TaskRecord(
            id: taskID,
            clientRequestID: clientRequestID,
            createdAt: now(),
            text: text,
            attachments: attachments,
            title: title,
            slug: slug,
            titleSetByUser: pinnedTitle != nil,
            source: source,
            pinned: pinned,
            resolved: resolved,
            workspaceID: workspaceID,
            projectRoot: projectRoot?.path,
            setup: setup,
            parentTaskID: caller.workspaceID.flatMap { store.state.workspacesByID[$0]?.taskID },
            startWork: startWork
        )
        var prepared = record
        prepared.creatorScope = caller.sessionID.flatMap { sessions?.scope(sessionID: $0) }
        return TaskCreatePreparation(
            record: prepared,
            copies: copies,
            saveRootDirectory: projectRoot?.isNew == true,
            existing: nil
        )
    }

    /// Copies the files off the main thread, then saves the record and
    /// starts setup.
    func finishCreate(_ preparation: TaskCreatePreparation) async throws -> TaskRecord {
        if let existing = preparation.existing {
            return existing
        }
        var record = preparation.record
        let directoryURL = attachmentsDirectoryURL.appending(path: record.id.uuidString, directoryHint: .isDirectory)
        if preparation.copies.isEmpty == false {
            let copies = preparation.copies
            do {
                try await Task.detached(priority: .userInitiated) {
                    let fileManager = FileManager.default
                    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                    for copy in copies {
                        try fileManager.copyItem(at: URL(filePath: copy.source), to: URL(filePath: copy.destination))
                    }
                }.value
            } catch {
                try? fileManager.removeItem(at: directoryURL)
                throw TaskError("Toastty could not copy an attachment: \(error.localizedDescription)")
            }
        }
        // A repeat of this request may have finished while the files copied.
        if let clientRequestID = record.clientRequestID,
           let existing = records.record(clientRequestID: clientRequestID, source: record.source) {
            try? fileManager.removeItem(at: directoryURL)
            return existing
        }
        if let workspaceID = record.workspaceID, store.state.workspacesByID[workspaceID] == nil {
            try? fileManager.removeItem(at: directoryURL)
            throw TaskError("The task's workspace closed before the task was saved.")
        }
        record.createdAt = now()
        do {
            try records.insert(record)
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw TaskError("Toastty could not save the task: \(error.localizedDescription)")
        }
        if preparation.saveRootDirectory, let workspaceID = record.workspaceID, let projectRoot = record.projectRoot {
            _ = store.send(.setWorkspaceRootDirectory(workspaceID: workspaceID, rootDirectory: projectRoot))
        }
        ToasttyLog.info("Created a task", category: .tasks, metadata: [
            "task_id": record.id.uuidString,
            "workspace_id": record.workspaceID?.uuidString ?? "",
            "agent": record.resolved?.agent ?? "",
            "attachments": String(record.attachments.count),
            "routing": String(record.setup == .routing),
        ])
        switch record.setup {
        case .routing:
            startRouting(taskID: record.id)
        case .settingUp:
            startSetup(taskID: record.id)
        case .needsWorkspace, .setupFailed, .started:
            break
        }
        return record
    }

    // MARK: - Retry, delete

    /// Runs setup again for a task whose setup failed, or a move into a
    /// worktree that failed, from the last step it finished. A task that
    /// has no workspace or agent yet goes through triage again.
    func retry(taskID: UUID) throws {
        guard let record = records.record(id: taskID) else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        // The agent's first message names the attached files.
        guard record.attachmentsRemovedAt == nil else {
            throw TaskError("This task's attached files were removed a week after it finished. Create a new task instead.")
        }
        switch record.setup {
        case .setupFailed, .needsWorkspace:
            break
        case .routing, .settingUp:
            throw TaskError("This task is still setting up.")
        case .started:
            guard case .failed? = record.startWork?.state else {
                throw TaskError("This task has already started.")
            }
            do {
                try records.save(id: taskID) { $0.startWork?.state = .running }
            } catch {
                throw TaskError("Toastty could not save the task: \(error.localizedDescription)")
            }
            startStartWork(taskID: taskID)
            return
        }
        let needsRouting = record.resolved == nil || record.workspaceID == nil
        do {
            try records.save(id: taskID) {
                $0.setup = needsRouting ? .routing : .settingUp
                if $0.startWork != nil { $0.startWork?.state = .running }
            }
        } catch {
            throw TaskError("Toastty could not save the task: \(error.localizedDescription)")
        }
        if needsRouting {
            startRouting(taskID: taskID)
        } else {
            startSetup(taskID: taskID)
        }
    }

    /// Places a task that has not started in a workspace the user chose:
    /// an open one, or a recently closed one or a project directory, which
    /// Toastty opens.
    /// Triage then runs for anything else still missing, with the
    /// workspace fixed.
    func setWorkspace(taskID: UUID, choice: TaskWorkspaceChoice) throws {
        guard let record = records.record(id: taskID) else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        switch record.setup {
        case .routing, .needsWorkspace, .setupFailed:
            break
        case .settingUp:
            throw TaskError("This task is still setting up.")
        case .started:
            throw TaskError("This task has already started.")
        }
        guard record.operation.taskSpace == nil else {
            throw TaskError("This task already has a task space. Retry it, or delete it and create it again.")
        }
        let workspaceID: UUID
        switch choice {
        case .open(let requestedID):
            guard store.state.workspacesByID[requestedID] != nil else {
                throw TaskError("No open workspace has ID \(requestedID.uuidString).")
            }
            workspaceID = store.state.subspaceParentIDsByWorkspaceID()[requestedID] ?? requestedID
            let root = store.state.workspacesByID[workspaceID].flatMap { Self.rootDirectory(of: $0, fileManager: fileManager) }
            try checkProjectUnchanged(record, newRoot: root)
        case .recent(let recentID):
            try checkProjectUnchanged(record, newRoot: recentWorkspaces?.item(id: recentID)?.rootDirectory)
            guard let recent = recentWorkspaces?.item(id: recentID) else {
                throw TaskError("No recently closed workspace has ID \(recentID.uuidString).")
            }
            workspaceID = try openProject(title: recent.title, rootDirectory: recent.rootDirectory)
        case .directory(let path):
            let rootDirectory = TasksConfigFile.normalizedPath(path, homeDirectoryPath: homeDirectoryPath)
            try checkProjectUnchanged(record, newRoot: rootDirectory)
            workspaceID = try openProject(
                title: Self.projectTitle(rootDirectory: rootDirectory, suggestion: record.suggestedWorkspace, homeDirectoryPath: homeDirectoryPath),
                rootDirectory: rootDirectory
            )
        }
        do {
            try records.save(id: taskID) {
                $0.pinned.workspaceID = workspaceID
                $0.workspaceID = workspaceID
                $0.projectRoot = nil
                $0.resolved = nil
                $0.suggestedWorkspace = nil
                $0.setup = .routing
            }
        } catch {
            throw TaskError("Toastty could not save the task: \(error.localizedDescription)")
        }
        ToasttyLog.info("Placed a task in a chosen workspace", category: .tasks, metadata: [
            "task_id": taskID.uuidString,
            "workspace_id": workspaceID.uuidString,
        ])
        startRouting(taskID: taskID)
    }

    /// A move into a worktree pins its base commit and reserves its
    /// worktree in the task's project; another project cannot reuse them.
    /// The same project, open again, is fine.
    private func checkProjectUnchanged(_ record: TaskRecord, newRoot: String?) throws {
        guard record.operation.base != nil || record.operation.worktree != nil,
              let projectRoot = record.projectRoot else { return }
        let same = newRoot.map {
            TasksConfigFile.normalizedPath($0, homeDirectoryPath: homeDirectoryPath)
                == TasksConfigFile.normalizedPath(projectRoot, homeDirectoryPath: homeDirectoryPath)
        } ?? false
        guard same else {
            throw TaskError("This task already has a worktree in \(projectRoot), so it stays in that project. Retry it there, or delete it and create it again.")
        }
    }

    /// The workspaces a task can be placed in, for the picker: the open
    /// top-level ones, then recently closed ones whose project is not open,
    /// and the project triage suggested for `taskID`, if any.
    func workspaceChoices(taskID: UUID? = nil) -> TaskWorkspaceChoices {
        let recent = (recentWorkspaces?.items ?? []).filter { openWorkspace(onRoot: $0.rootDirectory) == nil }
        var choices = TaskWorkspaceChoices(
            open: topLevelWorkspaces().map {
                TaskWorkspaceChoices.Open(id: $0.id, title: $0.title, rootDirectory: Self.rootDirectory(of: $0, fileManager: fileManager))
            },
            recent: recent
        )
        if let taskID, let record = records.record(id: taskID), case .needsWorkspace = record.setup,
           let suggestion = record.suggestedWorkspace {
            let target = TasksConfigFile.normalizedPath(suggestion.rootDirectory, homeDirectoryPath: homeDirectoryPath)
            let choice: TaskWorkspaceChoice
            if let open = openWorkspace(onRoot: suggestion.rootDirectory) {
                choice = .open(open.id)
            } else if let item = recent.first(where: { TasksConfigFile.normalizedPath($0.rootDirectory, homeDirectoryPath: homeDirectoryPath) == target }) {
                choice = .recent(item.id)
            } else {
                choice = .directory(suggestion.rootDirectory)
            }
            // A reopened or open workspace keeps its own title; a directory
            // opens under the suggestion's, as `projectTitle` names it.
            let title: String
            if case .directory = choice {
                title = suggestion.title
            } else {
                title = choices.title(of: choice) ?? suggestion.title
            }
            choices.suggested = TaskWorkspaceChoices.Suggested(
                title: title,
                rootDirectory: suggestion.rootDirectory,
                choice: choice
            )
        }
        return choices
    }

    /// The title for a workspace opened on a project directory: the
    /// suggestion's, else the directory's name.
    static func projectTitle(rootDirectory: String, suggestion: TaskWorkspaceSuggestion?, homeDirectoryPath: String) -> String {
        if let suggestion,
           TasksConfigFile.normalizedPath(suggestion.rootDirectory, homeDirectoryPath: homeDirectoryPath) == rootDirectory {
            return suggestion.title
        }
        return URL(filePath: rootDirectory).lastPathComponent
    }

    /// The projects that are not open, for triage to suggest: recently
    /// closed workspaces, then the `[workspace."<root>"]` roots in
    /// tasks.toml, one per root directory, each still a directory. `open`
    /// holds the open workspaces' git roots, so a terminal inside a nested
    /// repository does not hide the project around it.
    private func closedWorkspaces(config: TasksConfig, open: [TaskTriage.Workspace]) -> [TaskTriage.ClosedWorkspace] {
        var seen = Set(open.map { TasksConfigFile.normalizedPath($0.rootDirectory, homeDirectoryPath: homeDirectoryPath) })
        var result: [TaskTriage.ClosedWorkspace] = []
        func add(title: String?, root: String) {
            let normalized = TasksConfigFile.normalizedPath(root, homeDirectoryPath: homeDirectoryPath)
            guard seen.insert(normalized).inserted, isDirectory(normalized) else { return }
            result.append(TaskTriage.ClosedWorkspace(
                title: title ?? URL(filePath: normalized).lastPathComponent,
                rootDirectory: normalized,
                guidelines: config.workspace(forProjectRoot: normalized, homeDirectoryPath: homeDirectoryPath)?.guidelines
            ))
        }
        for item in recentWorkspaces?.items ?? [] {
            add(title: item.title, root: item.rootDirectory)
        }
        for workspace in config.workspaces {
            add(title: nil, root: workspace.path)
        }
        return result
    }

    /// Opens a project that is not open as a new top-level workspace, or
    /// finds it open already, and returns its workspace.
    private func openProject(title: String, rootDirectory: String) throws -> UUID {
        if let open = openWorkspace(onRoot: rootDirectory) {
            return open.id
        }
        guard isDirectory(rootDirectory) else {
            throw TaskError("The directory \(rootDirectory) no longer exists.")
        }
        guard let windowID = store.state.windows.first?.id else {
            throw TaskError("Open a Toastty window, then try again.")
        }
        let workspaceID = UUID()
        guard store.send(.reopenWorkspace(
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: UUID(),
            title: title,
            rootDirectory: rootDirectory
        )) else {
            throw TaskError("Toastty could not open \(title).")
        }
        flushLayout()
        ToasttyLog.info("Opened a project workspace for a task", category: .tasks, metadata: [
            "workspace_id": workspaceID.uuidString,
            "root": rootDirectory,
        ])
        return workspaceID
    }

    /// Removes a task and its attachments, and stops its setup. A task
    /// space that setup made is closed while nothing has used it; one that
    /// was used stays, without its task link.
    func delete(taskID: UUID) throws {
        guard let record = records.record(id: taskID) else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        setupAttempts[taskID] = nil
        setupTasks.removeValue(forKey: taskID)?.cancel()
        startWorkAttempts[taskID] = nil
        startWorkTasks.removeValue(forKey: taskID)?.cancel()
        if let taskSpace = record.operation.taskSpace,
           store.state.workspacesByID[taskSpace.workspaceID] != nil {
            if closeTaskSpaceIfUnused(taskSpace, record: record) == false {
                _ = store.send(.setWorkspaceTaskID(workspaceID: taskSpace.workspaceID, taskID: nil))
            }
            // Saved before the record goes, so a crash cannot leave a task
            // link that brings the deleted task back on the next launch.
            flushLayout()
        }
        do {
            try records.remove(id: taskID)
        } catch {
            throw TaskError("Toastty could not delete the task: \(error.localizedDescription)")
        }
        try? fileManager.removeItem(at: attachmentsDirectoryURL.appending(path: taskID.uuidString, directoryHint: .isDirectory))
        ToasttyLog.info("Deleted a task", category: .tasks, metadata: ["task_id": taskID.uuidString])
    }

    /// Removes the attached files of tasks that have been Done or Archived
    /// for a week; see `TaskAttachmentRetention`. Runs at launch and with
    /// the release monitor. Skipped while tasks.toml cannot be read, since
    /// `release_tags` decides whether a merged task is finished.
    func removeExpiredAttachments() {
        guard let config = try? configLoader() else { return }
        let date = now()
        for record in records.records {
            let directoryURL = attachmentsDirectoryURL.appending(path: record.id.uuidString, directoryHint: .isDirectory)
            let releaseTagsConfigured = record.projectRoot.flatMap {
                config.workspace(forProjectRoot: $0, homeDirectoryPath: homeDirectoryPath)?.releaseTags
            } != nil
            let taskSpaceOpen = record.taskSpaceWorkspaceID.map { store.state.workspacesByID[$0] != nil } ?? false
            let step = TaskAttachmentRetention.step(
                record,
                hasFiles: fileManager.fileExists(atPath: directoryURL.path),
                releaseTagsConfigured: releaseTagsConfigured,
                taskSpaceOpen: taskSpaceOpen,
                now: date
            )
            switch step {
            case .none:
                continue
            case .startClock:
                records.update(id: record.id) { $0.attachmentsFinishedSeenAt = date }
            case .resetClock:
                records.update(id: record.id) { $0.attachmentsFinishedSeenAt = nil }
            case .remove:
                do {
                    try fileManager.removeItem(at: directoryURL)
                } catch {
                    ToasttyLog.warning(
                        "Could not remove a finished task's attachments",
                        category: .tasks,
                        metadata: ["task_id": record.id.uuidString, "error": error.localizedDescription]
                    )
                    continue
                }
                records.update(id: record.id) { $0.attachmentsRemovedAt = date }
                ToasttyLog.info("Removed a finished task's attachments", category: .tasks, metadata: ["task_id": record.id.uuidString])
            }
        }
    }

    // MARK: - Launch reconciliation

    /// Brings records and workspaces back in line after a launch: a setup
    /// that the last run did not finish is marked failed, unless its agent
    /// had already started, and a task space whose record is missing gets
    /// one rebuilt from what the workspace shows.
    func reconcileAfterLaunch() {
        // An archive or a release cleanup that a quit interrupted shows as
        // stopped, so Clean Up continues it from what is still there.
        for record in records.records {
            guard let cleanup = record.cleanup, cleanup.kind != .merge,
                  cleanup.finishedAt == nil, cleanup.problem == nil else { continue }
            records.update(id: record.id) {
                $0.cleanup?.problem = "Toastty quit before the cleanup finished. Clean Up continues it."
            }
        }
        // Triage changes nothing outside the record, so a triage the last
        // run did not finish simply runs again.
        for record in records.records where record.setup == .routing && setupAttempts[record.id] == nil {
            startRouting(taskID: record.id)
        }
        for record in records.records where record.setup == .settingUp && setupAttempts[record.id] == nil {
            if record.operation.agentLaunch != nil {
                saveOrDefer(taskID: record.id) {
                    $0.setup = .started
                    if $0.startWork != nil { $0.startWork?.state = .finished }
                }
            } else {
                let reason = "Toastty quit before setup finished. Retry to continue."
                saveOrDefer(taskID: record.id) {
                    $0.setup = .setupFailed(reason: reason)
                    if $0.startWork != nil { $0.startWork?.state = .failed(reason: reason) }
                }
            }
        }
        for record in records.records
        where record.setup == .started && record.startWork?.state == .running && startWorkAttempts[record.id] == nil {
            if record.operation.worktreeSession?.nativeConversationID != nil || record.operation.sourceOutcome != nil {
                // The agent already works in the worktree; only closing the
                // old session was left.
                saveOrDefer(taskID: record.id) {
                    if $0.operation.sourceOutcome == nil {
                        $0.operation.sourceOutcome = .kept(reason: "Toastty quit before it closed this session.")
                    }
                    $0.startWork?.state = .finished
                }
            } else {
                saveOrDefer(taskID: record.id) {
                    $0.startWork?.state = .failed(reason: "Toastty quit before the move into the worktree finished. Retry to continue.")
                }
            }
        }
        for workspace in store.state.workspacesByID.values {
            guard let taskID = workspace.taskID, records.record(id: taskID) == nil else { continue }
            let parent = workspace.parentWorkspaceID.flatMap { store.state.workspacesByID[$0] }
            let panelID = workspace.orderedTabs.first?.panels.keys.sorted { $0.uuidString < $1.uuidString }.first
            let rebuilt = TaskRecord(
                id: taskID,
                createdAt: now(),
                text: workspace.title,
                title: workspace.title,
                slug: TaskRecord.sanitizedSlug(workspace.title) ?? "task",
                source: .recovered,
                workspaceID: parent?.id,
                projectRoot: parent?.rootDirectory,
                setup: .started,
                operation: TaskOperation(
                    taskSpace: panelID.map { TaskOperation.TaskSpace(workspaceID: workspace.id, panelID: $0) }
                )
            )
            do {
                try records.insert(rebuilt)
            } catch {
                ToasttyLog.warning("Failed saving a rebuilt task record", category: .tasks, metadata: [
                    "task_id": taskID.uuidString,
                    "error": error.localizedDescription,
                ])
                continue
            }
            ToasttyLog.warning("Rebuilt a missing task record from its task space", category: .tasks, metadata: [
                "task_id": taskID.uuidString,
                "workspace_id": workspace.id.uuidString,
            ])
        }
        // Saved watches keep waiting across a relaunch; old fired ones go.
        evaluateWatches()
        startWatchMonitorIfNeeded()
    }

    // MARK: - Setup

    func startSetup(taskID: UUID) {
        let attempt = UUID()
        setupAttempts[taskID] = attempt
        setupTasks.removeValue(forKey: taskID)?.cancel()
        setupTasks[taskID] = Task { [weak self] in
            await self?.runSetup(taskID: taskID, attempt: attempt)
        }
    }

    /// Saves a change at once; if the disk refuses it, keeps it in memory
    /// and saves it with the next delayed write. For bookkeeping after the
    /// fact, where stopping would not undo anything.
    func saveOrDefer(taskID: UUID, _ body: (inout TaskRecord) -> Void) {
        do {
            try records.save(id: taskID, body)
        } catch {
            ToasttyLog.warning("Failed saving a task record at once", category: .tasks, metadata: [
                "task_id": taskID.uuidString,
                "error": error.localizedDescription,
            ])
            records.update(id: taskID, body)
        }
    }

    func isCurrent(taskID: UUID, attempt: UUID) -> Bool {
        setupAttempts[taskID] == attempt
            && records.record(id: taskID)?.setup == .settingUp
            && Task.isCancelled == false
    }

    private func runSetup(taskID: UUID, attempt: UUID) async {
        guard isCurrent(taskID: taskID, attempt: attempt),
              let record = records.record(id: taskID),
              let resolved = record.resolved,
              let profileID = resolved.agent else {
            setupFailed(taskID: taskID, attempt: attempt, reason: "The task has no agent. Delete it and create it again.")
            return
        }
        guard let workspaceID = record.workspaceID,
              let windowID = store.state.workspaceSelection(containingWorkspaceID: workspaceID)?.windowID else {
            setupFailed(taskID: taskID, attempt: attempt, reason: "The task's workspace is closed. Open it, then retry.")
            return
        }
        guard let projectRoot = record.projectRoot, isDirectory(projectRoot) else {
            setupFailed(
                taskID: taskID,
                attempt: attempt,
                reason: "The project directory \(record.projectRoot ?? "") no longer exists."
            )
            return
        }

        // 0. With --start-work, the worktree, which the task space's terminal
        // and the agent then use.
        var directory = projectRoot
        var worktree: TaskOperation.Worktree?
        if record.startWork != nil {
            guard let prepared = await prepareWorktree(taskID: taskID, job: .setup(attempt)) else { return }
            worktree = prepared
            directory = prepared.path
        }

        // 1. The task space. One that an earlier attempt made is reused,
        // and if an agent already runs there, the task has started.
        let taskSpace: TaskOperation.TaskSpace
        if let existing = record.operation.taskSpace, store.state.workspacesByID[existing.workspaceID] != nil {
            if record.operation.agentLaunch != nil || hasActiveSession(existing.workspaceID) {
                finishStarted(taskID: taskID, attempt: attempt)
                return
            }
            guard let panelID = reusablePanel(in: existing.workspaceID, preferred: existing.panelID, directory: directory) else {
                setupFailed(taskID: taskID, attempt: attempt, reason: "Toastty could not open a terminal in the task space.")
                return
            }
            taskSpace = TaskOperation.TaskSpace(workspaceID: existing.workspaceID, panelID: panelID)
            saveOrDefer(taskID: taskID) { $0.operation.taskSpace = taskSpace }
        } else {
            taskSpace = TaskOperation.TaskSpace(workspaceID: UUID(), panelID: UUID())
            // Saved first: after a crash, a retry finds this task space
            // instead of making a second one. Nothing is made if the save
            // fails.
            do {
                try records.save(id: taskID) {
                    $0.operation.taskSpace = taskSpace
                    $0.operation.agentLaunch = nil
                }
            } catch {
                setupFailed(taskID: taskID, attempt: attempt, reason: "Toastty could not save the task: \(error.localizedDescription)")
                return
            }
            guard store.send(.createTaskSpace(
                windowID: windowID,
                workspaceID: taskSpace.workspaceID,
                panelID: taskSpace.panelID,
                parentWorkspaceID: workspaceID,
                spawningSessionID: creatorSessionID(of: record),
                taskID: taskID,
                title: record.slug,
                terminalCWD: directory
            )) else {
                saveOrDefer(taskID: taskID) { $0.operation.taskSpace = nil }
                setupFailed(taskID: taskID, attempt: attempt, reason: "Toastty could not create the task space.")
                return
            }
            flushLayout()
            if let creator = creatorSessionID(of: record) {
                grantScope(creator, taskSpace.workspaceID)
            }
        }

        // 2. The agent.
        guard let launcher else {
            setupFailed(taskID: taskID, attempt: attempt, reason: "The agent launcher is not available.")
            return
        }
        let base = records.record(id: taskID)?.operation.base
        var firstPrompt = resolved.prompt
        var prompt = TaskPrompt.compose(
            firstPrompt: firstPrompt,
            text: record.text,
            attachmentPaths: record.attachments.map(\.path),
            worktree: worktree,
            base: base
        )
        // Routing checked the message without the worktree line, which is
        // known only now. Triage's own prompt is the part that can go; the
        // caller's message was checked when the task was made.
        if prompt.utf8.count > AgentLaunchService.maximumInitialPromptUTF8Count,
           firstPrompt != nil, record.pinned.prompt == nil {
            firstPrompt = nil
            prompt = TaskPrompt.compose(
                firstPrompt: nil,
                text: record.text,
                attachmentPaths: record.attachments.map(\.path),
                worktree: worktree,
                base: base
            )
            let dropped = "Toastty left out triage's first prompt, which made the agent's first message longer than \(AgentLaunchService.maximumInitialPromptUTF8Count / 1024) KB."
            saveOrDefer(taskID: taskID) {
                $0.resolved?.prompt = nil
                $0.triageNote = [$0.triageNote, dropped].compactMap { $0 }.joined(separator: " ")
            }
        }
        let parentSessionID = creatorSessionID(of: record)
        let result: AgentLaunchResult
        do {
            result = try await Self.launchWhenTerminalIsReady(timeout: terminalReadinessTimeout) {
                try await launcher.launchTask(
                    profileID: profileID,
                    workspaceID: taskSpace.workspaceID,
                    panelID: taskSpace.panelID,
                    cwd: directory,
                    model: resolved.model,
                    reasoningEffort: resolved.effort,
                    initialPrompt: prompt,
                    parentSessionID: parentSessionID,
                    forkFromSessionID: nil,
                    // A task session is unscoped unless the session that
                    // made the task was scoped; then it keeps that scope,
                    // with this task space added.
                    scopedWorkspaceIDs: record.creatorScope.map { $0.union([taskSpace.workspaceID]) },
                    beforeDispatch: { [weak self] in
                        guard let self, self.isCurrent(taskID: taskID, attempt: attempt) else {
                            throw CancellationError()
                        }
                    }
                )
            }
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            if case .commandDeliveryUncertain? = error as? AgentLaunchError {
                setupFailed(
                    taskID: taskID,
                    attempt: attempt,
                    reason: "The agent command may not have reached the terminal. Check the task space before you retry."
                )
                return
            }
            setupFailed(taskID: taskID, attempt: attempt, reason: Self.launchFailureReason(for: error))
            return
        }
        saveOrDefer(taskID: taskID) {
            $0.operation.agentLaunch = TaskOperation.AgentLaunch(sessionID: result.sessionID, at: now())
        }
        finishStarted(taskID: taskID, attempt: attempt)
    }

    private func creatorSessionID(of record: TaskRecord) -> String? {
        if case .agent(let sessionID) = record.source { return sessionID }
        return nil
    }

    private func finishStarted(taskID: UUID, attempt: UUID) {
        guard setupAttempts[taskID] == attempt else { return }
        setupAttempts[taskID] = nil
        setupTasks[taskID] = nil
        saveOrDefer(taskID: taskID) {
            $0.setup = .started
            if $0.startWork != nil { $0.startWork?.state = .finished }
        }
        ToasttyLog.info("Started a task", category: .tasks, metadata: [
            "task_id": taskID.uuidString,
            "workspace_id": records.record(id: taskID)?.taskSpaceWorkspaceID?.uuidString ?? "",
        ])
    }

    func setupFailed(taskID: UUID, attempt: UUID, reason: String) {
        guard setupAttempts[taskID] == attempt else { return }
        setupAttempts[taskID] = nil
        setupTasks[taskID] = nil
        saveOrDefer(taskID: taskID) {
            $0.setup = .setupFailed(reason: reason)
            if $0.startWork != nil { $0.startWork?.state = .failed(reason: reason) }
        }
        ToasttyLog.info("Task setup failed", category: .tasks, metadata: [
            "task_id": taskID.uuidString,
            "reason": reason,
        ])
    }

    // MARK: - Routing

    /// Triage needs a command to run.
    private func isTriageEnabled(_ config: TasksConfig) -> Bool {
        triageRunner != nil && config.triage?.command != nil
    }

    private func startRouting(taskID: UUID) {
        let attempt = UUID()
        setupAttempts[taskID] = attempt
        setupTasks.removeValue(forKey: taskID)?.cancel()
        setupTasks[taskID] = Task { [weak self] in
            await self?.route(taskID: taskID, attempt: attempt)
        }
    }

    private func isRouting(taskID: UUID, attempt: UUID) -> Bool {
        setupAttempts[taskID] == attempt
            && records.record(id: taskID)?.setup == .routing
            && Task.isCancelled == false
    }

    /// Fills what the caller left out, with triage when it is on and
    /// `[defaults]` after it, then starts setup. Without a workspace, the
    /// task waits for the user to pick one.
    private func route(taskID: UUID, attempt: UUID) async {
        guard isRouting(taskID: taskID, attempt: attempt), let record = records.record(id: taskID) else { return }
        let config: TasksConfig
        do {
            config = try configLoader()
        } catch {
            routingEnded(taskID: taskID, attempt: attempt) {
                $0.setup = .setupFailed(reason: "\(error.localizedDescription) Fix the file, then retry.")
            }
            return
        }

        // A workspace the caller or the user chose that has closed sends the
        // task back to the user; triage never moves it somewhere else.
        if let chosenID = record.workspaceID, store.state.workspacesByID[chosenID] == nil {
            routingEnded(taskID: taskID, attempt: attempt) {
                $0.setup = .needsWorkspace(reason: "The task's workspace closed. Pick a workspace.")
            }
            return
        }
        let fixedID = record.workspaceID
        // Triage may choose only agents that take the model and effort the
        // caller set.
        let agents = triageAgents().filter {
            (record.pinned.model == nil || $0.acceptsModel) && (record.pinned.effort == nil || $0.acceptsEffort)
        }
        var workspaces = await openWorkspaces(config: config)
        guard isRouting(taskID: taskID, attempt: attempt) else { return }
        var closed = fixedID == nil ? closedWorkspaces(config: config, open: workspaces) : []
        let pinnedAgent = record.pinned.agent.flatMap { id in agents.first { $0.id == id } }
        let missing = TaskTriage.missingFields(pinned: record.pinned, workspaceID: fixedID, pinnedAgent: pinnedAgent)

        var answer: TaskTriage.Answer?
        var triageFailure: String?
        if missing.isEmpty == false, isTriageEnabled(config), let triage = config.triage, let triageRunner {
            do {
                let input = TaskTriage.Input(
                    text: record.text,
                    fileNames: record.attachments.map(\.displayName),
                    fixed: record.pinned,
                    fixedWorkspace: fixedID.flatMap { id in workspaces.first { $0.id == id } },
                    workspaces: workspaces,
                    closedWorkspaces: closed,
                    agents: agents,
                    guidelines: try triageGuidelines(triage)
                )
                ToasttyLog.info("Running triage", category: .tasks, metadata: [
                    "task_id": taskID.uuidString,
                    "missing": missing.map(\.rawValue).joined(separator: ","),
                ])
                switch await triageRunner.run(prompt: TaskTriage.prompt(for: input), triage: triage) {
                case .success(let triageAnswer):
                    answer = triageAnswer
                case .failure(.cancelled):
                    return
                case .failure(let failure):
                    triageFailure = failure.message
                }
            } catch {
                triageFailure = "Triage failed: \(error.localizedDescription)"
            }
            guard isRouting(taskID: taskID, attempt: attempt) else { return }
            // A workspace may have closed, or opened, while triage ran.
            workspaces = await openWorkspaces(config: config)
            guard isRouting(taskID: taskID, attempt: attempt) else { return }
            if fixedID == nil {
                closed = closedWorkspaces(config: config, open: workspaces)
            }
        }
        guard let current = records.record(id: taskID) else { return }
        let stillFixedID = fixedID.flatMap { store.state.workspacesByID[$0] == nil ? nil : $0 }
        let resolution = TaskTriage.resolve(
            pinned: current.pinned,
            workspaceID: stillFixedID,
            answer: answer,
            workspaces: workspaces,
            closedWorkspaces: closed,
            agents: agents,
            homeDirectoryPath: homeDirectoryPath
        )
        var notes = triageFailure.map { [$0] } ?? []
        if resolution.rejected.isEmpty == false {
            notes.append("Toastty ignored triage's " + resolution.rejected.joined(separator: "; ") + ".")
        }
        let triageNote = notes.isEmpty ? nil : notes.joined(separator: " ")
        if let triageNote {
            ToasttyLog.info("Triage did not answer in full", category: .tasks, metadata: [
                "task_id": taskID.uuidString,
                "note": triageNote,
            ])
        }
        let title = current.titleSetByUser ? current.title : resolution.title ?? current.title
        var slug = current.slug
        if current.pinned.slug == nil, let triageSlug = resolution.slug, triageSlug != current.slug {
            let taken = Set(records.records.lazy.filter { $0.id != taskID }.map(\.slug))
            slug = TaskRecord.uniqueSlug(triageSlug, taken: taken)
        }

        let fixedClosed = fixedID != nil && stillFixedID == nil
        guard fixedClosed == false, let workspaceID = resolution.workspaceID, store.state.workspacesByID[workspaceID] != nil else {
            let reason: String
            if fixedClosed {
                reason = "The task's workspace closed. Pick a workspace."
            } else if let triageFailure {
                reason = "\(triageFailure) Pick a workspace."
            } else if isTriageEnabled(config) {
                reason = resolution.workspaceReason ?? "Triage did not choose an open workspace."
            } else {
                reason = "No workspace was named, and triage is off. Pick a workspace for this task."
            }
            let suggestion = fixedClosed ? nil : resolution.suggestedWorkspace.map {
                TaskWorkspaceSuggestion(title: $0.title, rootDirectory: $0.rootDirectory)
            }
            routingEnded(taskID: taskID, attempt: attempt) {
                $0.title = title
                $0.slug = slug
                $0.triageNote = triageNote
                $0.suggestedWorkspace = suggestion
                $0.setup = .needsWorkspace(reason: reason)
            }
            return
        }

        let projectRoot: (path: String, isNew: Bool)
        var resolved: TaskFields
        var finalNote = triageNote
        do {
            projectRoot = try resolvedProjectRoot(workspaceID: workspaceID)
            // A worktree needs a git repository at the project root the task
            // now has.
            if let startWork = current.startWork {
                _ = try newStartWork(
                    branchPrefix: startWork.branchPrefix,
                    base: startWork.base,
                    source: startWork.source,
                    projectRoot: projectRoot.path,
                    config: config
                )
            }
            guard resolution.agent ?? config.defaults.agent != nil else {
                throw TaskError("Triage did not choose an agent, and [defaults] in ~/.toastty/tasks.toml names none. Set agent there, then retry.")
            }
            resolved = try resolvedFields(
                pinned: TaskFields(
                    workspaceID: current.pinned.workspaceID,
                    agent: resolution.agent,
                    model: resolution.model,
                    effort: resolution.effort,
                    prompt: resolution.prompt
                ),
                workspaceID: workspaceID,
                defaults: config.defaults
            )
            let firstMessage = TaskPrompt.compose(
                firstPrompt: resolved.prompt,
                text: current.text,
                attachmentPaths: current.attachments.map(\.path)
            )
            // The caller's own message was checked when the task was made, so
            // only triage's prompt can push it over; the task starts without it.
            if firstMessage.utf8.count > AgentLaunchService.maximumInitialPromptUTF8Count, current.pinned.prompt == nil {
                resolved.prompt = nil
                let dropped = "Toastty left out triage's first prompt, which made the agent's first message longer than \(AgentLaunchService.maximumInitialPromptUTF8Count / 1024) KB."
                finalNote = [triageNote, dropped].compactMap { $0 }.joined(separator: " ")
            }
        } catch {
            routingEnded(taskID: taskID, attempt: attempt) {
                $0.title = title
                $0.slug = slug
                $0.triageNote = triageNote
                $0.setup = .setupFailed(reason: error.localizedDescription)
            }
            return
        }

        do {
            // Saved at once: setup reads these fields, and a crash after
            // this point must not run triage a second time.
            try records.save(id: taskID) {
                $0.workspaceID = workspaceID
                $0.projectRoot = projectRoot.path
                $0.resolved = resolved
                $0.title = title
                $0.slug = slug
                $0.triageNote = finalNote
                $0.suggestedWorkspace = nil
                $0.setup = .settingUp
            }
        } catch {
            routingEnded(taskID: taskID, attempt: attempt) {
                $0.setup = .setupFailed(reason: "Toastty could not save the task: \(error.localizedDescription)")
            }
            return
        }
        if projectRoot.isNew {
            _ = store.send(.setWorkspaceRootDirectory(workspaceID: workspaceID, rootDirectory: projectRoot.path))
        }
        ToasttyLog.info("Routed a task", category: .tasks, metadata: [
            "task_id": taskID.uuidString,
            "workspace_id": workspaceID.uuidString,
            "agent": resolved.agent ?? "",
            "triage": String(answer != nil),
        ])
        startSetup(taskID: taskID)
    }

    private func routingEnded(taskID: UUID, attempt: UUID, _ body: (inout TaskRecord) -> Void) {
        guard setupAttempts[taskID] == attempt else { return }
        setupAttempts[taskID] = nil
        setupTasks[taskID] = nil
        saveOrDefer(taskID: taskID, body)
    }

    /// The installed agents that can take a task as their first message.
    private func triageAgents() -> [TaskTriage.Agent] {
        (launcher?.launchProfileSummaries() ?? [])
            .filter { $0.isInstalled && $0.acceptsInitialPrompt }
            .map(Self.triageAgent)
    }

    private static func triageAgent(_ profile: AgentLaunchProfileSummary) -> TaskTriage.Agent {
        TaskTriage.Agent(
            id: profile.profileID,
            name: profile.displayName,
            acceptsModel: profile.supportsModel,
            acceptsEffort: profile.supportsReasoningEffort
        )
    }

    /// The open top-level workspaces with a known directory, in window
    /// order, each with the guidelines from its tasks.toml section. A root
    /// that is not saved is looked up off the main actor; a workspace that
    /// closed meanwhile is left out.
    private func openWorkspaces(config: TasksConfig) async -> [TaskTriage.Workspace] {
        let candidates = topLevelWorkspaces().map { workspace in
            (
                id: workspace.id,
                title: workspace.title,
                savedRoot: workspace.rootDirectory,
                terminalDirectory: workspace.rootDirectory == nil
                    ? Self.firstTerminalDirectory(in: workspace, fileManager: fileManager)
                    : nil
            )
        }
        let roots = await Task.detached(priority: .userInitiated) {
            candidates.map { candidate -> String? in
                if let saved = candidate.savedRoot { return saved }
                guard let directory = candidate.terminalDirectory else { return nil }
                return RepositoryRootLocator.inferRepoRoot(from: directory) ?? directory
            }
        }.value
        return zip(candidates, roots).compactMap { candidate, root in
            guard let root, store.state.workspacesByID[candidate.id] != nil else { return nil }
            return TaskTriage.Workspace(
                id: candidate.id,
                title: candidate.title,
                rootDirectory: root,
                guidelines: config.workspace(forProjectRoot: root, homeDirectoryPath: homeDirectoryPath)?.guidelines
            )
        }
    }

    /// Whether an open top-level workspace is on `root`: its saved root, or
    /// a first terminal at or inside it. No git lookup, so it is cheap
    /// enough for the picker on the main actor.
    private func openWorkspace(onRoot root: String) -> WorkspaceState? {
        let target = TasksConfigFile.normalizedPath(root, homeDirectoryPath: homeDirectoryPath)
        return topLevelWorkspaces().first { workspace in
            guard let directory = workspace.rootDirectory ?? Self.firstTerminalDirectory(in: workspace, fileManager: fileManager) else {
                return false
            }
            let normalized = TasksConfigFile.normalizedPath(directory, homeDirectoryPath: homeDirectoryPath)
            if workspace.rootDirectory != nil { return normalized == target }
            return normalized == target || normalized.hasPrefix(target + "/")
        }
    }

    private func topLevelWorkspaces() -> [WorkspaceState] {
        store.state.windows
            .flatMap(\.workspaceIDs)
            .compactMap { store.state.workspacesByID[$0] }
            .filter { $0.parentWorkspaceID == nil }
    }

    /// A workspace's saved root, else its first terminal's git root, else
    /// that terminal's directory.
    static func rootDirectory(of workspace: WorkspaceState, fileManager: FileManager = .default) -> String? {
        if let root = workspace.rootDirectory { return root }
        guard let directory = firstTerminalDirectory(in: workspace, fileManager: fileManager) else { return nil }
        return RepositoryRootLocator.inferRepoRootBestEffort(from: directory).repoRoot ?? directory
    }

    /// `[triage] guidelines`, or the file `guidelines_file` names: an
    /// absolute path, one under `~`, or one relative to `~/.toastty`.
    private func triageGuidelines(_ triage: TasksConfig.Triage) throws -> String? {
        if let guidelines = triage.guidelines { return guidelines }
        guard let file = triage.guidelinesFile else { return nil }
        var path = file
        if path == "~" || path.hasPrefix("~/") {
            path = homeDirectoryPath + path.dropFirst()
        } else if path.hasPrefix("/") == false {
            path = TasksConfigFile.fileURL(homeDirectoryPath: homeDirectoryPath)
                .deletingLastPathComponent()
                .appending(path: path)
                .path(percentEncoded: false)
        }
        do {
            let text = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            throw TaskError("could not read guidelines_file \(path)")
        }
    }

    // MARK: - Resolution

    private func validatedClientRequestID(_ raw: String?) throws -> String? {
        guard let value = raw.flatMap(taskNonEmpty) else { return nil }
        guard value.count <= TaskRecord.maximumClientRequestIDLength,
              value.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }) else {
            throw TaskError("A request ID must be printable ASCII with no spaces, at most \(TaskRecord.maximumClientRequestIDLength) characters.")
        }
        return value
    }

    /// The top-level workspace a task belongs to: the one asked for, or the
    /// calling agent's own. A subspace resolves to its parent. `nil` when
    /// neither is known; triage or the user chooses it later.
    private func resolvedWorkspaceID(_ requested: UUID?, caller: TaskCaller) throws -> UUID? {
        guard let candidate = requested ?? caller.workspaceID else {
            return nil
        }
        guard let workspace = store.state.workspacesByID[candidate] else {
            throw TaskError("No open workspace has ID \(candidate.uuidString).")
        }
        let rootID = store.state.subspaceParentIDsByWorkspaceID()[candidate] ?? workspace.id
        guard store.state.workspacesByID[rootID] != nil else {
            throw TaskError("No open workspace has ID \(rootID.uuidString).")
        }
        return rootID
    }

    /// The workspace's root directory. When it has none yet, it comes from
    /// its first terminal's git root, or that terminal's directory outside a
    /// repository; `isNew` tells the caller to save it on the workspace once
    /// the task is saved.
    func resolvedProjectRoot(workspaceID: UUID) throws -> (path: String, isNew: Bool) {
        guard let workspace = store.state.workspacesByID[workspaceID] else {
            throw TaskError("No open workspace has ID \(workspaceID.uuidString).")
        }
        if let rootDirectory = workspace.rootDirectory {
            return (rootDirectory, false)
        }
        guard let directory = Self.firstTerminalDirectory(in: workspace, fileManager: fileManager) else {
            throw TaskError("Toastty could not find the directory of workspace \(workspace.title). Open a terminal there, then try again.")
        }
        let resolution = RepositoryRootLocator.inferRepoRootBestEffort(from: directory, timeout: 0.5)
        // A timed-out lookup is not saved, so the next task tries again.
        return (resolution.repoRoot ?? directory, resolution.timedOut == false)
    }

    /// The pinned fields, completed from `[defaults]`. A pinned value that
    /// cannot work fails the request; a default that does not fit the
    /// chosen agent is left out.
    func resolvedFields(pinned: TaskFields, workspaceID: UUID?, defaults: TasksConfig.Defaults) throws -> TaskFields {
        guard let agent = pinned.agent ?? defaults.agent else {
            throw TaskError("Name an agent with --agent <profile>, or set agent in the [defaults] table of ~/.toastty/tasks.toml.")
        }
        let profile = try checkedProfile(agent)
        var fields = TaskFields(workspaceID: workspaceID, agent: agent, prompt: pinned.prompt)
        if let model = pinned.model {
            try checkModel(model, profile: profile)
            fields.model = model
        } else if profile.supportsModel, pinned.agent == nil || pinned.agent == defaults.agent {
            fields.model = defaults.model
        }
        if let effort = pinned.effort {
            try checkEffort(effort, profile: profile)
            fields.effort = effort
        } else if profile.supportsReasoningEffort, pinned.agent == nil || pinned.agent == defaults.agent {
            fields.effort = defaults.effort
        }
        return fields
    }

    /// Checks the agent, model and effort a caller set, before triage or
    /// `[defaults]` add anything, and returns the agent's profile.
    private func checkedPinnedFields(_ pinned: TaskFields) throws -> AgentLaunchProfileSummary? {
        let profile = try pinned.agent.map(checkedProfile)
        if let model = pinned.model { try checkModel(model, profile: profile) }
        if let effort = pinned.effort { try checkEffort(effort, profile: profile) }
        return profile
    }

    private func checkedProfile(_ agent: String) throws -> AgentLaunchProfileSummary {
        let profiles = launcher?.launchProfileSummaries() ?? []
        guard let profile = profiles.first(where: { $0.profileID == agent }) else {
            let available = profiles.map(\.profileID).joined(separator: ", ")
            throw TaskError("Agent \(agent) is not a profile in agents.toml\(available.isEmpty ? "" : " (available: \(available))").")
        }
        guard profile.acceptsInitialPrompt else {
            throw TaskError("Agent \(agent) cannot take the task as its first message.")
        }
        return profile
    }

    /// `profile` is `nil` when triage will choose the agent; then only the
    /// value's form is checked.
    private func checkModel(_ model: String, profile: AgentLaunchProfileSummary?) throws {
        if let profile, profile.supportsModel == false {
            throw TaskError("Agent \(profile.profileID) does not accept a model.")
        }
        guard RemoteSessionStartPolicy.isValidSelectionValue(model, maximumLength: RemoteSessionStartPolicy.maximumModelLength) else {
            throw TaskError("A model must be one word with no spaces that does not start with a dash.")
        }
    }

    private func checkEffort(_ effort: String, profile: AgentLaunchProfileSummary?) throws {
        if let profile, profile.supportsReasoningEffort == false {
            throw TaskError("Agent \(profile.profileID) does not accept an effort.")
        }
        guard RemoteSessionStartPolicy.isValidSelectionValue(effort, maximumLength: RemoteSessionStartPolicy.maximumReasoningEffortLength) else {
            throw TaskError("An effort must be one word with no spaces that does not start with a dash.")
        }
    }

    /// The pinned title, checked, or the first line of the first fallback
    /// that has one; and the pinned slug, checked, or one made from the
    /// title that no other task uses.
    func titleAndSlug(pinnedTitle: String?, pinnedSlug: String?, fallbacks: [String]) throws -> (title: String, slug: String) {
        let title: String
        if let pinnedTitle {
            guard let cleaned = TaskRecord.defaultTitle(for: pinnedTitle), cleaned == pinnedTitle else {
                throw TaskError("A title must be one line of at most \(TaskRecord.maximumTitleLength) characters.")
            }
            title = cleaned
        } else {
            title = fallbacks.lazy.compactMap(TaskRecord.defaultTitle(for:)).first ?? "Untitled task"
        }
        let takenSlugs = Set(records.records.map(\.slug))
        let slug: String
        if let pinnedSlug = pinnedSlug.flatMap(taskNonEmpty) {
            guard TaskRecord.sanitizedSlug(pinnedSlug) == pinnedSlug else {
                throw TaskError("A slug must be lowercase letters, digits and single hyphens, at most \(TaskRecord.maximumSlugLength) characters.")
            }
            guard takenSlugs.contains(pinnedSlug) == false else {
                throw TaskError("Another task already uses the slug \(pinnedSlug).")
            }
            slug = pinnedSlug
        } else {
            slug = TaskRecord.uniqueSlug(TaskRecord.sanitizedSlug(title) ?? "task", taken: takenSlugs)
        }
        return (title, slug)
    }

    // MARK: - Attachments

    /// The file a requested path names, with symbolic links resolved so
    /// Toastty copies the file itself, after checking that it is a regular
    /// file within the size limit. Opening without following it into a FIFO
    /// or device keeps a bad path from blocking the app.
    private func attachableFile(_ path: String) throws -> String {
        let name = (path as NSString).lastPathComponent
        guard path.hasPrefix("/") else {
            throw TaskError("\(path): attachments need an absolute path.")
        }
        let resolved = URL(filePath: path).resolvingSymlinksInPath().path(percentEncoded: false)
        let descriptor = open(resolved, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw TaskError("\(name): \(String(cString: strerror(errno))).")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw TaskError("\(name) is not a regular file.")
        }
        guard info.st_size <= Self.maximumAttachmentBytes else {
            throw TaskError("\(name) is larger than \(Self.maximumAttachmentBytes / 1024 / 1024) MB.")
        }
        return resolved
    }

    private static func uniqueFileName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var number = 2
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(number)" : "\(base)-\(number).\(ext)"
            if taken.contains(candidate) == false { return candidate }
            number += 1
        }
    }

    // MARK: - Task space helpers

    func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The task space's terminal when it is still there, else a new
    /// background terminal tab in the project directory.
    func reusablePanel(in workspaceID: UUID, preferred panelID: UUID, directory: String) -> UUID? {
        if let workspace = store.state.workspacesByID[workspaceID],
           case .terminal? = workspace.panelState(for: panelID) {
            return panelID
        }
        let newPanelID = UUID()
        guard store.send(.createBackgroundTerminalTab(
            workspaceID: workspaceID,
            tabID: UUID(),
            panelID: newPanelID,
            terminalCWD: directory
        )) else { return nil }
        return newPanelID
    }

    /// Closes a task space setup made, but only while it is still what setup
    /// made: never visited, one tab with its one terminal, and no agent ever
    /// started there, since an agent that exited may have left output.
    private func closeTaskSpaceIfUnused(_ taskSpace: TaskOperation.TaskSpace, record: TaskRecord) -> Bool {
        guard record.operation.agentLaunch == nil,
              let workspace = store.state.workspacesByID[taskSpace.workspaceID],
              workspace.hasBeenVisited == false,
              workspace.tabIDs.count == 1,
              let tab = workspace.orderedTabs.first,
              tab.panels.count == 1,
              tab.panels[taskSpace.panelID] != nil,
              hasActiveSession(taskSpace.workspaceID) == false else { return false }
        return store.send(.closeWorkspace(workspaceID: taskSpace.workspaceID))
    }

    /// The first terminal, in tab order, whose directory is known and still
    /// exists. This does not follow focus, so the answer stays the same.
    static func firstTerminalDirectory(in workspace: WorkspaceState, fileManager: FileManager = .default) -> String? {
        for tab in workspace.orderedTabs {
            for slot in tab.layoutTree.allSlotInfos {
                guard case .terminal(let terminal) = tab.panels[slot.panelID],
                      let directory = terminal.agentLaunchWorkingDirectory else { continue }
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue {
                    return directory
                }
            }
        }
        return nil
    }

    /// A new terminal is not ready at once: it reports itself busy until its
    /// shell prints the first prompt, and its surface can refuse input for a
    /// moment after that. Both refusals happen before any text is sent, so
    /// they are retried until `timeout` passes. A delivery the terminal did
    /// not confirm is never retried.
    static func launchWhenTerminalIsReady(
        timeout: Duration,
        attempt: @MainActor () async throws -> AgentLaunchResult
    ) async throws -> AgentLaunchResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            do {
                return try await attempt()
            } catch let error as AgentLaunchError {
                switch error {
                case .panelBusy, .terminalUnavailable:
                    guard clock.now < deadline else { throw error }
                    try await Task.sleep(for: .milliseconds(250))
                default:
                    throw error
                }
            }
        }
    }

    static func launchFailureReason(for error: any Error) -> String {
        guard let launchError = error as? AgentLaunchError else {
            return "The agent did not start: \(error.localizedDescription)"
        }
        switch launchError {
        case .panelBusy, .terminalUnavailable:
            return "The task space's terminal did not get ready in time. Retry to try again."
        default:
            return "The agent did not start: \(launchError.localizedDescription)"
        }
    }
}

func taskNonEmpty(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
