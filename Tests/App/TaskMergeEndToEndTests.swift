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
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: scenario.head, caller: scenario.agentCaller)
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
            #expect(scenario.record?.mergeFailure == nil, "\(scenario.notifications)")
            // No release_tags: a merged task is done.
            #expect(scenario.boardItem?.stage == .done)
            #expect(scenario.fired(merged))
            #expect(scenario.fired(done))
            // Cleanup removes the child branch, but keeps the target branch.
            #expect(try scenario.git(["rev-parse", baseBranch], in: scenario.repo) == baseHead)
            #expect(try scenario.git(["ls-remote", "--heads", "origin", baseBranch], in: scenario.repo).hasPrefix(baseHead))
        }
    }

    /// After the merge the task is Done, but its task space stays open for
    /// the hold, so the user can still look at it; then the usual cleanup
    /// runs. Both a merge Toastty runs and one seen on GitHub are held.
    @Test(arguments: [false, true])
    func aMergedTaskSpaceStaysOpenUntilItsCleanupTime(mergedOnGitHub: Bool) async throws {
        try await withScenario(cleanupHold: 3) { scenario in
            scenario.reportAgent(.ready)
            if mergedOnGitHub {
                FileManager.default.createFile(atPath: scenario.mergedMarker, contents: nil)
                await scenario.pullRequests.refresh(scenario.pullRequest).value
            } else {
                try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: scenario.head, caller: scenario.agentCaller)
            }
            await scenario.waitUntil("the cleanup is held") { scenario.isHeld }
            let item = try #require(scenario.boardItem)
            #expect(scenario.record?.mergedAt != nil)
            #expect(item.stage == .done)
            #expect(item.merge == nil)
            #expect(TaskBoardPresentation.detailActions(item) == [.closeTaskSpace])
            #expect(TaskBoardPresentation.statusLine(item) == "Done · task space closes in 1 h")
            #expect(scenario.headerPresentation == .done(pullRequest: "PR #7"))
            // Several checks pass while the hold lasts; nothing closes.
            try await Task.sleep(for: .seconds(1))
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] != nil)
            #expect(FileManager.default.fileExists(atPath: scenario.worktree))

            await scenario.waitUntil("the held cleanup finishes") { scenario.record?.cleanup?.finishedAt != nil }
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] == nil)
            #expect(FileManager.default.fileExists(atPath: scenario.worktree) == false)
            #expect(try scenario.remoteBranch().isEmpty)
            #expect(scenario.boardItem?.stage == .done)
            #expect(scenario.boardItem?.cleanupHeldUntil == nil)
            #expect(scenario.record?.mergeFailure == nil, "\(scenario.notifications)")
        }
    }

    /// While the task space waits for its cleanup, the task's agent reads
    /// when it closes, and a caller reads what an archive would do instead,
    /// both through the CLI and without changing anything.
    @Test
    func aHeldTaskSpaceReportsItsCloseTimeAndAnArchivePreview() async throws {
        try await withScenario(cleanupHold: 3_600) { scenario in
            scenario.reportAgent(.ready)
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: scenario.head, caller: scenario.agentCaller)
            await scenario.waitUntil("the cleanup is held") { scenario.isHeld }
            let taskSocketPath = temporarySocketPath()
            let taskServer = try makeTaskServer(scenario, socketPath: taskSocketPath)
            defer { withExtendedLifetime(taskServer) {} }
            try waitForSocket(at: taskSocketPath)
            scenario.socketPath = taskSocketPath
            let taskID = scenario.taskID.uuidString

            let get = try await scenario.cli(["--json", "task", "get", taskID])
            #expect(get.status == 0, "\(get.output)")
            let task = try #require(
                (try JSONSerialization.jsonObject(with: Data(get.output.utf8)) as? [String: Any])?["result"] as? [String: Any]
            )
            let closesAt = try #require((task["cleanup"] as? [String: Any])?["taskSpaceClosesAt"] as? String, "\(get.output)")
            let closes = try #require(ISO8601DateFormatter().date(from: closesAt))
            #expect(abs(closes.timeIntervalSinceNow - 3_600) < 120, "\(closesAt)")

            let preview = try await scenario.cli(["--json", "task", "archive", taskID, "--dry-run"])
            #expect(preview.status == 0, "\(preview.output)")
            let result = try #require(
                (try JSONSerialization.jsonObject(with: Data(preview.output.utf8)) as? [String: Any])?["result"] as? [String: Any]
            )
            #expect(result["dryRun"] as? Bool == true)
            #expect(result["refusal"] is NSNull, "\(preview.output)")
            let summary = try #require(result["summary"] as? [String])
            #expect(summary.contains("Removes the worktree."), "\(summary)")
            #expect(summary.contains("Deletes the local branch fix/task-7. It stays on the remote."), "\(summary)")
            #expect(summary.contains("test/repo#7 merged, but the task shows as Archived, not Done."), "\(summary)")
            // Nothing changed.
            #expect(scenario.record?.archivedAt == nil)
            #expect(scenario.isHeld)
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] != nil)
            #expect(FileManager.default.fileExists(atPath: scenario.worktree))
        }
    }

    @Test
    func aHeldCleanupWaitsWhileAWindowShowsTheTaskSpace() async throws {
        try await withScenario(cleanupHold: 0.5) { scenario in
            scenario.reportAgent(.ready)
            scenario.store.send(.selectWorkspace(windowID: scenario.windowID, workspaceID: scenario.taskSpaceID))
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: scenario.head, caller: scenario.agentCaller)
            await scenario.waitUntil("the cleanup is held") { scenario.isHeld }
            try await Task.sleep(for: .seconds(1.5))
            #expect(scenario.isHeld)
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] != nil)

            scenario.store.send(.selectWorkspace(windowID: scenario.windowID, workspaceID: scenario.parentWorkspaceID))
            await scenario.waitUntil("the cleanup runs once the task space is not shown") {
                scenario.record?.cleanup?.finishedAt != nil
            }
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] == nil)
            #expect(FileManager.default.fileExists(atPath: scenario.worktree) == false)
        }
    }

    @Test
    func closeTaskSpaceCleansUpAHeldTaskNow() async throws {
        try await withScenario(cleanupHold: 3_600) { scenario in
            scenario.reportAgent(.ready)
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: scenario.head, caller: scenario.agentCaller)
            await scenario.waitUntil("the cleanup is held") { scenario.isHeld }
            #expect(scenario.boardItem.map { TaskBoardPresentation.statusLine($0) } == "Done · task space closes in 1 h")
            try TaskActions.run(.closeTaskSpace, taskID: scenario.taskID, coordinator: scenario.tasks)
            await scenario.waitUntil("the cleanup finishes") { scenario.record?.cleanup?.finishedAt != nil }
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] == nil)
            #expect(FileManager.default.fileExists(atPath: scenario.worktree) == false)
            #expect(try scenario.remoteBranch().isEmpty)
            #expect(scenario.boardItem?.stage == .done)
        }
    }

    /// Closing the task space by hand, as the user does once done with it,
    /// still removes the worktree and the local branch, with an archive's
    /// checks. Work left in the worktree stops that until the user decides.
    @Test(arguments: [false, true])
    func closingAHeldTaskSpaceRemovesTheWorktree(withUncommittedWork: Bool) async throws {
        try await withScenario(cleanupHold: 3_600) { scenario in
            scenario.reportAgent(.ready)
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: scenario.head, caller: scenario.agentCaller)
            await scenario.waitUntil("the cleanup is held") { scenario.isHeld }
            if withUncommittedWork {
                try "draft\n".write(toFile: "\(scenario.worktree)/notes.txt", atomically: true, encoding: .utf8)
            }
            scenario.store.send(.closeWorkspace(workspaceID: scenario.taskSpaceID))
            #expect(scenario.merges.request(workspaceID: scenario.taskSpaceID) == nil)

            if withUncommittedWork {
                await scenario.waitUntil("the cleanup stops on the uncommitted file") {
                    scenario.record?.cleanup?.problem != nil
                }
                #expect(FileManager.default.fileExists(atPath: scenario.worktree))
                #expect(scenario.boardItem?.stage == .needsYou(.cleanupStopped(reason: try #require(scenario.record?.cleanup?.problem))))
                #expect(scenario.boardItem.map { TaskBoardPresentation.statusLine($0) } == "Merged · clean up?")
                // As if Toastty quit while that teardown ran: a relaunch
                // shows it as stopped, so Clean Up can continue it.
                try scenario.tasks.records.save(id: scenario.taskID) { $0.cleanup?.problem = nil }
                scenario.tasks.reconcileAfterLaunch()
                #expect(scenario.record?.cleanup?.problem == "Toastty quit before the cleanup finished. Clean Up continues it.")
                // Once the file is gone, Clean Up finishes the job.
                try FileManager.default.removeItem(atPath: "\(scenario.worktree)/notes.txt")
                try TaskActions.run(.cleanUp, taskID: scenario.taskID, coordinator: scenario.tasks)
            }
            // Closing the task space ends the held request, which marks the
            // merge's cleanup finished at once; the teardown then follows.
            await scenario.waitUntil("the local branch is deleted") {
                (try? scenario.git(["rev-parse", "--verify", "refs/heads/fix/task-7"], in: scenario.repo)) == nil
            }
            await scenario.waitUntil("the teardown is recorded") { scenario.record?.cleanup?.finishedAt != nil }
            #expect(scenario.record?.cleanup?.problem == nil)
            #expect(scenario.record?.cleanup?.stepsDone.contains("removed the worktree") == true)
            #expect(FileManager.default.fileExists(atPath: scenario.worktree) == false)
            #expect(try scenario.remoteBranch().isEmpty == false)
            #expect((try? scenario.git(["rev-parse", "--verify", "refs/heads/fix/task-7"], in: scenario.repo)) == nil)
            #expect(scenario.boardItem?.stage == .done)
        }
    }

    /// Moving the last pane out removes the task space too, but its terminal
    /// lives on in the other workspace, so its worktree stays.
    @Test
    func movingTheLastPaneOutOfAHeldTaskSpaceKeepsItsWorktree() async throws {
        try await withScenario(cleanupHold: 3_600) { scenario in
            scenario.reportAgent(.ready)
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: scenario.head, caller: scenario.agentCaller)
            await scenario.waitUntil("the cleanup is held") { scenario.isHeld }
            scenario.store.send(.movePanelToWorkspace(
                panelID: scenario.taskPanelID, targetWorkspaceID: scenario.parentWorkspaceID, targetSlotID: nil
            ))
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] == nil)
            try await Task.sleep(for: .seconds(1))
            #expect(FileManager.default.fileExists(atPath: scenario.worktree))
            #expect(try scenario.git(["rev-parse", "--verify", "refs/heads/fix/task-7"], in: scenario.repo) == scenario.head)
        }
    }

    /// A held cleanup that Close Task Space started and that stopped tries
    /// again at once on Retry, not after another day.
    @Test
    func retryingAStoppedHeldCleanupDoesNotWaitAgain() async throws {
        try await withScenario(cleanupHold: 3_600) { scenario in
            scenario.reportAgent(.ready)
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: scenario.head, caller: scenario.agentCaller)
            await scenario.waitUntil("the cleanup is held") { scenario.isHeld }
            try "draft\n".write(toFile: "\(scenario.worktree)/notes.txt", atomically: true, encoding: .utf8)
            try TaskActions.run(.closeTaskSpace, taskID: scenario.taskID, coordinator: scenario.tasks)
            await scenario.waitUntil("the cleanup stops on the uncommitted file") {
                if case .failed? = scenario.merges.request(workspaceID: scenario.taskSpaceID)?.phase { return true }
                return false
            }
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] != nil)

            try FileManager.default.removeItem(atPath: "\(scenario.worktree)/notes.txt")
            try TaskActions.run(.cleanUp, taskID: scenario.taskID, coordinator: scenario.tasks)
            // Well inside the hour the hold would have added.
            await scenario.waitUntil("the retried cleanup finishes", timeout: .seconds(20)) {
                scenario.record?.cleanup?.finishedAt != nil
            }
            #expect(scenario.isHeld == false)
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] == nil)
            #expect(FileManager.default.fileExists(atPath: scenario.worktree) == false)
        }
    }

    @Test
    func archivingAHeldTaskClosesItsTaskSpace() async throws {
        try await withScenario(cleanupHold: 3_600) { scenario in
            scenario.reportAgent(.ready)
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: scenario.head, caller: scenario.agentCaller)
            await scenario.waitUntil("the cleanup is held") { scenario.isHeld }
            _ = try await scenario.tasks.archive(taskID: scenario.taskID, options: TaskArchiveOptions())
            await scenario.waitUntil("the archive finishes") {
                scenario.record?.cleanup?.kind == .archive && scenario.record?.cleanup?.finishedAt != nil
            }
            #expect(scenario.record?.cleanup?.problem == nil)
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] == nil)
            #expect(FileManager.default.fileExists(atPath: scenario.worktree) == false)
            #expect(scenario.boardItem?.stage == .archived)
        }
    }

    /// A prompt after the merge starts a turn, which clears the done mark:
    /// the user works on in the task space, so the held cleanup is dropped
    /// and it stays open until the user closes it.
    @Test
    func newWorkInAHeldTaskSpaceCancelsItsCleanup() async throws {
        try await withScenario(cleanupHold: 0.5) { scenario in
            scenario.reportAgent(.ready)
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: scenario.head, caller: scenario.agentCaller)
            await scenario.waitUntil("the cleanup is held") { scenario.isHeld }
            scenario.reportAgent(.working)
            #expect(scenario.merges.request(workspaceID: scenario.taskSpaceID) == nil)
            scenario.reportAgent(.ready)
            try await Task.sleep(for: .seconds(1.5))
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] != nil)
            #expect(FileManager.default.fileExists(atPath: scenario.worktree))
            #expect(scenario.boardItem?.stage == .done)
            #expect(scenario.boardItem.map(TaskBoardPresentation.detailActions) == [])

            scenario.store.send(.closeWorkspace(workspaceID: scenario.taskSpaceID))
            await scenario.waitUntil("closing it deletes the local branch") {
                (try? scenario.git(["rev-parse", "--verify", "refs/heads/fix/task-7"], in: scenario.repo)) == nil
            }
            #expect(FileManager.default.fileExists(atPath: scenario.worktree) == false)
            #expect(scenario.record?.cleanup?.problem == nil)
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
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: nil, caller: scenario.agentCaller)
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
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: nil, caller: scenario.agentCaller)
            await scenario.waitUntil("the cleanup finishes") { scenario.record?.cleanup?.finishedAt != nil }
            // The merge closes the task space and removes the worktree, as in
            // a project without release tags; the task waits in To ship.
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] == nil)
            #expect(FileManager.default.fileExists(atPath: scenario.worktree) == false)
            #expect(scenario.boardItem?.stage == .toShip)
            #expect(scenario.record?.mergeFailure == nil, "\(scenario.notifications)")
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
            #expect(scenario.record?.mergeFailure == nil, "\(scenario.notifications)")
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

    /// A refused `--expect-head` merge, as when a coordinator passes the
    /// wrong commit: nothing merges, no modal alert holds the main thread,
    /// and the task, `task get` and a waiting `task watch` all say why.
    @Test
    func aPushAfterTheChecksIsNotMerged() async throws {
        try await withScenario { scenario in
            let taskID = scenario.taskID.uuidString
            // A coordinator watches for the merge before it starts.
            let merged = try scenario.watch(.merged)
            let checked = try scenario.git(["rev-parse", "HEAD~1"], in: scenario.worktree)
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: checked, caller: scenario.agentCaller)
            await scenario.waitUntil("the merge is refused") { scenario.record?.mergeFailure != nil }
            let reason = try #require(scenario.record?.mergeFailure?.reason)
            #expect(reason.contains("not the checked commit"), "\(reason)")
            #expect(FileManager.default.fileExists(atPath: scenario.mergedMarker) == false)
            #expect(scenario.merges.request(workspaceID: scenario.taskSpaceID) == nil)
            // A desktop notification instead of an alert to dismiss.
            #expect(scenario.notifications == ["Unable to Merge PR #7: \(reason)"])

            // The acceptance ended with the merge; the task offers Merge again
            // and shows why the last one stopped.
            #expect(scenario.record?.mergeRequestedAt == nil)
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID]?.doneAt == nil)
            let item = try #require(scenario.boardItem)
            #expect(item.stage == .needsYou(.review))
            #expect(item.merge == nil)
            #expect(TaskBoardPresentation.statusLine(item) == "⚠ merge stopped")
            #expect(TaskBoardPresentation.stageDescription(item).why == "the last merge stopped: \(reason)")
            #expect(TaskBoardPresentation.detailActions(item).contains(.merge))
            if case .ready? = scenario.headerPresentation {} else {
                Issue.record("The header should offer Merge again: \(String(describing: scenario.headerPresentation))")
            }

            // The watch ends instead of waiting for a merge nobody started.
            #expect(scenario.fired(merged))
            if case .fired(_, let firedReason, let impossible, _)? = scenario.tasks.waitWatches[merged]?.watch.state {
                #expect(impossible)
                #expect(firedReason == "was not merged: \(reason)")
            } else {
                Issue.record("The merged watch did not fire")
            }

            // The automation socket keeps answering, and a CLI caller reads
            // the failure. As in the app, the CLI talks to a server that has
            // the task coordinator.
            let taskSocketPath = temporarySocketPath()
            let taskServer = try makeTaskServer(scenario, socketPath: taskSocketPath)
            defer { withExtendedLifetime(taskServer) {} }
            try waitForSocket(at: taskSocketPath)
            scenario.socketPath = taskSocketPath
            let get = try await scenario.cli(["--json", "task", "get", taskID])
            #expect(get.status == 0, "\(get.output)")
            #expect(get.output.contains("\"mergeFailure\""), "\(get.output)")
            #expect(get.output.contains("not the checked commit"), "\(get.output)")
            let watch = try await scenario.cli(["task", "watch", taskID, "--until", "merged", "--wait", "--timeout", "10"])
            #expect(watch.status != 0)
            #expect(watch.output.contains("was not merged"), "\(watch.output)")

            // Accepting the right commit merges, and clears the failure.
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: scenario.head, caller: scenario.agentCaller)
            #expect(scenario.record?.mergeFailure == nil)
            await scenario.waitUntil("the merge and cleanup finish") { scenario.record?.cleanup?.finishedAt != nil }
            #expect(scenario.record?.mergedAt != nil)
            #expect(FileManager.default.fileExists(atPath: scenario.mergedMarker))
        }
    }

    /// The merge skill's `task merge`, from the task's agent through the CLI,
    /// answers with the script's refusal instead of an acceptance, so the
    /// agent cannot report a merge that will not happen. An untracked cache
    /// file is enough: the script refuses any untracked file.
    @Test
    func taskMergeAnswersWithTheRefusalOfADirtyWorktree() async throws {
        try await withScenario { scenario in
            let taskSocketPath = temporarySocketPath()
            let taskServer = try makeTaskServer(scenario, socketPath: taskSocketPath)
            defer { withExtendedLifetime(taskServer) {} }
            try waitForSocket(at: taskSocketPath)
            scenario.socketPath = taskSocketPath
            // The merge skill runs in the agent's turn.
            scenario.reportAgent(.working)
            let cache = "\(scenario.worktree)/__pycache__"
            try FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: "\(cache)/helper.cpython-314.pyc", contents: Data([0]))

            let refused = try await scenario.cli(["--json", "task", "merge", "--head", scenario.head], sessionID: "agent")
            #expect(refused.status != 0, "\(refused.output)")
            #expect(refused.output.contains("refused to merge"), "\(refused.output)")
            #expect(refused.output.contains("uncommitted changes"), "\(refused.output)")
            #expect(FileManager.default.fileExists(atPath: scenario.mergedMarker) == false)
            #expect(scenario.record?.mergeFailure?.cause == .refused)
            #expect(scenario.merges.request(workspaceID: scenario.taskSpaceID) == nil)

            // An answer that does not come in time is no answer: the call
            // returns while the merge runs, and the refusal lands on the task.
            let unanswered = try await scenario.tasks.mergeAndAwaitAnswer(
                taskID: scenario.taskID, expectedHead: scenario.head, caller: scenario.agentCaller, wait: .zero
            )
            #expect(unanswered.mergeFailure == nil)
            #expect(scenario.boardItem?.merge == .merging)
            await scenario.waitUntil("the merge is refused again") { scenario.record?.mergeFailure != nil }

            // With the cache gone, the same call merges and says so.
            try FileManager.default.removeItem(atPath: cache)
            let accepted = try await scenario.cli(["--json", "task", "merge", "--head", scenario.head], sessionID: "agent")
            #expect(accepted.status == 0, "\(accepted.output)")
            #expect(accepted.output.contains("\"merge\" : \"cleaningUp\""), "\(accepted.output)")
            #expect(scenario.record?.mergeFailure == nil)
            await scenario.waitUntil("GitHub merges it") { FileManager.default.fileExists(atPath: scenario.mergedMarker) }
        }
    }

    @Test(arguments: [false, true])
    func anUnreadChildRemainsReachableWhileItsParentWaitsForTheMerge(agentExited: Bool) async throws {
        try await withScenario(checksPending: true) { scenario in
            let store = scenario.store
            let runtime = scenario.sessionRuntimeStore
            let parentSpaceID = try #require(store.selectedWorkspace?.id)
            let parentPanelID = try #require(store.selectedWorkspace?.focusedPanelID)
            let parent = TaskRecord(
                createdAt: Date(),
                text: "Coordinate the work", title: "Coordinate the work", slug: "coordinate", source: .cli,
                workspaceID: parentSpaceID, projectRoot: scenario.repo, setup: .started,
                operation: TaskOperation(taskSpace: .init(workspaceID: parentSpaceID, panelID: parentPanelID))
            )
            try scenario.tasks.records.insert(parent)
            try scenario.tasks.records.save(id: scenario.taskID) { $0.parentTaskID = parent.id }
            runtime.startSession(
                sessionID: "parent", agent: .claude, panelID: parentPanelID,
                windowID: scenario.windowID, workspaceID: parentSpaceID,
                codexStatusTrackingSource: .externallyReported, cwd: scenario.repo, repoRoot: scenario.repo, at: Date()
            )
            runtime.updateStatus(sessionID: "parent", status: SessionStatus(kind: .working, summary: "Working"), at: Date())
            scenario.reportAgent(.working)
            scenario.reportAgent(.ready)
            if agentExited {
                runtime.stopSession(sessionID: "agent", at: Date())
            }
            #expect(store.state.workspacesByID[scenario.taskSpaceID]?.unreadPanelIDs.contains(scenario.taskPanelID) == true)

            // The parent accepts the child's merge without reading its report.
            try scenario.tasks.merge(
                taskID: scenario.taskID, expectedHead: scenario.head,
                caller: TaskCaller(sessionID: "parent", workspaceID: parentSpaceID)
            )
            await scenario.waitUntil("the child's merge waits for checks") {
                if case .awaitingChecks? = scenario.merges.request(workspaceID: scenario.taskSpaceID)?.phase { return true }
                return false
            }
            #expect(scenario.boardItem?.stage == .running)
            #expect(scenario.boardItem?.merge == .waitingForChecks)
            #expect(store.state.workspacesByID[scenario.taskSpaceID]?.doneAt != nil)
            #expect(store.state.workspacesByID[scenario.taskSpaceID]?.unreadPanelIDs.contains(scenario.taskPanelID) == true)

            #expect(ToasttyCommandMenus.canFocusNextUnreadOrActivePanel(
                store: store, preferredWindowID: scenario.windowID, sessionRuntimeStore: runtime
            ))
            #expect(store.canFocusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: scenario.windowID, sessionRuntimeStore: runtime
            ))
            #expect(store.nextUnreadOrActivePanelTargetFromCommand(
                preferredWindowID: scenario.windowID, sessionRuntimeStore: runtime
            )?.panelID == scenario.taskPanelID)
            #expect(store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: scenario.windowID, sessionRuntimeStore: runtime
            ))
            #expect(store.selectedWorkspace?.id == scenario.taskSpaceID)
            #expect(store.state.workspacesByID[scenario.taskSpaceID]?.unreadPanelIDs.contains(scenario.taskPanelID) == false)
            // Reading the reply must keep the accepted merge alive.
            #expect(store.state.workspacesByID[scenario.taskSpaceID]?.doneAt != nil)
            #expect(scenario.boardItem?.merge == .waitingForChecks)
            #expect(store.focusNextUnreadOrActivePanelFromCommand(
                preferredWindowID: scenario.windowID, sessionRuntimeStore: runtime
            ))
            #expect(store.selectedWorkspace?.id == parentSpaceID)

            try scenario.tasks.cancelMerge(taskID: scenario.taskID)
            #expect(scenario.merges.request(workspaceID: scenario.taskSpaceID) == nil)
        }
    }

    @Test
    func cancelMergeStopsAMergeWaitingForChecks() async throws {
        try await withScenario(checksPending: true) { scenario in
            // `task merge` answers once the merge waits for the checks.
            _ = try await scenario.tasks.mergeAndAwaitAnswer(taskID: scenario.taskID, expectedHead: nil, caller: scenario.agentCaller)
            guard case .awaitingChecks? = scenario.merges.request(workspaceID: scenario.taskSpaceID)?.phase else {
                Issue.record("The merge should wait for checks: \(String(describing: scenario.merges.request(workspaceID: scenario.taskSpaceID)))")
                return
            }
            #expect(scenario.boardItem?.merge == .waitingForChecks)
            #expect(scenario.boardItem?.stage == .running)

            try scenario.tasks.cancelMerge(taskID: scenario.taskID)
            #expect(scenario.merges.request(workspaceID: scenario.taskSpaceID) == nil)
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID]?.doneAt == nil)
            #expect(scenario.record?.mergeRequestedAt == nil)
            #expect(scenario.record?.mergeCancelledAt != nil)
            // The user stopped it, so it is not reported as a merge that stopped.
            #expect(scenario.record?.mergeFailure == nil)
            #expect(scenario.notifications.isEmpty, "\(scenario.notifications)")
            #expect(FileManager.default.fileExists(atPath: scenario.mergedMarker) == false)
        }
    }

    /// Closing the project's workspace leaves its task spaces open as
    /// top-level workspaces. An accepted merge there still waits for the
    /// checks after the agent's turn ends, then merges and cleans up.
    @Test(arguments: [false, true])
    func aMergeWaitingInATopLevelTaskSpaceMergesAfterTheAgentsTurn(closeProjectWhileWaiting: Bool) async throws {
        try await withScenario(checksPending: true) { scenario in
            if closeProjectWhileWaiting == false {
                scenario.closeProjectWorkspace()
            }
            // The merge skill calls task merge in the middle of its turn.
            scenario.reportAgent(.working)
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: scenario.head, caller: scenario.agentCaller)
            await scenario.waitUntil("the merge waits for checks") { scenario.isWaitingForChecks }
            if closeProjectWhileWaiting {
                scenario.closeProjectWorkspace()
            }
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID]?.doneAt != nil)

            // The turn ends. The next state change used to drop the waiting
            // merge; one is made here, since whether the turn's end marks
            // the panel unread depends on what the window shows.
            scenario.reportAgent(.ready)
            #expect(scenario.store.send(.updateTerminalPanelMetadata(
                panelID: scenario.taskPanelID, title: "after the turn", cwd: nil
            )))
            try await Task.sleep(for: .milliseconds(700))
            #expect(scenario.isWaitingForChecks)
            #expect(scenario.boardItem?.merge == .waitingForChecks)
            #expect(scenario.record?.mergeFailure == nil, "\(scenario.notifications)")

            scenario.passChecks()
            await scenario.waitUntil("the merge and cleanup finish") { scenario.record?.cleanup?.finishedAt != nil }
            #expect(FileManager.default.fileExists(atPath: scenario.mergedMarker))
            #expect(scenario.record?.mergedAt != nil)
            #expect(scenario.record?.mergeFailure == nil, "\(scenario.notifications)")
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] == nil)
            #expect(FileManager.default.fileExists(atPath: scenario.worktree) == false)
            #expect(scenario.boardItem?.stage == .done)
        }
    }

    /// A merge that does not wait still cleans up a top-level task space
    /// after the agent's turn ends, also after the cleanup's hold.
    @Test(arguments: [0, 1.0])
    func aMergeInATopLevelTaskSpaceCleansUpAfterTheAgentsTurn(cleanupHold: TimeInterval) async throws {
        try await withScenario(cleanupHold: cleanupHold) { scenario in
            scenario.closeProjectWorkspace()
            // The window shows another workspace, so a held cleanup can run.
            #expect(scenario.store.send(.createWorkspace(windowID: scenario.windowID, title: "other", activate: true)))
            scenario.reportAgent(.working)
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: scenario.head, caller: scenario.agentCaller)
            await scenario.waitUntil("the merge is recorded") { scenario.record?.mergedAt != nil }
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID]?.doneAt != nil)

            scenario.reportAgent(.ready)
            if cleanupHold > 0 {
                await scenario.waitUntil("the cleanup is held") { scenario.isHeld }
                // A state change during the hold keeps it.
                #expect(scenario.store.send(.updateTerminalPanelMetadata(
                    panelID: scenario.taskPanelID, title: "after the merge", cwd: nil
                )))
                #expect(scenario.isHeld)
            }
            await scenario.waitUntil("the cleanup finishes") { scenario.record?.cleanup?.finishedAt != nil }
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] == nil)
            #expect(FileManager.default.fileExists(atPath: scenario.worktree) == false)
            #expect(scenario.record?.cleanup?.problem == nil)
        }
    }

    /// New agent work in the task space after the acceptance, with no new
    /// commit, is not a new version, so the merge keeps waiting and merges
    /// the accepted commit; in a subspace and in a top-level task space.
    /// Such work is, for example, a test run that a parent task asks for.
    @Test(arguments: [false, true])
    func newWorkWithoutACommitKeepsAWaitingMerge(topLevel: Bool) async throws {
        try await withScenario(checksPending: true) { scenario in
            if topLevel {
                scenario.closeProjectWorkspace()
            }
            scenario.reportAgent(.working)
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: scenario.head, caller: scenario.agentCaller)
            await scenario.waitUntil("the merge waits for checks") { scenario.isWaitingForChecks }
            scenario.reportAgent(.ready)

            // The agent starts more work and leaves files uncommitted.
            scenario.reportAgent(.working)
            try Data("test output".utf8).write(to: URL(filePath: scenario.worktree).appending(path: "test-output.log"))
            // Several waiting runs pass.
            try await Task.sleep(for: .milliseconds(700))
            #expect(scenario.isWaitingForChecks)
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID]?.doneAt != nil)
            #expect(scenario.record?.mergeRequestedAt != nil)
            #expect(scenario.record?.mergeFailure == nil, "\(scenario.notifications)")
            #expect(scenario.boardItem?.merge == .waitingForChecks)

            scenario.passChecks()
            await scenario.waitUntil("the accepted commit merges") { scenario.record?.mergedAt != nil }
            #expect(FileManager.default.fileExists(atPath: scenario.mergedMarker))
            #expect(scenario.record?.mergeFailure == nil, "\(scenario.notifications)")
            #expect(scenario.notifications.contains { $0.contains("not merged") } == false, "\(scenario.notifications)")
        }
    }

    /// A commit in the worktree after the acceptance is a new version, also
    /// before it is pushed: the waiting merge stops, the task says why and
    /// offers Merge again, and passing checks merge nothing.
    @Test
    func aCommitInTheWorktreeStopsAWaitingMerge() async throws {
        try await withScenario(checksPending: true) { scenario in
            scenario.reportAgent(.working)
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: scenario.head, caller: scenario.agentCaller)
            await scenario.waitUntil("the merge waits for checks") { scenario.isWaitingForChecks }
            scenario.reportAgent(.ready)

            // The user asks for more work, and the agent commits it.
            scenario.reportAgent(.working)
            let newHead = try commit("third", in: scenario.worktree)
            await scenario.waitUntil("the waiting merge stops") { scenario.record?.mergeFailure != nil }
            let failure = try #require(scenario.record?.mergeFailure)
            #expect(failure.cause == .refused)
            #expect(failure.reason.contains("its HEAD is \(newHead.prefix(8))"), "\(failure.reason)")
            #expect(failure.head == scenario.head)
            #expect(scenario.merges.request(workspaceID: scenario.taskSpaceID) == nil)
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID]?.doneAt == nil)
            #expect(scenario.record?.mergeRequestedAt == nil)
            #expect(scenario.notifications == ["PR #7 was not merged: \(failure.reason)"])
            scenario.reportAgent(.ready)
            let item = try #require(scenario.boardItem)
            #expect(item.merge == nil)
            #expect(TaskBoardPresentation.statusLine(item) == "⚠ merge stopped")
            #expect(TaskBoardPresentation.detailActions(item).contains(.merge))

            // Passing checks no longer merge the version accepted earlier.
            scenario.passChecks()
            try await Task.sleep(for: .milliseconds(700))
            #expect(FileManager.default.fileExists(atPath: scenario.mergedMarker) == false)
            #expect(FileManager.default.fileExists(atPath: scenario.worktree))
        }
    }

    @Test
    func retargetingAWaitingFeatureMergeRequiresAcceptanceAgain() async throws {
        try await withScenario(checksPending: true, baseBranch: "feat/integration") { scenario in
            let mainHead = try scenario.git(["rev-parse", "main"], in: scenario.repo)
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: scenario.head, caller: scenario.agentCaller)
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
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: scenario.head, caller: scenario.agentCaller)
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
    func heldCleanupResumesWithAWorktreeOnAnotherBranchThanThePullRequest() async throws {
        try await withScenario(
            cleanupHold: 3_600, pullRequestBranch: "feat/shared", restoredCleanup: .holdingCleanup(until: .distantPast)
        ) { scenario in
            await scenario.waitUntil("restored cleanup finishes") { scenario.record?.cleanup?.finishedAt != nil }
            #expect(scenario.record?.cleanup?.problem == nil)
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] == nil)
            #expect(FileManager.default.fileExists(atPath: scenario.worktree) == false)
            let localTaskBranch = try scenario.git(["branch", "--list", "fix/task-7"], in: scenario.repo)
            let remotePRBranch = try scenario.git(["ls-remote", "--heads", "origin", "feat/shared"], in: scenario.repo)
            #expect(localTaskBranch.isEmpty)
            #expect(remotePRBranch.hasPrefix(scenario.head))
            #expect(scenario.boardItem?.stage == .done)
        }
    }

    @Test
    func oneCleanUpFinishesAStopSavedBeforeBranchMismatchWasRecorded() async throws {
        try await withScenario(
            cleanupHold: 3_600, pullRequestBranch: "feat/shared",
            restoredCleanup: .failed(reason: "the recorded worktree branch does not match the PR's branch")
        ) { scenario in
            #expect(scenario.boardItem?.stage == .needsYou(.cleanupStopped(
                reason: "the recorded worktree branch does not match the PR's branch"
            )))
            let socketPath = temporarySocketPath()
            let taskServer = try makeTaskServer(scenario, socketPath: socketPath)
            defer { withExtendedLifetime(taskServer) {} }
            try waitForSocket(at: socketPath)
            scenario.socketPath = socketPath
            let wrongPR = try await scenario.cli([
                "--json", "action", "run", "workspace.close", "--workspace", scenario.taskSpaceID.uuidString,
                "requireDone=true", "requirePullRequest=https://github.com/test/repo/pull/8",
            ])
            #expect(wrongPR.status != 0, "\(wrongPR.output)")
            #expect(wrongPR.output.contains("pull request link changed"), "\(wrongPR.output)")
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] != nil)
            let result = try await scenario.cli(["--json", "task", "clean-up", scenario.taskID.uuidString])
            #expect(result.status == 0, "\(result.output)")

            await scenario.waitUntil("the first retry finishes") { scenario.record?.cleanup?.finishedAt != nil }
            #expect(scenario.record?.cleanup?.problem == nil)
            #expect(scenario.isHeld == false)
            #expect(scenario.boardItem?.stage == .done)
        }
    }

    @Test
    func cleanupOfAnotherBranchStillChecksForUncommittedChanges() async throws {
        try await withScenario(pullRequestBranch: "feat/shared") { scenario in
            scenario.reportAgent(.ready)
            let draft = URL(filePath: scenario.worktree).appending(path: "draft.txt")
            try Data("draft".utf8).write(to: draft)
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
            #expect(reason.contains("uncommitted changes"), "\(reason)")
            #expect(scenario.boardItem.map { TaskBoardPresentation.statusLine($0) } == "Merged · clean up?")
            #expect(scenario.boardItem.map { TaskBoardPresentation.detailActions($0) } == [.cleanUp, .keepAsIs])
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] != nil)
            #expect(FileManager.default.fileExists(atPath: draft.path))
            try FileManager.default.removeItem(at: draft)
            try scenario.tasks.retryCleanup(taskID: scenario.taskID)
            await scenario.waitUntil("the cleanup finishes") { scenario.record?.cleanup?.finishedAt != nil }
            #expect(scenario.record?.cleanup?.problem == nil)
            #expect(scenario.merges.request(workspaceID: scenario.taskSpaceID) == nil)
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] == nil)
            #expect(FileManager.default.fileExists(atPath: scenario.worktree) == false)
            #expect(try scenario.git(["branch", "--list", "fix/task-7"], in: scenario.repo).isEmpty)
            #expect(try scenario.git(["ls-remote", "--heads", "origin", "feat/shared"], in: scenario.repo).isEmpty == false)
            #expect(scenario.record?.mergedAt != nil)
            #expect(scenario.record?.archivedAt == nil)
            #expect(scenario.boardItem?.stage == .done)
        }
    }

    /// A merge on GitHub while the agent works is the user's acceptance too.
    /// Its cleanup waits for the agent's turn, as after a merge Toastty
    /// ran, and does not ask the user. Work the agent starts afterwards, or
    /// a new pull request in the task space, ends the cleanup quietly.
    @Test(arguments: ["turnEnds", "newTurn", "newPullRequest"])
    func aMergeOnGitHubWhileTheAgentWorksWaitsForItsTurn(after: String) async throws {
        try await withScenario { scenario in
            scenario.fakeSessions.sessions["agent"] = TaskSessionInfo(
                sessionID: "agent", agent: .claude, panelID: scenario.taskPanelID, workspaceID: scenario.taskSpaceID,
                cwd: scenario.worktree, isActive: true, isInTurn: true
            )
            scenario.reportAgent(.working)
            FileManager.default.createFile(atPath: scenario.mergedMarker, contents: nil)
            await scenario.pullRequests.refresh(scenario.pullRequest).value

            await scenario.waitUntil("the merge is recorded") { scenario.record?.mergedAt != nil }
            #expect(scenario.record?.cleanup?.problem == nil)
            #expect(scenario.boardItem?.stage == .done)
            // The agent is still in its turn, so nothing closes.
            try await Task.sleep(for: .milliseconds(600))
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] != nil)
            #expect(scenario.record?.cleanup?.finishedAt == nil)

            switch after {
            case "turnEnds":
                scenario.fakeSessions.sessions["agent"]?.isInTurn = false
                scenario.reportAgent(.ready)
                await scenario.waitUntil("the cleanup finishes") { scenario.record?.cleanup?.finishedAt != nil }
                #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] == nil)
                #expect(FileManager.default.fileExists(atPath: scenario.worktree) == false)
            case "newTurn":
                scenario.reportAgent(.ready)
                scenario.reportAgent(.working)
                await scenario.waitUntil("the cleanup ends") { scenario.record?.cleanup?.finishedAt != nil }
                #expect(scenario.record?.cleanup?.stepsDone == ["left the task space open"])
                #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] != nil)
                #expect(FileManager.default.fileExists(atPath: scenario.worktree))
            default:
                scenario.store.send(.setWorkspaceAnnotation(
                    workspaceID: scenario.taskSpaceID,
                    key: "github-pr",
                    annotation: try #require(WorkspaceAnnotation.validated(text: "PR #8", url: "https://github.com/test/repo/pull/8"))
                ))
                await scenario.waitUntil("the cleanup ends") { scenario.record?.cleanup?.finishedAt != nil }
                #expect(scenario.record?.cleanup?.stepsDone == ["left the task space open"])
                #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID] != nil)
            }
            #expect(scenario.record?.cleanup?.problem == nil)
            #expect(scenario.boardItem.map { if case .needsYou = $0.stage { true } else { false } } == false)
        }
    }

    /// GitHub can fail the merge call itself when every check has passed,
    /// as it did with "Server Error" for a merge the user had accepted.
    /// Toastty runs the accepted merge again, so one failed call costs the
    /// user nothing.
    @Test
    func aMergeThatGitHubFailsOnceMergesWithoutTheUser() async throws {
        try await withScenario { scenario in
            scenario.failMergeCalls(once: true)
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: scenario.head, caller: scenario.agentCaller)
            await scenario.waitUntil("the merge and cleanup finish") { scenario.record?.cleanup?.finishedAt != nil }

            #expect(scenario.isFailingMergeCalls == false, "GitHub did not get a failed merge call")
            #expect(FileManager.default.fileExists(atPath: scenario.mergedMarker))
            #expect(scenario.record?.mergedAt != nil)
            #expect(scenario.record?.mergeFailure == nil, "\(scenario.notifications)")
            // Nothing told the user that the merge stopped.
            #expect(scenario.notifications.contains { $0.contains("not merged") || $0.contains("Unable to Merge") } == false,
                    "\(scenario.notifications)")
        }
    }

    /// While GitHub keeps failing, Toastty stops after a few runs and
    /// records what a caller outside the task needs to ask for the same
    /// merge again: that an error stopped it, and the accepted commit.
    @Test
    func aMergeThatGitHubKeepsFailingStopsAndCanBeRequestedAgain() async throws {
        try await withScenario { scenario in
            scenario.fakeSessions.sessions["agent"] = TaskSessionInfo(
                sessionID: "agent", agent: .claude, panelID: scenario.taskPanelID, workspaceID: scenario.taskSpaceID,
                cwd: scenario.worktree, isActive: true, isInTurn: false
            )
            let taskID = scenario.taskID.uuidString
            scenario.failMergeCalls(once: false)
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: scenario.head, caller: scenario.agentCaller)
            // The accepted merge waits and runs again before it stops.
            await scenario.waitUntil("the merge waits to run again") { scenario.isWaitingForChecks }
            #expect(scenario.record?.mergeFailure == nil)
            await scenario.waitUntil("the merge stops") { scenario.record?.mergeFailure != nil }

            let failure = try #require(scenario.record?.mergeFailure)
            #expect(failure.cause == .error)
            #expect(failure.head == scenario.head)
            #expect(failure.base == "main")
            #expect(failure.reason.contains("Server Error"), "\(failure.reason)")
            #expect(FileManager.default.fileExists(atPath: scenario.mergedMarker) == false)
            #expect(scenario.notifications == ["PR #7 was not merged: \(failure.reason)"])
            // The acceptance ended, and the task offers Merge again.
            #expect(scenario.record?.mergeRequestedAt == nil)
            #expect(scenario.store.state.workspacesByID[scenario.taskSpaceID]?.doneAt == nil)
            #expect(scenario.merges.request(workspaceID: scenario.taskSpaceID) == nil)

            // A caller outside the task, such as the coordinator, reads the
            // cause and the commit, and asks for the same merge again.
            let taskSocketPath = temporarySocketPath()
            let taskServer = try makeTaskServer(scenario, socketPath: taskSocketPath)
            defer { withExtendedLifetime(taskServer) {} }
            try waitForSocket(at: taskSocketPath)
            scenario.socketPath = taskSocketPath
            let get = try await scenario.cli(["--json", "task", "get", taskID])
            #expect(get.status == 0, "\(get.output)")
            let response = try JSONSerialization.jsonObject(with: Data(get.output.utf8)) as? [String: Any]
            let reported = (response?["result"] as? [String: Any])?["mergeFailure"] as? [String: Any]
            #expect(reported?["cause"] as? String == "error", "\(get.output)")
            #expect(reported?["head"] as? String == scenario.head, "\(get.output)")
            #expect(reported?["base"] as? String == "main", "\(get.output)")

            scenario.gitHubWorksAgain()
            let requested = try await scenario.cli(["--json", "task", "request-merge", taskID])
            #expect(requested.status == 0, "\(requested.output)")
            #expect(scenario.record?.mergeFailure == nil)
            #expect(scenario.fakeSessions.delivered.last?.text.hasPrefix("Use the toastty-task-merge skill.") == true)
            // The merge skill's task merge, from the task's agent, merges.
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: scenario.head, caller: scenario.agentCaller)
            await scenario.waitUntil("the merge and cleanup finish") { scenario.record?.cleanup?.finishedAt != nil }
            #expect(scenario.record?.mergedAt != nil)
            #expect(scenario.record?.mergeFailure == nil)
            #expect(FileManager.default.fileExists(atPath: scenario.mergedMarker))
        }
    }

    /// An outside coordinator, such as Grok Bot, runs the CLI with no
    /// managed session. It cannot merge directly; request-merge hands the
    /// merge to the task's agent, also in a project with merge = "direct",
    /// and that agent's task merge then merges.
    @Test
    func anOutsideCallerRequestsTheMergeThroughTheAgent() async throws {
        try await withScenario { scenario in
            scenario.config.defaults.merge = .direct
            scenario.fakeSessions.sessions["agent"] = TaskSessionInfo(
                sessionID: "agent", agent: .claude, panelID: scenario.taskPanelID, workspaceID: scenario.taskSpaceID,
                cwd: scenario.worktree, isActive: true, isInTurn: false
            )
            let taskID = scenario.taskID.uuidString
            // The scenario's own server starts before its task coordinator
            // exists, so the CLI talks to a second one that has it, as the
            // app's server does.
            let taskSocketPath = temporarySocketPath()
            let taskServer = try makeTaskServer(scenario, socketPath: taskSocketPath)
            defer { withExtendedLifetime(taskServer) {} }
            try waitForSocket(at: taskSocketPath)
            scenario.socketPath = taskSocketPath

            let direct = try await scenario.cli(["task", "merge", taskID])
            #expect(direct.status != 0)
            #expect(direct.output.contains("To accept the merge, run: toastty task request-merge \(taskID)"), "\(direct.output)")
            #expect(scenario.record?.mergeRequestedAt == nil)

            let requested = try await scenario.cli(["--json", "task", "request-merge", taskID])
            #expect(requested.status == 0, "\(requested.output)")
            #expect(scenario.record?.mergeRequestedAt != nil)
            #expect(scenario.fakeSessions.delivered.last?.text
                == "Use the toastty-task-merge skill.\n\nThe user accepted https://github.com/test/repo/pull/7 for merging.")
            // The agent route: nothing merged on its own.
            try await Task.sleep(for: .milliseconds(400))
            #expect(FileManager.default.fileExists(atPath: scenario.mergedMarker) == false)

            // While the agent checks, Merge is not offered, so a second
            // request is refused.
            scenario.reportAgent(.working)
            let again = try await scenario.cli(["task", "request-merge", taskID])
            #expect(again.status != 0)
            #expect(again.output.contains("Merge is not available for Fix task 7 now"), "\(again.output)")

            // The merge skill's task merge, from the task's agent, merges.
            try scenario.tasks.merge(taskID: scenario.taskID, expectedHead: scenario.head, caller: scenario.agentCaller)
            await scenario.waitUntil("GitHub merges it") { FileManager.default.fileExists(atPath: scenario.mergedMarker) }
        }
    }

    /// A socket server on the scenario's store whose executor has the task
    /// coordinator, as the app's server has.
    private func makeTaskServer(_ scenario: Scenario, socketPath: String) throws -> AutomationSocketServer {
        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        let webPanelRuntimeRegistry = WebPanelRuntimeRegistry()
        webPanelRuntimeRegistry.bind(store: scenario.store)
        return try AutomationSocketServer(
            socketPath: socketPath,
            automationConfig: nil,
            store: scenario.store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            webPanelRuntimeRegistry: webPanelRuntimeRegistry,
            sessionRuntimeStore: scenario.sessionRuntimeStore,
            focusedPanelCommandController: FocusedPanelCommandController(
                store: scenario.store,
                runtimeRegistry: terminalRuntimeRegistry,
                slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
            ),
            agentLaunchService: AgentLaunchService(
                store: scenario.store,
                terminalCommandRouter: terminalRuntimeRegistry,
                sessionRuntimeStore: scenario.sessionRuntimeStore,
                agentCatalogProvider: TestAgentCatalogProvider(),
                cliExecutablePathProvider: { "/bin/sh" },
                socketPathProvider: { socketPath }
            ),
            taskCoordinator: scenario.tasks,
            codexStatusHooksPreflightProvider: { _ in .ready },
            codexStatusHooksWarningPresenter: { _, _, completion in completion(.cancel) },
            codexStatusHooksInstallAction: {}
        )
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
        /// The project the task space belongs to, which the window shows.
        var parentWorkspaceID = UUID()
        var tasks: TaskCoordinator!
        var merges: WorkspaceMergeCoordinator!
        var board: TaskBoardStore!
        var pullRequests: PullRequestStateCache!
        let fakeSessions = TaskStartWorkTests.FakeSessions()
        var notifications: [String] = []
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
        /// The merge skill's caller: the agent in the task's task space.
        var agentCaller: TaskCaller { TaskCaller(sessionID: "agent", workspaceID: taskSpaceID) }
        var socketPath = ""
        var cliPath = ""

        /// Runs the bundled `toastty` CLI as a shell outside Toastty does:
        /// no managed session in its environment, unless `sessionID` names
        /// the managed session it runs in. Off the main actor, so the socket
        /// server can answer.
        func cli(_ arguments: [String], sessionID: String? = nil) async throws -> (status: Int32, output: String) {
            let executable = cliPath
            let fullArguments = ["--socket-path", socketPath] + arguments
            var environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
            environment[ToasttyLaunchContextEnvironment.sessionIDKey] = sessionID
            return try await Task.detached { [environment] in
                let process = Process()
                process.executableURL = URL(filePath: executable)
                process.arguments = fullArguments
                process.environment = environment
                let output = Pipe()
                process.standardOutput = output
                process.standardError = output
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, String(decoding: data, as: UTF8.self))
            }.value
        }

        /// A `--wait` watch on the task, as a caller outside Toastty makes.
        func watch(_ condition: TaskWatchCondition) throws -> UUID {
            try tasks.addWatch(targetTaskID: taskID, condition: condition, notifyTaskID: nil).id
        }

        func fired(_ watchID: UUID) -> Bool {
            tasks.evaluateWatches()
            return tasks.waitWatches[watchID]?.firedAt != nil
        }
        var boardItem: TaskBoardItem? { board.items().first { $0.taskID == taskID } }
        var isHeld: Bool {
            if case .holdingCleanup? = merges.request(workspaceID: taskSpaceID)?.phase { return true }
            return false
        }
        func remoteBranch() throws -> String {
            try git(["ls-remote", "--heads", "origin", "fix/task-7"], in: repo)
        }
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

        @discardableResult
        func git(_ arguments: [String], in directory: String) throws -> String { try git(arguments, directory) }

        /// Closes the project's workspace, as Cmd+W on its last panel does.
        /// Its subspaces stay open as top-level workspaces.
        func closeProjectWorkspace() {
            #expect(store.send(.closeWorkspace(workspaceID: parentWorkspaceID)))
            #expect(store.state.workspacesByID[taskSpaceID]?.parentWorkspaceID == nil)
        }

        var isWaitingForChecks: Bool {
            if case .awaitingChecks? = merges.request(workspaceID: taskSpaceID)?.phase { return true }
            return false
        }

        /// GitHub answers the merge call with "Server Error": one time, or
        /// until `gitHubWorksAgain()`.
        func failMergeCalls(once: Bool) {
            FileManager.default.createFile(atPath: mergedMarker + (once ? "-github-error-once" : "-github-down"), contents: nil)
        }

        func gitHubWorksAgain() {
            try? FileManager.default.removeItem(atPath: mergedMarker + "-github-down")
        }

        var isFailingMergeCalls: Bool {
            ["-github-error-once", "-github-down"].contains { FileManager.default.fileExists(atPath: mergedMarker + $0) }
        }

        /// GitHub's checks finish and pass.
        func passChecks() {
            FileManager.default.createFile(atPath: mergedMarker + "-checks-passed", contents: nil)
        }

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
                    Issue.record("Timed out waiting until \(description); notes: \(notifications)")
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
        cleanupHold: TimeInterval = 0, pullRequestBranch: String = "fix/task-7",
        restoredCleanup: WorkspaceMergeRequest.Phase? = nil,
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
        if pullRequestBranch == "fix/task-7" {
            try git(["push", "-q", "-u", "origin", "fix/task-7"], in: worktree)
        } else {
            // The task's work went to another branch's pull request.
            try git(["push", "-q", "origin", "HEAD:refs/heads/\(pullRequestBranch)"], in: worktree)
        }

        let fakeBin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        let checks: [[String: Any]] = checksPending
            ? [["name": "CI gate", "status": "IN_PROGRESS", "conclusion": NSNull()]]
            : [["name": "CI gate", "status": "COMPLETED", "conclusion": "SUCCESS"]]
        let pullRequest: [String: Any] = [
            "number": 7, "title": "task", "state": "OPEN", "isDraft": false, "headRefName": pullRequestBranch,
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
        var checksPassed = pullRequest
        checksPassed["mergeStateStatus"] = "CLEAN"
        checksPassed["statusCheckRollup"] = [["name": "CI gate", "status": "COMPLETED", "conclusion": "SUCCESS"]]
        func json(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let mergedMarker = root.appendingPathComponent("pr-7-merged").path
        let fakeGh = fakeBin.appendingPathComponent("gh")
        try """
        #!/bin/sh
        # What `gh api` prints for an HTTP 500 answer.
        server_error() { echo '{"message":"Server Error"}'; echo 'gh: Server Error (HTTP 500)' >&2; exit 1; }
        case "$1 $2" in
          "repo view") echo '{"nameWithOwner":"test/repo","defaultBranchRef":{"name":"main"},"mergeCommitAllowed":true}' ;;
          "pr view") if [ -e '\(mergedMarker)' ]; then echo '\(try json(merged))'; elif [ -e '\(mergedMarker)-retargeted' ]; then echo '\(try json(retargeted))'; elif [ -e '\(mergedMarker)-checks-passed' ]; then echo '\(try json(checksPassed))'; else echo '\(try json(pullRequest))'; fi ;;
          "pr list") echo '[]' ;;
          "api --method")
            [ -e '\(mergedMarker)-github-down' ] && server_error
            if [ -e '\(mergedMarker)-github-error-once' ]; then rm '\(mergedMarker)-github-error-once'; server_error; fi
            [ "$3 $4 $6 $8" = 'PUT repos/test/repo/pulls/7/merge sha=\(head) merge_method=merge' ] && touch '\(mergedMarker)' ;;
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
        #expect(store.state.windows.first?.selectedWorkspaceID == parentWorkspaceID)
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
        scenario.parentWorkspaceID = parentWorkspaceID
        let cliPath = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/toastty").path
        scenario.cliPath = cliPath
        let runner = WorkspaceMergeLiveCommandRunner(
            socketPath: socketPath,
            cliExecutablePath: cliPath,
            pathOverride: "\(fakeBin.path):/usr/bin:/bin"
        )
        let defaultsSuite = "TaskMergeEndToEndTests.\(UUID())"
        let defaults = restoredCleanup == nil ? nil : UserDefaults(suiteName: defaultsSuite)
        defer { defaults?.removePersistentDomain(forName: defaultsSuite) }
        if let restoredCleanup {
            FileManager.default.createFile(atPath: mergedMarker, contents: nil)
            store.send(.setWorkspaceDone(workspaceID: taskSpaceID, doneAt: Date()))
            let request = WorkspaceMergeRequest(
                pullRequest: scenario.pullRequest, repoPath: worktree, phase: restoredCleanup
            )
            let data = try JSONEncoder().encode([taskSpaceID.uuidString: request])
            defaults?.set(data, forKey: "toastty.workspaceMergeRequests")
        }
        scenario.merges = WorkspaceMergeCoordinator(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            runner: runner,
            userDefaults: defaults,
            pollInterval: .milliseconds(200),
            taskSpaceCleanupHold: cleanupHold,
            notify: { [scenario] title, body in scenario.notifications.append("\(title): \(body)") }
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
        var record = TaskRecord(
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
        if restoredCleanup != nil {
            record.pullRequestURL = scenario.pullRequest.url
            record.mergedAt = Date()
            record.cleanup = TaskCleanup(kind: .merge)
        }
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
