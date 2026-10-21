import CoreState
import Foundation

/// How a Merge from the UI is carried out.
enum TaskMergeRoute: Equatable {
    /// The task's agent gets `merge_prompt`, checks the pull request with
    /// its merge skill, and calls `task.merge`.
    case agent
    /// Toastty merges at once: "Merge Without Checks", or `merge = "direct"`.
    case direct
}

extension TaskCoordinator {
    static let defaultMergePrompt = "Use toastty-task-merge."
    /// How long a merge prompt waits for a busy agent to finish its turn.
    static let mergePromptTurnTimeout: Duration = .seconds(30 * 60)

    /// The task space, pull request and checkout a merge acts on.
    struct MergeTarget {
        var taskSpaceID: UUID
        var pullRequest: WorkspacePullRequestLink
        var repoPath: String
    }

    // MARK: - Merge

    /// `task.merge`: what the merge skill calls once its checks pass. It
    /// records the user's acceptance and hands the merge to the merge
    /// coordinator, which merges at the checkout's commit, waits for
    /// GitHub's checks if they still run, and cleans up after the agent's
    /// turn ends. Returns at once. With `expectedHead`, the merge is
    /// refused unless the checkout is still at the commit the skill checked.
    @discardableResult
    func merge(taskID: UUID, expectedHead: String?, caller: TaskCaller) throws -> TaskRecord {
        guard let record = records.record(id: taskID) else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        if let expectedHead {
            guard (7...64).contains(expectedHead.count), expectedHead.allSatisfy(\.isHexDigit) else {
                throw TaskError("head must be a commit ID.")
            }
        }
        let target = try mergeTarget(record)
        try checkNotCancelled(record, caller: caller)
        return try startMerge(record, target: target, expectedHead: expectedHead)
    }

    /// Merge from the UI: the top bar's button and its shortcut, the
    /// sidebar's menu, and the Tasks view. With the agent route, the
    /// task's agent gets the merge prompt and decides; `nil` takes the
    /// route from tasks.toml.
    func requestMerge(taskID: UUID, route requestedRoute: TaskMergeRoute? = nil) throws {
        guard let record = records.record(id: taskID) else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        let target = try mergeTarget(record)
        let config = try? configLoader()
        let workspaceConfig = record.projectRoot.flatMap { config?.workspace(forProjectRoot: $0, homeDirectoryPath: homeDirectoryPath) }
        let mode = workspaceConfig?.merge ?? config?.defaults.merge ?? .agent
        let route = requestedRoute ?? (mode == .direct ? .direct : .agent)
        if route == .direct {
            try startMerge(record, target: target, expectedHead: nil)
            return
        }
        let mergePrompt = workspaceConfig?.mergePrompt ?? config?.defaults.mergePrompt ?? Self.defaultMergePrompt
        let prompt = "\(mergePrompt)\n\nThe user accepted \(target.pullRequest.url) for merging."
        let requestedAt = now()
        try saveMergeState(taskID: taskID) {
            $0.mergeRequestedAt = requestedAt
            $0.mergeCancelledAt = nil
        }
        mergeDeliveryTasks.removeValue(forKey: taskID)?.cancel()
        do {
            try deliverMergePrompt(prompt, taskID: taskID, target: target, requestedAt: requestedAt)
        } catch {
            try? saveMergeState(taskID: taskID) { $0.mergeRequestedAt = nil }
            throw error
        }
        ToasttyLog.info("Asked a task's agent to merge", category: .tasks, metadata: [
            "task_id": taskID.uuidString,
            "pull_request": String(target.pullRequest.number),
        ])
    }

    /// Stops a merge the user accepted: the agent's check, or Toastty's
    /// wait for GitHub's checks. Clearing the done mark ends the wait; the
    /// pull request script also refuses a waiting merge without it. A
    /// `task.merge` from the turn that was checking is refused after this.
    func cancelMerge(taskID: UUID) throws {
        guard let record = records.record(id: taskID) else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        let taskSpaceID = record.taskSpaceWorkspaceID
        let request = taskSpaceID.flatMap { merges?.request(workspaceID: $0) }
        guard record.mergeRequestedAt != nil || request != nil else {
            throw TaskError("No merge of task \(record.title) is under way.")
        }
        if let taskSpaceID, merges?.isScriptRunning(workspaceID: taskSpaceID) == true {
            throw TaskError("Toastty is merging the pull request right now, so the merge cannot be cancelled.")
        }
        switch request?.phase {
        case .awaitingMerge?, .cleaningUp?:
            throw TaskError("The pull request has merged.")
        case .merging?, .closing?:
            throw TaskError("Toastty is merging the pull request right now, so the merge cannot be cancelled.")
        case .awaitingChecks?, .failed?, nil:
            break
        }
        mergeDeliveryTasks.removeValue(forKey: taskID)?.cancel()
        try saveMergeState(taskID: taskID) {
            $0.mergeRequestedAt = nil
            $0.mergeCancelledAt = self.now()
        }
        if let taskSpaceID, store.state.workspacesByID[taskSpaceID]?.doneAt != nil {
            _ = store.send(.setWorkspaceDone(workspaceID: taskSpaceID, doneAt: nil))
        }
        ToasttyLog.info("Cancelled a task's merge", category: .tasks, metadata: ["task_id": taskID.uuidString])
    }

    // MARK: - Done without a merge

    /// `task.ready-for-review`: the agent's work has no pull request and is
    /// ready for the user to look at.
    @discardableResult
    func readyForReview(taskID: UUID) throws -> TaskRecord {
        guard records.record(id: taskID) != nil else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        try saveMergeState(taskID: taskID) { $0.readyForReviewAt = self.now() }
        return records.record(id: taskID)!
    }

    /// `task.mark-done`: the user finished the task by hand. The task space
    /// gets the done mark too, which new work clears again.
    @discardableResult
    func markDone(taskID: UUID) throws -> TaskRecord {
        guard let record = records.record(id: taskID) else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        guard record.archivedAt == nil else {
            throw TaskError("Task \(record.title) is archived.")
        }
        let doneAt = now()
        try saveMergeState(taskID: taskID) { $0.doneAt = doneAt }
        if let taskSpaceID = record.taskSpaceWorkspaceID, store.state.workspacesByID[taskSpaceID] != nil {
            _ = store.send(.setWorkspaceDone(workspaceID: taskSpaceID, doneAt: doneAt))
        }
        return records.record(id: taskID)!
    }

    // MARK: - Cleanup after a merge

    /// What the merge coordinator reports about a task space's cleanup.
    func mergeCleanupEvent(workspaceID: UUID, event: WorkspaceMergeCoordinator.CleanupEvent) {
        guard let record = records.record(taskSpaceWorkspaceID: workspaceID) else { return }
        switch event {
        case .merged(let state):
            // Saved before anything closes, so the task keeps its merge if
            // the cleanup or the app stops partway.
            do {
                try records.save(id: record.id) {
                    $0.mergedAt = $0.mergedAt ?? self.now()
                    $0.mergeCommit = state?.mergeCommit ?? $0.mergeCommit
                    $0.mergeRequestedAt = $0.mergeRequestedAt ?? self.now()
                    $0.cleanup = TaskCleanup(kind: .merge)
                }
                try records.flush()
            } catch {
                ToasttyLog.warning("Could not save a task's merge before its cleanup", category: .tasks, metadata: [
                    "task_id": record.id.uuidString,
                    "error": error.localizedDescription,
                ])
            }
        case .cleaned(let detail):
            records.update(id: record.id) {
                $0.cleanup = TaskCleanup(kind: .merge, stepsDone: [detail], finishedAt: self.now())
            }
        case .stopped(let reason):
            // While the task space is open, the coordinator's stopped
            // request shows the reason and offers the retry. After it
            // closed, only the record can.
            guard store.state.workspacesByID[workspaceID] == nil else { return }
            records.update(id: record.id) {
                var cleanup = $0.cleanup ?? TaskCleanup(kind: .merge)
                cleanup.problem = reason
                $0.cleanup = cleanup
            }
        case .dropped:
            // The user kept the task space (Don't Clean Up), or new work
            // started there after the merge. Either way the cleanup is over,
            // so a later answer from GitHub does not start it again; Archive
            // still closes the task.
            guard var cleanup = record.cleanup, cleanup.kind == .merge, cleanup.finishedAt == nil else { return }
            cleanup.stepsDone.append("left the task space open")
            cleanup.problem = nil
            cleanup.finishedAt = now()
            let finished = cleanup
            records.update(id: record.id) { $0.cleanup = finished }
        }
    }

    /// Cleans up the task spaces whose pull request merged on GitHub, which
    /// counts as the user's acceptance. Only when nothing is in the way:
    /// the task has a worktree on its own branch, no merge or cleanup ran
    /// for it, and no agent there is in a turn. The pull request script
    /// then checks that the worktree is clean at the merged head. A task
    /// whose agent was working gets "Merged · clean up?" instead.
    func cleanUpMergedTasks(_ taskIDs: [UUID]) {
        guard let merges else { return }
        for taskID in taskIDs {
            guard let record = records.record(id: taskID),
                  record.archivedAt == nil,
                  record.release == nil,
                  record.cleanup == nil,
                  let worktree = record.worktree, worktree.isDetached == false,
                  let taskSpaceID = record.taskSpaceWorkspaceID,
                  store.state.workspacesByID[taskSpaceID] != nil,
                  merges.request(workspaceID: taskSpaceID) == nil,
                  let target = try? mergeTarget(record, afterMerge: true) else { continue }
            if agentInTurn(workspaceID: taskSpaceID) {
                records.update(id: taskID) {
                    $0.cleanup = TaskCleanup(
                        kind: .merge,
                        problem: "The pull request merged while the agent was working, so Toastty left the task space open."
                    )
                }
                continue
            }
            records.update(id: taskID) { $0.cleanup = TaskCleanup(kind: .merge) }
            merges.cleanUpAfterMerge(workspaceID: taskSpaceID, pullRequest: target.pullRequest, repoPath: target.repoPath)
            ToasttyLog.info("Cleaning up a task merged on GitHub", category: .tasks, metadata: ["task_id": taskID.uuidString])
        }
    }

    /// "Clean up": tries a stopped cleanup again.
    func retryCleanup(taskID: UUID) throws {
        guard let record = records.record(id: taskID) else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        if let taskSpaceID = record.taskSpaceWorkspaceID,
           case .failed? = merges?.request(workspaceID: taskSpaceID)?.phase {
            merges?.retryCleanup(workspaceID: taskSpaceID)
            return
        }
        guard let cleanup = record.cleanup, cleanup.problem != nil else {
            throw TaskError("Task \(record.title) has no stopped cleanup.")
        }
        switch cleanup.kind {
        case .merge:
            guard let taskSpaceID = record.taskSpaceWorkspaceID, store.state.workspacesByID[taskSpaceID] != nil else {
                throw TaskError("The task space is closed. Remove what is left of the worktree by hand, then choose Keep As Is.")
            }
            guard agentInTurn(workspaceID: taskSpaceID) == false else {
                throw TaskError("The agent is still working. Clean up once its turn ends.")
            }
            try saveMergeState(taskID: taskID) { $0.cleanup = nil }
            cleanUpMergedTasks([taskID])
        case .archive, .release:
            startTeardown(taskID: taskID, kind: cleanup.kind, options: cleanup.kind == .archive ? lastArchiveOptions(record) : TaskArchiveOptions())
        }
    }

    /// "Keep As Is": the user leaves what a stopped cleanup left behind.
    /// The cleanup counts as finished, so a later answer from GitHub does
    /// not start it again.
    func dismissCleanup(taskID: UUID) throws {
        guard let record = records.record(id: taskID) else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        if let taskSpaceID = record.taskSpaceWorkspaceID,
           case .failed? = merges?.request(workspaceID: taskSpaceID)?.phase {
            // The drop event marks the merge's cleanup finished.
            merges?.cancelCleanup(workspaceID: taskSpaceID)
            if records.record(id: taskID)?.cleanup == nil {
                try saveMergeState(taskID: taskID) {
                    $0.cleanup = TaskCleanup(kind: .merge, stepsDone: ["left the task space open"], finishedAt: self.now())
                }
            }
            return
        }
        guard var cleanup = record.cleanup, cleanup.problem != nil else {
            throw TaskError("Task \(record.title) has no stopped cleanup.")
        }
        cleanup.stepsDone.append("left the rest as it was")
        cleanup.problem = nil
        cleanup.finishedAt = now()
        let finished = cleanup
        try saveMergeState(taskID: taskID) { $0.cleanup = finished }
    }

    // MARK: - Helpers

    /// `afterMerge` is for the cleanup that follows a merge made on GitHub.
    func mergeTarget(_ record: TaskRecord, afterMerge: Bool = false) throws -> MergeTarget {
        guard record.archivedAt == nil else {
            throw TaskError("Task \(record.title) is archived.")
        }
        guard afterMerge || record.mergedAt == nil else {
            throw TaskError("Task \(record.title) has merged.")
        }
        guard let taskSpaceID = record.taskSpaceWorkspaceID,
              let workspace = store.state.workspacesByID[taskSpaceID] else {
            throw TaskError("The task space of \(record.title) is closed.")
        }
        guard let pullRequest = TaskBoard.pullRequestLink(workspace)
            ?? WorkspacePullRequestLink(annotationURL: record.pullRequestURL) else {
            throw TaskError("Task \(record.title) has no pull request. Its task space needs a github-pr annotation with the pull request URL.")
        }
        let repoPath: String
        if let worktree = record.worktree, isDirectory(worktree.path) {
            repoPath = worktree.path
        } else if let directory = Self.firstTerminalDirectory(in: workspace, fileManager: fileManager) {
            repoPath = directory
        } else {
            throw TaskError("Toastty could not find the checkout of \(record.title).")
        }
        return MergeTarget(taskSpaceID: taskSpaceID, pullRequest: pullRequest, repoPath: repoPath)
    }

    /// Whether any agent in the workspace is working or waiting for an
    /// approval.
    func agentInTurn(workspaceID: UUID) -> Bool {
        sessions?.activeSessions(workspaceID: workspaceID).contains { $0.isInTurn } ?? false
    }

    @discardableResult
    private func startMerge(_ record: TaskRecord, target: MergeTarget, expectedHead: String?) throws -> TaskRecord {
        guard let merges else {
            throw TaskError("Merging is not available in this Toastty instance.")
        }
        if let request = merges.request(workspaceID: target.taskSpaceID) {
            switch request.phase {
            case .failed:
                break
            case .merging, .awaitingChecks, .awaitingMerge, .cleaningUp, .closing:
                throw TaskError("A merge of \(record.title) is already under way.")
            }
        }
        mergeDeliveryTasks.removeValue(forKey: record.id)?.cancel()
        try saveMergeState(taskID: record.id) {
            $0.mergeRequestedAt = $0.mergeRequestedAt ?? self.now()
            $0.mergeCancelledAt = nil
        }
        guard merges.merge(
            workspaceID: target.taskSpaceID,
            pullRequest: target.pullRequest,
            repoPath: target.repoPath,
            thenCleanUp: true,
            expectedHead: expectedHead
        ) != nil else {
            throw TaskError("A merge of \(record.title) is already under way.")
        }
        ToasttyLog.info("Merging a task", category: .tasks, metadata: [
            "task_id": record.id.uuidString,
            "pull_request": String(target.pullRequest.number),
            "expected_head": expectedHead ?? "",
        ])
        return records.record(id: record.id) ?? record
    }

    /// A cancelled merge stays cancelled for every agent turn that started
    /// before the cancel: the task's own agent that was checking it, and a
    /// coordinating task merging its children. A turn that started after
    /// the cancel, such as the user saying "merge it", may merge. A caller
    /// outside Toastty has no turn and is not held back.
    private func checkNotCancelled(_ record: TaskRecord, caller: TaskCaller) throws {
        guard let cancelledAt = record.mergeCancelledAt, let callerSessionID = caller.sessionID else { return }
        if let turnStartedAt = sessions?.session(callerSessionID)?.turnStartedAt, turnStartedAt > cancelledAt {
            return
        }
        throw TaskError("The user cancelled this merge. Do not merge unless the user asks again.")
    }

    /// Sends the merge prompt to the task's agent once it is at rest, or
    /// starts an agent for it when none runs. A busy agent finishes its
    /// turn first, so the prompt is the next thing it reads.
    private func deliverMergePrompt(_ prompt: String, taskID: UUID, target: MergeTarget, requestedAt: Date) throws {
        guard let record = records.record(id: taskID) else { return }
        if let session = liveAgentSession(of: record) {
            guard session.isInTurn else {
                try send(taskID: taskID, text: prompt)
                return
            }
            mergeDeliveryTasks[taskID] = Task { [weak self] in
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: Self.mergePromptTurnTimeout)
                while Task.isCancelled == false, clock.now < deadline {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, self.records.record(id: taskID)?.mergeRequestedAt == requestedAt else { return }
                    guard let current = self.records.record(id: taskID).flatMap(self.liveAgentSession(of:)) else { break }
                    if current.isInTurn { continue }
                    self.mergeDeliveryTasks[taskID] = nil
                    do {
                        // The request starts when the agent can read it, so
                        // its earlier statuses do not count as a reply.
                        try self.saveMergeState(taskID: taskID) { $0.mergeRequestedAt = self.now() }
                        try self.send(taskID: taskID, text: prompt)
                    } catch {
                        self.mergePromptFailed(taskID: taskID, reason: error.localizedDescription)
                    }
                    return
                }
                guard Task.isCancelled == false else { return }
                self?.mergeDeliveryTasks[taskID] = nil
                self?.mergePromptFailed(taskID: taskID, reason: "the agent did not finish its turn")
            }
            return
        }
        try launchMergeAgent(prompt: prompt, record: record, target: target, requestedAt: requestedAt)
    }

    /// Starts the task's agent in a new terminal tab in its checkout, with
    /// the merge prompt as its first message.
    private func launchMergeAgent(prompt: String, record: TaskRecord, target: MergeTarget, requestedAt: Date) throws {
        guard let launcher else {
            throw TaskError("The agent launcher is not available.")
        }
        let config = try? configLoader()
        guard let profileID = record.resolved?.agent ?? config?.defaults.agent else {
            throw TaskError("No agent runs in the task space, and tasks.toml names no default agent to start.")
        }
        let model = record.resolved?.agent == profileID ? record.resolved?.model : config?.defaults.model
        let effort = record.resolved?.agent == profileID ? record.resolved?.effort : config?.defaults.effort
        guard let panelID = reusablePanel(in: target.taskSpaceID, preferred: UUID(), directory: target.repoPath) else {
            throw TaskError("Toastty could not open a terminal in the task space.")
        }
        let taskID = record.id
        mergeDeliveryTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await Self.launchWhenTerminalIsReady(timeout: self.terminalReadinessTimeout) {
                    try await launcher.launchTask(
                        profileID: profileID,
                        workspaceID: target.taskSpaceID,
                        panelID: panelID,
                        cwd: target.repoPath,
                        model: model,
                        reasoningEffort: effort,
                        initialPrompt: prompt,
                        parentSessionID: nil,
                        forkFromSessionID: nil,
                        scopedWorkspaceIDs: record.creatorScope.map { $0.union([target.taskSpaceID]) },
                        // The launch prepares for a while; a Cancel Merge in
                        // that time stops it before the prompt is typed.
                        beforeDispatch: { [weak self] in
                            guard Task.isCancelled == false,
                                  self?.records.record(id: taskID)?.mergeRequestedAt == requestedAt else {
                                throw CancellationError()
                            }
                        }
                    )
                }
                self.mergeDeliveryTasks[taskID] = nil
            } catch {
                self.mergeDeliveryTasks[taskID] = nil
                if error is CancellationError { return }
                self.mergePromptFailed(taskID: taskID, reason: Self.launchFailureReason(for: error))
            }
        }
    }

    /// The prompt never reached an agent, so nothing checks the merge.
    private func mergePromptFailed(taskID: UUID, reason: String) {
        records.update(id: taskID) { $0.mergeRequestedAt = nil }
        ToasttyLog.warning("A task's merge prompt was not delivered", category: .tasks, metadata: [
            "task_id": taskID.uuidString,
            "reason": reason,
        ])
    }

    func saveMergeState(taskID: UUID, _ body: (inout TaskRecord) -> Void) throws {
        do {
            try records.save(id: taskID, body)
        } catch {
            throw TaskError("Toastty could not save the task: \(error.localizedDescription)")
        }
    }
}
