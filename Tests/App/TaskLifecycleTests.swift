import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

/// Finishing tasks: the merge prompt that Merge sends to a task's agent,
/// Cancel Merge, Mark done, Archive, and releases with their tag monitor.
/// The real reducer, store and git, with the start-work fixture's fake
/// launcher and sessions in place of agents.
@MainActor
struct TaskLifecycleTests {
    typealias Fixture = TaskStartWorkTests.Fixture

    private let pullRequestURL = "https://github.com/example/project/pull/7"

    /// A task that started in its own worktree, whose agent is at rest, with
    /// its pull request linked on the task space.
    private func taskInWorktree(_ fixture: Fixture, linkPullRequest: Bool = true) async throws -> TaskRecord {
        let created = try await fixture.coordinator.create(TaskCreateRequest(
            text: "Fix the composer",
            workspaceID: fixture.workspaceID,
            agent: "claude",
            startWork: true
        ))
        await fixture.waitUntil("setup ends") { fixture.record(created.id)?.setup != .settingUp }
        let task = try #require(fixture.record(created.id))
        #expect(task.setup == .started)
        let session = try #require(task.operation.agentLaunch?.sessionID)
        fixture.sessions.report(session, .ready, at: Date().addingTimeInterval(-60))
        if linkPullRequest {
            fixture.store.send(.setWorkspaceAnnotation(
                workspaceID: try #require(task.taskSpaceWorkspaceID),
                key: "github-pr",
                annotation: try #require(WorkspaceAnnotation.validated(text: "PR #7", url: pullRequestURL))
            ))
        }
        return task
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: String) throws -> String {
        try TaskGitTestRepository.git(arguments, in: directory)
    }

    // MARK: - Merge through the agent

    @Test func mergeSendsTheMergePromptToAnIdleAgent() async throws {
        let fixture = try Fixture()
        fixture.config.workspaces = [TasksConfig.Workspace(path: fixture.repository.project, mergePrompt: "Use my-merge.")]
        let task = try await taskInWorktree(fixture)
        let panel = try #require(task.operation.taskSpace?.panelID)

        try fixture.coordinator.requestMerge(taskID: task.id)

        let delivered = try #require(fixture.sessions.delivered.last)
        #expect(delivered.panelID == panel)
        #expect(delivered.text == "Use my-merge.\n\nThe user accepted \(pullRequestURL) for merging.")
        #expect(fixture.record(task.id)?.mergeRequestedAt != nil)
    }

    @Test func mergeNamesTheMergeSkillBeforeTheMergePrompt() async throws {
        let fixture = try Fixture()
        // The project's skill and the default prompt, each from its own table.
        fixture.config.defaults.mergePrompt = "Wait for CI."
        fixture.config.workspaces = [TasksConfig.Workspace(path: fixture.repository.project, mergeSkill: "my-merge")]
        let task = try await taskInWorktree(fixture)

        try fixture.coordinator.requestMerge(taskID: task.id)

        #expect(fixture.sessions.delivered.last?.text
            == "Use the my-merge skill.\n\nWait for CI.\n\nThe user accepted \(pullRequestURL) for merging.")
    }

    @Test func mergeWaitsForABusyAgentsTurnThenSendsTheDefaultPrompt() async throws {
        let fixture = try Fixture()
        let task = try await taskInWorktree(fixture)
        let session = try #require(task.operation.agentLaunch?.sessionID)
        fixture.sessions.report(session, .working)

        try fixture.coordinator.requestMerge(taskID: task.id)
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.sessions.delivered.isEmpty)
        let accepted = try #require(fixture.record(task.id)?.mergeRequestedAt)

        fixture.sessions.report(session, .ready)
        await fixture.waitUntil("the prompt is sent") { fixture.sessions.delivered.isEmpty == false }
        #expect(fixture.sessions.delivered.last?.text.hasPrefix("Use the toastty-task-merge skill.\n\n") == true)
        // The request restarts when the agent can read it, so the status it
        // reported before does not count as its answer.
        #expect(try #require(fixture.record(task.id)?.mergeRequestedAt) > accepted)
    }

    @Test func mergeStartsAnAgentWhenNoneRuns() async throws {
        let fixture = try Fixture()
        fixture.config.defaults = TasksConfig.Defaults(agent: "codex")
        let task = try await taskInWorktree(fixture)
        fixture.sessions.stop(try #require(task.operation.agentLaunch?.sessionID))
        let worktree = try #require(task.worktree)

        try fixture.coordinator.requestMerge(taskID: task.id)

        await fixture.waitUntil("an agent starts") { fixture.launcher.calls.count == 2 }
        let launch = fixture.launcher.calls[1]
        // The task's own agent, not the default one.
        #expect(launch.profileID == "claude")
        #expect(launch.cwd == worktree.path)
        #expect(launch.workspaceID == task.taskSpaceWorkspaceID)
        #expect(launch.panelID != task.operation.taskSpace?.panelID)
        #expect(launch.prompt.hasPrefix("Use the toastty-task-merge skill.\n\n"))
        // A launch without its skills gets the skill's file.
        let skillFile = try #require(ToasttyAgentPluginBundle.skillFiles()[TaskPrompt.defaultMergeSkill])
        #expect(launch.promptWithoutSkills?.contains("The toastty-task-merge skill's instructions are in \(skillFile)") == true)
    }

    /// The task's agent runs but did not get its skills at launch.
    @Test func mergeToAnAgentWithoutItsSkillsSaysWhereTheMergeSkillIs() async throws {
        let fixture = try Fixture()
        let task = try await taskInWorktree(fixture)
        let session = try #require(task.operation.agentLaunch?.sessionID)
        fixture.launcher.sessionIDsWithoutSkills.insert(session)
        let skillFile = try #require(ToasttyAgentPluginBundle.skillFiles()[TaskPrompt.defaultMergeSkill])
        // The name the Skills sheet shows finds the same file.
        #expect(ToasttyAgentPluginBundle.skillFiles()["toastty:\(TaskPrompt.defaultMergeSkill)"] == skillFile)

        try fixture.coordinator.requestMerge(taskID: task.id)

        #expect(fixture.sessions.delivered.last?.text == "Use the toastty-task-merge skill.\n\n"
            + "Toastty could not give this session its skills. The toastty-task-merge skill's instructions are in \(skillFile): "
            + "read that file and follow it.\n\nThe user accepted \(pullRequestURL) for merging.")
    }

    @Test func mergeWithoutAPullRequestOrAfterCancelIsRefused() async throws {
        let fixture = try Fixture()
        let unlinked = try await taskInWorktree(fixture, linkPullRequest: false)
        #expect(throws: TaskError.self) { try fixture.coordinator.requestMerge(taskID: unlinked.id) }

        let task = try await taskInWorktree(fixture)
        let session = try #require(task.operation.agentLaunch?.sessionID)
        try fixture.coordinator.requestMerge(taskID: task.id)
        // The agent starts checking, then the user cancels mid-turn.
        fixture.sessions.report(session, .working)
        fixture.sessions.sessions[session]?.turnStartedAt = Date()
        try await Task.sleep(for: .milliseconds(20))
        try fixture.coordinator.cancelMerge(taskID: task.id)
        #expect(fixture.record(task.id)?.mergeRequestedAt == nil)

        let caller = TaskCaller(sessionID: session, workspaceID: task.taskSpaceWorkspaceID)
        let cancelled = #expect(throws: TaskError.self) {
            try fixture.coordinator.merge(taskID: task.id, expectedHead: nil, caller: caller)
        }
        #expect(cancelled?.message.contains("cancelled") == true)
        // Only an agent in the task's or its parent's task space may merge:
        // a shell, an outside coordinator or an agent elsewhere asks with
        // task request-merge.
        for outsider in [TaskCaller.unmanaged, TaskCaller(sessionID: "elsewhere", workspaceID: fixture.workspaceID)] {
            let refused = #expect(throws: TaskError.self) {
                try fixture.coordinator.merge(taskID: task.id, expectedHead: nil, caller: outsider)
            }
            #expect(refused?.message.contains("toastty task request-merge \(task.id.uuidString)") == true)
        }

        // A coordinating task's turn that started before the cancel is held
        // back the same way.
        let parent = try await fixture.startedTask()
        try fixture.coordinator.records.save(id: task.id) { $0.parentTaskID = parent.id }
        let parentSpace = try #require(parent.taskSpaceWorkspaceID)
        fixture.sessions.sessions["parent"] = TaskSessionInfo(
            sessionID: "parent", agent: .claude, panelID: UUID(), workspaceID: parentSpace,
            cwd: nil, isActive: true, isInTurn: true, turnStartedAt: Date().addingTimeInterval(-60)
        )
        let heldBack = #expect(throws: TaskError.self) {
            try fixture.coordinator.merge(taskID: task.id, expectedHead: nil, caller: TaskCaller(sessionID: "parent", workspaceID: parentSpace))
        }
        #expect(heldBack?.message.contains("cancelled") == true)

        // A later turn, such as the user saying "merge it", may merge. Here no
        // merge owner runs, so it gets past the cancel and stops there.
        fixture.sessions.sessions[session]?.turnStartedAt = Date().addingTimeInterval(1)
        let unavailable = #expect(throws: TaskError.self) {
            try fixture.coordinator.merge(taskID: task.id, expectedHead: nil, caller: caller)
        }
        #expect(unavailable?.message.contains("not available") == true)
    }

    @Test func readyForReviewThenMarkDoneFinishesWorkWithoutAPullRequest() async throws {
        let fixture = try Fixture()
        let task = try await taskInWorktree(fixture, linkPullRequest: false)
        let taskSpace = try #require(task.taskSpaceWorkspaceID)

        try fixture.coordinator.readyForReview(taskID: task.id)
        #expect(fixture.record(task.id)?.readyForReviewAt != nil)

        try fixture.coordinator.markDone(taskID: task.id)
        #expect(fixture.record(task.id)?.doneAt != nil)
        #expect(fixture.store.state.workspacesByID[taskSpace]?.doneAt != nil)
    }

    // MARK: - Archive

    @Test func archiveRemovesTheWorktreeAndKeepsOnlyTheRemoteBranch() async throws {
        let fixture = try Fixture()
        let task = try await taskInWorktree(fixture)
        let worktree = try #require(task.worktree)
        try fixture.repository.commit("work", in: worktree.path)
        try git(["push", "--quiet", "origin", "HEAD:refs/heads/\(worktree.branch)"], in: worktree.path)
        try git(["fetch", "--quiet", "origin"], in: fixture.repository.project)

        let archivedWatch = try fixture.coordinator.addWatch(targetTaskID: task.id, condition: .archived, notifyTaskID: nil)
        let check = try await fixture.coordinator.archiveCheck(taskID: task.id)
        #expect(check.unpushedCommits == 0)
        #expect(check.branch == worktree.branch)
        try await fixture.coordinator.archive(taskID: task.id, options: TaskArchiveOptions())
        await fixture.waitUntil("the archive finishes") { fixture.record(task.id)?.cleanup?.finishedAt != nil }

        let archived = try #require(fixture.record(task.id))
        #expect(archived.archivedAt != nil)
        #expect(archived.cleanup?.problem == nil)
        #expect(archived.cleanup?.stepsDone == ["closed the task space", "removed the worktree", "deleted the local branch \(worktree.branch)"])
        #expect(fixture.store.state.workspacesByID[try #require(task.taskSpaceWorkspaceID)] == nil)
        #expect(FileManager.default.fileExists(atPath: worktree.path) == false)
        #expect(try git(["branch", "--list", worktree.branch], in: fixture.repository.project).isEmpty)
        #expect(try git(["ls-remote", "--heads", "origin", worktree.branch], in: fixture.repository.project).isEmpty == false)
        // A watch for the archive fires; it reads the record, not the board.
        fixture.coordinator.evaluateWatches()
        #expect(fixture.coordinator.waitWatches[archivedWatch.id]?.firedAt != nil)
    }

    @Test func archiveKeepsABranchWithUnpushedCommitsAndAsksBeforeDiscardingChanges() async throws {
        let fixture = try Fixture()
        let task = try await taskInWorktree(fixture)
        let worktree = try #require(task.worktree)
        try fixture.repository.commit("local only", in: worktree.path)
        try Data("draft".utf8).write(to: URL(filePath: worktree.path).appending(path: "notes.txt"))

        // The preview says what the archive would do, and why it would
        // refuse, and changes nothing.
        let preview = try await fixture.coordinator.archivePreview(taskID: task.id, options: TaskArchiveOptions())
        #expect(preview.refusal?.contains("1 uncommitted file") == true)
        #expect(preview.summary.contains("Removes the worktree and its 1 uncommitted file."))
        #expect(preview.summary.contains("Keeps the branch \(worktree.branch): 1 of its commits are on no remote branch."))
        let discarding = try await fixture.coordinator.archivePreview(
            taskID: task.id, options: TaskArchiveOptions(deleteUnpushedCommits: true, discardChanges: true)
        )
        #expect(discarding.refusal == nil)
        #expect(discarding.summary.contains("Deletes the local branch \(worktree.branch) and its 1 commit on no remote branch."))
        #expect(fixture.record(task.id)?.archivedAt == nil)
        #expect(fixture.record(task.id)?.cleanup == nil)

        let refused = await #expect(throws: TaskError.self) {
            try await fixture.coordinator.archive(taskID: task.id, options: TaskArchiveOptions())
        }
        #expect(refused?.message.contains("1 uncommitted file") == true)
        #expect(fixture.record(task.id)?.archivedAt == nil)
        #expect(FileManager.default.fileExists(atPath: worktree.path))

        try await fixture.coordinator.archive(taskID: task.id, options: TaskArchiveOptions(discardChanges: true))
        await fixture.waitUntil("the archive finishes") { fixture.record(task.id)?.cleanup?.finishedAt != nil }
        #expect(FileManager.default.fileExists(atPath: worktree.path) == false)
        #expect(try git(["branch", "--list", worktree.branch], in: fixture.repository.project).isEmpty == false)
        #expect(fixture.record(task.id)?.cleanup?.stepsDone.last == "kept the branch \(worktree.branch): 1 commit is on no remote branch")
    }

    @Test func archiveKeepsCommitsThatOnlyTheWorktreeHolds() async throws {
        let fixture = try Fixture()
        let task = try await taskInWorktree(fixture)
        let worktree = try #require(task.worktree)
        // The agent left the branch and committed on a detached HEAD.
        try git(["checkout", "--quiet", "--detach"], in: worktree.path)
        try fixture.repository.commit("detached work", in: worktree.path)

        let refused = await #expect(throws: TaskError.self) {
            try await fixture.coordinator.archive(taskID: task.id, options: TaskArchiveOptions())
        }
        #expect(refused?.message.contains("on no branch") == true)
        #expect(FileManager.default.fileExists(atPath: worktree.path))

        try await fixture.coordinator.archive(taskID: task.id, options: TaskArchiveOptions(deleteUnpushedCommits: true))
        await fixture.waitUntil("the archive finishes") { fixture.record(task.id)?.cleanup?.finishedAt != nil }
        #expect(FileManager.default.fileExists(atPath: worktree.path) == false)
    }

    @Test func aCleanupAQuitInterruptedCanBeRetried() async throws {
        let fixture = try Fixture()
        let task = try await taskInWorktree(fixture)
        try fixture.coordinator.saveMergeState(taskID: task.id) {
            $0.archivedAt = Date()
            $0.cleanup = TaskCleanup(kind: .archive, stepsDone: ["closed the task space"], archiveOptions: TaskArchiveOptions())
        }
        fixture.coordinator.reconcileAfterLaunch()
        #expect(fixture.record(task.id)?.cleanup?.problem?.contains("quit") == true)

        try fixture.coordinator.retryCleanup(taskID: task.id)
        await fixture.waitUntil("the archive finishes") { fixture.record(task.id)?.cleanup?.finishedAt != nil }
        #expect(FileManager.default.fileExists(atPath: try #require(task.worktree).path) == false)
    }

    @Test func aStoppedArchiveNeedsTheUserAndContinuesOnRetry() async throws {
        let fixture = try Fixture()
        let task = try await taskInWorktree(fixture)
        let worktree = try #require(task.worktree)
        // A locked worktree refuses removal.
        try git(["worktree", "lock", worktree.path], in: fixture.repository.project)

        try await fixture.coordinator.archive(taskID: task.id, options: TaskArchiveOptions())
        await fixture.waitUntil("the archive stops") { fixture.record(task.id)?.cleanup?.problem != nil }
        let stopped = try #require(fixture.record(task.id))
        #expect(stopped.cleanup?.stepsDone == ["closed the task space"])
        #expect(TaskStage.derive(TaskStageFacts(record: stopped), live: TaskLiveFacts(taskSpaceOpen: false), releaseTagsConfigured: false)
            == .needsYou(.cleanupStopped(reason: try #require(stopped.cleanup?.problem))))

        try git(["worktree", "unlock", worktree.path], in: fixture.repository.project)
        try fixture.coordinator.retryCleanup(taskID: task.id)
        await fixture.waitUntil("the archive finishes") { fixture.record(task.id)?.cleanup?.finishedAt != nil }
        #expect(fixture.record(task.id)?.cleanup?.stepsDone == [
            "closed the task space", "removed the worktree", "deleted the local branch \(worktree.branch)",
        ])
    }

    @Test func archiveRefusesWhileDocumentsAreUnsaved() async throws {
        let fixture = try Fixture()
        let task = try await taskInWorktree(fixture)
        fixture.coordinator.unsavedDocumentCount = { _ in 1 }
        await #expect(throws: TaskError.self) {
            try await fixture.coordinator.archive(taskID: task.id, options: TaskArchiveOptions(discardChanges: true))
        }
        #expect(fixture.record(task.id)?.archivedAt == nil)
    }

    // MARK: - Release

    /// A project that releases from Toastty, with one merged task waiting
    /// for a release at `mergeCommit`.
    private func releasingProject(
        _ fixture: Fixture,
        mergeCommit: String,
        releaseSkill: String? = nil,
        releasePrompt: String? = "Use toastty-release."
    ) throws -> TaskRecord {
        fixture.config.defaults = TasksConfig.Defaults(agent: "claude", startPrompt: "Ask for a review first.", startSkill: "task-start")
        fixture.config.workspaces = [TasksConfig.Workspace(
            path: fixture.repository.project,
            releaseTags: "v*",
            releasePrompt: releasePrompt,
            releaseSkill: releaseSkill
        )]
        var merged = TaskRecord(
            createdAt: Date(),
            text: "Fix the parser",
            title: "Fix the parser",
            slug: "fix-the-parser",
            source: .cli,
            workspaceID: fixture.workspaceID,
            projectRoot: fixture.repository.project,
            setup: .started
        )
        merged.pullRequestURL = "https://github.com/example/project/pull/3"
        merged.mergedAt = Date()
        merged.mergeCommit = mergeCommit
        try fixture.coordinator.records.insert(merged)
        return merged
    }

    @Test func releaseStartsFromTheFetchedTipNotTheProjectCheckout() async throws {
        let fixture = try Fixture()
        // The project checkout is old, dirty, and on a feature branch.
        try git(["checkout", "--quiet", "-b", "feature"], in: fixture.repository.project)
        try fixture.repository.commit("feature work", in: fixture.repository.project)
        try Data("dirty".utf8).write(to: URL(filePath: fixture.repository.project).appending(path: "dirty.txt"))
        let tip = try fixture.repository.pushToRemote("released")
        let child = try releasingProject(fixture, mergeCommit: tip)

        let release = try fixture.coordinator.release(workspaceID: fixture.workspaceID, caller: .unmanaged)
        #expect(release.release?.childTaskIDs == [child.id])
        await fixture.waitUntil("setup ends") { fixture.record(release.id)?.setup != .settingUp }

        let started = try #require(fixture.record(release.id))
        #expect(started.setup == .started)
        let worktree = try #require(started.worktree)
        #expect(worktree.isDetached)
        #expect(started.operation.base == TaskOperation.Base(sha: tip, ref: "origin/main", fetched: true))
        #expect(try git(["rev-parse", "HEAD"], in: worktree.path) == tip)
        #expect(throws: TaskError.self) { try git(["symbolic-ref", "--quiet", "HEAD"], in: worktree.path) }
        let launch = try #require(fixture.launcher.calls.last)
        #expect(launch.cwd == worktree.path)
        #expect(launch.prompt.hasPrefix("You are in the git worktree \(worktree.path), on no branch, at origin/main (\(tip.prefix(12)))"))
        #expect(launch.prompt.contains("Use toastty-release."))
        // A release names the release skill, never the start skill.
        #expect(launch.prompt.contains("Use the task-start skill.") == false)
        #expect(launch.prompt.contains("Ask for a review first.") == false)
        #expect(launch.prompt.contains("- \(CoordinatorTaskLink.markdown(taskID: child.id, title: child.title)) — https://github.com/example/project/pull/3 (merge \(tip.prefix(12)))"))

        // One release per project at a time.
        #expect(throws: TaskError.self) { try fixture.coordinator.release(workspaceID: fixture.workspaceID, caller: .unmanaged) }
    }

    @Test(arguments: [nil, "Wait for my approval."] as [String?])
    func releaseSkillStartsTheReleaseMessage(releasePrompt: String?) async throws {
        let fixture = try Fixture()
        let tip = try fixture.repository.pushToRemote("released")
        let child = try releasingProject(fixture, mergeCommit: tip, releaseSkill: "toastty-release", releasePrompt: releasePrompt)

        let release = try fixture.coordinator.release(workspaceID: fixture.workspaceID, caller: .unmanaged)
        await fixture.waitUntil("setup ends") { fixture.record(release.id)?.setup != .settingUp }
        let launch = try #require(fixture.launcher.calls.last)
        let worktree = try #require(fixture.record(release.id)?.worktree)
        #expect(launch.prompt.hasPrefix("Use the toastty-release skill.\n\nYou are in the git worktree \(worktree.path), on no branch"))
        if let releasePrompt {
            #expect(launch.prompt.contains("\(releasePrompt)\n\nThe task, as written:\n\nRelease "))
        }
        #expect(launch.prompt.contains(
            "- \(CoordinatorTaskLink.markdown(taskID: child.id, title: child.title)) — https://github.com/example/project/pull/3 (merge \(tip.prefix(12)))"
        ))
        #expect(launch.prompt.contains("toastty task release-complete --text-file"))
        #expect(launch.prompt.hasSuffix("\(TaskPrompt.coordinatorLine)\n\n\(TaskPrompt.replyLine)"))
    }

    /// A coordinator passes the agent its policy names for releases; the
    /// default agent fills only what the caller leaves out.
    @Test func releaseStartsTheAgentTheCallerChose() async throws {
        let fixture = try Fixture()
        let tip = try fixture.repository.pushToRemote("released")
        _ = try releasingProject(fixture, mergeCommit: tip)
        fixture.config.defaults.model = "default-model"
        fixture.config.defaults.effort = "low"

        #expect(throws: TaskError.self) {
            try fixture.coordinator.release(workspaceID: fixture.workspaceID, caller: .unmanaged, agent: "missing")
        }
        #expect(throws: TaskError.self) {
            try fixture.coordinator.release(workspaceID: fixture.workspaceID, caller: .unmanaged, agent: "codex", effort: "very high")
        }
        let release = try fixture.coordinator.release(
            workspaceID: fixture.workspaceID, caller: .unmanaged, agent: "codex", model: "gpt-6.2-sol", effort: "high"
        )
        #expect(release.resolved?.agent == "codex")
        #expect(release.resolved?.model == "gpt-6.2-sol")
        #expect(release.resolved?.effort == "high")
        await fixture.waitUntil("setup ends") { fixture.record(release.id)?.setup != .settingUp }
        let launch = try #require(fixture.launcher.calls.last)
        #expect(launch.profileID == "codex")
        #expect(launch.model == "gpt-6.2-sol")
    }

    @Test func releaseFailsRatherThanBuildFromAnOldCommit() async throws {
        let fixture = try Fixture()
        _ = try releasingProject(fixture, mergeCommit: "0000000")
        try git(["remote", "set-url", "origin", fixture.repository.root.appendingPathComponent("missing.git").path], in: fixture.repository.project)

        let release = try fixture.coordinator.release(workspaceID: fixture.workspaceID, caller: .unmanaged)
        await fixture.waitUntil("setup ends") { fixture.record(release.id)?.setup != .settingUp }
        guard case .setupFailed(let reason)? = fixture.record(release.id)?.setup else {
            Issue.record("the release started from a cached commit")
            return
        }
        #expect(reason.contains("origin"))
        #expect(fixture.record(release.id)?.worktree == nil)

        // Placed again, the release routes like a new task but keeps to its
        // own prompt rather than the start skill.
        try git(["remote", "set-url", "origin", fixture.repository.remote], in: fixture.repository.project)
        try fixture.coordinator.setWorkspace(taskID: release.id, choice: .open(fixture.workspaceID))
        await fixture.waitUntil("setup ends") {
            let setup = fixture.record(release.id)?.setup
            return setup != .routing && setup != .settingUp
        }
        #expect(fixture.record(release.id)?.setup == .started)
        #expect(fixture.record(release.id)?.resolved?.skill == nil)
        let launch = try #require(fixture.launcher.calls.last)
        #expect(launch.prompt.contains("Use toastty-release."))
        #expect(launch.prompt.contains("Use the task-start skill.") == false)
        #expect(launch.prompt.contains("Ask for a review first.") == false)
    }

    @Test func relatedWorktreeReleasesShareSettingsAndExcludeFeatureBranchMerges() async throws {
        let fixture = try Fixture()
        let tip = try fixture.repository.pushToRemote("release work")
        var child = try releasingProject(fixture, mergeCommit: tip)
        child.mergeTarget = TaskMergeTarget(baseBranch: "main", releaseBranch: "main")
        fixture.coordinator.records.update(id: child.id) { $0 = child }
        let related = fixture.repository.root.appendingPathComponent("coordinator").path
        try git(["worktree", "add", "--quiet", "-b", "feature/coordinator", related], in: fixture.repository.project)
        var feature = TaskRecord(createdAt: Date(), text: "Feature", title: "Feature", slug: "feature", source: .cli,
            workspaceID: fixture.workspaceID, projectRoot: related, setup: .started)
        feature.mergedAt = Date()
        feature.mergeCommit = tip
        feature.mergeTarget = TaskMergeTarget(baseBranch: "feature/coordinator", releaseBranch: "main")
        feature.operation.worktree = TaskOperation.Worktree(path: related, branch: "feature/coordinator", checkoutRoot: fixture.repository.project, added: true)
        try fixture.coordinator.records.insert(feature)
        fixture.store.send(.setWorkspaceRootDirectory(workspaceID: fixture.workspaceID, rootDirectory: related))
        #expect(fixture.coordinator.toShipTasks(projectRoot: related).map(\.id) == [child.id])
        let release = try fixture.coordinator.release(workspaceID: fixture.workspaceID, caller: .unmanaged)
        #expect(release.release?.childTaskIDs == [child.id])
        #expect(fixture.coordinator.releaseUnderWay(projectRoot: fixture.repository.project)?.id == release.id)
        await fixture.waitUntil("release setup ends") { fixture.record(release.id)?.setup != .settingUp }
        #expect(fixture.record(release.id)?.setup == .started)
        #expect(fixture.record(release.id)?.operation.base?.sha == tip)
        #expect(fixture.launcher.calls.last?.prompt.contains("Use toastty-release.") == true)
        #expect(fixture.launcher.calls.last?.prompt.contains("- Feature") == false)
        try git(["tag", "v1.2", tip], in: fixture.repository.seed)
        try git(["push", "--quiet", "origin", "v1.2"], in: fixture.repository.seed)
        await fixture.coordinator.checkReleases()
        #expect(fixture.record(child.id)?.shippedAt == nil)
        #expect(fixture.record(release.id)?.shippedAt == nil)
        let started = try #require(fixture.record(release.id))
        _ = try await fixture.coordinator.reportReleaseCompletion(
            caller: TaskCaller(sessionID: started.currentSessionID, workspaceID: started.taskSpaceWorkspaceID),
            tags: [.init(tag: "v1.2", taskIDs: [child.id])]
        )
        #expect(fixture.record(child.id)?.releaseTag == "v1.2")
        #expect(fixture.record(feature.id)?.shippedAt == nil)
    }

    @Test func onlyTheReleaseAgentCanConfirmWhichTasksEachTagShipped() async throws {
        let fixture = try Fixture()
        let tip = try fixture.repository.pushToRemote("worker work")
        let worker = try releasingProject(fixture, mergeCommit: tip)
        fixture.config.workspaces[0].releaseTracking = .reported
        var bundle = TaskRecord(
            createdAt: Date(), text: "Bundle", title: "Bundle", slug: "bundle", source: .cli,
            workspaceID: fixture.workspaceID, projectRoot: fixture.repository.project, setup: .started
        )
        bundle.mergedAt = Date()
        bundle.mergeCommit = try fixture.repository.pushToRemote("bundle work")
        try fixture.coordinator.records.insert(bundle)
        var unreported = TaskRecord(
            createdAt: Date(), text: "Website", title: "Website", slug: "website", source: .cli,
            workspaceID: fixture.workspaceID, projectRoot: fixture.repository.project, setup: .started
        )
        unreported.mergedAt = Date()
        unreported.mergeCommit = bundle.mergeCommit
        try fixture.coordinator.records.insert(unreported)
        try git(["tag", "v1.0-worker", try #require(bundle.mergeCommit)], in: fixture.repository.seed)
        try git(["push", "--quiet", "origin", "v1.0-worker"], in: fixture.repository.seed)

        let release = try fixture.coordinator.release(workspaceID: fixture.workspaceID, caller: .unmanaged)
        await fixture.waitUntil("setup ends") { fixture.record(release.id)?.setup != .settingUp }
        let started = try #require(fixture.record(release.id))
        let releaseWorktree = try #require(started.worktree)
        let sessionID = try #require(started.currentSessionID)
        let caller = TaskCaller(sessionID: sessionID, workspaceID: started.taskSpaceWorkspaceID)

        fixture.sessions.report(sessionID, .ready)
        await fixture.coordinator.checkReleases()
        #expect(fixture.record(release.id)?.shippedAt == nil)
        #expect(fixture.record(worker.id)?.shippedAt == nil)
        #expect(fixture.record(bundle.id)?.shippedAt == nil)
        #expect(fixture.coordinator.releaseUnderWay(projectRoot: fixture.repository.project)?.id == release.id)

        let report: [TaskRelease.Tag] = [
            .init(tag: "v1.0-worker", taskIDs: [worker.id]),
            .init(tag: "v1.0-bundle", taskIDs: [bundle.id]),
        ]
        try git(["tag", "v1.0-bundle", "origin/main"], in: fixture.repository.project)
        await #expect(throws: TaskError.self) {
            try await fixture.coordinator.reportReleaseCompletion(caller: caller, tags: report)
        }
        #expect(fixture.record(worker.id)?.shippedAt == nil)
        try git(["tag", "v1.0-bundle", try #require(bundle.mergeCommit)], in: fixture.repository.seed)
        try git(["push", "--quiet", "origin", "v1.0-bundle"], in: fixture.repository.seed)
        await #expect(throws: TaskError.self) {
            try await fixture.coordinator.reportReleaseCompletion(caller: .unmanaged, tags: report)
        }
        try git(["tag", "v0.9-worker", tip], in: fixture.repository.seed)
        try git(["push", "--quiet", "origin", "v0.9-worker"], in: fixture.repository.seed)
        await #expect(throws: TaskError.self) {
            try await fixture.coordinator.reportReleaseCompletion(caller: caller, tags: [.init(tag: "v0.9-worker", taskIDs: [bundle.id])])
        }
        #expect(fixture.record(release.id)?.release?.completion == nil)

        fixture.sessions.report(sessionID, .working)
        let accepted = try await fixture.coordinator.reportReleaseCompletion(caller: caller, tags: report)
        #expect(accepted.release?.completion?.tags == report)
        let repeated = try await fixture.coordinator.reportReleaseCompletion(caller: caller, tags: report)
        #expect(repeated.release?.completion == accepted.release?.completion)
        let restored = fixture.makeCoordinator(records: TaskRecordStore(fileURL: fixture.recordsFile))
        fixture.replaceCoordinator(restored)
        let restoredReport = try #require(fixture.record(release.id)?.release?.completion)
        #expect(restoredReport.tags == report)
        #expect(abs(restoredReport.reportedAt.timeIntervalSince(try #require(accepted.release?.completion?.reportedAt))) < 1)
        #expect(fixture.record(worker.id)?.releaseTag == "v1.0-worker")
        #expect(fixture.record(bundle.id)?.releaseTag == "v1.0-bundle")
        #expect(fixture.record(unreported.id)?.shippedAt == nil)
        await fixture.coordinator.checkReleases()
        #expect(fixture.record(release.id)?.shippedAt == nil)
        fixture.sessions.report(sessionID, .ready)
        fixture.sessions.sessions[sessionID]?.hasBackgroundWork = true
        await fixture.coordinator.checkReleases()
        #expect(fixture.record(release.id)?.shippedAt == nil)
        fixture.sessions.sessions[sessionID]?.hasBackgroundWork = false
        _ = try fixture.coordinator.setWaiting(taskID: release.id, reason: "Waiting on final work", wakeAt: nil)
        await fixture.coordinator.checkReleases()
        #expect(fixture.record(release.id)?.shippedAt == nil)
        #expect(fixture.record(release.id)?.cleanup == nil)
        _ = try fixture.coordinator.clearWaiting(taskID: release.id)
        let localChanges = URL(filePath: releaseWorktree.path).appending(path: "pending-notes")
        try Data("keep my local notes".utf8).write(to: localChanges)
        await fixture.coordinator.checkReleases()
        await fixture.waitUntil("cleanup stops at local changes") { fixture.record(release.id)?.cleanup?.problem != nil }
        #expect(fixture.store.state.workspacesByID[try #require(started.taskSpaceWorkspaceID)] != nil)
        #expect(FileManager.default.fileExists(atPath: localChanges.path))
        try FileManager.default.removeItem(at: localChanges)
        try fixture.coordinator.retryCleanup(taskID: release.id)
        await fixture.waitUntil("the release cleans up") { fixture.record(release.id)?.cleanup?.finishedAt != nil }
        #expect(FileManager.default.fileExists(atPath: releaseWorktree.path) == false)
        #expect(fixture.store.state.workspacesByID[try #require(fixture.record(release.id)?.taskSpaceWorkspaceID)] == nil)
        await fixture.coordinator.checkReleases()
        #expect(fixture.record(unreported.id)?.shippedAt == nil)
    }

    @Test func anOldTagOnlyReleaseRecordDoesNotAuthorizeCleanup() async throws {
        let fixture = try Fixture()
        let tip = try fixture.repository.pushToRemote("release work")
        _ = try releasingProject(fixture, mergeCommit: tip)
        let release = try fixture.coordinator.release(workspaceID: fixture.workspaceID, caller: .unmanaged)
        await fixture.waitUntil("release setup ends") { fixture.record(release.id)?.setup != .settingUp }
        let started = try #require(fixture.record(release.id))
        let worktree = try #require(started.worktree)
        fixture.sessions.report(try #require(started.currentSessionID), .ready)
        try fixture.coordinator.records.save(id: release.id) {
            $0.shippedAt = Date()
            $0.releaseTag = "v1.0"
        }
        await fixture.coordinator.checkReleases()
        #expect(fixture.coordinator.cleanupTasks[release.id] == nil)
        #expect(fixture.record(release.id)?.cleanup == nil)
        #expect(FileManager.default.fileExists(atPath: worktree.path))
        #expect(fixture.store.state.workspacesByID[try #require(started.taskSpaceWorkspaceID)] != nil)
    }

    @Test func keepingAReleaseDuringRetryPreservesItsSpaceAndWorktree() async throws {
        let fixture = try Fixture()
        let tip = try fixture.repository.pushToRemote("release work")
        _ = try releasingProject(fixture, mergeCommit: tip)
        let release = try fixture.coordinator.release(workspaceID: fixture.workspaceID, caller: .unmanaged)
        await fixture.waitUntil("release setup ends") { fixture.record(release.id)?.setup != .settingUp }
        let started = try #require(fixture.record(release.id))
        let worktree = try #require(started.worktree)
        fixture.sessions.report(try #require(started.currentSessionID), .ready)
        try fixture.coordinator.records.save(id: release.id) {
            $0.shippedAt = Date()
            $0.release?.completion = .init(reportedAt: Date(), tags: [.init(tag: "v1.0", taskIDs: [])])
            $0.cleanup = TaskCleanup(kind: .release, problem: "Previous cleanup stopped.")
        }
        let git = PausedReleaseStatus()
        fixture.replaceCoordinator(fixture.makeCoordinator(
            records: fixture.coordinator.records,
            worktreeCreator: TaskWorktreeCreator(runner: git, environment: { TaskGitTestRepository.environment })
        ))
        try fixture.coordinator.retryCleanup(taskID: release.id)
        await fixture.waitUntil("cleanup waits on git status") { git.statusCheck != nil }
        let check = try #require(git.statusCheck)
        do {
            defer { check.resume() }
            try fixture.coordinator.dismissCleanup(taskID: release.id)
        }
        await fixture.waitUntil("the retry exits") { fixture.coordinator.cleanupTasks[release.id] == nil }
        #expect(fixture.record(release.id)?.cleanup?.stepsDone == ["left the rest as it was"])
        #expect(FileManager.default.fileExists(atPath: worktree.path))
        #expect(fixture.store.state.workspacesByID[try #require(started.taskSpaceWorkspaceID)] != nil)
    }

    @MainActor
    private final class PausedReleaseStatus: TaskCommandRunning {
        var statusCheck: CheckedContinuation<Void, Never>?

        func run(_ command: TaskCommand) async -> TaskCommandResult {
            if command.arguments.suffix(2).elementsEqual(["status", "--porcelain"]) {
                await withCheckedContinuation { statusCheck = $0 }
                statusCheck = nil
            }
            return await TaskLiveCommandRunner().run(command)
        }
    }
}
