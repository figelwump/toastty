import AppKit
import CoreState
import Foundation
import RemoteProtocol

/// What a cleanup script run produced. `exitCode` is `nil` when the script
/// did not start or did not finish in time; `failure` then says why. The
/// script's stdout and stderr are read as one stream, in the order written,
/// so the last line is the last thing the script said on either.
struct WorkspaceTaskCleanupCommandResult: Equatable, Sendable {
    var exitCode: Int32?
    var output: String
    var failure: String?
}

/// Runs a cleanup script. The live runner works on its own thread, never on
/// the main actor, because the script calls back into this app's automation
/// socket to list and close workspaces.
protocol WorkspaceTaskCleanupCommandRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        directory: String?,
        environment: [String: String],
        timeout: TimeInterval
    ) async -> WorkspaceTaskCleanupCommandResult
}

struct WorkspaceTaskCleanupLiveCommandRunner: WorkspaceTaskCleanupCommandRunning {
    private static let terminationGracePeriod: TimeInterval = 2

    func run(
        executable: String,
        arguments: [String],
        directory: String?,
        environment: [String: String],
        timeout: TimeInterval
    ) async -> WorkspaceTaskCleanupCommandResult {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: Self.runBlocking(
                    executable: executable,
                    arguments: arguments,
                    directory: directory,
                    environment: environment,
                    timeout: timeout
                ))
            }
            thread.name = "toastty-task-cleanup"
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    private static func runBlocking(
        executable: String,
        arguments: [String],
        directory: String?,
        environment: [String: String],
        timeout: TimeInterval
    ) -> WorkspaceTaskCleanupCommandResult {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.environment = environment
        if let directory {
            process.currentDirectoryURL = URL(filePath: directory, directoryHint: .isDirectory)
        }
        process.standardInput = FileHandle.nullDevice
        // One pipe for both streams keeps the script's lines in order, so
        // the last line is its final word whether it printed or errored.
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let collector = OutputCollector(handle: outputPipe.fileHandleForReading)
        let exitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSemaphore.signal() }
        do {
            try process.run()
        } catch {
            collector.cancel()
            return WorkspaceTaskCleanupCommandResult(
                exitCode: nil,
                output: "",
                failure: "Could not run \(executable): \(error.localizedDescription)"
            )
        }
        var failure: String?
        switch exitSemaphore.wait(timeout: .now() + timeout) {
        case .success:
            break
        case .timedOut:
            kill(process.processIdentifier, SIGTERM)
            if exitSemaphore.wait(timeout: .now() + terminationGracePeriod) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSemaphore.wait(timeout: .now() + terminationGracePeriod)
            }
            failure = "The cleanup script did not finish within \(Int(timeout)) seconds"
        }
        return WorkspaceTaskCleanupCommandResult(
            exitCode: failure == nil ? process.terminationStatus : nil,
            output: collector.finish(),
            failure: failure
        )
    }

    /// Reads a pipe to the end on a background queue, so a script that
    /// prints more than the pipe buffer holds cannot block on write.
    private final class OutputCollector: @unchecked Sendable {
        private let handle: FileHandle
        private let lock = NSLock()
        private var data = Data()
        private let done = DispatchSemaphore(value: 0)

        init(handle: FileHandle) {
            self.handle = handle
            DispatchQueue.global(qos: .utility).async { [self] in
                let bytes = handle.readDataToEndOfFile()
                lock.withLock { data = bytes }
                done.signal()
            }
        }

        func cancel() {
            try? handle.close()
            _ = done.wait(timeout: .now() + 1)
        }

        func finish() -> String {
            _ = done.wait(timeout: .now() + 5)
            try? handle.close()
            return lock.withLock { String(decoding: data, as: UTF8.self) }
        }
    }
}

/// One script hook run (cleanup or close) for a workspace, from the click
/// until the result has been shown. Not saved across launches: a quit while
/// a script runs leaves whatever the script got to, which it reports the
/// next time.
struct WorkspaceTaskScriptRun: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case running
        /// The script exited 3: it changed nothing and said why.
        case skipped(detail: String)
        /// The script exited with any other non-zero code, printed no
        /// detail, or did not finish.
        case failed(detail: String)
    }

    var kind: WorkspaceTaskHooks.ScriptKind
    var phase: Phase
}

/// What the task buttons and their tooltips say about each hook, so the
/// user knows what a click runs before clicking.
enum WorkspaceTaskHookPresentation {
    static func finishHelp(skill: String) -> String {
        "Runs the \(skill) skill in this task's agent session"
    }

    static func scriptHelp(_ hook: WorkspaceTaskHooks.ScriptHook) -> String {
        "Runs " + ([hook.skill + "/" + hook.script] + hook.arguments).joined(separator: " ")
    }

    static func title(_ kind: WorkspaceTaskHooks.ScriptKind) -> String {
        switch kind {
        case .cleanup: return "Clean Up"
        case .close: return "Close Task"
        }
    }

    static func runningTitle(_ kind: WorkspaceTaskHooks.ScriptKind) -> String {
        switch kind {
        case .cleanup: return "Cleaning Up…"
        case .close: return "Closing…"
        }
    }

    static func failedTitle(_ kind: WorkspaceTaskHooks.ScriptKind) -> String {
        switch kind {
        case .cleanup: return "Cleanup Failed"
        case .close: return "Close Failed"
        }
    }

    static func confirmation(_ kind: WorkspaceTaskHooks.ScriptKind, taskTitle: String) -> (title: String, message: String, button: String) {
        switch kind {
        case .cleanup:
            return (
                "Clean up \(taskTitle)?",
                "Toastty runs this task's cleanup script. The script decides whether cleanup is safe, and may close this workspace, end its sessions, and remove its worktree.",
                "Clean Up"
            )
        case .close:
            return (
                "Close \(taskTitle) without finishing?",
                "Toastty runs this task's close script. It may close the task's pull request, close this workspace, end its sessions, and remove its worktree. Work pushed to GitHub stays there.",
                "Close Task"
            )
        }
    }
}

/// The confirmation and failure alerts the task buttons show. Statics so
/// hosted tests can replace the modal dialogs.
@MainActor
enum WorkspaceTaskHookPrompts {
    static var confirm: (_ title: String, _ message: String, _ button: String) -> Bool = { title, message, button in
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static var presentAlert: (_ title: String, _ message: String) -> Void = { title, message in
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Runs a subspace's task lifecycle hooks: Finish Task sends the finish
/// skill to the task's agent; Clean Up and Close Task run their scripts
/// without an agent. Script runs are shown through `SessionRuntimeStore`.
@MainActor
final class WorkspaceTaskHookRunner {
    static let cleanupTimeout: TimeInterval = 300
    /// The exit status a cleanup script uses for "nothing changed, and here
    /// is why"; the row shows it as a skip rather than a failure.
    static let cleanupSkippedExitCode: Int32 = 3
    /// Toastty delivers user skills to Claude and Codex under this plugin
    /// name, so an accepted user skill is invoked as `<plugin>:<skill>`.
    static let userSkillPluginName = UserSkillPluginSnapshot.pluginName

    typealias LaunchAgent = @MainActor (
        _ profileID: String,
        _ workspaceID: UUID,
        _ cwd: String?,
        _ prompt: String
    ) async throws -> (sessionID: String, panelID: UUID)

    enum FinishOutcome: Equatable {
        /// The prompt went to an existing session in the workspace.
        case sentToSession(sessionID: String, panelID: UUID)
        /// No agent session was running, so one was launched with the
        /// prompt.
        case launchedSession(sessionID: String, panelID: UUID)
    }

    enum FinishProblem: Error, Equatable {
        case noFinishHook
        case workspaceNotFound
        case workspaceIsTopLevel
        /// Another Finish Task for this workspace is still launching.
        case alreadyFinishing
        case sendFailed(String)
        case launchFailed(String)
    }

    enum ScriptProblem: Error, Equatable {
        case noHook(WorkspaceTaskHooks.ScriptKind)
        case workspaceNotFound
        case alreadyRunning
        /// The hook names a skill that is not an accepted user skill, or a
        /// script that is not a regular file inside it.
        case scriptNotInstalled(path: String)
    }

    /// How a script hook finished, for the caller that started it.
    enum ScriptOutcome: Equatable, Sendable {
        case cleaned(detail: String)
        case skipped(detail: String)
        case failed(detail: String)
    }

    private weak var store: AppStore?
    private weak var sessionRuntimeStore: SessionRuntimeStore?
    private let runner: any WorkspaceTaskCleanupCommandRunning
    private let userSkillsDirectoryURL: URL
    private let acceptedUserSkillNames: () -> Set<String>
    private let baseEnvironment: @MainActor () -> [String: String]
    private let sendText: @MainActor (_ text: String, _ panelID: UUID) -> Bool
    private let launchAgent: LaunchAgent
    private let notify: @MainActor (_ title: String, _ body: String) -> Void
    private let fileManager: FileManager
    private var scriptTasks: [UUID: Task<ScriptOutcome, Never>] = [:]
    private var batchTasks: [UUID: Task<[(workspaceID: UUID, outcome: ScriptOutcome)], Never>] = [:]
    private var finishingWorkspaceIDs: Set<UUID> = []
    private var storeObserverToken: UUID?

    init(
        store: AppStore,
        sessionRuntimeStore: SessionRuntimeStore,
        runner: any WorkspaceTaskCleanupCommandRunning,
        userSkillsDirectoryURL: URL,
        acceptedUserSkillNames: (() -> Set<String>)? = nil,
        baseEnvironment: @escaping @MainActor () -> [String: String],
        sendText: @escaping @MainActor (_ text: String, _ panelID: UUID) -> Bool,
        launchAgent: @escaping LaunchAgent,
        notify: @escaping @MainActor (_ title: String, _ body: String) -> Void = WorkspaceTaskHookRunner.sendNotification,
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.sessionRuntimeStore = sessionRuntimeStore
        self.runner = runner
        self.userSkillsDirectoryURL = userSkillsDirectoryURL
        self.acceptedUserSkillNames = acceptedUserSkillNames ?? {
            Set(ToasttyUserSkillValidator(fileManager: fileManager)
                .scan(userSkillsDirectoryURL: userSkillsDirectoryURL)
                .state.acceptedPackages.map(\.name))
        }
        self.baseEnvironment = baseEnvironment
        self.sendText = sendText
        self.launchAgent = launchAgent
        self.notify = notify
        self.fileManager = fileManager
        sessionRuntimeStore.workspaceTaskHookRunner = self
        // A skipped or failed result belongs to the done task it ran for;
        // once the task reopens or closes, the row is back to Finish Task
        // or gone, so the old result must not cover it.
        storeObserverToken = store.addActionAppliedObserver { [weak self] _, _, nextState in
            self?.dropStaleScriptResults(state: nextState)
        }
    }

    // MARK: - Finish

    /// The prompt Finish Task sends: the skill invocation in the agent's own
    /// syntax, then a sentence that records the user's acceptance, because
    /// the skill treats the click as the user saying they are done. An
    /// accepted user skill is named through the plugin Toastty delivers it
    /// in; any other name is sent as given.
    static func finishPrompt(skill: String, agent: AgentKind, isUserSkill: Bool) -> String {
        let name = isUserSkill ? "\(userSkillPluginName):\(skill)" : skill
        let invocation: String
        switch agent {
        case .codex:
            invocation = "$\(name)"
        default:
            invocation = "/\(name)"
        }
        return "\(invocation) The user clicked Finish Task for this workspace, which accepts the current version."
    }

    /// Sends the finish skill to the workspace's most recently active agent
    /// session. The agent queues the prompt if it is busy. With no agent
    /// session, launches one with the prompt, using the profile of the
    /// workspace's last agent session.
    func finish(workspaceID: UUID) async -> Result<FinishOutcome, FinishProblem> {
        guard let store, let sessionRuntimeStore else { return .failure(.workspaceNotFound) }
        guard let workspace = store.state.workspacesByID[workspaceID] else { return .failure(.workspaceNotFound) }
        guard workspace.parentWorkspaceID != nil else { return .failure(.workspaceIsTopLevel) }
        guard let skill = workspace.taskHooks.finishSkill else { return .failure(.noFinishHook) }
        guard finishingWorkspaceIDs.contains(workspaceID) == false else { return .failure(.alreadyFinishing) }
        let isUserSkill = acceptedUserSkillNames().contains(skill)

        let sessions = Self.agentSessions(in: workspaceID, registry: sessionRuntimeStore.sessionRegistry)
        if let active = sessions.first(where: \.isActive) {
            let prompt = Self.finishPrompt(skill: skill, agent: active.agent, isUserSkill: isUserSkill)
            guard sendText(prompt, active.panelID) else {
                return .failure(.sendFailed("The agent's terminal is not available."))
            }
            ToasttyLog.info(
                "Sent finish hook to task session",
                category: .terminal,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "session_id": active.sessionID,
                    "skill": skill,
                ]
            )
            return .success(.sentToSession(sessionID: active.sessionID, panelID: active.panelID))
        }
        // The profile of the last agent that ran here, else whatever the
        // app launches by default.
        let agent = sessions.first?.agent ?? .codex
        let cwd = Self.taskDirectory(workspace: workspace, sessions: sessions)
        finishingWorkspaceIDs.insert(workspaceID)
        defer { finishingWorkspaceIDs.remove(workspaceID) }
        do {
            let launched = try await launchAgent(
                agent.rawValue,
                workspaceID,
                cwd,
                Self.finishPrompt(skill: skill, agent: agent, isUserSkill: isUserSkill)
            )
            ToasttyLog.info(
                "Launched agent for finish hook",
                category: .terminal,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "session_id": launched.sessionID,
                    "profile_id": agent.rawValue,
                    "skill": skill,
                ]
            )
            return .success(.launchedSession(sessionID: launched.sessionID, panelID: launched.panelID))
        } catch let problem as FinishProblem {
            return .failure(problem)
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }
    }

    /// Whether `skill` is an accepted user skill, which Toastty delivers
    /// under its plugin name; the tooltips and prompts name it that way.
    func isUserSkill(_ skill: String) -> Bool {
        acceptedUserSkillNames().contains(skill)
    }

    // MARK: - Script hooks

    func isRunningScript(workspaceID: UUID) -> Bool {
        scriptTasks[workspaceID] != nil
    }

    /// The script a hook names, or why it cannot run. The skill must be an
    /// accepted user skill package, and the script a regular file reached
    /// without any symbolic link, so a hook cannot run anything outside the
    /// installed skills.
    func scriptPath(for hook: WorkspaceTaskHooks.ScriptHook) -> Result<String, ScriptProblem> {
        let rootURL = userSkillsDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        let scriptURL = rootURL
            .appending(path: hook.skill, directoryHint: .isDirectory)
            .appending(path: hook.script)
        guard acceptedUserSkillNames().contains(hook.skill),
              Self.isRegularFileWithoutSymlinks(scriptURL, under: rootURL, fileManager: fileManager) else {
            return .failure(.scriptNotInstalled(path: scriptURL.path))
        }
        return .success(scriptURL.path)
    }

    private static func isRegularFileWithoutSymlinks(_ fileURL: URL, under rootURL: URL, fileManager: FileManager) -> Bool {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let components = fileURL.standardizedFileURL.pathComponents
        guard components.count > rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents else {
            return false
        }
        var current = rootURL
        for component in components.dropFirst(rootComponents.count) {
            current = current.appending(path: component)
            guard let type = try? fileManager.attributesOfItem(atPath: current.path)[.type] as? FileAttributeType else {
                return false
            }
            if type == .typeSymbolicLink {
                return false
            }
            if current.path == fileURL.standardizedFileURL.path {
                return type == .typeRegular
            }
            guard type == .typeDirectory else { return false }
        }
        return false
    }

    /// Runs the workspace's cleanup script. The script closes the workspace
    /// itself after its own checks; Toastty only reports what it said.
    @discardableResult
    func cleanUp(workspaceID: UUID) -> Result<Task<ScriptOutcome, Never>, ScriptProblem> {
        runScript(.cleanup, workspaceID: workspaceID)
    }

    /// Runs the workspace's close script, which abandons the task.
    @discardableResult
    func close(workspaceID: UUID) -> Result<Task<ScriptOutcome, Never>, ScriptProblem> {
        runScript(.close, workspaceID: workspaceID)
    }

    @discardableResult
    func runScript(_ kind: WorkspaceTaskHooks.ScriptKind, workspaceID: UUID) -> Result<Task<ScriptOutcome, Never>, ScriptProblem> {
        guard let store, let sessionRuntimeStore else { return .failure(.workspaceNotFound) }
        guard let workspace = store.state.workspacesByID[workspaceID] else { return .failure(.workspaceNotFound) }
        guard let hook = workspace.taskHooks.script(kind) else { return .failure(.noHook(kind)) }
        guard scriptTasks[workspaceID] == nil else { return .failure(.alreadyRunning) }
        let scriptPath: String
        switch self.scriptPath(for: hook) {
        case .success(let path):
            scriptPath = path
        case .failure(let problem):
            return .failure(problem)
        }
        let sessions = Self.agentSessions(in: workspaceID, registry: sessionRuntimeStore.sessionRegistry)
        let directory = Self.taskDirectory(workspace: workspace, sessions: sessions)
        var environment = baseEnvironment()
        environment["TOASTTY_WORKSPACE_ID"] = workspaceID.uuidString
        // The script acts for the user, not for any agent session, so it
        // must not inherit a session's identity or scope.
        for key in [
            ToasttyLaunchContextEnvironment.sessionIDKey,
            ToasttyLaunchContextEnvironment.panelIDKey,
            ToasttyLaunchContextEnvironment.agentKey,
            ToasttyLaunchContextEnvironment.paneJournalFileKey,
        ] {
            environment.removeValue(forKey: key)
        }
        let title = workspace.title
        let (executable, arguments) = Self.command(scriptPath: scriptPath, arguments: hook.arguments)
        let task = Task<ScriptOutcome, Never> { [runner, weak self] in
            let result = await runner.run(
                executable: executable,
                arguments: arguments,
                directory: directory,
                environment: environment,
                timeout: Self.cleanupTimeout
            )
            let outcome = Self.outcome(from: result)
            self?.finishScript(kind, workspaceID: workspaceID, title: title, outcome: outcome)
            return outcome
        }
        scriptTasks[workspaceID] = task
        sessionRuntimeStore.setWorkspaceTaskScriptRun(WorkspaceTaskScriptRun(kind: kind, phase: .running), for: workspaceID)
        ToasttyLog.info(
            "Started task script hook",
            category: .terminal,
            metadata: [
                "workspace_id": workspaceID.uuidString,
                "kind": kind.rawValue,
                "script": scriptPath,
                "directory": directory ?? "none",
            ]
        )
        return .success(task)
    }

    /// Runs the cleanup script of every finished subspace under a workspace,
    /// one at a time so the scripts do not race each other for git and the
    /// workspace list. Eligibility is checked again just before each script
    /// starts, because an earlier script can take minutes, during which a
    /// task may reopen or close. One batch per parent at a time: a second
    /// request joins the running one.
    func cleanUpFinished(
        parentWorkspaceID: UUID,
        isAllowed: @escaping @MainActor (UUID) -> Bool = { _ in true }
    ) -> Task<[(workspaceID: UUID, outcome: ScriptOutcome)], Never> {
        if let running = batchTasks[parentWorkspaceID] {
            return running
        }
        let task = Task<[(workspaceID: UUID, outcome: ScriptOutcome)], Never> { [weak self] in
            var results: [(workspaceID: UUID, outcome: ScriptOutcome)] = []
            guard let self else { return results }
            // The order is fixed at the start; membership is rechecked per task.
            let candidates = self.cleanupCandidates(under: parentWorkspaceID).filter(isAllowed)
            for workspaceID in candidates {
                guard self.cleanupCandidates(under: parentWorkspaceID).contains(workspaceID), isAllowed(workspaceID) else {
                    continue
                }
                switch self.cleanUp(workspaceID: workspaceID) {
                case .success(let run):
                    results.append((workspaceID, await run.value))
                case .failure(let problem):
                    results.append((workspaceID, .failed(detail: Self.message(for: problem))))
                }
            }
            self.batchTasks[parentWorkspaceID] = nil
            return results
        }
        batchTasks[parentWorkspaceID] = task
        return task
    }

    /// Subspaces under `parentWorkspaceID` that are done, have a cleanup
    /// hook, and are not already cleaning up.
    func cleanupCandidates(under parentWorkspaceID: UUID) -> [UUID] {
        guard let store else { return [] }
        let rootID = store.state.workspacesByID[parentWorkspaceID]?.parentWorkspaceID ?? parentWorkspaceID
        return store.state.subspaceWorkspaceIDs(of: rootID).filter { subspaceID in
            guard let workspace = store.state.workspacesByID[subspaceID] else { return false }
            return workspace.taskStage == .done && workspace.taskHooks.cleanup != nil && scriptTasks[subspaceID] == nil
        }
    }

    /// Drops a skipped or failed run from the row.
    func dismissScriptResult(workspaceID: UUID) {
        guard scriptTasks[workspaceID] == nil else { return }
        sessionRuntimeStore?.setWorkspaceTaskScriptRun(nil, for: workspaceID)
    }

    private func finishScript(_ kind: WorkspaceTaskHooks.ScriptKind, workspaceID: UUID, title: String, outcome: ScriptOutcome) {
        scriptTasks[workspaceID] = nil
        let workspace = store?.state.workspacesByID[workspaceID]
        var run: WorkspaceTaskScriptRun?
        switch outcome {
        case .cleaned:
            run = nil
        case .skipped(let detail):
            run = WorkspaceTaskScriptRun(kind: kind, phase: .skipped(detail: detail))
        case .failed(let detail):
            run = WorkspaceTaskScriptRun(kind: kind, phase: .failed(detail: detail))
        }
        if let workspace {
            // The task may have moved on while the script ran (reopened,
            // hook replaced); a result that no longer belongs to its stage
            // must not cover the stage's button. Same rule as the observer.
            if run != nil, Self.resultApplies(kind, to: workspace) == false {
                run = nil
            }
            sessionRuntimeStore?.setWorkspaceTaskScriptRun(run, for: workspaceID)
        } else {
            // The script closed the workspace, so there is no row to show
            // what happened after; say it another way when it is not done.
            sessionRuntimeStore?.setWorkspaceTaskScriptRun(nil, for: workspaceID)
            if run != nil {
                notify("\(title): \(kind == .cleanup ? "cleanup" : "close") did not finish", Self.outcomeDetail(outcome))
            }
        }
        ToasttyLog.info(
            "Task script hook finished",
            category: .terminal,
            metadata: [
                "workspace_id": workspaceID.uuidString,
                "kind": kind.rawValue,
                "workspace_title": title,
                "outcome": Self.outcomeName(outcome),
                "detail": Self.outcomeDetail(outcome),
            ]
        )
    }

    /// A skipped or failed result belongs to the stage it ran in: a cleanup
    /// result to the done task, a close result to any stage. Once the task
    /// moves on or closes, the row shows its stage's button again.
    private func dropStaleScriptResults(state: AppState) {
        guard let sessionRuntimeStore else { return }
        for (workspaceID, run) in sessionRuntimeStore.workspaceTaskScriptRuns where run.phase != .running {
            guard let workspace = state.workspacesByID[workspaceID],
                  Self.resultApplies(run.kind, to: workspace) else {
                sessionRuntimeStore.setWorkspaceTaskScriptRun(nil, for: workspaceID)
                continue
            }
        }
    }

    static func resultApplies(_ kind: WorkspaceTaskHooks.ScriptKind, to workspace: WorkspaceState) -> Bool {
        workspace.taskHooks.script(kind) != nil && (kind == .close || workspace.taskStage == .done)
    }

    /// A script runs through its interpreter when it has one in its name
    /// and is not executable, so a skill does not need `chmod +x`.
    static func command(scriptPath: String, arguments: [String]) -> (executable: String, arguments: [String]) {
        if FileManager.default.isExecutableFile(atPath: scriptPath) {
            return (scriptPath, arguments)
        }
        switch (scriptPath as NSString).pathExtension.lowercased() {
        case "py":
            return ("/usr/bin/env", ["python3", scriptPath] + arguments)
        case "sh":
            return ("/bin/sh", [scriptPath] + arguments)
        default:
            return (scriptPath, arguments)
        }
    }

    /// Exit 0 is cleaned, 3 is skipped, and anything else failed. The last
    /// non-empty line the script printed is the detail shown on the row.
    static func outcome(from result: WorkspaceTaskCleanupCommandResult) -> ScriptOutcome {
        if let failure = result.failure {
            return .failed(detail: failure)
        }
        let detail = lastLine(result.output)
        switch result.exitCode {
        case 0:
            return .cleaned(detail: detail ?? "cleaned")
        case cleanupSkippedExitCode:
            return .skipped(detail: detail ?? "skipped")
        case let code?:
            return .failed(detail: detail ?? "the cleanup script exited with status \(code)")
        case nil:
            return .failed(detail: detail ?? "the cleanup script did not finish")
        }
    }

    private static func lastLine(_ output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.isEmpty == false }
    }

    /// The workspace's agent sessions, most recently updated first.
    private static func agentSessions(in workspaceID: UUID, registry: SessionRegistry) -> [SessionRecord] {
        registry.sessionsByID.values
            .filter { $0.workspaceID == workspaceID && $0.agent != .processWatch }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Where the task lives: the most recent agent session's repository root
    /// or directory, else a terminal's directory.
    static func taskDirectory(workspace: WorkspaceState, sessions: [SessionRecord]) -> String? {
        for session in sessions {
            for path in [session.repoRoot, session.cwd] {
                if let path, path.isEmpty == false {
                    return path
                }
            }
        }
        var panelIDs: [UUID] = []
        if let focusedPanelID = workspace.focusedPanelID {
            panelIDs.append(focusedPanelID)
        }
        panelIDs.append(contentsOf: workspace.allPanelsByID.keys.sorted { $0.uuidString < $1.uuidString })
        for panelID in panelIDs {
            if case .terminal(let terminal)? = workspace.panelState(for: panelID) {
                for path in [terminal.agentLaunchWorkingDirectory, terminal.cwd] {
                    if let path, path.isEmpty == false {
                        return path
                    }
                }
            }
        }
        return nil
    }

    static func outcomeName(_ outcome: ScriptOutcome) -> String {
        switch outcome {
        case .cleaned: return "cleaned"
        case .skipped: return "skipped"
        case .failed: return "failed"
        }
    }

    static func outcomeDetail(_ outcome: ScriptOutcome) -> String {
        switch outcome {
        case .cleaned(let detail), .skipped(let detail), .failed(let detail):
            return detail
        }
    }

    static func message(for problem: FinishProblem) -> String {
        switch problem {
        case .noFinishHook: return "this workspace has no finish hook; set one with workspace.task.set-hooks"
        case .workspaceNotFound: return "workspaceID does not exist"
        case .workspaceIsTopLevel: return "workspace.task.finish applies to subspaces; this workspace is top-level"
        case .alreadyFinishing: return "a Finish Task for this workspace is still starting its agent"
        case .sendFailed(let detail): return "could not send the finish skill: \(detail)"
        case .launchFailed(let detail): return "could not launch an agent for the finish skill: \(detail)"
        }
    }

    static func message(for problem: ScriptProblem) -> String {
        switch problem {
        case .noHook(let kind): return "this workspace has no \(kind.rawValue) hook; set one with workspace.task.set-hooks"
        case .workspaceNotFound: return "workspaceID does not exist"
        case .alreadyRunning: return "a script hook is already running for this workspace"
        case .scriptNotInstalled(let path):
            return "the cleanup script is not an installed user skill script: \(path)"
        }
    }

    static func sendNotification(title: String, body: String) {
        Task {
            await SystemNotificationSender.send(title: title, body: body, workspaceID: nil, panelID: nil)
        }
    }
}
