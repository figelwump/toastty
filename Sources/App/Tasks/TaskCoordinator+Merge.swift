import CoreState
import Foundation

/// How a Merge from the UI is carried out.
enum TaskMergeRoute: Equatable {
    /// The task's agent gets the merge message, from `merge_skill` and
    /// `merge_prompt`, checks the pull request with its merge skill, and
    /// calls `task.merge`.
    case agent
    /// Toastty merges at once: "Merge Without Checks", or `merge = "direct"`.
    case direct
}

extension TaskCoordinator {
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
    /// Only an agent working on the task, or on its parent task, may call
    /// it; see `checkMergeCaller`.
    @discardableResult
    func merge(taskID: UUID, expectedHead: String?, caller: TaskCaller) throws -> TaskRecord {
        try beginMerge(taskID: taskID, expectedHead: expectedHead, caller: caller).record
    }

    /// `merge`, with the pull request script's first answer for this merge.
    private func beginMerge(
        taskID: UUID, expectedHead: String?, caller: TaskCaller
    ) throws -> (record: TaskRecord, answer: Task<WorkspaceMergeCoordinator.MergeAnswer, Never>) {
        guard let record = records.record(id: taskID) else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        try checkMergeCaller(record, caller: caller)
        if let expectedHead {
            guard (7...64).contains(expectedHead.count), expectedHead.allSatisfy(\.isHexDigit) else {
                throw TaskError("head must be a commit ID.")
            }
        }
        let target = try mergeTarget(record)
        try checkNotCancelled(record, caller: caller)
        return try startMerge(record, target: target, expectedHead: expectedHead)
    }

    /// How long `task.merge` from the socket waits for the merge's first
    /// answer. The pull request script usually answers in a few seconds;
    /// the CLI stops reading after 10.
    static let mergeAnswerWait: Duration = .seconds(8)

    /// `task.merge` from the socket: `merge`, then a wait for the pull
    /// request script's first answer for this merge, so that the caller
    /// learns of a refusal before it reports the merge. Throws the reason
    /// when Toastty refused the merge, the merge failed, or the task space
    /// or its pull request link changed meanwhile. Otherwise returns the
    /// task: merged, waiting for checks, or, after `wait`, still merging.
    func mergeAndAwaitAnswer(
        taskID: UUID,
        expectedHead: String?,
        caller: TaskCaller,
        wait: Duration = mergeAnswerWait
    ) async throws -> TaskRecord {
        let (started, answerTask) = try beginMerge(taskID: taskID, expectedHead: expectedHead, caller: caller)
        let answer = await Self.value(of: answerTask, within: wait)
        let record = records.record(id: taskID) ?? started
        switch answer {
        case nil, .merged?, .waitingForChecks?:
            return record
        case .stopped(let reason, .refused)?:
            throw TaskError("Toastty refused to merge \(record.title), and nothing changed: \(reason)")
        case .stopped(let reason, _)?:
            throw TaskError(
                "Toastty could not finish the merge of \(record.title): \(reason). "
                    + "Check the pull request on GitHub before you report or merge again."
            )
        case .replaced?:
            throw TaskError(
                "The merge of \(record.title) ended without an answer: its task space or pull request link changed "
                    + "while Toastty merged. Check the pull request on GitHub before you report or merge again."
            )
        }
    }

    /// The task's value, or `nil` when `limit` passes first. The task runs on.
    private static func value<Value: Sendable>(of task: Task<Value, Never>, within limit: Duration) async -> Value? {
        let answered = FirstAnswer()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            let timer = Task { @MainActor in
                try? await Task.sleep(for: limit)
                guard answered.claim() else { return }
                continuation.resume(returning: nil)
            }
            Task { @MainActor in
                let value = await task.value
                guard answered.claim() else { return }
                timer.cancel()
                continuation.resume(returning: value)
            }
        }
    }

    /// `task.request-merge`: the user's acceptance given outside the task,
    /// for example through an outside coordinator. It is allowed where the
    /// Merge button is offered, and it always goes through the task's agent,
    /// so the agent's checks run even in a project with `merge = "direct"`.
    func requestMergeFromOutside(taskID: UUID) throws {
        guard let record = records.record(id: taskID) else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        guard let item = board?.items().first(where: { $0.taskID == taskID }) else {
            throw TaskError("Toastty has not read the state of \(record.title) yet. Try again.")
        }
        guard TaskBoardPresentation.detailActions(item).contains(.merge) else {
            let reason = item.pullRequest == nil
                ? "it has no pull request"
                : TaskBoardPresentation.statusLine(item)
            throw TaskError("Merge is not available for \(record.title) now: \(reason).")
        }
        try requestMerge(taskID: taskID, route: .agent)
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
            _ = try startMerge(record, target: target, expectedHead: nil)
            return
        }
        let mergeSkill = workspaceConfig?.mergeSkill ?? config?.defaults.mergeSkill
        let mergePrompt = workspaceConfig?.mergePrompt ?? config?.defaults.mergePrompt
        let prompt = MergePrompt(
            text: TaskPrompt.merge(skill: mergeSkill, prompt: mergePrompt, pullRequestURL: target.pullRequest.url),
            withoutSkills: TaskPrompt.merge(
                skill: mergeSkill,
                prompt: mergePrompt,
                pullRequestURL: target.pullRequest.url,
                skills: Self.skillsMissing()
            )
        )
        let requestedAt = now()
        try saveMergeState(taskID: taskID) {
            $0.mergeRequestedAt = requestedAt
            $0.mergeCancelledAt = nil
            $0.mergeFailure = nil
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
    /// wait for GitHub's checks. The wait ends here, and the done mark goes
    /// too; the pull request script also refuses a waiting merge without
    /// it. A `task.merge` from the turn that was checking is refused after
    /// this.
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
        case .awaitingMerge?, .holdingCleanup?, .cleaningUp?:
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
        // Before the done mark clears, so the wait does not end as a merge
        // that stopped.
        if let taskSpaceID {
            merges?.cancelWaitingMerge(workspaceID: taskSpaceID)
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
        // The latest mark wins: work marked ready no longer waits for a
        // reply, or on anything outside Toastty.
        try saveMergeState(taskID: taskID) {
            $0.readyForReviewAt = self.now()
            $0.replyRequest = nil
            $0.waiting = nil
        }
        return records.record(id: taskID)!
    }

    /// `task.waiting`: the agent ends its turn to wait on something outside
    /// Toastty, such as an email reply or a date. The task rests in Idle
    /// with `reason`, and a parent does not finish through its children.
    /// At `wakeAt`, Toastty sends the agent one line to go on. A new mark
    /// replaces the old one, and, as the latest mark, ends a ready mark:
    /// the work is not ready while it still waits.
    @discardableResult
    func setWaiting(taskID: UUID, reason: String, wakeAt: Date?) throws -> TaskRecord {
        guard let record = records.record(id: taskID) else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        guard record.archivedAt == nil else {
            throw TaskError("Task \(record.title) is archived.")
        }
        // One line: the row shows it, and the wake's line repeats it.
        let reason = reason.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard let reason = taskNonEmpty(reason) else {
            throw TaskError("Say what the task waits for.")
        }
        let since = now()
        if let wakeAt, wakeAt <= since {
            throw TaskError("The wake time has passed. Give a time in the future, or leave the wake out.")
        }
        try saveMergeState(taskID: taskID) {
            $0.waiting = TaskWaiting(on: reason, since: since, wakeAt: wakeAt)
            $0.readyForReviewAt = nil
        }
        startWakeMonitorIfNeeded()
        ToasttyLog.info("Marked a task as waiting", category: .tasks, metadata: [
            "task_id": taskID.uuidString,
            "has_wake": String(wakeAt != nil),
        ])
        return records.record(id: taskID)!
    }

    /// `task.waiting --clear`: the task no longer waits.
    @discardableResult
    func clearWaiting(taskID: UUID) throws -> TaskRecord {
        guard let record = records.record(id: taskID) else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        if record.waiting != nil {
            try saveMergeState(taskID: taskID) { $0.waiting = nil }
        }
        return records.record(id: taskID)!
    }

    /// `task.needs-reply`: the agent ends its turn with a question for the
    /// user. The task waits in Needs you, even after the user reads the
    /// turn, until the task's agent starts new work.
    @discardableResult
    func needsReply(taskID: UUID, question: String?) throws -> TaskRecord {
        guard records.record(id: taskID) != nil else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        let request = TaskReplyRequest(askedAt: now(), question: question.flatMap(taskNonEmpty))
        try saveMergeState(taskID: taskID) { $0.replyRequest = request }
        return records.record(id: taskID)!
    }

    /// Clears the marks that end with the next turn of the task whose task
    /// space is `workspaceID`, when the task's own agent, `sessionID`,
    /// starts new work: a reply request, since the user answered or the
    /// work went on without an answer; and a wait whose wake Toastty sent,
    /// since this is the turn the wake started. Another agent in the task
    /// space does neither.
    func clearMarksForNewWork(taskSpaceWorkspaceID workspaceID: UUID, sessionID: String) {
        guard let record = records.record(taskSpaceWorkspaceID: workspaceID),
              record.replyRequest != nil || record.waiting?.wokenAt != nil,
              liveAgentSession(of: record)?.sessionID == sessionID else { return }
        saveOrDefer(taskID: record.id) {
            $0.replyRequest = nil
            if $0.waiting?.wokenAt != nil { $0.waiting = nil }
        }
        ToasttyLog.info("Cleared a task's turn marks for new work", category: .tasks, metadata: [
            "task_id": record.id.uuidString,
            "reply_request": String(record.replyRequest != nil),
            "woken_wait": String(record.waiting?.wokenAt != nil),
        ])
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
        // A finished task waits on nothing, and gets no wake.
        try saveMergeState(taskID: taskID) {
            $0.doneAt = doneAt
            $0.waiting = nil
        }
        if let taskSpaceID = record.taskSpaceWorkspaceID, store.state.workspacesByID[taskSpaceID] != nil {
            _ = store.send(.setWorkspaceDone(workspaceID: taskSpaceID, doneAt: doneAt))
        }
        return records.record(id: taskID)!
    }

    /// What completing the task closes, read before the user confirms.
    struct CompleteCheck: Equatable {
        var hasTaskSpace: Bool
        var agentSessions: Int
        var unsavedDocuments: Int
        /// A worktree that completing leaves in place.
        var worktreePath: String?
    }

    func completeCheck(taskID: UUID) throws -> CompleteCheck {
        guard let record = records.record(id: taskID) else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        let taskSpaceID = record.taskSpaceWorkspaceID.flatMap { store.state.workspacesByID[$0]?.id }
        return CompleteCheck(
            hasTaskSpace: taskSpaceID != nil,
            agentSessions: taskSpaceID.map { sessions?.activeSessions(workspaceID: $0).count ?? 0 } ?? 0,
            unsavedDocuments: taskSpaceID.map { unsavedDocumentCount($0) } ?? 0,
            worktreePath: record.worktree.flatMap { isDirectory($0.path) ? $0.path : nil }
        )
    }

    /// Complete Task in the app: marks the task done, as `task mark-done`
    /// does, then closes its task space, since the person is finished with
    /// it. A worktree stays. Unsaved documents refuse before anything
    /// changes.
    @discardableResult
    func complete(taskID: UUID) throws -> TaskRecord {
        guard let record = records.record(id: taskID) else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        let taskSpaceID = record.taskSpaceWorkspaceID.flatMap { store.state.workspacesByID[$0]?.id }
        if let taskSpaceID, unsavedDocumentCount(taskSpaceID) > 0 {
            throw TaskError("The task space has unsaved documents. Save or close them, then complete the task.")
        }
        let done = try markDone(taskID: taskID)
        guard let taskSpaceID else { return done }
        let closed = closeFinishedTaskSpace?(taskSpaceID) ?? store.send(.closeWorkspace(workspaceID: taskSpaceID))
        guard closed else {
            throw TaskError("Toastty marked \(record.title) done but could not close its task space.")
        }
        flushLayout()
        ToasttyLog.info("Completed a task and closed its task space", category: .tasks, metadata: [
            "task_id": taskID.uuidString,
        ])
        return records.record(id: taskID) ?? done
    }

    // MARK: - Cleanup after a merge

    /// What the merge coordinator reports about a task space's cleanup.
    func mergeCleanupEvent(workspaceID: UUID, event: WorkspaceMergeCoordinator.CleanupEvent) {
        guard let record = records.record(taskSpaceWorkspaceID: workspaceID) else { return }
        switch event {
        case .mergeFailed(let reason, let cause, let head, let base):
            // The acceptance ends with the merge, as with Cancel Merge, so
            // the task no longer shows a merge under way and offers Merge
            // again. The reason stays for `task get`, the task's row, and
            // watches until merged. The cause, the commit and the target let
            // a caller outside the task decide whether to ask for the same
            // merge again.
            saveOrDefer(taskID: record.id) {
                $0.mergeRequestedAt = nil
                $0.mergeFailure = TaskMergeFailure(at: self.now(), reason: reason, cause: cause, head: head, base: base)
            }
            ToasttyLog.info("A task's merge stopped without merging", category: .tasks, metadata: [
                "task_id": record.id.uuidString,
                "reason": reason,
                "cause": cause.rawValue,
            ])
        case .merged(let state):
            // Saved before anything closes, so the task keeps its merge if
            // the cleanup or the app stops partway. A task in a project with
            // `release_tags` is cleaned up now too. Only a merge into the
            // repository's default branch waits in To ship without its task space.
            do {
                try records.save(id: record.id) {
                    $0.mergedAt = $0.mergedAt ?? self.now()
                    $0.mergeCommit = state?.mergeCommit ?? $0.mergeCommit
                    $0.mergeTarget = state?.mergeTarget ?? $0.mergeTarget
                    $0.mergeRequestedAt = $0.mergeRequestedAt ?? self.now()
                    $0.mergeFailure = nil
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
    /// counts as the user's acceptance, when no merge or cleanup ran for it.
    /// The task has a worktree on its own branch, or was adopted from an
    /// older space. Without a saved checkout, only an absent worktree
    /// permits cleanup. The script checks an existing worktree is clean at
    /// the merged head. An agent in a turn does not stop it: the cleanup
    /// waits for the hold and for the turn to end, as after a merge
    /// Toastty ran, and new work in the task space ends it. A task in a
    /// project with `release_tags` is cleaned up the same way and waits in
    /// To ship without its task space.
    func cleanUpMergedTasks(_ taskIDs: [UUID]) {
        guard let merges else { return }
        for taskID in taskIDs {
            guard let record = records.record(id: taskID),
                  record.archivedAt == nil,
                  record.release == nil,
                  record.cleanup == nil,
                  record.worktree != nil || record.source == .adopted,
                  record.worktree?.isDetached != true,
                  let taskSpaceID = record.taskSpaceWorkspaceID,
                  store.state.workspacesByID[taskSpaceID] != nil,
                  merges.request(workspaceID: taskSpaceID) == nil,
                  let target = try? mergeTarget(record, afterMerge: true) else { continue }
            records.update(id: taskID) { $0.cleanup = TaskCleanup(kind: .merge) }
            merges.cleanUpAfterMerge(
                workspaceID: taskSpaceID, pullRequest: target.pullRequest, repoPath: target.repoPath,
                requiresAbsentWorktree: record.worktree == nil
            )
            ToasttyLog.info("Cleaning up a task merged on GitHub", category: .tasks, metadata: ["task_id": taskID.uuidString])
        }
    }

    /// "Clean up": tries a stopped cleanup again.
    func retryCleanup(taskID: UUID) throws {
        guard let record = records.record(id: taskID) else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        if let taskSpaceID = record.taskSpaceWorkspaceID,
           let request = merges?.request(workspaceID: taskSpaceID),
           case .failed = request.phase {
            merges?.retryCleanup(workspaceID: taskSpaceID, afterMerge: record.mergedAt != nil)
            return
        }
        guard let cleanup = record.cleanup, cleanup.problem != nil else {
            throw TaskError("Task \(record.title) has no stopped cleanup.")
        }
        switch cleanup.kind {
        case .merge:
            guard let taskSpaceID = record.taskSpaceWorkspaceID, store.state.workspacesByID[taskSpaceID] != nil else {
                // The user closed the task space; its worktree and local
                // branch go the way an archive removes them.
                startTeardown(taskID: taskID, kind: .merge, options: TaskArchiveOptions())
                return
            }
            guard agentInTurn(workspaceID: taskSpaceID) == false else {
                throw TaskError("The agent is still working. Clean up once its turn ends.")
            }
            if cleanup.removesWorktreeDirectly == true {
                startTeardown(taskID: taskID, kind: .merge, options: TaskArchiveOptions())
                return
            }
            try saveMergeState(taskID: taskID) { $0.cleanup = nil }
            cleanUpMergedTasks([taskID])
        case .archive, .release:
            startTeardown(taskID: taskID, kind: cleanup.kind, options: cleanup.kind == .archive ? lastArchiveOptions(record) : TaskArchiveOptions())
        }
    }

    /// "Close Task Space": the cleanup Toastty holds for a day after the
    /// merge runs now.
    func cleanUpHeldTaskSpaceNow(taskID: UUID) throws {
        guard let record = records.record(id: taskID) else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        guard let taskSpaceID = record.taskSpaceWorkspaceID, let merges else {
            throw TaskError("\(record.title) has no task space to close.")
        }
        try merges.cleanUpHeldTaskSpaceNow(workspaceID: taskSpaceID)
    }

    /// The user closed the task space of a merged task before its cleanup
    /// did: removes the worktree and the local branch the merge's cleanup
    /// would have removed, with an archive's checks, so uncommitted files
    /// and commits on no remote branch stay. The branch on GitHub stays.
    /// A cleanup that closes the task space itself is still running then,
    /// so it is left alone.
    func mergedTaskSpaceClosed(workspaceID: UUID) {
        guard store.state.workspacesByID[workspaceID] == nil,
              let record = records.record(taskSpaceWorkspaceID: workspaceID),
              record.mergedAt != nil, record.archivedAt == nil,
              let worktree = record.worktree, worktree.isDetached == false,
              isDirectory(worktree.path),
              cleanupTasks[record.id] == nil,
              merges?.request(workspaceID: workspaceID) == nil else { return }
        ToasttyLog.info("Removing the worktree of a merged task whose task space closed", category: .tasks, metadata: [
            "task_id": record.id.uuidString,
        ])
        startTeardown(taskID: record.id, kind: .merge, options: TaskArchiveOptions())
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
        } else if afterMerge, let worktree = record.worktree, worktree.isDetached == false,
                  isDirectory(worktree.checkoutRoot) {
            repoPath = worktree.checkoutRoot
        } else if afterMerge, let root = record.projectRoot, isDirectory(root) {
            // A restored pane can fall back outside Git after its worktree
            // was removed. The script resolves the PR's checkout from here.
            repoPath = root
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
    private func startMerge(
        _ record: TaskRecord, target: MergeTarget, expectedHead: String?
    ) throws -> (record: TaskRecord, answer: Task<WorkspaceMergeCoordinator.MergeAnswer, Never>) {
        guard let merges else {
            throw TaskError("Merging is not available in this Toastty instance.")
        }
        if let request = merges.request(workspaceID: target.taskSpaceID) {
            switch request.phase {
            case .failed:
                break
            case .merging, .awaitingChecks, .awaitingMerge, .cleaningUp, .closing:
                throw TaskError("A merge of \(record.title) is already under way.")
            case .holdingCleanup:
                throw TaskError("\(record.title) has merged.")
            }
        }
        mergeDeliveryTasks.removeValue(forKey: record.id)?.cancel()
        try saveMergeState(taskID: record.id) {
            $0.mergeRequestedAt = $0.mergeRequestedAt ?? self.now()
            $0.mergeCancelledAt = nil
            $0.mergeFailure = nil
        }
        guard let answer = merges.merge(
            workspaceID: target.taskSpaceID,
            pullRequest: target.pullRequest,
            repoPath: target.repoPath,
            thenCleanUp: true,
            expectedHead: expectedHead
        ) else {
            throw TaskError("A merge of \(record.title) is already under way.")
        }
        ToasttyLog.info("Merging a task", category: .tasks, metadata: [
            "task_id": record.id.uuidString,
            "pull_request": String(target.pullRequest.number),
            "expected_head": expectedHead ?? "",
        ])
        return (records.record(id: record.id) ?? record, answer)
    }

    /// A cancelled merge stays cancelled for every agent turn that started
    /// before the cancel: the task's own agent that was checking it, and a
    /// coordinating task merging its children. A turn that started after
    /// the cancel, such as the user saying "merge it", may merge. A caller
    /// outside Toastty has no turn and is not held back.
    /// `task.merge` records the user's acceptance itself, so it runs only
    /// from an agent session in the task's own task space, where the merge
    /// skill runs, or in its parent task's task space, which merges its
    /// child tasks. Any agent there counts: the merge prompt can start the
    /// agent in a new tab, and a relaunch restores sessions with new IDs.
    /// Callers outside, such as a shell or an outside coordinator, ask for
    /// the merge with `task.request-merge`, so the task's agent checks it
    /// first. The caller's session comes from the CLI's environment, so this
    /// prevents mistakes, not a process that claims a session.
    private func checkMergeCaller(_ record: TaskRecord, caller: TaskCaller) throws {
        if let callerWorkspaceID = caller.workspaceID {
            if callerWorkspaceID == record.taskSpaceWorkspaceID { return }
            if let parentID = record.parentTaskID,
               callerWorkspaceID == records.record(id: parentID)?.taskSpaceWorkspaceID {
                return
            }
        }
        throw TaskError(
            "task merge runs from an agent in the task's task space or its parent task's. "
                + "To accept the merge, run: toastty task request-merge \(record.id.uuidString)"
        )
    }

    private func checkNotCancelled(_ record: TaskRecord, caller: TaskCaller) throws {
        guard let cancelledAt = record.mergeCancelledAt, let callerSessionID = caller.sessionID else { return }
        if let turnStartedAt = sessions?.session(callerSessionID)?.turnStartedAt, turnStartedAt > cancelledAt {
            return
        }
        throw TaskError("The user cancelled this merge. Do not merge unless the user asks again.")
    }

    /// What Merge sends, and the same message for an agent that Toastty
    /// knows did not get its skills.
    struct MergePrompt {
        var text: String
        var withoutSkills: String

        /// The message for `session`.
        @MainActor
        func text(for session: TaskSessionInfo, launcher: (any TaskAgentLaunching)?) -> String {
            launcher?.lacksShippedSkills(sessionID: session.sessionID) == true ? withoutSkills : text
        }
    }

    /// Sends the merge prompt to the task's agent once it is at rest, or
    /// starts an agent for it when none runs. A busy agent finishes its
    /// turn first, so the prompt is the next thing it reads.
    private func deliverMergePrompt(_ prompt: MergePrompt, taskID: UUID, target: MergeTarget, requestedAt: Date) throws {
        guard let record = records.record(id: taskID) else { return }
        if let session = liveAgentSession(of: record) {
            guard session.isInTurn else {
                try send(taskID: taskID, text: prompt.text(for: session, launcher: launcher))
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
                        try self.send(taskID: taskID, text: prompt.text(for: current, launcher: self.launcher))
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
    private func launchMergeAgent(prompt: MergePrompt, record: TaskRecord, target: MergeTarget, requestedAt: Date) throws {
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
                        initialPrompt: prompt.text,
                        initialPromptWithoutSkills: Self.promptWithoutSkills(prompt.text, prompt.withoutSkills),
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

/// Lets the first of two racing tasks resume a continuation.
@MainActor
private final class FirstAnswer {
    private var isClaimed = false

    func claim() -> Bool {
        guard isClaimed == false else { return false }
        isClaimed = true
        return true
    }
}
