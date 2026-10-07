import AppKit
import CoreState
import Foundation

/// What one command run produced. `exitCode` is `nil` when the command did
/// not start or did not finish in time; `failure` then says why.
struct WorkspaceMergeCommandResult: Equatable, Sendable {
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

/// Runs `gh` and the pull request script. The live runner works on its own thread,
/// never on the main actor, because the script calls back into this app's
/// automation socket to list and close workspaces.
protocol WorkspaceMergeCommandRunning: Sendable {
    func run(arguments: [String], directory: String, timeout: TimeInterval) async -> WorkspaceMergeCommandResult
}

struct WorkspaceMergeLiveCommandRunner: WorkspaceMergeCommandRunning {
    let socketPath: String
    let cliExecutablePath: String?
    /// Replaces the login shell's PATH; integration tests use it to put a
    /// fake `gh` first.
    var pathOverride: String?

    private static let terminationGracePeriod: TimeInterval = 2
    private static let resolvedPath = PathCache()

    func run(arguments: [String], directory: String, timeout: TimeInterval) async -> WorkspaceMergeCommandResult {
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
            thread.name = "toastty-workspace-merge"
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
    ) -> WorkspaceMergeCommandResult {
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
            return WorkspaceMergeCommandResult(
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
        return WorkspaceMergeCommandResult(
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

/// Runs what a subspace's Merge button asks for, with the bundled
/// `workspace-pull-request.py` script. Merge has the script merge the pull
/// request, or turn on auto-merge while checks run, and then marks the
/// workspace done. After a Merge and Clean it checks the pull request with
/// `gh` until it merges, then has the script close the workspace, remove the
/// worktree, and delete the branches. Close Without Merging has the script
/// close the pull request and clean up. The script checks everything before
/// its first change. Requests are shown through `SessionRuntimeStore`, and
/// the ones waiting for a merge are saved in user defaults.
@MainActor
final class WorkspaceMergeCoordinator {
    static let pollInterval: Duration = .seconds(30)
    /// Failed `gh` checks in a row before the request shows as failed.
    static let maximumPollFailures = 3
    static let pullRequestCheckTimeout: TimeInterval = 30
    static let scriptTimeout: TimeInterval = 300
    private static let persistenceKey = "toastty.workspaceMergeRequests"

    private weak var store: AppStore?
    private weak var sessionRuntimeStore: SessionRuntimeStore?
    private let runner: any WorkspaceMergeCommandRunning
    private let scriptPath: String?
    private let userDefaults: UserDefaults?
    private let pollInterval: Duration
    private let notify: @MainActor (_ title: String, _ body: String) -> Void
    private let presentFailure: @MainActor (_ title: String, _ message: String) -> Void
    private var requests: [UUID: WorkspaceMergeRequest] = [:]
    private var pollTasks: [UUID: Task<Void, Never>] = [:]
    private var pollFailureCounts: [UUID: Int] = [:]
    private var storeObserverToken: UUID?

    init(
        store: AppStore,
        sessionRuntimeStore: SessionRuntimeStore,
        runner: any WorkspaceMergeCommandRunning,
        scriptPath: String? = Bundle.main.url(forResource: "workspace-pull-request", withExtension: "py")?.path,
        userDefaults: UserDefaults? = ToasttyAppDefaults.current,
        pollInterval: Duration = WorkspaceMergeCoordinator.pollInterval,
        notify: @escaping @MainActor (_ title: String, _ body: String) -> Void = WorkspaceMergeCoordinator.sendNotification,
        presentFailure: @escaping @MainActor (_ title: String, _ message: String) -> Void = WorkspaceMergeCoordinator.presentAlert
    ) {
        self.store = store
        self.sessionRuntimeStore = sessionRuntimeStore
        self.runner = runner
        self.scriptPath = scriptPath
        self.userDefaults = userDefaults
        self.pollInterval = pollInterval
        self.notify = notify
        self.presentFailure = presentFailure
        sessionRuntimeStore.workspaceMergeCoordinator = self
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

    /// Merges the pull request, or turns on auto-merge, and marks the
    /// workspace done. With `thenCleanUp`, the request then waits for the
    /// merge and cleans up after it. A refusal shows why and changes nothing.
    @discardableResult
    func merge(
        workspaceID: UUID,
        pullRequest: WorkspacePullRequestLink,
        repoPath: String,
        thenCleanUp: Bool
    ) -> Task<Void, Never>? {
        guard requests[workspaceID]?.isRunning != true else { return nil }
        let request = WorkspaceMergeRequest(pullRequest: pullRequest, repoPath: repoPath, phase: .merging(thenCleanUp: thenCleanUp))
        update(workspaceID, request)
        return Task { [weak self] in
            await self?.runMerge(workspaceID: workspaceID, request: request, thenCleanUp: thenCleanUp)
        }
    }

    /// Drops a cleanup that is waiting for the merge or that failed.
    func cancelCleanup(workspaceID: UUID) {
        guard let request = requests[workspaceID], request.isRunning == false else { return }
        update(workspaceID, nil)
    }

    /// Closes the pull request without merging it, then closes the workspace,
    /// removes its worktree, and deletes its local branch. The branch stays
    /// on GitHub, so the pull request can be reopened. The script checks
    /// everything before its first change, so a refusal leaves the pull
    /// request open. Replaces any pending cleanup.
    @discardableResult
    func closeWithoutMerging(
        workspaceID: UUID,
        pullRequest: WorkspacePullRequestLink,
        repoPath: String
    ) -> Task<Void, Never>? {
        guard requests[workspaceID]?.isRunning != true else { return nil }
        let request = WorkspaceMergeRequest(pullRequest: pullRequest, repoPath: repoPath, phase: .closing)
        update(workspaceID, request)
        return Task { [weak self] in
            await self?.runClose(workspaceID: workspaceID, request: request)
        }
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
                pullRequest: WorkspacePullRequestLink(annotationURL: annotation?.url)
            )
            if next != request {
                update(workspaceID, next)
            }
        }
    }

    /// The one place requests change: publishes them, saves them, and starts
    /// or stops the pull request checks to match.
    private func update(_ workspaceID: UUID, _ request: WorkspaceMergeRequest?) {
        let previous = requests[workspaceID]
        requests[workspaceID] = request
        if previous != request {
            ToasttyLog.info(
                "Workspace merge request changed",
                category: .terminal,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "pull_request": request.map { String($0.pullRequest.number) } ?? "none",
                    "phase": request.map { Self.phaseName($0.phase) } ?? "none",
                ]
            )
        }
        sessionRuntimeStore?.setWorkspaceMergeRequests(requests)
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

    // MARK: - Merge

    private func runMerge(workspaceID: UUID, request: WorkspaceMergeRequest, thenCleanUp: Bool) async {
        let outcome = await runScript("merge", workspaceID: workspaceID, request: request)
        guard requests[workspaceID] == request else { return }
        let pullRequest = "PR #\(request.pullRequest.number)"
        guard outcome.status == "merged" || outcome.status == "queued" else {
            update(workspaceID, nil)
            presentFailure("Unable to Merge \(pullRequest)", outcome.detail)
            return
        }
        // The workspace may have closed, or moved to another pull request,
        // while the script ran; the done mark belongs to this one only.
        let annotation = store?.state.workspacesByID[workspaceID]?
            .annotations[SidebarSubspacePresentation.annotationKeyPullRequest]
        guard let store, WorkspacePullRequestLink(annotationURL: annotation?.url) == request.pullRequest else {
            update(workspaceID, nil)
            return
        }
        // The done mark records that the user accepted this version. New work
        // in the workspace clears it, and with it a pending cleanup.
        store.send(.setWorkspaceDone(workspaceID: workspaceID, doneAt: Date()))
        if thenCleanUp {
            var waiting = request
            waiting.phase = .awaitingMerge
            update(workspaceID, waiting)
        } else {
            update(workspaceID, nil)
        }
    }

    // MARK: - Pull request checks

    /// Checks the pull request once. Returns whether to check again later.
    private func checkPullRequest(workspaceID: UUID) async -> Bool {
        guard let request = requests[workspaceID], request.phase == .awaitingMerge else { return false }
        let number = request.pullRequest.number
        let result = await runner.run(
            arguments: ["gh", "pr", "view", request.pullRequest.url, "--json", "state"],
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
            fail(workspaceID, request, "PR #\(number) was closed without merging.")
            return false
        case "OPEN":
            pollFailureCounts[workspaceID] = nil
            return true
        default:
            let failures = (pollFailureCounts[workspaceID] ?? 0) + 1
            pollFailureCounts[workspaceID] = failures
            ToasttyLog.warning(
                "Workspace merge could not check its pull request",
                category: .terminal,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "pull_request": String(number),
                    "failures": String(failures),
                    "problem": result.problemSummary,
                ]
            )
            if failures >= Self.maximumPollFailures {
                pollTasks[workspaceID] = nil
                fail(workspaceID, request, "Could not check PR #\(number) with gh: \(result.problemSummary)")
                return false
            }
            return true
        }
    }

    private static func pullRequestState(from result: WorkspaceMergeCommandResult) -> String? {
        guard result.exitCode == 0,
              let object = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] else {
            return nil
        }
        return object["state"] as? String
    }

    // MARK: - Cleanup and close

    private func runCleanup(workspaceID: UUID, request: WorkspaceMergeRequest) async {
        let workspaceTitle = store?.state.workspacesByID[workspaceID]?.title ?? "the workspace"
        var running = request
        running.phase = .cleaningUp
        update(workspaceID, running)

        let outcome = await runScript("clean-up", workspaceID: workspaceID, request: request)
        let workspaceClosed = store?.state.workspacesByID[workspaceID] == nil
        let pullRequest = "PR #\(request.pullRequest.number)"
        if outcome.status == "cleaned" {
            update(workspaceID, nil)
            notify("Cleaned up \(pullRequest)", "\(workspaceTitle): \(outcome.detail)")
        } else if workspaceClosed {
            // The workspace is gone, so its button cannot show what is left.
            update(workspaceID, nil)
            notify("Cleanup of \(pullRequest) did not finish", "\(workspaceTitle): \(outcome.detail)")
        } else {
            fail(workspaceID, request, outcome.detail)
            // New work or a changed pull request during the run drops the
            // request instead of offering a retry.
            if let state = store?.state {
                reconcile(state: state)
            }
        }
    }

    private func runClose(workspaceID: UUID, request: WorkspaceMergeRequest) async {
        let workspaceTitle = store?.state.workspacesByID[workspaceID]?.title ?? "the workspace"
        let outcome = await runScript("close", workspaceID: workspaceID, request: request)
        // Nothing is left to wait for, whatever the outcome.
        if requests[workspaceID] == request {
            update(workspaceID, nil)
        }
        let pullRequest = "PR #\(request.pullRequest.number)"
        if outcome.status == "cleaned" {
            notify("Closed \(pullRequest) without merging", "\(workspaceTitle): \(outcome.detail)")
        } else if store?.state.workspacesByID[workspaceID] == nil {
            notify("Closing \(pullRequest) did not finish", "\(workspaceTitle): \(outcome.detail)")
        } else {
            presentFailure("Unable to Close \(pullRequest)", outcome.detail)
        }
    }

    /// Runs the pull request script on one pull request and workspace and
    /// reads what it did.
    private func runScript(
        _ action: String,
        workspaceID: UUID,
        request: WorkspaceMergeRequest
    ) async -> ScriptOutcome {
        let outcome: ScriptOutcome
        if let scriptPath, FileManager.default.fileExists(atPath: scriptPath) {
            let result = await runner.run(
                arguments: [
                    "python3", scriptPath, action,
                    "--pr", String(request.pullRequest.number),
                    "--pr-url", request.pullRequest.url,
                    "--workspace", workspaceID.uuidString,
                    "--repo", request.repoPath,
                ],
                directory: request.repoPath,
                timeout: Self.scriptTimeout
            )
            outcome = Self.scriptOutcome(from: result)
        } else {
            outcome = ScriptOutcome(status: nil, detail: "The pull request script is missing from this Toastty build.")
        }
        ToasttyLog.info(
            "Workspace pull request script finished",
            category: .terminal,
            metadata: [
                "workspace_id": workspaceID.uuidString,
                "pull_request": String(request.pullRequest.number),
                "action": action,
                "status": outcome.status ?? "none",
                "detail": outcome.detail,
            ]
        )
        return outcome
    }

    struct ScriptOutcome: Equatable {
        /// The script's status: merged, queued, or refused for a merge;
        /// cleaned, partial, stopped, or skipped for a cleanup or close;
        /// failed, or `nil` when the script printed no report.
        var status: String?
        var detail: String
    }

    static func scriptOutcome(from result: WorkspaceMergeCommandResult) -> ScriptOutcome {
        guard result.exitCode == 0 else {
            return ScriptOutcome(status: nil, detail: "The pull request script failed: \(result.problemSummary)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
              let status = object["status"] as? String else {
            return ScriptOutcome(status: nil, detail: "The pull request script printed no report.")
        }
        return ScriptOutcome(status: status, detail: object["detail"] as? String ?? status)
    }

    private func fail(_ workspaceID: UUID, _ request: WorkspaceMergeRequest, _ reason: String) {
        var failed = request
        failed.phase = .failed(reason: reason)
        update(workspaceID, failed)
    }

    // MARK: - Persistence

    private func saveRequests() {
        guard let userDefaults else { return }
        let saved = Dictionary(uniqueKeysWithValues: requests.compactMap { workspaceID, request in
            request.persisted.map { (workspaceID.uuidString, $0) }
        })
        if saved.isEmpty {
            userDefaults.removeObject(forKey: Self.persistenceKey)
        } else if let data = try? JSONEncoder().encode(saved) {
            userDefaults.set(data, forKey: Self.persistenceKey)
        }
    }

    private static func loadRequests(userDefaults: UserDefaults?) -> [UUID: WorkspaceMergeRequest] {
        guard let data = userDefaults?.data(forKey: persistenceKey),
              let saved = try? JSONDecoder().decode([String: WorkspaceMergeRequest].self, from: data) else {
            return [:]
        }
        var requests: [UUID: WorkspaceMergeRequest] = [:]
        for (key, request) in saved {
            guard let workspaceID = UUID(uuidString: key) else { continue }
            requests[workspaceID] = request.persisted
        }
        return requests
    }

    private static func phaseName(_ phase: WorkspaceMergeRequest.Phase) -> String {
        switch phase {
        case .merging(let thenCleanUp): return thenCleanUp ? "merging_then_clean_up" : "merging"
        case .awaitingMerge: return "awaiting_merge"
        case .cleaningUp: return "cleaning_up"
        case .failed: return "failed"
        case .closing: return "closing"
        }
    }

    static func sendNotification(title: String, body: String) {
        Task {
            await SystemNotificationSender.send(title: title, body: body, workspaceID: nil, panelID: nil)
        }
    }

    static func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
