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
    @Test(arguments: ["main", "feat/integration"])
    func taskMergeWaitsForTheAgentsTurnThenCleansUp(baseBranch: String) async throws {
        try await withScenario(baseBranch: baseBranch) { scenario in
            let baseHead = try scenario.git(["rev-parse", baseBranch], in: scenario.repo)
            let merged = try scenario.watch(.merged)
            let done = try scenario.watch(.done)
            // The merge skill calls task merge in the middle of its turn.
            scenario.reportAgent(.working)
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: scenario.head, caller: .unmanaged)
            #expect(scenario.fired(merged) == false)

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
            #expect(scenario.fired(merged))
            #expect(scenario.fired(done))
            // Cleanup removes the child branch, but keeps the target branch.
            #expect(try scenario.git(["rev-parse", baseBranch], in: scenario.repo) == baseHead)
            #expect(try scenario.git(["ls-remote", "--heads", "origin", baseBranch], in: scenario.repo).hasPrefix(baseHead))
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
    func aMergeInAProjectThatReleasesCleansUpThenWaitsToShip() async throws {
        try await withScenario { scenario in
            scenario.config.workspaces = [TasksConfig.Workspace(path: scenario.repo, releaseTags: "v*")]
            scenario.board.reloadConfig()
            let toShip = try scenario.watch(.toShip)
            let done = try scenario.watch(.done)
            scenario.reportAgent(.ready)
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: nil, caller: .unmanaged)
            await scenario.waitUntil("the cleanup finishes") { scenario.record?.cleanup?.finishedAt != nil }
            // The merge closes the task space and removes the worktree, as in
            // a project without release tags; the task waits in To ship.
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] == nil)
            #expect(FileManager.default.fileExists(atPath: scenario.worktree) == false)
            #expect(scenario.boardItem?.stage == .toShip)
            #expect(scenario.failureAlerts.isEmpty, "\(scenario.failureAlerts)")
            #expect(scenario.fired(toShip))
            #expect(scenario.fired(done) == false)

            // A release tag on the remote ships the task.
            try scenario.git(["tag", "v1.0", scenario.head], in: scenario.repo)
            try scenario.git(["push", "-q", "origin", "v1.0"], in: scenario.repo)
            await scenario.tasks.checkReleases()
            #expect(scenario.record?.releaseTag == "v1.0")
            #expect(scenario.boardItem?.stage == .done)
            #expect(scenario.fired(done))
        }
    }

    @Test
    func aMergeOnGitHubInAProjectThatReleasesCleansUp() async throws {
        try await withScenario { scenario in
            scenario.config.workspaces = [TasksConfig.Workspace(path: scenario.repo, releaseTags: "v*")]
            scenario.board.reloadConfig()
            scenario.reportAgent(.ready)
            FileManager.default.createFile(atPath: scenario.mergedMarker, contents: nil)
            await scenario.pullRequests.refresh(scenario.pullRequest).value

            #expect(scenario.record?.mergedAt != nil)
            await scenario.waitUntil("the cleanup finishes") { scenario.record?.cleanup?.finishedAt != nil }
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] == nil)
            #expect(FileManager.default.fileExists(atPath: scenario.worktree) == false)
            #expect(scenario.boardItem?.stage == .toShip)
        }
    }

    @Test(arguments: [false, true])
    func anAdoptedTaskClosesOnlyAfterItsWorktreeIsGone(worktreeAlreadyRemoved: Bool) async throws {
        try await withScenario(adopted: true) { scenario in
            scenario.config.workspaces = [TasksConfig.Workspace(path: scenario.repo, releaseTags: "v*")]
            scenario.board.reloadConfig()
            #expect(scenario.record?.source == .adopted)
            #expect(scenario.record?.worktree == nil)
            if worktreeAlreadyRemoved {
                try scenario.git(["worktree", "remove", scenario.worktree], in: scenario.repo)
                // A restored pane falls back outside the repository when
                // its saved working directory has gone away.
                scenario.store.send(.updateTerminalPanelMetadata(
                    panelID: scenario.taskPanelID, title: nil,
                    cwd: (scenario.repo as NSString).deletingLastPathComponent
                ))
            }
            FileManager.default.createFile(atPath: scenario.mergedMarker, contents: nil)
            await scenario.pullRequests.refresh(scenario.pullRequest).value

            if worktreeAlreadyRemoved == false {
                await scenario.waitUntil("the adopted task's checkout is kept for review") {
                    if case .failed? = scenario.merges.request(workspaceID: scenario.taskSpaceID)?.phase { return true }
                    return false
                }
                #expect(FileManager.default.fileExists(atPath: scenario.worktree))
                #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] != nil)
                #expect(scenario.boardItem?.stage.group == .needsYou)
                // A retry must preserve the same restriction.
                try scenario.tasks.retryCleanup(taskID: scenario.taskID)
                await scenario.waitUntil("the retry also keeps the checkout") {
                    if case .failed? = scenario.merges.request(workspaceID: scenario.taskSpaceID)?.phase { return true }
                    return false
                }
                #expect(FileManager.default.fileExists(atPath: scenario.worktree))
                #expect(scenario.merges.request(workspaceID: scenario.taskSpaceID)?.requiresAbsentWorktree == true)
                // New metadata must not turn a saved workspace-only cleanup
                // into permission to remove a checkout on retry.
                try scenario.tasks.records.save(id: scenario.taskID) {
                    $0.operation.worktree = TaskOperation.Worktree(
                        path: scenario.worktree, branch: "fix/task-7", checkoutRoot: scenario.repo, added: true
                    )
                }
                try scenario.tasks.retryCleanup(taskID: scenario.taskID)
                await scenario.waitUntil("the saved cleanup keeps its absent-only restriction") {
                    if case .failed? = scenario.merges.request(workspaceID: scenario.taskSpaceID)?.phase { return true }
                    return false
                }
                #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] != nil)
                #expect(FileManager.default.fileExists(atPath: scenario.worktree))
                #expect(try scenario.git(["rev-parse", "fix/task-7"], in: scenario.repo) == scenario.head)
                return
            }
            await scenario.waitUntil("the adopted task's cleanup finishes") { scenario.record?.cleanup?.finishedAt != nil }
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] == nil)
            #expect(FileManager.default.fileExists(atPath: scenario.worktree) == false)
            #expect(scenario.boardItem?.stage == .toShip)
            #expect(scenario.failureAlerts.isEmpty, "\(scenario.failureAlerts)")
            if worktreeAlreadyRemoved {
                // Workspace-only cleanup does not delete branch references.
                #expect(try scenario.git(["rev-parse", "fix/task-7"], in: scenario.repo) == scenario.head)
            }
        }
    }

    @Test
    func aNewTaskWithoutAWorktreeIsNotAutomaticallyClosed() async throws {
        try await withScenario { scenario in
            try scenario.tasks.records.save(id: scenario.taskID) { $0.operation.worktree = nil }
            FileManager.default.createFile(atPath: scenario.mergedMarker, contents: nil)
            await scenario.pullRequests.refresh(scenario.pullRequest).value

            #expect(scenario.record?.mergedAt != nil)
            #expect(scenario.record?.cleanup == nil)
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] != nil)
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
    func retargetingAWaitingFeatureMergeRequiresAcceptanceAgain() async throws {
        try await withScenario(checksPending: true, baseBranch: "feat/integration") { scenario in
            let mainHead = try scenario.git(["rev-parse", "main"], in: scenario.repo)
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: scenario.head, caller: .unmanaged)
            await scenario.waitUntil("the merge waits") {
                scenario.merges.request(workspaceID: scenario.taskSpaceID)?.acceptedBase == "feat/integration"
            }
            FileManager.default.createFile(atPath: scenario.mergedMarker + "-retargeted", contents: nil)
            await scenario.waitUntil("the retargeted merge stops") {
                scenario.notifications.contains { $0.contains("target branch changed") }
            }
            #expect(scenario.merges.request(workspaceID: scenario.taskSpaceID) == nil)
            #expect(scenario.record?.mergedAt == nil)
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] != nil)
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID]?.doneAt == nil)
            #expect(FileManager.default.fileExists(atPath: scenario.worktree))
            #expect(FileManager.default.fileExists(atPath: scenario.mergedMarker) == false)
            #expect(try scenario.git(["rev-parse", "main"], in: scenario.repo) == mainHead)
            // A new acceptance uses the new target and can finish normally.
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: scenario.head, caller: .unmanaged)
            await scenario.waitUntil("the accepted merge and cleanup finish") {
                scenario.record?.cleanup?.finishedAt != nil
            }
            #expect(scenario.record?.mergedAt != nil)
            #expect(FileManager.default.fileExists(atPath: scenario.mergedMarker))
            #expect(FileManager.default.fileExists(atPath: scenario.worktree) == false)
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
            // A stopped cleanup still lets a merged watch fire.
            #expect(scenario.fired(try scenario.watch(.merged)))
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
    func cleanupRecoversARecordedTaskWhoseWorktreeIsAlreadyGone() async throws {
        try await withScenario { scenario in
            let primaryHead = try scenario.git(["rev-parse", "HEAD"], in: scenario.repo)
            try scenario.git(["worktree", "remove", scenario.worktree], in: scenario.repo)
            // Restoring a terminal whose directory disappeared starts it in
            // the existing parent directory, outside any repository.
            scenario.store.send(.updateTerminalPanelMetadata(
                panelID: scenario.taskPanelID, title: nil,
                cwd: URL(filePath: scenario.repo).deletingLastPathComponent().path
            ))
            FileManager.default.createFile(atPath: scenario.mergedMarker, contents: nil)
            await scenario.pullRequests.refresh(scenario.pullRequest).value

            await scenario.waitUntil("cleanup recovers the missing worktree") { scenario.record?.cleanup?.finishedAt != nil }
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] == nil)
            #expect(scenario.record?.cleanup?.problem == nil)
            #expect(scenario.boardItem?.stage == .done)
            #expect(try scenario.git(["branch", "--list", "fix/task-7"], in: scenario.repo).isEmpty)
            #expect(try scenario.git(["ls-remote", "--heads", "origin", "fix/task-7"], in: scenario.repo).isEmpty)
            #expect(try scenario.git(["rev-parse", "HEAD"], in: scenario.repo) == primaryHead)
            #expect(try scenario.git(["status", "--porcelain"], in: scenario.repo).isEmpty)
            #expect(try scenario.git(["worktree", "list", "--porcelain"], in: scenario.repo).contains(scenario.repo))
        }
    }

    @Test(arguments: [false, true])
    func stoppedCleanupCanRetryAfterExternalRemovalOfItsWorktreeAndBranches(removeBranches: Bool) async throws {
        try await withScenario { scenario in
            let notes = URL(filePath: scenario.worktree).appending(path: "notes.txt")
            try Data("draft".utf8).write(to: notes)
            FileManager.default.createFile(atPath: scenario.mergedMarker, contents: nil)
            await scenario.pullRequests.refresh(scenario.pullRequest).value
            await scenario.waitUntil("local work stops cleanup") {
                if case .failed? = scenario.merges.request(workspaceID: scenario.taskSpaceID)?.phase { return true }
                return false
            }
            try FileManager.default.removeItem(at: notes)
            try scenario.git(["worktree", "remove", scenario.worktree], in: scenario.repo)
            if removeBranches {
                try scenario.git(["branch", "-D", "fix/task-7"], in: scenario.repo)
                try scenario.git(["push", "-q", "origin", "--delete", "fix/task-7"], in: scenario.repo)
            }
            scenario.store.send(.updateTerminalPanelMetadata(
                panelID: scenario.taskPanelID, title: nil,
                cwd: URL(filePath: scenario.repo).deletingLastPathComponent().path
            ))

            // The stopped request still names the now-missing worktree as
            // its repository. Retry must resolve the recorded checkout.
            #expect(scenario.merges.request(workspaceID: scenario.taskSpaceID)?.repoPath == scenario.worktree)
            try scenario.tasks.retryCleanup(taskID: scenario.taskID)
            await scenario.waitUntil("the old cleanup request recovers") { scenario.record?.cleanup?.finishedAt != nil }
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] == nil)
            #expect(scenario.record?.cleanup?.problem == nil)
            #expect(scenario.boardItem?.stage == .done)
            #expect(try scenario.git(["ls-remote", "--heads", "origin", "fix/task-7"], in: scenario.repo).isEmpty)
        }
    }

    @Test
    func cleanupKeepsARecreatedDirectoryAndItsTaskSpace() async throws {
        try await withScenario { scenario in
            try scenario.git(["worktree", "remove", scenario.worktree], in: scenario.repo)
            try FileManager.default.createDirectory(atPath: scenario.worktree, withIntermediateDirectories: true)
            let notes = URL(filePath: scenario.worktree).appending(path: "notes.txt")
            try Data("new work".utf8).write(to: notes)
            FileManager.default.createFile(atPath: scenario.mergedMarker, contents: nil)
            await scenario.pullRequests.refresh(scenario.pullRequest).value
            await scenario.waitUntil("cleanup refuses the recreated directory") {
                if case .failed? = scenario.merges.request(workspaceID: scenario.taskSpaceID)?.phase { return true }
                return false
            }
            guard case .needsYou(.cleanupStopped(let reason))? = scenario.boardItem?.stage else {
                Issue.record("Expected cleanup to stop for a recreated directory")
                return
            }
            #expect(reason.contains("path exists"))
            #expect(try Data(contentsOf: notes) == Data("new work".utf8))
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] != nil)
            #expect(try scenario.git(["ls-remote", "--heads", "origin", "fix/task-7"], in: scenario.repo).isEmpty == false)
        }
    }

    @Test
    func aMergeOnGitHubWhileTheAgentWorksWaitsForTheUser() async throws {
        try await withScenario { scenario in
            scenario.fakeSessions.sessions["agent"] = TaskSessionInfo(
                sessionID: "agent", agent: .claude, panelID: scenario.taskPanelID, workspaceID: scenario.taskSpaceID,
                cwd: scenario.worktree, isActive: true, isInTurn: true
            )
            #expect(scenario.headerPresentation?.title == "Merge PR #7")
            FileManager.default.createFile(atPath: scenario.mergedMarker, contents: nil)
            await scenario.pullRequests.refresh(scenario.pullRequest).value

            #expect(scenario.record?.cleanup?.problem?.contains("while the agent was working") == true)
            #expect(scenario.merges.request(workspaceID: scenario.taskSpaceID) == nil)
            guard case .needsYou(.cleanupStopped)? = scenario.boardItem?.stage else {
                Issue.record("expected Merged · clean up?, got \(String(describing: scenario.boardItem?.stage))")
                return
            }
            // The task space stays open, and its header shows the merge as
            // done instead of offering Merge for the merged pull request.
            #expect(scenario.headerPresentation?.title == "Done · PR #7")

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
        /// What tasks.toml says; tests may change it.
        var config = TasksConfig()
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

        /// A `--wait` watch on the task, as a caller outside Toastty makes.
        func watch(_ condition: TaskWatchCondition) throws -> UUID {
            try tasks.addWatch(targetTaskID: taskID, condition: condition, notifyTaskID: nil).id
        }

        func fired(_ watchID: UUID) -> Bool {
            tasks.evaluateWatches()
            return tasks.waitWatches[watchID]?.firedAt != nil
        }
        var boardItem: TaskBoardItem? { board.items().first { $0.taskID == taskID } }
        /// The task space's merge control, from what the top bar reads.
        var headerPresentation: WorkspaceMergePresentation? {
            guard let workspace = store.state.workspacesByID[taskSpaceID] else { return nil }
            return WorkspaceMergePresentation.make(
                workspace: workspace,
                request: merges.request(workspaceID: taskSpaceID),
                isCheckingMerge: sessionRuntimeStore.isCheckingTaskMerge(workspaceID: taskSpaceID),
                isTaskMerged: sessionRuntimeStore.isTaskMerged(workspaceID: taskSpaceID),
                pullRequestState: pullRequests.state(for: pullRequest)
            )
        }

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
    /// of its base branch, its task space open with the pull request linked, wired the
    /// way the app wires it.
    private func withScenario(
        checksPending: Bool = false, baseBranch: String = "main", adopted: Bool = false,
        _ body: (Scenario) async throws -> Void
    ) async throws {
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
        if baseBranch != "main" {
            try git(["checkout", "-q", "-b", baseBranch], in: repo)
            _ = try commit("feature", in: repo)
            try git(["push", "-q", "origin", baseBranch], in: repo)
        }
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
            "headRefOid": head, "baseRefName": baseBranch, "isCrossRepository": false,
            "mergeable": "MERGEABLE", "mergeStateStatus": checksPending ? "BLOCKED" : "CLEAN",
            "url": "https://github.com/test/repo/pull/7", "statusCheckRollup": checks, "body": "",
        ]
        var merged = pullRequest
        merged["state"] = "MERGED"
        merged["mergeCommit"] = ["oid": head]
        var retargeted = pullRequest
        retargeted["baseRefName"] = "main"
        retargeted["mergeStateStatus"] = "CLEAN"
        retargeted["statusCheckRollup"] = [["name": "CI gate", "status": "COMPLETED", "conclusion": "SUCCESS"]]
        func json(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let mergedMarker = root.appendingPathComponent("pr-7-merged").path
        let fakeGh = fakeBin.appendingPathComponent("gh")
        try """
        #!/bin/sh
        case "$1 $2" in
          "repo view") echo '{"nameWithOwner":"test/repo","defaultBranchRef":{"name":"main"},"mergeCommitAllowed":true}' ;;
          "pr view") if [ -e '\(mergedMarker)' ]; then echo '\(try json(merged))'; elif [ -e '\(mergedMarker)-retargeted' ]; then echo '\(try json(retargeted))'; else echo '\(try json(pullRequest))'; fi ;;
          "pr list") echo '[]' ;;
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
        store.send(.setWorkspaceRootDirectory(workspaceID: parentWorkspaceID, rootDirectory: repo))
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
            configLoader: { [unowned scenario] in scenario.config },
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
        if adopted {
            scenario.taskID = try scenario.tasks.adopt(workspaceID: taskSpaceID).id
        } else {
            try scenario.tasks.records.insert(record)
            scenario.taskID = record.id
            store.send(.setWorkspaceTaskID(workspaceID: taskSpaceID, taskID: record.id))
        }

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
