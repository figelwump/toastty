import CoreState
import Foundation

/// What an archive would lose or end, read before it changes anything.
struct TaskArchiveCheck: Equatable {
    var hasWorktree: Bool
    var detached: Bool
    var branch: String?
    /// Files `git status` lists in the worktree: changed, staged or untracked.
    var uncommittedFiles: Int
    /// Commits on the task's branch that no remote branch has. The branch
    /// is kept while there are any.
    var unpushedCommits: Int
    /// Commits at the worktree's HEAD that no branch, remote branch or tag
    /// has: work that removing the worktree would lose, such as commits on
    /// a detached HEAD.
    var orphanedCommits: Int = 0
    var pullRequest: WorkspacePullRequestLink?
    /// Agent sessions closing the task space ends.
    var agentSessions: Int
    var unsavedDocuments: Int
}

extension TaskCoordinator {
    /// How long closed sessions get to stop writing before the worktree is
    /// checked again, as the pull request script waits.
    static let closeGracePeriod: Duration = .seconds(2)

    // MARK: - Archive

    /// Reads what archiving the task would end and what it would lose.
    func archiveCheck(taskID: UUID) async throws -> TaskArchiveCheck {
        guard let record = records.record(id: taskID) else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        let taskSpace = record.taskSpaceWorkspaceID.flatMap { store.state.workspacesByID[$0] }
        var check = TaskArchiveCheck(
            hasWorktree: false,
            detached: false,
            branch: nil,
            uncommittedFiles: 0,
            unpushedCommits: 0,
            pullRequest: taskSpace.flatMap(TaskBoard.pullRequestLink) ?? WorkspacePullRequestLink(annotationURL: record.pullRequestURL),
            agentSessions: taskSpace.map { sessions?.activeSessions(workspaceID: $0.id).count ?? 0 } ?? 0,
            unsavedDocuments: taskSpace.map { unsavedDocumentCount($0.id) } ?? 0
        )
        if let worktree = record.worktree, isDirectory(worktree.path) {
            check.hasWorktree = true
            check.detached = worktree.isDetached
            check.uncommittedFiles = try await uncommittedFileCount(in: worktree.path)
            check.orphanedCommits = try await orphanedCommitCount(in: worktree.path)
        }
        if let worktree = record.worktree, worktree.isDetached == false,
           let head = try await branchHead(worktree.branch, in: worktree.checkoutRoot) {
            check.branch = worktree.branch
            check.unpushedCommits = try await unpushedCommitCount(head, in: worktree.checkoutRoot)
        }
        return check
    }

    /// `task.archive`: closes the task without merging. It closes the task
    /// space and removes a clean worktree; a branch whose commits are all
    /// on the remote is deleted locally and kept there, and one with
    /// unpushed commits is kept unless the user chose to delete it. It
    /// closes the pull request only when asked. The checks run first and
    /// refuse with a reason; the steps then run in the background, each
    /// saved as it finishes, and running it again continues them.
    @discardableResult
    func archive(taskID: UUID, options: TaskArchiveOptions) async throws -> TaskRecord {
        guard let record = records.record(id: taskID) else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        if record.archivedAt != nil, record.cleanup?.kind == .archive, record.cleanup?.finishedAt != nil {
            return record
        }
        if let taskSpaceID = record.taskSpaceWorkspaceID, let request = merges?.request(workspaceID: taskSpaceID) {
            switch request.phase {
            case .failed:
                break
            case .awaitingChecks:
                throw TaskError("Toastty is waiting to merge \(record.title). Cancel the merge first.")
            case .merging, .awaitingMerge, .cleaningUp, .closing:
                throw TaskError("\(record.title) is merging or cleaning up now.")
            }
        }
        if record.operation.worktree?.added == false, setupTasks[taskID] != nil || startWorkTasks[taskID] != nil {
            throw TaskError("Toastty is making the worktree of \(record.title). Try again when it is done.")
        }
        let check = try await archiveCheck(taskID: taskID)
        if let problem = Self.archiveRefusal(check, options: options) {
            throw TaskError(problem)
        }
        // The git checks awaited; a merge may have started meanwhile. From
        // here to the saved archive nothing awaits, and a merge refuses an
        // archived task.
        if let taskSpaceID = record.taskSpaceWorkspaceID, let request = merges?.request(workspaceID: taskSpaceID) {
            if case .failed = request.phase {} else {
                throw TaskError("\(record.title) started merging. Cancel the merge first.")
            }
        }
        // Nothing that started before the archive may make more of the task.
        setupAttempts[taskID] = nil
        setupTasks.removeValue(forKey: taskID)?.cancel()
        startWorkAttempts[taskID] = nil
        startWorkTasks.removeValue(forKey: taskID)?.cancel()
        mergeDeliveryTasks.removeValue(forKey: taskID)?.cancel()
        try saveMergeState(taskID: taskID) {
            $0.archivedAt = $0.archivedAt ?? self.now()
            $0.mergeRequestedAt = nil
        }
        startTeardown(taskID: taskID, kind: .archive, options: options)
        ToasttyLog.info("Archiving a task", category: .tasks, metadata: [
            "task_id": taskID.uuidString,
            "close_pull_request": String(options.closePullRequest),
        ])
        return records.record(id: taskID) ?? record
    }

    /// Why the archive must not start without another choice from the user.
    static func archiveRefusal(_ check: TaskArchiveCheck, options: TaskArchiveOptions) -> String? {
        if check.unsavedDocuments > 0 {
            return "The task space has unsaved documents. Save or close them, then archive."
        }
        if check.uncommittedFiles > 0, options.discardChanges == false {
            return "The worktree has \(check.uncommittedFiles) uncommitted \(check.uncommittedFiles == 1 ? "file" : "files"). Commit and push them, or archive with discardChanges."
        }
        if check.orphanedCommits > 0, options.deleteUnpushedCommits == false {
            return "The worktree's HEAD has \(check.orphanedCommits) \(check.orphanedCommits == 1 ? "commit" : "commits") on no branch, remote branch or tag. Push or branch them, or archive with deleteUnpushedCommits."
        }
        return nil
    }

    func lastArchiveOptions(_ record: TaskRecord) -> TaskArchiveOptions {
        record.cleanup?.archiveOptions ?? TaskArchiveOptions()
    }

    // MARK: - Teardown

    /// Runs the steps that close a task in the background: an archive, or
    /// the cleanup after a release shipped.
    func startTeardown(taskID: UUID, kind: TaskCleanup.Kind, options: TaskArchiveOptions) {
        guard cleanupTasks[taskID] == nil else { return }
        cleanupTasks[taskID] = Task { [weak self] in
            await self?.runTeardown(taskID: taskID, kind: kind, options: options)
            self?.cleanupTasks[taskID] = nil
        }
    }

    /// Each step checks what is still there, so a second run skips what the
    /// first finished. The first refusal stops the run and is saved as the
    /// cleanup's problem.
    private func runTeardown(taskID: UUID, kind: TaskCleanup.Kind, options: TaskArchiveOptions) async {
        guard let record = records.record(id: taskID) else { return }
        var cleanup = record.cleanup?.kind == kind ? record.cleanup! : TaskCleanup(kind: kind)
        cleanup.problem = nil
        cleanup.finishedAt = nil
        if kind == .archive {
            cleanup.archiveOptions = options
        }
        func save() {
            let snapshot = cleanup
            records.update(id: taskID) { $0.cleanup = snapshot }
        }
        func finish(_ step: String) {
            cleanup.stepsDone.append(step)
            save()
        }
        func stop(_ reason: String) {
            cleanup.problem = reason
            save()
            ToasttyLog.warning("A task's cleanup stopped", category: .tasks, metadata: [
                "task_id": taskID.uuidString,
                "kind": kind.rawValue,
                "reason": reason,
            ])
        }
        save()

        // 1. The pull request, only when the user chose to close it.
        let closedPullRequestStep = "closed the pull request"
        if kind == .archive, options.closePullRequest, cleanup.stepsDone.contains(closedPullRequestStep) == false,
           let link = (record.taskSpaceWorkspaceID.flatMap { store.state.workspacesByID[$0] }.flatMap(TaskBoard.pullRequestLink))
            ?? WorkspacePullRequestLink(annotationURL: record.pullRequestURL) {
            do {
                try await closePullRequest(link)
                finish(closedPullRequestStep)
            } catch {
                return stop(error.localizedDescription)
            }
        }

        // 2. The task space. Closing it ends its sessions and commands.
        if let taskSpaceID = record.taskSpaceWorkspaceID, store.state.workspacesByID[taskSpaceID] != nil {
            if unsavedDocumentCount(taskSpaceID) > 0 {
                return stop("The task space has unsaved documents. Save or close them, then try again.")
            }
            if kind == .release, agentInTurn(workspaceID: taskSpaceID) {
                return stop("The release shipped while its agent was working, so Toastty left the task space open.")
            }
            let hadSessions = (sessions?.activeSessions(workspaceID: taskSpaceID).isEmpty == false)
            guard store.send(.closeWorkspace(workspaceID: taskSpaceID)) else {
                return stop("Toastty could not close the task space.")
            }
            flushLayout()
            finish("closed the task space")
            if hadSessions {
                try? await Task.sleep(for: Self.closeGracePeriod)
            }
        }

        // 3. The worktree, checked again now that nothing writes to it.
        if let worktree = record.worktree, isDirectory(worktree.path) {
            do {
                let uncommitted = try await uncommittedFileCount(in: worktree.path)
                if uncommitted > 0, options.discardChanges == false {
                    return stop("The worktree has \(uncommitted) uncommitted \(uncommitted == 1 ? "file" : "files"), so Toastty kept it at \(worktree.path).")
                }
                // HEAD may have left the branch since the checks, so read it
                // again: commits that only this worktree holds stay unless
                // the user chose to delete them.
                let orphaned = try await orphanedCommitCount(in: worktree.path)
                if orphaned > 0, options.deleteUnpushedCommits == false {
                    return stop("The worktree's HEAD has commits on no branch, remote branch or tag, so Toastty kept it at \(worktree.path).")
                }
                var arguments = ["worktree", "remove"]
                if uncommitted > 0 { arguments.append("--force") }
                arguments.append(worktree.path)
                try await worktreeCreator.git(arguments, in: worktree.checkoutRoot)
                finish("removed the worktree")
            } catch {
                return stop(error.localizedDescription)
            }
        }

        // 4. The local branch. The remote branch always stays.
        if let worktree = record.worktree, worktree.isDetached == false {
            do {
                // One read of the branch's commit, which the checks and the
                // delete then use, so a commit added in between is never
                // deleted unchecked.
                if let head = try await branchHead(worktree.branch, in: worktree.checkoutRoot) {
                    let unpushed = try await unpushedCommitCount(head, in: worktree.checkoutRoot)
                    if try await isCheckedOut(worktree.branch, in: worktree.checkoutRoot) {
                        finish("kept the branch \(worktree.branch): another worktree has it checked out")
                    } else if unpushed > 0, options.deleteUnpushedCommits == false {
                        finish("kept the branch \(worktree.branch): \(unpushed) \(unpushed == 1 ? "commit is" : "commits are") on no remote branch")
                    } else {
                        // Compare-and-delete: the branch goes only if it is
                        // still at the commit checked above.
                        try await worktreeCreator.git(["update-ref", "-d", "refs/heads/\(worktree.branch)", head], in: worktree.checkoutRoot)
                        finish("deleted the local branch \(worktree.branch)")
                    }
                }
            } catch {
                return stop(error.localizedDescription)
            }
        }

        cleanup.finishedAt = now()
        save()
        ToasttyLog.info("Finished a task's cleanup", category: .tasks, metadata: [
            "task_id": taskID.uuidString,
            "kind": kind.rawValue,
        ])
    }

    // MARK: - Git

    private func uncommittedFileCount(in path: String) async throws -> Int {
        try await worktreeCreator.git(["status", "--porcelain"], in: path).output
            .split(whereSeparator: \.isNewline).count
    }

    /// Commits reachable from `commit` that no remote branch has.
    private func unpushedCommitCount(_ commit: String, in directory: String) async throws -> Int {
        let output = try await worktreeCreator.git(["rev-list", "--count", commit, "--not", "--remotes"], in: directory).output
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Commits at the worktree's HEAD that no local branch, remote branch
    /// or tag has.
    private func orphanedCommitCount(in path: String) async throws -> Int {
        let output = try await worktreeCreator.git(
            ["rev-list", "--count", "HEAD", "--not", "--branches", "--remotes", "--tags"],
            in: path
        ).output
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// The branch's commit, or `nil` when there is no such branch.
    private func branchHead(_ branch: String, in directory: String) async throws -> String? {
        let result = try await worktreeCreator.git(
            ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"],
            in: directory,
            allowFailure: true
        )
        let head = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && head.isEmpty == false ? head : nil
    }

    private func isCheckedOut(_ branch: String, in directory: String) async throws -> Bool {
        try await worktreeCreator.git(["worktree", "list", "--porcelain"], in: directory).output
            .split(whereSeparator: \.isNewline)
            .contains { $0 == "branch refs/heads/\(branch)" }
    }

    /// Closes an open pull request with `gh`; a closed or merged one stays.
    private func closePullRequest(_ link: WorkspacePullRequestLink) async throws {
        let view = await gitHub(["pr", "view", link.url, "--json", "state", "--jq", ".state"])
        guard view.succeeded else {
            throw TaskError("Toastty could not read \(link.displayName) with gh: \(view.summary)")
        }
        guard view.output.trimmingCharacters(in: .whitespacesAndNewlines) == "OPEN" else { return }
        let closed = await gitHub(["pr", "close", link.url])
        guard closed.succeeded else {
            throw TaskError("Toastty could not close \(link.displayName): \(closed.summary)")
        }
    }

    private func gitHub(_ arguments: [String]) async -> TaskWorktreeCreator.GitResult {
        var environment = worktreeCreator.environment()
        environment["GH_PROMPT_DISABLED"] = "1"
        let result = await worktreeCreator.runner.run(TaskCommand(
            executablePath: "/usr/bin/env",
            arguments: ["gh"] + arguments,
            directory: homeDirectoryPath,
            environment: environment,
            timeout: 30
        ))
        let lastLine = result.stderrText.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        switch result.termination {
        case .exited(0):
            return .init(succeeded: true, output: result.stdoutText, summary: "")
        case .exited(let status):
            return .init(succeeded: false, output: result.stdoutText, summary: lastLine.isEmpty ? "exit status \(status)" : lastLine)
        case .timedOut:
            return .init(succeeded: false, output: "", summary: "gh did not answer within 30 seconds")
        case .signaled, .cancelled:
            return .init(succeeded: false, output: "", summary: "gh stopped")
        case .launchFailed(let message):
            return .init(succeeded: false, output: "", summary: message)
        }
    }
}
