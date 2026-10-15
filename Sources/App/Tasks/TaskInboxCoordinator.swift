import AppKit
import CoreState
import Foundation
import RemoteProtocol

/// The part of the agent launcher a task start uses. A protocol so tests
/// can run the flow without terminals.
@MainActor
protocol TaskAgentLaunching: AnyObject {
    func launchProfileSummaries() -> [AgentLaunchProfileSummary]
    func profileExecutableState(profileID: String) throws -> AgentProfileExecutableState
    /// Launches into the given terminal without moving focus, scoped to the
    /// task space. `beforeDispatch` runs directly before the command is
    /// sent; a throw there cancels the launch.
    func launchTask(
        profileID: String,
        workspaceID: UUID,
        panelID: UUID,
        cwd: String,
        model: String?,
        reasoningEffort: String?,
        initialPrompt: String,
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
            focusPolicy: .preserveFirstResponder,
            beforeDispatch: beforeDispatch
        )
    }
}

struct TaskSetupProblem: Error, Equatable {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

enum TaskInboxError: LocalizedError, Equatable {
    case emptyTask
    case textTooLong
    case invalidPin(String)
    case attachmentsInvalid
    case attachmentStorageUnavailable
    case taskNotFound
    case notAllowed(String)
    case placement(TaskPlacementProblem)

    var errorDescription: String? {
        switch self {
        case .emptyTask: "A task needs text or a file."
        case .textTooLong: "The task text is longer than \(TaskInboxItem.maximumTextLength / 1024) KB."
        case .invalidPin(let detail): detail
        case .attachmentsInvalid: "Attach up to 4 images, PDFs or text files, 4 MiB each and 8 MiB in total."
        case .attachmentStorageUnavailable: "Toastty could not save the attached files."
        case .taskNotFound: "That task is no longer in the Inbox."
        case .notAllowed(let detail): detail
        case .placement(let problem): problem.message
        }
    }
}

/// Runs the quick-task flow: Inbox, triage, the create script, and the
/// agent start in a new task space. Triage runs one task at a time; setup
/// runs per task.
@MainActor
final class TaskInboxCoordinator {
    private let store: AppStore
    let inbox: TaskInboxStore
    private let configStore: TasksConfigStore
    private let sessionRuntimeStore: SessionRuntimeStore
    private weak var launcher: (any TaskAgentLaunching)?
    private let runner: any TaskCommandRunning
    private let attachmentStore: RemoteMessageAttachmentStore
    private let runtimePaths: ToasttyRuntimePaths
    private let acceptedUserSkillNames: @MainActor () -> Set<String>
    private let commandPath: @MainActor () -> String?
    private let fileManager: FileManager
    private let now: () -> Date
    private let terminalReadinessTimeout: Duration

    private var triageQueue: [UUID] = []
    private var triageInFlight: (taskID: UUID, task: Task<Void, Never>)?
    private var setupTasks: [UUID: Task<Void, Never>] = [:]
    /// The current setup attempt of each task. A launch checks it right
    /// before the agent command is sent, so a Delete, a new placement or a
    /// second Retry can never let an older attempt start an agent.
    private var setupAttempts: [UUID: UUID] = [:]
    nonisolated(unsafe) private var terminationObserver: NSObjectProtocol?

    init(
        store: AppStore,
        inbox: TaskInboxStore,
        configStore: TasksConfigStore,
        sessionRuntimeStore: SessionRuntimeStore,
        launcher: any TaskAgentLaunching,
        runner: any TaskCommandRunning = TaskLiveCommandRunner(),
        runtimePaths: ToasttyRuntimePaths,
        acceptedUserSkillNames: @escaping @MainActor () -> Set<String>,
        commandPath: @escaping @MainActor () -> String?,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        terminalReadinessTimeout: Duration = AgentLaunchReadiness.defaultTimeout
    ) {
        self.store = store
        self.inbox = inbox
        self.configStore = configStore
        self.sessionRuntimeStore = sessionRuntimeStore
        self.launcher = launcher
        self.runner = runner
        self.runtimePaths = runtimePaths
        attachmentStore = RemoteMessageAttachmentStore(root: runtimePaths.taskAttachmentsDirectoryURL)
        self.acceptedUserSkillNames = acceptedUserSkillNames
        self.commandPath = commandPath
        self.fileManager = fileManager
        self.now = now
        self.terminalReadinessTimeout = terminalReadinessTimeout
        // A quit stops the scripts and triage calls in flight; the setup
        // shows as interrupted at the next launch.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            TaskLiveCommandRunner.stopAllRunningCommands()
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    /// Resumes work saved before the last quit: routing tasks go back to
    /// triage, and a setup that was cut off waits for the user's Retry.
    func resume() {
        for item in inbox.items {
            switch item.phase {
            case .routing:
                triageQueue.append(item.id)
            case .settingUp:
                inbox.update(id: item.id) {
                    $0.phase = .setupFailed
                    $0.problem = "Toastty quit during setup. Retry to continue."
                }
            case .needsWorkspace, .setupFailed:
                break
            }
        }
        let protected = protectedAttachmentDirectoryNames()
        Task { [attachmentStore] in try? await attachmentStore.cleanup(protecting: protected) }
        pumpTriage()
    }

    // MARK: - Commands

    /// Adds a task to the Inbox and starts placing it. Files are copied into
    /// Toastty's task folder before the task is saved.
    @discardableResult
    func add(
        text rawText: String,
        attachments: [RemoteMessageAttachment] = [],
        pins: TaskInboxItem.Pins = TaskInboxItem.Pins(),
        source: TaskInboxItem.Source
    ) async throws -> TaskInboxItem {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false || attachments.isEmpty == false else { throw TaskInboxError.emptyTask }
        guard text.utf8.count <= TaskInboxItem.maximumTextLength, text.contains("\0") == false else {
            throw TaskInboxError.textTooLong
        }
        try validate(pins: pins)

        var stored: [TaskInboxItem.Attachment] = []
        if attachments.isEmpty == false {
            guard RemoteAttachmentPolicy.validationError(for: attachments) == nil else {
                throw TaskInboxError.attachmentsInvalid
            }
            let staged: RemoteMessageAttachmentStore.Staged
            do {
                staged = try await attachmentStore.stage(attachments, protecting: protectedAttachmentDirectoryNames())
            } catch RemoteMessageAttachmentStore.StorageError.invalidAttachments {
                throw TaskInboxError.attachmentsInvalid
            } catch {
                throw TaskInboxError.attachmentStorageUnavailable
            }
            stored = zip(attachments, staged.files).map { attachment, file in
                TaskInboxItem.Attachment(
                    displayName: RemoteAttachmentPolicy.displayFilename(attachment.filename),
                    path: file.path
                )
            }
        }

        var item = TaskInboxItem(text: text, attachments: stored, source: source, createdAt: now(), pins: pins)
        if configStore.config.triage != nil {
            item.phase = .routing
            inbox.add(item)
            triageQueue.append(item.id)
            pumpTriage()
        } else {
            item.phase = .needsWorkspace
            item.problem = TaskPlacementProblem.noWorkspace.message
            inbox.add(item)
            if pins.workspaceID != nil {
                do {
                    try beginSetup(taskID: item.id, chosenWorkspaceID: nil, replanning: true)
                } catch {
                    needsWorkspace(taskID: item.id, problem: error.localizedDescription)
                }
            }
        }
        ToasttyLog.info(
            "Added a quick task",
            category: .tasks,
            metadata: ["task_id": item.id.uuidString, "source": source.rawValue, "attachments": String(stored.count)]
        )
        return inbox.item(id: item.id) ?? item
    }

    /// The user's own placement for a task that waits for one. Agent,
    /// model and effort, when given, become pins.
    func place(
        taskID: UUID,
        workspaceID: UUID,
        profileID: String? = nil,
        model: String? = nil,
        effort: String? = nil
    ) throws {
        guard let item = inbox.item(id: taskID) else { throw TaskInboxError.taskNotFound }
        guard item.phase == .needsWorkspace || item.phase == .setupFailed else {
            throw TaskInboxError.notAllowed("This task is already being placed or set up.")
        }
        // The user's pick replaces any earlier workspace pin, which may
        // name a workspace that has since closed.
        var candidate = item
        candidate.pins.workspaceID = workspaceID
        candidate.pins.profileID = profileID ?? item.pins.profileID
        candidate.pins.model = model ?? item.pins.model
        candidate.pins.effort = effort ?? item.pins.effort
        try validate(pins: candidate.pins)
        if item.plan.map({ $0.workspaceID != workspaceID }) ?? true {
            // The old directory and task space belong to the old
            // workspace; they stay where they are.
            candidate.plan = nil
            candidate.createdDirectory = nil
            candidate.taskSpace = nil
        }
        // Nothing is saved unless the new placement is valid.
        try beginSetup(taskID: taskID, from: candidate, chosenWorkspaceID: workspaceID, replanning: true)
    }

    /// Runs triage again for a task that waits for a workspace, or setup
    /// again for one whose setup failed.
    func retry(taskID: UUID) throws {
        guard let item = inbox.item(id: taskID) else { throw TaskInboxError.taskNotFound }
        switch item.phase {
        case .needsWorkspace:
            guard configStore.config.triage != nil else {
                throw TaskInboxError.notAllowed("Triage is not set up in tasks.toml. Pick a workspace instead.")
            }
            inbox.update(id: taskID) {
                $0.phase = .routing
                $0.problem = nil
            }
            triageQueue.append(taskID)
            pumpTriage()
        case .setupFailed:
            // The plan, its slug and any directory or task space made so far
            // are kept, so the create script and the start see the same task.
            try beginSetup(taskID: taskID, chosenWorkspaceID: item.plan?.workspaceID)
        case .routing, .settingUp:
            throw TaskInboxError.notAllowed("This task is already being placed or set up.")
        }
    }

    /// Removes a task and stops its triage or setup. A directory or task
    /// space that setup already made stays.
    func delete(taskID: UUID) {
        guard let removed = inbox.remove(id: taskID) else { return }
        triageQueue.removeAll { $0 == taskID }
        if triageInFlight?.taskID == taskID {
            triageInFlight?.task.cancel()
        }
        setupAttempts[taskID] = nil
        setupTasks.removeValue(forKey: taskID)?.cancel()
        let directories = Set(removed.attachments.map { URL(filePath: $0.path).deletingLastPathComponent() })
        Task { [attachmentStore] in
            for directory in directories { await attachmentStore.discard(directory: directory) }
        }
        ToasttyLog.info("Deleted a quick task", category: .tasks, metadata: ["task_id": taskID.uuidString])
    }

    // MARK: - Context

    func placementContext(excluding taskID: UUID? = nil) -> TaskPlacementContext {
        let state = store.state
        var workspaces: [TaskPlacementContext.Workspace] = []
        for window in state.windows {
            for workspaceID in state.topLevelWorkspaceIDs(in: window.id) {
                guard let workspace = state.workspacesByID[workspaceID] else { continue }
                workspaces.append(.init(
                    id: workspaceID,
                    title: workspace.title,
                    directory: AgentLaunchReadiness.launchDirectory(in: workspace, fileManager: fileManager),
                    isTopLevel: true,
                    taskSpaceTitles: state.subspaceWorkspaceIDs(of: workspaceID).compactMap { state.workspacesByID[$0]?.title }
                ))
                for subspaceID in state.subspaceWorkspaceIDs(of: workspaceID) {
                    guard let subspace = state.workspacesByID[subspaceID] else { continue }
                    workspaces.append(.init(id: subspaceID, title: subspace.title, directory: nil, isTopLevel: false))
                }
            }
        }
        var reserved: [UUID: Set<String>] = [:]
        for item in inbox.items where item.id != taskID {
            if let plan = item.plan { reserved[plan.workspaceID, default: []].insert(plan.slug) }
        }
        return TaskPlacementContext(workspaces: workspaces, profiles: offeredProfiles(), reservedSlugs: reserved)
    }

    private func offeredProfiles() -> [TaskPlacementContext.Profile] {
        (launcher?.launchProfileSummaries() ?? [])
            .filter { ProviderTranscriptSupport.isManagedProvider($0.agent) }
            .map { summary in
                TaskPlacementContext.Profile(
                    id: summary.profileID,
                    displayName: summary.displayName,
                    agent: summary.agent,
                    isAvailable: summary.isInstalled && summary.acceptsInitialPrompt,
                    supportsModel: summary.supportsModel,
                    efforts: summary.reasoningEffortChoices
                )
            }
    }

    private func validate(pins: TaskInboxItem.Pins) throws {
        if let workspaceID = pins.workspaceID {
            guard let workspace = store.state.workspacesByID[workspaceID] else {
                throw TaskInboxError.invalidPin("That workspace is not open.")
            }
            guard workspace.parentWorkspaceID == nil else {
                throw TaskInboxError.invalidPin("\(workspace.title) is a task space. Pick a top-level workspace.")
            }
        }
        let profiles = offeredProfiles()
        let profile = pins.profileID.flatMap { id in profiles.first { $0.id == id } }
        if let profileID = pins.profileID, profile == nil {
            throw TaskInboxError.invalidPin("agents.toml has no profile \"\(profileID)\" that can start a task.")
        }
        if let model = pins.model {
            guard RemoteSessionStartPolicy.isValidSelectionValue(model, maximumLength: RemoteSessionStartPolicy.maximumModelLength) else {
                throw TaskInboxError.invalidPin("A model is one word with no spaces that doesn't start with a dash.")
            }
            if let profile, profile.supportsModel == false {
                throw TaskInboxError.invalidPin("\(profile.displayName) does not take a model choice.")
            }
        }
        if let effort = pins.effort {
            guard RemoteSessionStartPolicy.isValidSelectionValue(effort, maximumLength: RemoteSessionStartPolicy.maximumReasoningEffortLength) else {
                throw TaskInboxError.invalidPin("An effort is one word with no spaces that doesn't start with a dash.")
            }
            if let profile, profile.efforts.contains(effort) == false {
                throw TaskInboxError.invalidPin("\(profile.displayName) does not take effort \"\(effort)\".")
            }
        }
    }

    private func protectedAttachmentDirectoryNames() -> Set<String> {
        Set(inbox.items.flatMap { item in
            item.attachments.map { URL(filePath: $0.path).deletingLastPathComponent().lastPathComponent }
        })
    }

    private func commandEnvironment(extra: [String: String] = [:]) -> [String: String] {
        TaskCommandEnvironment.make(path: commandPath(), extra: extra)
    }

    // MARK: - Triage

    private func pumpTriage() {
        guard triageInFlight == nil else { return }
        while let taskID = triageQueue.first {
            triageQueue.removeFirst()
            guard inbox.item(id: taskID)?.phase == .routing else { continue }
            let task = Task { [weak self] in
                await self?.runTriage(taskID: taskID)
                guard let self else { return }
                self.triageInFlight = nil
                self.pumpTriage()
            }
            triageInFlight = (taskID, task)
            return
        }
    }

    private func runTriage(taskID: UUID) async {
        guard let item = inbox.item(id: taskID) else { return }
        guard let triage = configStore.config.triage else {
            finishTriage(taskID: taskID, outcome: .failure(.failed("triage is no longer set up in tasks.toml")))
            return
        }
        guard let executable = triageExecutable(for: triage) else {
            needsWorkspace(
                taskID: taskID,
                problem: "Triage needs a claude or codex profile in agents.toml that runs the plain CLI. Check [triage] profile in tasks.toml, then retry."
            )
            return
        }
        let context = placementContext(excluding: taskID)
        let prompt: String
        do {
            prompt = try TaskTriage.prompt(for: item, context: context, guidance: triage.guidance)
        } catch {
            needsWorkspace(taskID: taskID, problem: TaskTriageFailure.unreadableAnswer.message)
            return
        }
        let result = await TaskTriageRunner(runner: runner).run(
            prompt: prompt,
            executable: executable,
            triage: triage,
            environment: commandEnvironment()
        )
        finishTriage(taskID: taskID, outcome: result)
    }

    private func triageExecutable(for triage: TasksConfig.Triage) -> TaskTriageExecutable? {
        guard let launcher,
              let summary = launcher.launchProfileSummaries().first(where: { $0.profileID == triage.profileID }),
              let state = try? launcher.profileExecutableState(profileID: triage.profileID),
              let path = state.executablePath else { return nil }
        return TaskTriageExecutable(agent: summary.agent, executablePath: path)
    }

    private func finishTriage(taskID: UUID, outcome: Result<TaskTriageAnswer, TaskTriageFailure>) {
        // A task deleted or placed by hand during triage keeps its new state.
        guard let item = inbox.item(id: taskID), item.phase == .routing else { return }
        switch outcome {
        case .failure(.cancelled):
            return
        case .failure(let failure):
            ToasttyLog.info("Triage could not place a quick task", category: .tasks, metadata: [
                "task_id": taskID.uuidString, "reason": failure.message,
            ])
            needsWorkspace(taskID: taskID, problem: failure.message)
        case .success(let answer):
            let context = placementContext(excluding: taskID)
            let suggestion = TaskPlacement.suggestion(from: answer, context: context)
            inbox.update(id: taskID) { $0.suggestion = suggestion }
            guard answer.confident else {
                needsWorkspace(taskID: taskID, problem: "Triage was not sure where this goes. " + (suggestion.reason ?? ""))
                return
            }
            guard suggestion.workspaceID != nil || item.pins.workspaceID != nil else {
                needsWorkspace(taskID: taskID, problem: "Triage did not pick an open workspace. Pick one to start the task.")
                return
            }
            do {
                try beginSetup(taskID: taskID, chosenWorkspaceID: nil, replanning: true)
            } catch {
                needsWorkspace(taskID: taskID, problem: error.localizedDescription)
            }
        }
    }

    private func needsWorkspace(taskID: UUID, problem: String) {
        inbox.update(id: taskID) {
            $0.phase = .needsWorkspace
            $0.problem = problem.trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - Setup

    /// Checks the placement, then starts setup. `replanning` makes a new
    /// plan; otherwise an existing plan is reused so a retry keeps its slug.
    private func beginSetup(
        taskID: UUID,
        from candidate: TaskInboxItem? = nil,
        chosenWorkspaceID: UUID?,
        replanning: Bool = false
    ) throws {
        guard let stored = inbox.item(id: taskID) else { throw TaskInboxError.taskNotFound }
        let item = candidate ?? stored
        let context = placementContext(excluding: taskID)
        let plan: TaskInboxItem.Plan
        if replanning == false, let existing = item.plan {
            guard let workspace = context.workspace(existing.workspaceID), workspace.directory != nil else {
                throw TaskInboxError.placement(.workspaceClosed)
            }
            plan = existing
        } else {
            switch TaskPlacement.plan(for: item, workspaceID: chosenWorkspaceID, context: context) {
            case .success(var planned):
                // A new plan in the same workspace keeps the task's name, so
                // the create script and an existing task space still match.
                if let existing = item.plan, existing.workspaceID == planned.workspaceID {
                    planned.title = existing.title
                    planned.slug = existing.slug
                    planned.branchPrefix = existing.branchPrefix
                }
                plan = planned
            case .failure(let problem):
                throw TaskInboxError.placement(problem)
            }
        }
        let attempt = UUID()
        setupAttempts[taskID] = attempt
        inbox.update(id: taskID) {
            $0 = item
            $0.phase = .settingUp
            $0.plan = plan
            $0.problem = nil
        }
        setupTasks[taskID]?.cancel()
        setupTasks[taskID] = Task { [weak self] in
            await self?.runSetup(taskID: taskID, attempt: attempt)
        }
    }

    private func isCurrent(taskID: UUID, attempt: UUID) -> Bool {
        setupAttempts[taskID] == attempt
            && inbox.item(id: taskID)?.phase == .settingUp
            && Task.isCancelled == false
    }

    private func setupFailed(taskID: UUID, attempt: UUID, problem: String) {
        guard setupAttempts[taskID] == attempt else { return }
        setupAttempts[taskID] = nil
        setupTasks[taskID] = nil
        inbox.update(id: taskID) {
            $0.phase = .setupFailed
            $0.problem = problem
        }
        ToasttyLog.info("Quick task setup failed", category: .tasks, metadata: [
            "task_id": taskID.uuidString, "reason": problem,
        ])
    }

    private func runSetup(taskID: UUID, attempt: UUID) async {
        guard isCurrent(taskID: taskID, attempt: attempt),
              let item = inbox.item(id: taskID), let plan = item.plan else { return }
        let context = placementContext(excluding: taskID)
        guard let workspace = context.workspace(plan.workspaceID), let workspaceDirectory = workspace.directory else {
            setupFailed(taskID: taskID, attempt: attempt, problem: TaskPlacementProblem.workspaceClosed.message)
            return
        }

        // 1. The task's directory.
        let directory: String
        var createdDirectory = item.createdDirectory
        if let created = createdDirectory, isDirectory(created.directory) {
            directory = created.directory
        } else if let create = configStore.config.create {
            inbox.update(id: taskID) { $0.createdDirectory = nil }
            switch await runCreateScript(create, item: item, plan: plan, workspaceDirectory: workspaceDirectory) {
            case .success(let created):
                guard isCurrent(taskID: taskID, attempt: attempt) else { return }
                createdDirectory = created
                directory = created.directory
                inbox.update(id: taskID) { $0.createdDirectory = created }
            case .failure(let problem):
                setupFailed(taskID: taskID, attempt: attempt, problem: problem.message)
                return
            }
        } else {
            createdDirectory = nil
            directory = workspaceDirectory
        }
        guard isCurrent(taskID: taskID, attempt: attempt) else { return }

        // 2. The task space. One that an earlier attempt made is reused, and
        // if an agent already runs there, the task has started.
        let taskSpace: TaskInboxItem.TaskSpace
        var createdTaskSpace = false
        if let existing = item.taskSpace, store.state.workspacesByID[existing.workspaceID] != nil {
            if hasActiveSession(in: existing.workspaceID) {
                await finishStarted(taskID: taskID, attempt: attempt, workspaceID: existing.workspaceID)
                return
            }
            guard let panelID = reusablePanel(in: existing.workspaceID, preferred: existing.panelID, directory: directory) else {
                setupFailed(taskID: taskID, attempt: attempt, problem: "Toastty could not open a terminal in the task space.")
                return
            }
            taskSpace = TaskInboxItem.TaskSpace(workspaceID: existing.workspaceID, panelID: panelID)
            inbox.update(id: taskID) { $0.taskSpace = taskSpace }
        } else {
            guard let windowID = store.state.workspaceSelection(containingWorkspaceID: plan.workspaceID)?.windowID else {
                setupFailed(taskID: taskID, attempt: attempt, problem: TaskPlacementProblem.workspaceClosed.message)
                return
            }
            taskSpace = TaskInboxItem.TaskSpace(workspaceID: UUID(), panelID: UUID())
            // Saved first: after a crash, a retry finds this task space
            // instead of making a second one.
            inbox.update(id: taskID) { $0.taskSpace = taskSpace }
            guard store.send(.createTaskSpace(
                windowID: windowID,
                workspaceID: taskSpace.workspaceID,
                panelID: taskSpace.panelID,
                parentWorkspaceID: plan.workspaceID,
                title: plan.slug,
                terminalCWD: directory
            )) else {
                inbox.update(id: taskID) { $0.taskSpace = nil }
                setupFailed(taskID: taskID, attempt: attempt, problem: "Toastty could not create the task space.")
                return
            }
            createdTaskSpace = true
        }

        // 3. The agent.
        guard let launcher else {
            setupFailed(taskID: taskID, attempt: attempt, problem: "The agent launcher is not available.")
            return
        }
        let prompt = firstPrompt(item: item, plan: plan, workspaceTitle: workspace.title, directory: directory, createdDirectory: createdDirectory)
        do {
            _ = try await AgentLaunchReadiness.launchWhenTerminalIsReady(timeout: terminalReadinessTimeout) {
                try await launcher.launchTask(
                    profileID: plan.profileID,
                    workspaceID: taskSpace.workspaceID,
                    panelID: taskSpace.panelID,
                    cwd: directory,
                    model: plan.model,
                    reasoningEffort: plan.effort,
                    initialPrompt: prompt,
                    beforeDispatch: { [weak self] in
                        guard let self, self.isCurrent(taskID: taskID, attempt: attempt) else {
                            throw CancellationError()
                        }
                    }
                )
            }
        } catch {
            if case .commandDeliveryUncertain? = error as? AgentLaunchError {
                setupFailed(
                    taskID: taskID,
                    attempt: attempt,
                    problem: "The agent command may not have arrived. Check the task space before you retry."
                )
                return
            }
            // Nothing was sent. A task space this attempt made is removed
            // while it is still untouched.
            if createdTaskSpace {
                closeTaskSpaceIfUnused(taskSpace)
                inbox.update(id: taskID) { $0.taskSpace = nil }
            }
            if error is CancellationError || Task.isCancelled { return }
            setupFailed(taskID: taskID, attempt: attempt, problem: Self.launchProblem(for: error))
            return
        }
        await finishStarted(taskID: taskID, attempt: attempt, workspaceID: taskSpace.workspaceID)
    }

    private func finishStarted(taskID: UUID, attempt: UUID, workspaceID: UUID) async {
        guard setupAttempts[taskID] == attempt, let item = inbox.item(id: taskID) else { return }
        setupAttempts[taskID] = nil
        setupTasks[taskID] = nil
        // Retention of the files now counts from delivery. Renewed while the
        // task is still in the Inbox, so no sweep can fall in between.
        for directory in Set(item.attachments.map({ URL(filePath: $0.path).deletingLastPathComponent() })) {
            await attachmentStore.renew(directory: directory)
        }
        guard let removed = inbox.remove(id: taskID) else { return }
        ToasttyLog.info("Started a quick task", category: .tasks, metadata: [
            "task_id": taskID.uuidString,
            "workspace_id": workspaceID.uuidString,
            "profile_id": removed.plan?.profileID ?? "",
        ])
    }

    private func firstPrompt(
        item: TaskInboxItem,
        plan: TaskInboxItem.Plan,
        workspaceTitle: String,
        directory: String,
        createdDirectory: TaskInboxItem.CreatedDirectory?
    ) -> String {
        let agent = launcher?.launchProfileSummaries().first { $0.profileID == plan.profileID }?.agent
            ?? AgentKind(rawValue: plan.profileID)
        let skillLine = configStore.config.start.map { start in
            TaskStartPrompt.skillLine(
                skill: start.skill,
                agent: agent ?? .claude,
                isUserSkill: acceptedUserSkillNames().contains(start.skill)
            )
        }
        return TaskStartPrompt.compose(
            skillLine: skillLine,
            text: item.text,
            attachmentPaths: item.attachments.map(\.path),
            plan: plan,
            workspaceTitle: workspaceTitle,
            directory: directory,
            createdDirectory: createdDirectory
        )
    }

    private func runCreateScript(
        _ create: TasksConfig.Create,
        item: TaskInboxItem,
        plan: TaskInboxItem.Plan,
        workspaceDirectory: String
    ) async -> Result<TaskInboxItem.CreatedDirectory, TaskSetupProblem> {
        let scriptPath = TaskCreateScriptOutput.expandingTilde(create.script, homeDirectoryPath: NSHomeDirectory())
        guard scriptPath.hasPrefix("/"), fileManager.isExecutableFile(atPath: scriptPath) else {
            return .failure(TaskSetupProblem("The create script \(create.script) is missing or not executable. Check tasks.toml."))
        }
        // A folder the script may use to remember what it made for this
        // task, so running it again after a failure returns the same result.
        // Per workspace too: after the user moves a task, the script must
        // not hand back the directory it made in the old workspace.
        let stateDirectory = runtimePaths.tasksDirectoryURL
            .appending(path: "state", directoryHint: .isDirectory)
            .appending(path: item.id.uuidString, directoryHint: .isDirectory)
            .appending(path: plan.workspaceID.uuidString, directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let result = await runner.run(TaskCommand(
            executablePath: scriptPath,
            arguments: [],
            directory: workspaceDirectory,
            environment: commandEnvironment(extra: [
                "TOASTTY_TASK_ID": item.id.uuidString,
                "TOASTTY_TASK_SLUG": plan.slug,
                "TOASTTY_TASK_BRANCH_PREFIX": plan.branchPrefix,
                "TOASTTY_TASK_TITLE": plan.title,
                "TOASTTY_TASK_STATE_DIR": stateDirectory.path,
            ]),
            standardInput: nil,
            timeout: TimeInterval(create.timeoutSeconds)
        ))
        let detail = TaskCreateScriptOutput.failureDetail(stderr: result.stderrText)
        switch result.termination {
        case .exited(0):
            do {
                let created = try TaskCreateScriptOutput.parse(stdout: result.stdoutText)
                guard isDirectory(created.directory) else {
                    return .failure(TaskSetupProblem("The create script printed a directory that does not exist: \(created.directory)"))
                }
                return .success(created)
            } catch {
                return .failure(TaskSetupProblem("The create script's last output line must be JSON with a \"directory\"."))
            }
        case .exited(let code):
            return .failure(TaskSetupProblem("The create script failed (exit \(code))" + (detail.map { ": \($0)" } ?? ".")))
        case .signaled(let signal):
            return .failure(TaskSetupProblem("The create script stopped with signal \(signal)."))
        case .timedOut:
            return .failure(TaskSetupProblem("The create script did not finish in \(create.timeoutSeconds) s."))
        case .cancelled:
            return .failure(TaskSetupProblem("The create script was stopped."))
        case .launchFailed(let message):
            return .failure(TaskSetupProblem(message))
        }
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func hasActiveSession(in workspaceID: UUID) -> Bool {
        let registry = sessionRuntimeStore.sessionRegistry
        return registry.activeSessionIDByPanelID.values.contains { sessionID in
            registry.sessionsByID[sessionID]?.workspaceID == workspaceID
        }
    }

    /// The task space's terminal when it is still there, else a new
    /// background terminal tab in the task directory.
    private func reusablePanel(in workspaceID: UUID, preferred panelID: UUID, directory: String) -> UUID? {
        if let workspace = store.state.workspacesByID[workspaceID],
           case .terminal? = workspace.panelState(for: panelID) {
            return panelID
        }
        let tabID = UUID()
        let newPanelID = UUID()
        guard store.send(.createBackgroundTerminalTab(
            workspaceID: workspaceID,
            tabID: tabID,
            panelID: newPanelID,
            terminalCWD: directory
        )) else { return nil }
        return newPanelID
    }

    /// Closes a task space this flow made, but only while it is still what
    /// the flow made: never visited, one tab with its one terminal, and no
    /// agent session.
    private func closeTaskSpaceIfUnused(_ taskSpace: TaskInboxItem.TaskSpace) {
        guard let workspace = store.state.workspacesByID[taskSpace.workspaceID],
              workspace.hasBeenVisited == false,
              workspace.tabIDs.count == 1,
              let tab = workspace.orderedTabs.first,
              tab.panels.count == 1,
              tab.panels[taskSpace.panelID] != nil,
              hasActiveSession(in: taskSpace.workspaceID) == false else { return }
        _ = store.send(.closeWorkspace(workspaceID: taskSpace.workspaceID))
    }

    private static func launchProblem(for error: any Error) -> String {
        guard let launchError = error as? AgentLaunchError else {
            return "The agent did not start: \(error.localizedDescription)"
        }
        switch launchError {
        case .panelBusy, .terminalUnavailable:
            return "The task space's terminal did not get ready in time. Retry to try again."
        case .launchOverrideUnsupported, .invalidLaunchOverride, .unsafeLaunchOverrideArgv:
            return "The agent does not accept that model or effort."
        case .initialPromptUnsupported, .invalidInitialPrompt:
            return "The agent does not accept the task as its first message."
        default:
            return "The agent did not start: \(launchError.localizedDescription)"
        }
    }
}
