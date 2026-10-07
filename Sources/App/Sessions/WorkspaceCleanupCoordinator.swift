import CoreState
import Foundation

/// What one command run produced. `exitCode` is `nil` when the command did
/// not start or did not finish in time; `failure` then says why.
struct WorkspaceCleanupCommandResult: Equatable, Sendable {
    var exitCode: Int32?
    var stdout: String
    var stderr: String
    var failure: String?

    /// The last line of stderr, or the failure, to show the user.
    var problemSummary: String {
        if let failure {
            return failure
        }
        let lastLine = stderr
            .split(whereSeparator: \.isNewline)
            .last
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        return lastLine?.isEmpty == false ? lastLine! : "exit status \(exitCode ?? -1)"
    }
}

/// Runs `gh` and the cleanup script. The live runner works on its own thread,
/// never on the main actor, because the script calls back into this app's
/// automation socket to list and close workspaces.
protocol WorkspaceCleanupCommandRunning: Sendable {
    func run(arguments: [String], directory: String, timeout: TimeInterval) async -> WorkspaceCleanupCommandResult
}

struct WorkspaceCleanupLiveCommandRunner: WorkspaceCleanupCommandRunning {
    let socketPath: String
    let cliExecutablePath: String?
    /// Replaces the login shell's PATH; integration tests use it to put a
    /// fake `gh` first.
    var pathOverride: String?

    private static let terminationGracePeriod: TimeInterval = 2
    private static let resolvedPath = PathCache()

    func run(arguments: [String], directory: String, timeout: TimeInterval) async -> WorkspaceCleanupCommandResult {
        let environment = environment()
        return await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: Self.runBlocking(
                    arguments: arguments,
                    directory: directory,
                    environment: environment,
                    timeout: timeout
                ))
            }
            thread.name = "toastty-workspace-cleanup"
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    /// This app's environment without the variables that tie a process to a
    /// Toastty session or panel: with them, the script would act as that
    /// session, with its workspace scope. PATH comes from the login shell,
    /// because an app started from the Finder does not see Homebrew's `gh`.
    private func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            key.hasPrefix("TOASTTY_") == false
        }
        environment[ToasttyLaunchContextEnvironment.socketPathKey] = socketPath
        if let cliExecutablePath {
            environment[ToasttyLaunchContextEnvironment.cliPathKey] = cliExecutablePath
        }
        if let path = pathOverride ?? Self.resolvedPath.value() {
            environment["PATH"] = path
        }
        // Nothing can answer a prompt; fail instead of waiting for one.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GH_PROMPT_DISABLED"] = "1"
        return environment
    }

    private static func runBlocking(
        arguments: [String],
        directory: String,
        environment: [String: String],
        timeout: TimeInterval
    ) -> WorkspaceCleanupCommandResult {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = URL(filePath: directory, directoryHint: .isDirectory)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return WorkspaceCleanupCommandResult(
                exitCode: nil,
                stdout: "",
                stderr: "",
                failure: "Could not run \(arguments.first ?? "command"): \(error.localizedDescription)"
            )
        }

        // Drain both pipes while the process runs, so a full pipe buffer
        // cannot stall it.
        let output = PipeOutput()
        let drained = DispatchGroup()
        for (pipe, isStdout) in [(stdoutPipe, true), (stderrPipe, false)] {
            drained.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                output.set(data, isStdout: isStdout)
                drained.leave()
            }
        }

        var failure: String?
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            failure = "\(arguments.first ?? "command") did not finish within \(Int(timeout)) seconds"
            process.terminate()
            if exited.wait(timeout: .now() + terminationGracePeriod) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + terminationGracePeriod)
            }
        }
        _ = drained.wait(timeout: .now() + terminationGracePeriod)
        return WorkspaceCleanupCommandResult(
            exitCode: failure == nil ? process.terminationStatus : nil,
            stdout: output.stdout,
            stderr: output.stderr,
            failure: failure
        )
    }

    private final class PipeOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var stdoutData = Data()
        private var stderrData = Data()

        func set(_ data: Data, isStdout: Bool) {
            lock.withLock {
                if isStdout { stdoutData = data } else { stderrData = data }
            }
        }

        var stdout: String { lock.withLock { String(decoding: stdoutData, as: UTF8.self) } }
        var stderr: String { lock.withLock { String(decoding: stderrData, as: UTF8.self) } }
    }

    /// Resolving the login shell's PATH starts a shell, so it runs once, on
    /// the first command's thread.
    private final class PathCache: @unchecked Sendable {
        private let lock = NSLock()
        private var resolved = false
        private var path: String?

        func value() -> String? {
            lock.withLock {
                if resolved == false {
                    path = ManagedAgentBasePathResolver().resolve()
                    resolved = true
                }
                return path
            }
        }
    }
}

/// Carries out Merge and Clean after the agent's part. Once the workspace
/// is marked done it checks the pull request with `gh`, and when the pull
/// request has merged it runs the bundled `worktree-cleanup` status script on
/// that one pull request and workspace. The script closes the workspace,
/// removes the worktree, and deletes the branches, with the same checks the
/// skill uses. Requests are shown through `SessionRuntimeStore` and saved in
/// user defaults.
@MainActor
final class WorkspaceCleanupCoordinator {
    static let pollInterval: Duration = .seconds(30)
    /// Failed `gh` checks in a row before the request shows as failed.
    static let maximumPollFailures = 3
    static let pullRequestCheckTimeout: TimeInterval = 30
    static let cleanupTimeout: TimeInterval = 300
    static let scriptSubpath = "WorkflowExamples/skills/worktree-cleanup/scripts/worktree-status.py"
    private static let persistenceKey = "toastty.workspaceCleanupRequests"

    private weak var store: AppStore?
    private weak var sessionRuntimeStore: SessionRuntimeStore?
    private let runner: any WorkspaceCleanupCommandRunning
    private let scriptPath: String?
    private let userDefaults: UserDefaults?
    private let pollInterval: Duration
    private let notify: @MainActor (_ title: String, _ body: String) -> Void
    private var requests: [UUID: WorkspaceCleanupRequest] = [:]
    private var pollTasks: [UUID: Task<Void, Never>] = [:]
    private var pollFailureCounts: [UUID: Int] = [:]
    private var storeObserverToken: UUID?

    init(
        store: AppStore,
        sessionRuntimeStore: SessionRuntimeStore,
        runner: any WorkspaceCleanupCommandRunning,
        scriptPath: String? = Bundle.main.resourceURL?.appendingPathComponent(scriptSubpath).path,
        userDefaults: UserDefaults? = ToasttyAppDefaults.current,
        pollInterval: Duration = WorkspaceCleanupCoordinator.pollInterval,
        notify: @escaping @MainActor (_ title: String, _ body: String) -> Void = WorkspaceCleanupCoordinator.sendNotification
    ) {
        self.store = store
        self.sessionRuntimeStore = sessionRuntimeStore
        self.runner = runner
        self.scriptPath = scriptPath
        self.userDefaults = userDefaults
        self.pollInterval = pollInterval
        self.notify = notify
        sessionRuntimeStore.workspaceCleanupCoordinator = self
        // Through `update`, so saved requests are shown and their checks
        // start, before the reconcile below drops the ones that no longer apply.
        for (workspaceID, request) in Self.loadRequests(userDefaults: userDefaults) {
            update(workspaceID, request)
        }
        storeObserverToken = store.addActionAppliedObserver { [weak self] _, _, nextState in
            self?.reconcile(state: nextState)
        }
        reconcile(state: store.state)
    }

    // MARK: - Requests

    /// Records that the user chose Merge and Clean for `workspaceID`. A
    /// later Just Merge replaces it with `cancelCleanup`.
    func requestCleanup(workspaceID: UUID, pullRequestNumber: Int, repoPath: String) {
        guard requests[workspaceID]?.phase != .cleaningUp else { return }
        pollFailureCounts[workspaceID] = nil
        update(workspaceID, WorkspaceCleanupRequest(pullRequestNumber: pullRequestNumber, repoPath: repoPath))
        if let state = store?.state {
            reconcile(state: state)
        }
    }

    func cancelCleanup(workspaceID: UUID) {
        guard let request = requests[workspaceID], request.phase != .cleaningUp else { return }
        update(workspaceID, nil)
    }

    /// Checks the pull request again after a failure.
    func retryCleanup(workspaceID: UUID) {
        guard var request = requests[workspaceID], case .failed = request.phase else { return }
        pollFailureCounts[workspaceID] = nil
        request.phase = .awaitingMerge
        update(workspaceID, request)
    }

    private func reconcile(state: AppState) {
        for (workspaceID, request) in requests {
            let workspace = state.workspacesByID[workspaceID]
            let annotation = workspace?.annotations[SidebarSubspacePresentation.annotationKeyPullRequest]
            let next = request.reconciled(
                workspaceExists: workspace != nil,
                isDone: workspace?.doneAt != nil,
                pullRequestNumber: annotation.flatMap {
                    WorkspaceCleanupRequest.pullRequestNumber(text: $0.text, url: $0.url)
                }
            )
            if next != request {
                update(workspaceID, next)
            }
        }
    }

    /// The one place requests change: publishes them, saves them, and starts
    /// or stops the pull request checks to match.
    private func update(_ workspaceID: UUID, _ request: WorkspaceCleanupRequest?) {
        let previous = requests[workspaceID]
        requests[workspaceID] = request
        if previous != request {
            ToasttyLog.info(
                "Workspace cleanup request changed",
                category: .terminal,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "pull_request": request.map { String($0.pullRequestNumber) } ?? "none",
                    "phase": request.map { Self.phaseName($0.phase) } ?? "none",
                ]
            )
        }
        sessionRuntimeStore?.setWorkspaceCleanupRequests(requests)
        saveRequests()
        if request?.phase == .awaitingMerge {
            if pollTasks[workspaceID] == nil {
                // Holds the coordinator only during each check, not while it
                // sleeps between checks.
                pollTasks[workspaceID] = Task { [weak self, pollInterval] in
                    while Task.isCancelled == false,
                          await self?.checkPullRequest(workspaceID: workspaceID) == true {
                        try? await Task.sleep(for: pollInterval)
                    }
                }
            }
        } else {
            pollTasks.removeValue(forKey: workspaceID)?.cancel()
            pollFailureCounts[workspaceID] = nil
        }
    }

    // MARK: - Pull request checks

    /// Checks the pull request once. Returns whether to check again later.
    private func checkPullRequest(workspaceID: UUID) async -> Bool {
        guard let request = requests[workspaceID], request.phase == .awaitingMerge else { return false }
        let result = await runner.run(
            arguments: ["gh", "pr", "view", String(request.pullRequestNumber), "--json", "state"],
            directory: request.repoPath,
            timeout: Self.pullRequestCheckTimeout
        )
        guard Task.isCancelled == false,
              requests[workspaceID] == request else { return false }
        switch Self.pullRequestState(from: result) {
        case "MERGED":
            pollTasks[workspaceID] = nil
            await runCleanup(workspaceID: workspaceID, request: request)
            return false
        case "CLOSED":
            pollTasks[workspaceID] = nil
            fail(workspaceID, request, "PR #\(request.pullRequestNumber) was closed without merging.")
            return false
        case "OPEN":
            pollFailureCounts[workspaceID] = nil
            return true
        default:
            let failures = (pollFailureCounts[workspaceID] ?? 0) + 1
            pollFailureCounts[workspaceID] = failures
            ToasttyLog.warning(
                "Workspace cleanup could not check its pull request",
                category: .terminal,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "pull_request": String(request.pullRequestNumber),
                    "failures": String(failures),
                    "problem": result.problemSummary,
                ]
            )
            if failures >= Self.maximumPollFailures {
                pollTasks[workspaceID] = nil
                fail(
                    workspaceID,
                    request,
                    "Could not check PR #\(request.pullRequestNumber) with gh: \(result.problemSummary)"
                )
                return false
            }
            return true
        }
    }

    private static func pullRequestState(from result: WorkspaceCleanupCommandResult) -> String? {
        guard result.exitCode == 0,
              let object = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] else {
            return nil
        }
        return object["state"] as? String
    }

    // MARK: - Cleanup

    private func runCleanup(workspaceID: UUID, request: WorkspaceCleanupRequest) async {
        guard let scriptPath, FileManager.default.fileExists(atPath: scriptPath) else {
            fail(workspaceID, request, "The cleanup script is missing from this Toastty build.")
            return
        }
        let workspaceTitle = store?.state.workspacesByID[workspaceID]?.title ?? "the workspace"
        var running = request
        running.phase = .cleaningUp
        update(workspaceID, running)

        let result = await runner.run(
            arguments: [
                "python3", scriptPath, "--json", "--cleanup-merged",
                "--pr", String(request.pullRequestNumber),
                "--workspace", workspaceID.uuidString,
                "--repo", request.repoPath,
            ],
            directory: request.repoPath,
            timeout: Self.cleanupTimeout
        )
        let outcome = Self.cleanupOutcome(from: result, pullRequestNumber: request.pullRequestNumber)
        ToasttyLog.info(
            "Workspace cleanup finished",
            category: .terminal,
            metadata: [
                "workspace_id": workspaceID.uuidString,
                "pull_request": String(request.pullRequestNumber),
                "status": outcome.status ?? "none",
                "detail": outcome.detail,
            ]
        )
        let workspaceClosed = store?.state.workspacesByID[workspaceID] == nil
        if outcome.status == "cleaned" {
            update(workspaceID, nil)
            notify("Cleaned up PR #\(request.pullRequestNumber)", "\(workspaceTitle): \(outcome.detail)")
        } else if workspaceClosed {
            // The workspace is gone, so its button cannot show what is left.
            update(workspaceID, nil)
            notify("Cleanup of PR #\(request.pullRequestNumber) did not finish", "\(workspaceTitle): \(outcome.detail)")
        } else {
            fail(workspaceID, request, outcome.detail)
            // New work or a changed pull request during the run drops the
            // request instead of offering a retry.
            if let state = store?.state {
                reconcile(state: state)
            }
        }
    }

    struct CleanupOutcome: Equatable {
        /// The script's `cleanup_status`: cleaned, partial, stopped, or
        /// skipped; `nil` when the script did not clean up the row at all.
        var status: String?
        var detail: String
    }

    static func cleanupOutcome(from result: WorkspaceCleanupCommandResult, pullRequestNumber: Int) -> CleanupOutcome {
        guard result.exitCode == 0 else {
            return CleanupOutcome(status: nil, detail: "The cleanup script failed: \(result.problemSummary)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
              let rows = object["prs"] as? [[String: Any]] else {
            return CleanupOutcome(status: nil, detail: "The cleanup script printed no report.")
        }
        guard let row = rows.first(where: { ($0["pr"] as? Int) == pullRequestNumber }) else {
            return CleanupOutcome(
                status: nil,
                detail: "The cleanup script found no worktree for PR #\(pullRequestNumber)."
            )
        }
        if let status = row["cleanup_status"] as? String {
            return CleanupOutcome(status: status, detail: row["cleanup"] as? String ?? status)
        }
        // A merged PR whose worktree is not clean at the merged head is
        // blocked; the reason says what is in the way.
        let reason = (row["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return CleanupOutcome(status: nil, detail: reason ?? "The cleanup script did not clean up PR #\(pullRequestNumber).")
    }

    private func fail(_ workspaceID: UUID, _ request: WorkspaceCleanupRequest, _ reason: String) {
        var failed = request
        failed.phase = .failed(reason: reason)
        update(workspaceID, failed)
    }

    // MARK: - Persistence

    private func saveRequests() {
        guard let userDefaults else { return }
        let saved = Dictionary(uniqueKeysWithValues: requests.map { ($0.key.uuidString, $0.value.persisted) })
        if saved.isEmpty {
            userDefaults.removeObject(forKey: Self.persistenceKey)
        } else if let data = try? JSONEncoder().encode(saved) {
            userDefaults.set(data, forKey: Self.persistenceKey)
        }
    }

    private static func loadRequests(userDefaults: UserDefaults?) -> [UUID: WorkspaceCleanupRequest] {
        guard let data = userDefaults?.data(forKey: persistenceKey),
              let saved = try? JSONDecoder().decode([String: WorkspaceCleanupRequest].self, from: data) else {
            return [:]
        }
        var requests: [UUID: WorkspaceCleanupRequest] = [:]
        for (key, request) in saved {
            guard let workspaceID = UUID(uuidString: key) else { continue }
            requests[workspaceID] = request.persisted
        }
        return requests
    }

    private static func phaseName(_ phase: WorkspaceCleanupRequest.Phase) -> String {
        switch phase {
        case .awaitingDone: return "awaiting_done"
        case .awaitingMerge: return "awaiting_merge"
        case .cleaningUp: return "cleaning_up"
        case .failed: return "failed"
        }
    }

    static func sendNotification(title: String, body: String) {
        Task {
            await SystemNotificationSender.send(title: title, body: body, workspaceID: nil, panelID: nil)
        }
    }
}
