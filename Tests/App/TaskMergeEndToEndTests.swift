import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// A task's merge and cleanup for real: the task coordinator and board, the
/// merge coordinator with the bundled pull request script, the `toastty`
/// CLI from the app bundle, and an automation socket server bound to the
/// store. Git works on a disposable repository with a local bare origin; a
/// fake `gh` reports the pull request and records merges.
@MainActor
struct TaskMergeEndToEndTests: AutomationSocketServerTestSupport {
    @Test
    func taskMergeWaitsForTheAgentsTurnThenCleansUp() async throws {
        try await withScenario { scenario in
            // The merge skill calls task merge in the middle of its turn.
            scenario.reportAgent(.working)
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: scenario.head, caller: .unmanaged)

            await scenario.waitUntil("GitHub merges it") { FileManager.default.fileExists(atPath: scenario.mergedMarker) }
            await scenario.waitUntil("the merge is recorded") { scenario.record?.mergedAt != nil }
            // The agent is still writing its reply, so nothing closes.
            try await Task.sleep(for: .milliseconds(600))
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] != nil)
            #expect(scenario.boardItem?.merge == .cleaningUp)

            scenario.reportAgent(.ready)
            await scenario.waitUntil("the cleanup finishes") { scenario.record?.cleanup?.finishedAt != nil }
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] == nil)
            #expect(FileManager.default.fileExists(atPath: scenario.worktree) == false)
            #expect(scenario.record?.mergeRequestedAt != nil)
            #expect(scenario.failureAlerts.isEmpty, "\(scenario.failureAlerts)")
            // No release_tags: a merged task is done.
            #expect(scenario.boardItem?.stage == .done)
        }
    }

    @Test
    func aWatchedCommandDoesNotHoldUpTheCleanup() async throws {
        try await withScenario { scenario in
            // A dev server watched in the task space reports working while it runs.
            scenario.sessionRuntimeStore.startSession(
                sessionID: "server", agent: .processWatch, panelID: UUID(), windowID: scenario.windowID,
                workspaceID: scenario.taskSpaceID, codexStatusTrackingSource: .externallyReported,
                cwd: scenario.worktree, repoRoot: scenario.worktree, at: Date()
            )
            scenario.sessionRuntimeStore.updateStatus(sessionID: "server", status: SessionStatus(kind: .working, summary: "running"), at: Date())
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: nil, caller: .unmanaged)
            await scenario.waitUntil("the cleanup finishes") { scenario.record?.cleanup?.finishedAt != nil }
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] == nil)
        }
    }

    @Test
    func aPushAfterTheChecksIsNotMerged() async throws {
        try await withScenario { scenario in
            let checked = try scenario.git(["rev-parse", "HEAD~1"], in: scenario.worktree)
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: checked, caller: .unmanaged)
            await scenario.waitUntil("the merge is refused") { scenario.failureAlerts.isEmpty == false }
            #expect(scenario.failureAlerts.first?.contains("not the checked commit") == true, "\(scenario.failureAlerts)")
            #expect(FileManager.default.fileExists(atPath: scenario.mergedMarker) == false)
            #expect(scenario.merges.request(workspaceID: scenario.taskSpaceID) == nil)
        }
    }

    @Test
    func cancelMergeStopsAMergeWaitingForChecks() async throws {
        try await withScenario(checksPending: true) { scenario in
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: nil, caller: .unmanaged)
            await scenario.waitUntil("the merge waits") {
                if case .awaitingChecks? = scenario.merges.request(workspaceID: scenario.taskSpaceID)?.phase { return true }
                return false
            }
            #expect(scenario.boardItem?.merge == .waitingForChecks)
            #expect(scenario.boardItem?.stage == .running)

            try scenario.tasks.cancelMerge(taskID: scenario.taskID)
            #expect(scenario.merges.request(workspaceID: scenario.taskSpaceID) == nil)
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID]?.doneAt == nil)
            #expect(scenario.record?.mergeRequestedAt == nil)
            #expect(scenario.record?.mergeCancelledAt != nil)
            #expect(FileManager.default.fileExists(atPath: scenario.mergedMarker) == false)
        }
    }

    @Test
    func aMergeOnGitHubCleansUpWhenTheAgentIsAtRest() async throws {
        try await withScenario { scenario in
            scenario.reportAgent(.ready)
            // Someone merged the pull request on GitHub.
            FileManager.default.createFile(atPath: scenario.mergedMarker, contents: nil)
            await scenario.pullRequests.refresh(scenario.pullRequest).value

            await scenario.waitUntil("the cleanup finishes") { scenario.record?.cleanup?.finishedAt != nil }
            #expect(scenario.record?.mergedAt != nil)
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] == nil)
            #expect(FileManager.default.fileExists(atPath: scenario.worktree) == false)
        }
    }

    @Test
    func aMergeOnGitHubWithLocalWorkAsksBeforeCleaningUp() async throws {
        try await withScenario { scenario in
            scenario.reportAgent(.ready)
            try Data("draft".utf8).write(to: URL(filePath: scenario.worktree).appending(path: "notes.txt"))
            FileManager.default.createFile(atPath: scenario.mergedMarker, contents: nil)
            await scenario.pullRequests.refresh(scenario.pullRequest).value

            await scenario.waitUntil("the cleanup stops") {
                if case .failed? = scenario.merges.request(workspaceID: scenario.taskSpaceID)?.phase { return true }
                return false
            }
            guard case .needsYou(.cleanupStopped(let reason))? = scenario.boardItem?.stage else {
                Issue.record("expected Merged · clean up?, got \(String(describing: scenario.boardItem?.stage))")
                return
            }
            #expect(reason.contains("uncommitted changes"))
            #expect(FileManager.default.fileExists(atPath: scenario.worktree))

            // Keep As Is leaves the task space and drops the cleanup.
            try scenario.tasks.dismissCleanup(taskID: scenario.taskID)
            #expect(scenario.merges.request(workspaceID: scenario.taskSpaceID) == nil)
            #expect(scenario.boardItem?.stage == .done)
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] != nil)
            // A later answer from GitHub, as after a relaunch, leaves it.
            try FileManager.default.removeItem(atPath: scenario.worktree + "/notes.txt")
            scenario.tasks.cleanUpMergedTasks([scenario.taskID])
            #expect(scenario.merges.request(workspaceID: scenario.taskSpaceID) == nil)
            #expect(scenario.record?.cleanup?.finishedAt != nil)
        }
    }

    @Test
    func aMergeOnGitHubWhileTheAgentWorksWaitsForTheUser() async throws {
        try await withScenario { scenario in
            scenario.fakeSessions.sessions["agent"] = TaskSessionInfo(
                sessionID: "agent", agent: .claude, panelID: scenario.taskPanelID, workspaceID: scenario.taskSpaceID,
                cwd: scenario.worktree, isActive: true, isInTurn: true
            )
            FileManager.default.createFile(atPath: scenario.mergedMarker, contents: nil)
            await scenario.pullRequests.refresh(scenario.pullRequest).value

            #expect(scenario.record?.cleanup?.problem?.contains("while the agent was working") == true)
            #expect(scenario.merges.request(workspaceID: scenario.taskSpaceID) == nil)
            guard case .needsYou(.cleanupStopped)? = scenario.boardItem?.stage else {
                Issue.record("expected Merged · clean up?, got \(String(describing: scenario.boardItem?.stage))")
                return
            }

            // Clean Up once the agent is done.
            scenario.fakeSessions.sessions["agent"]?.isInTurn = false
            try scenario.tasks.retryCleanup(taskID: scenario.taskID)
            await scenario.waitUntil("the cleanup finishes") { scenario.record?.cleanup?.finishedAt != nil }
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] == nil)
        }
    }

    // MARK: - Scenario

    @MainActor
    final class Scenario {
        let repo: String
        let worktree: String
        let head: String
        let mergedMarker: String
        let pullRequest = WorkspacePullRequestLink(annotationURL: "https://github.com/test/repo/pull/7")!
        let store: AppStore
        let sessionRuntimeStore: SessionRuntimeStore
        let taskSpaceID: UUID
        let taskPanelID: UUID
        let windowID: UUID
        var taskID = UUID()
        var tasks: TaskCoordinator!
        var merges: WorkspaceMergeCoordinator!
        var board: TaskBoardStore!
        var pullRequests: PullRequestStateCache!
        let fakeSessions = TaskStartWorkTests.FakeSessions()
        var notifications: [String] = []
        var failureAlerts: [String] = []
        let git: (_ arguments: [String], _ directory: String) throws -> String

        init(
            repo: String, worktree: String, head: String, mergedMarker: String, store: AppStore,
            sessionRuntimeStore: SessionRuntimeStore, taskSpaceID: UUID, taskPanelID: UUID, windowID: UUID,
            git: @escaping (_ arguments: [String], _ directory: String) throws -> String
        ) {
            self.repo = repo
            self.worktree = worktree
            self.head = head
            self.mergedMarker = mergedMarker
            self.store = store
            self.sessionRuntimeStore = sessionRuntimeStore
            self.taskSpaceID = taskSpaceID
            self.taskPanelID = taskPanelID
            self.windowID = windowID
            self.git = git
        }

        var record: TaskRecord? { tasks.records.record(id: taskID) }
        var boardItem: TaskBoardItem? { board.items().first { $0.taskID == taskID } }

        func git(_ arguments: [String], in directory: String) throws -> String { try git(arguments, directory) }

        /// The task space's agent, as the merge owner sees it.
        func reportAgent(_ kind: SessionStatusKind) {
            if sessionRuntimeStore.sessionRegistry.sessionsByID["agent"] == nil {
                sessionRuntimeStore.startSession(
                    sessionID: "agent", agent: .claude, panelID: taskPanelID, windowID: windowID, workspaceID: taskSpaceID,
                    codexStatusTrackingSource: .externallyReported, cwd: worktree, repoRoot: worktree, at: Date()
                )
            }
            sessionRuntimeStore.updateStatus(sessionID: "agent", status: SessionStatus(kind: kind, summary: kind.rawValue), at: Date())
        }

        func waitUntil(_ description: String, timeout: Duration = .seconds(30), _ condition: () -> Bool) async {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while condition() == false {
                guard ContinuousClock.now < deadline else {
                    Issue.record("Timed out waiting until \(description); alerts: \(failureAlerts); notes: \(notifications)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// A task whose worktree holds a pushed branch with one commit on top
    /// of main, its task space open with the pull request linked, wired the
    /// way the app wires it.
    private func withScenario(checksPending: Bool = false, _ body: (Scenario) async throws -> Void) async throws {
        let root = URL(filePath: NSTemporaryDirectory())
            .appendingPathComponent("toastty-task-merge-e2e-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let origin = root.appendingPathComponent("origin.git").path
        let repo = root.appendingPathComponent("repo").path
        let worktree = root.appendingPathComponent("repo-fix").path
        try git(["init", "--bare", "-q", "-b", "main", origin], in: root.path)
        try git(["clone", "-q", origin, repo], in: root.path)
        try git(["config", "user.name", "Merge Test"], in: repo)
        try git(["config", "user.email", "merge@example.invalid"], in: repo)
        _ = try commit("base", in: repo)
        try git(["push", "-q", "origin", "main"], in: repo)
        try git(["worktree", "add", "-q", "-b", "fix/task-7", worktree], in: repo)
        _ = try commit("first", in: worktree)
        let head = try commit("second", in: worktree)
        try git(["push", "-q", "-u", "origin", "fix/task-7"], in: worktree)

        let fakeBin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        let checks: [[String: Any]] = checksPending
            ? [["name": "CI gate", "status": "IN_PROGRESS", "conclusion": NSNull()]]
            : [["name": "CI gate", "status": "COMPLETED", "conclusion": "SUCCESS"]]
        let pullRequest: [String: Any] = [
            "number": 7, "title": "task", "state": "OPEN", "isDraft": false, "headRefName": "fix/task-7",
            "headRefOid": head, "baseRefName": "main", "isCrossRepository": false,
            "mergeable": "MERGEABLE", "mergeStateStatus": checksPending ? "BLOCKED" : "CLEAN",
            "url": "https://github.com/test/repo/pull/7", "statusCheckRollup": checks, "body": "",
        ]
        var merged = pullRequest
        merged["state"] = "MERGED"
        merged["mergeCommit"] = ["oid": head]
        func json(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let mergedMarker = root.appendingPathComponent("pr-7-merged").path
        let fakeGh = fakeBin.appendingPathComponent("gh")
        try """
        #!/bin/sh
        case "$1 $2" in
          "repo view") echo '{"nameWithOwner":"test/repo","defaultBranchRef":{"name":"main"},"mergeCommitAllowed":true}' ;;
          "pr view") if [ -e '\(mergedMarker)' ]; then echo '\(try json(merged))'; else echo '\(try json(pullRequest))'; fi ;;
          "api --method") [ "$3 $4 $6 $8" = 'PUT repos/test/repo/pulls/7/merge sha=\(head) merge_method=merge' ] && touch '\(mergedMarker)' ;;
          *) echo "unexpected gh call: $*" >&2; exit 1 ;;
        esac
        """.write(to: fakeGh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGh.path)

        let socketPath = temporarySocketPath()
        // Status changes send no desktop notification: without notification
        // access, as on CI, the access alert would block the test host.
        let (server, store, _, parentWorkspaceID, sessionRuntimeStore) = try makeServer(
            socketPath: socketPath,
            sessionRuntimeStore: SessionRuntimeStore(sendSessionStatusNotification: { _, _, _, _, _ in })
        )
        defer { withExtendedLifetime(server) {} }
        try waitForSocket(at: socketPath)

        let windowID = try #require(store.state.windows.first?.id)
        let existing = Set(store.state.workspacesByID.keys)
        store.send(.createWorkspace(windowID: windowID, title: "fix-task-7", activate: false))
        let taskSpaceID = try #require(Set(store.state.workspacesByID.keys).subtracting(existing).first)
        store.send(.setWorkspaceParent(workspaceID: taskSpaceID, parentWorkspaceID: parentWorkspaceID, spawningSessionID: nil))
        let taskPanelID = try #require(store.state.workspacesByID[taskSpaceID]?.focusedPanelID)
        store.send(.updateTerminalPanelMetadata(panelID: taskPanelID, title: nil, cwd: worktree))
        store.send(.setWorkspaceAnnotation(
            workspaceID: taskSpaceID,
            key: "github-pr",
            annotation: try #require(WorkspaceAnnotation.validated(text: "PR #7", url: "https://github.com/test/repo/pull/7"))
        ))

        let scenario = Scenario(
            repo: repo, worktree: worktree, head: head, mergedMarker: mergedMarker, store: store,
            sessionRuntimeStore: sessionRuntimeStore, taskSpaceID: taskSpaceID, taskPanelID: taskPanelID, windowID: windowID,
            git: { [self] arguments, directory in try git(arguments, in: directory) }
        )
        let cliPath = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/toastty").path
        let runner = WorkspaceMergeLiveCommandRunner(
            socketPath: socketPath,
            cliExecutablePath: cliPath,
            pathOverride: "\(fakeBin.path):/usr/bin:/bin"
        )
        scenario.merges = WorkspaceMergeCoordinator(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            runner: runner,
            userDefaults: nil,
            pollInterval: .milliseconds(200),
            notify: { [scenario] title, body in scenario.notifications.append("\(title): \(body)") },
            presentFailure: { [scenario] title, message in scenario.failureAlerts.append("\(title): \(message)") }
        )
        scenario.tasks = TaskCoordinator(
            records: TaskRecordStore.inMemory(),
            store: store,
            launcher: nil,
            configLoader: { TasksConfig() },
            attachmentsDirectoryURL: root.appendingPathComponent("attachments"),
            hasActiveSession: { _ in false },
            grantScope: { _, _ in }
        )
        scenario.tasks.sessions = scenario.fakeSessions
        scenario.tasks.merges = scenario.merges
        scenario.merges.cleanupObserver = { [weak tasks = scenario.tasks] workspaceID, event in
            tasks?.mergeCleanupEvent(workspaceID: workspaceID, event: event)
        }
        sessionRuntimeStore.taskCoordinator = scenario.tasks
        scenario.pullRequests = PullRequestStateCache(runner: runner, directory: repo)
        scenario.merges.pullRequestStateCache = scenario.pullRequests
        scenario.board = TaskBoardStore(
            coordinator: scenario.tasks,
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            pullRequests: scenario.pullRequests,
            refreshInterval: nil,
            releaseCheckInterval: nil
        )
        scenario.tasks.board = scenario.board

        // The task Toastty made for this task space.
        let record = TaskRecord(
            createdAt: Date(),
            text: "Fix task 7",
            title: "Fix task 7",
            slug: "fix-task-7",
            source: .cli,
            workspaceID: parentWorkspaceID,
            projectRoot: repo,
            setup: .started,
            startWork: TaskStartWork(branchPrefix: "fix", requestedAt: Date(), state: .finished),
            operation: TaskOperation(
                taskSpace: TaskOperation.TaskSpace(workspaceID: taskSpaceID, panelID: taskPanelID),
                worktree: TaskOperation.Worktree(path: worktree, branch: "fix/task-7", checkoutRoot: repo, added: true)
            )
        )
        try scenario.tasks.records.insert(record)
        scenario.taskID = record.id
        store.send(.setWorkspaceTaskID(workspaceID: taskSpaceID, taskID: record.id))

        #expect(FileManager.default.isExecutableFile(atPath: cliPath))
        try await body(scenario)
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(filePath: directory)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TaskError("git \(arguments.joined(separator: " ")) failed")
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit(_ message: String, in directory: String) throws -> String {
        try "\(message)\n".write(toFile: "\(directory)/file.txt", atomically: true, encoding: .utf8)
        try git(["add", "file.txt"], in: directory)
        try git(["commit", "-q", "-m", message], in: directory)
        return try git(["rev-parse", "HEAD"], in: directory)
    }
}
