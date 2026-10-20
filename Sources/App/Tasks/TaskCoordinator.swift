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
    /// is scoped to its own task space. `beforeDispatch` runs directly
    /// before the command is sent; a throw there cancels the launch.
    func launchTask(
        profileID: String,
        workspaceID: UUID,
        panelID: UUID,
        cwd: String,
        model: String?,
        reasoningEffort: String?,
        initialPrompt: String,
        parentSessionID: String?,
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
            // An empty set scopes the session to its own task space.
            inheritedScopedWorkspaceIDs: [],
            parentSessionID: parentSessionID,
            focusPolicy: .preserveFirstResponder,
            beforeDispatch: beforeDispatch
        )
    }
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
    private let store: AppStore
    private weak var launcher: (any TaskAgentLaunching)?
    private let configLoader: () throws -> TasksConfig
    private let attachmentsDirectoryURL: URL
    private let hasActiveSession: (UUID) -> Bool
    /// Adds a task space to a session's workspace scope when that session
    /// is scoped; does nothing for an unscoped session.
    private let grantScope: (String, UUID) -> Void
    private let fileManager: FileManager
    private let now: () -> Date
    private let terminalReadinessTimeout: Duration

    /// One per running setup; a newer attempt or a delete makes an older
    /// one stop at its next check.
    private var setupAttempts: [UUID: UUID] = [:]
    private var setupTasks: [UUID: Task<Void, Never>] = [:]

    /// Saves the workspace layout at once. Setup calls it after it makes or
    /// unlinks a task space, so the layout on disk never lags a record that
    /// depends on it. Set once layout persistence exists.
    var flushLayout: () -> Void = {}

    init(
        records: TaskRecordStore,
        store: AppStore,
        launcher: (any TaskAgentLaunching)?,
        configLoader: @escaping () throws -> TasksConfig,
        attachmentsDirectoryURL: URL,
        hasActiveSession: @escaping (UUID) -> Bool,
        grantScope: @escaping (String, UUID) -> Void,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        terminalReadinessTimeout: Duration = .seconds(10)
    ) {
        self.records = records
        self.store = store
        self.launcher = launcher
        self.configLoader = configLoader
        self.attachmentsDirectoryURL = attachmentsDirectoryURL
        self.hasActiveSession = hasActiveSession
        self.grantScope = grantScope
        self.fileManager = fileManager
        self.now = now
        self.terminalReadinessTimeout = terminalReadinessTimeout
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
        let prompt = request.prompt.flatMap(nonEmpty)
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || prompt != nil else {
            throw TaskError("A task needs text or a prompt.")
        }
        guard request.files.count <= TaskRecord.maximumAttachmentCount else {
            throw TaskError("Attach at most \(TaskRecord.maximumAttachmentCount) files.")
        }
        let sources = try request.files.map(attachableFile)

        let workspaceID = try resolvedWorkspaceID(request.workspaceID, caller: caller)
        let projectRoot = try resolvedProjectRoot(workspaceID: workspaceID)
        let config: TasksConfig
        do {
            config = try configLoader()
        } catch {
            throw TaskError(error.localizedDescription)
        }
        let pinned = TaskFields(
            workspaceID: request.workspaceID,
            agent: request.agent.flatMap(nonEmpty),
            model: request.model.flatMap(nonEmpty),
            effort: request.effort.flatMap(nonEmpty),
            prompt: prompt
        )
        let resolved = try resolvedFields(pinned: pinned, workspaceID: workspaceID, defaults: config.defaults)

        let pinnedTitle = request.title.flatMap(nonEmpty)
        let title: String
        if let pinnedTitle {
            guard let cleaned = TaskRecord.defaultTitle(for: pinnedTitle), cleaned == pinnedTitle else {
                throw TaskError("A title must be one line of at most \(TaskRecord.maximumTitleLength) characters.")
            }
            title = cleaned
        } else {
            title = TaskRecord.defaultTitle(for: text)
                ?? prompt.flatMap(TaskRecord.defaultTitle(for:))
                ?? "Untitled task"
        }
        let takenSlugs = Set(records.records.map(\.slug))
        let slug: String
        if let pinnedSlug = request.slug.flatMap(nonEmpty) {
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
            projectRoot: projectRoot.path,
            setup: .settingUp
        )
        return TaskCreatePreparation(record: record, copies: copies, saveRootDirectory: projectRoot.isNew, existing: nil)
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
        guard let workspaceID = record.workspaceID, store.state.workspacesByID[workspaceID] != nil else {
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
        if preparation.saveRootDirectory, let projectRoot = record.projectRoot {
            _ = store.send(.setWorkspaceRootDirectory(workspaceID: workspaceID, rootDirectory: projectRoot))
        }
        ToasttyLog.info("Created a task", category: .tasks, metadata: [
            "task_id": record.id.uuidString,
            "workspace_id": workspaceID.uuidString,
            "agent": record.resolved?.agent ?? "",
            "attachments": String(record.attachments.count),
        ])
        startSetup(taskID: record.id)
        return record
    }

    // MARK: - Retry, delete

    /// Runs setup again for a task whose setup failed, from the last step
    /// it finished.
    func retry(taskID: UUID) throws {
        guard let record = records.record(id: taskID) else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        switch record.setup {
        case .setupFailed:
            break
        case .settingUp:
            throw TaskError("This task is still setting up.")
        case .started:
            throw TaskError("This task has already started.")
        }
        do {
            try records.save(id: taskID) { $0.setup = .settingUp }
        } catch {
            throw TaskError("Toastty could not save the task: \(error.localizedDescription)")
        }
        startSetup(taskID: taskID)
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

    // MARK: - Launch reconciliation

    /// Brings records and workspaces back in line after a launch: a setup
    /// that the last run did not finish is marked failed, unless its agent
    /// had already started, and a task space whose record is missing gets
    /// one rebuilt from what the workspace shows.
    func reconcileAfterLaunch() {
        for record in records.records where record.setup == .settingUp && setupAttempts[record.id] == nil {
            if record.operation.agentLaunch != nil {
                saveOrDefer(taskID: record.id) { $0.setup = .started }
            } else {
                saveOrDefer(taskID: record.id) {
                    $0.setup = .setupFailed(reason: "Toastty quit before setup finished. Retry to continue.")
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
    }

    // MARK: - Setup

    private func startSetup(taskID: UUID) {
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
    private func saveOrDefer(taskID: UUID, _ body: (inout TaskRecord) -> Void) {
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

    private func isCurrent(taskID: UUID, attempt: UUID) -> Bool {
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
        guard let directory = record.projectRoot, isDirectory(directory) else {
            setupFailed(
                taskID: taskID,
                attempt: attempt,
                reason: "The project directory \(record.projectRoot ?? "") no longer exists."
            )
            return
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
        let prompt = TaskPrompt.compose(
            firstPrompt: resolved.prompt,
            text: record.text,
            attachmentPaths: record.attachments.map(\.path)
        )
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
        saveOrDefer(taskID: taskID) { $0.setup = .started }
        ToasttyLog.info("Started a task", category: .tasks, metadata: [
            "task_id": taskID.uuidString,
            "workspace_id": records.record(id: taskID)?.taskSpaceWorkspaceID?.uuidString ?? "",
        ])
    }

    private func setupFailed(taskID: UUID, attempt: UUID, reason: String) {
        guard setupAttempts[taskID] == attempt else { return }
        setupAttempts[taskID] = nil
        setupTasks[taskID] = nil
        saveOrDefer(taskID: taskID) { $0.setup = .setupFailed(reason: reason) }
        ToasttyLog.info("Task setup failed", category: .tasks, metadata: [
            "task_id": taskID.uuidString,
            "reason": reason,
        ])
    }

    // MARK: - Resolution

    private func validatedClientRequestID(_ raw: String?) throws -> String? {
        guard let value = raw.flatMap(nonEmpty) else { return nil }
        guard value.count <= TaskRecord.maximumClientRequestIDLength,
              value.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }) else {
            throw TaskError("A request ID must be printable ASCII with no spaces, at most \(TaskRecord.maximumClientRequestIDLength) characters.")
        }
        return value
    }

    /// The top-level workspace a task belongs to: the one asked for, or the
    /// calling agent's own. A subspace resolves to its parent.
    private func resolvedWorkspaceID(_ requested: UUID?, caller: TaskCaller) throws -> UUID {
        guard let candidate = requested ?? caller.workspaceID else {
            throw TaskError("Name a workspace for the task with --workspace <id>, or create it from an agent session in that workspace.")
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
    private func resolvedProjectRoot(workspaceID: UUID) throws -> (path: String, isNew: Bool) {
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
    private func resolvedFields(pinned: TaskFields, workspaceID: UUID, defaults: TasksConfig.Defaults) throws -> TaskFields {
        let profiles = launcher?.launchProfileSummaries() ?? []
        guard let agent = pinned.agent ?? defaults.agent else {
            throw TaskError("Name an agent with --agent <profile>, or set agent in the [defaults] table of ~/.toastty/tasks.toml.")
        }
        guard let profile = profiles.first(where: { $0.profileID == agent }) else {
            let available = profiles.map(\.profileID).joined(separator: ", ")
            throw TaskError("Agent \(agent) is not a profile in agents.toml\(available.isEmpty ? "" : " (available: \(available))").")
        }
        guard profile.acceptsInitialPrompt else {
            throw TaskError("Agent \(agent) cannot take the task as its first message.")
        }
        var fields = TaskFields(workspaceID: workspaceID, agent: agent, prompt: pinned.prompt)
        if let model = pinned.model {
            guard profile.supportsModel else { throw TaskError("Agent \(agent) does not accept a model.") }
            guard RemoteSessionStartPolicy.isValidSelectionValue(model, maximumLength: RemoteSessionStartPolicy.maximumModelLength) else {
                throw TaskError("A model must be one word with no spaces that does not start with a dash.")
            }
            fields.model = model
        } else if profile.supportsModel, pinned.agent == nil || pinned.agent == defaults.agent {
            fields.model = defaults.model
        }
        if let effort = pinned.effort {
            guard profile.supportsReasoningEffort else { throw TaskError("Agent \(agent) does not accept an effort.") }
            guard RemoteSessionStartPolicy.isValidSelectionValue(effort, maximumLength: RemoteSessionStartPolicy.maximumReasoningEffortLength) else {
                throw TaskError("An effort must be one word with no spaces that does not start with a dash.")
            }
            fields.effort = effort
        } else if profile.supportsReasoningEffort, pinned.agent == nil || pinned.agent == defaults.agent {
            fields.effort = defaults.effort
        }
        return fields
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

    private func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The task space's terminal when it is still there, else a new
    /// background terminal tab in the project directory.
    private func reusablePanel(in workspaceID: UUID, preferred panelID: UUID, directory: String) -> UUID? {
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

    private static func launchFailureReason(for error: any Error) -> String {
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

private func nonEmpty(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
