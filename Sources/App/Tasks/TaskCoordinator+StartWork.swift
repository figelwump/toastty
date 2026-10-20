import CoreState
import RemoteProtocol
import Foundation

/// What a caller asked for in `task.start-work`.
struct TaskStartWorkRequest: Equatable {
    var branchPrefix: String?
    var base: String?
    /// For a session that is not a task's yet: the new task's title and
    /// slug.
    var title: String?
    var slug: String?
}

/// Which run of a task a worktree step belongs to: its setup, or a move
/// into a worktree. A newer run of the same kind makes an older one stop.
enum TaskJob: Equatable, Sendable {
    case setup(UUID)
    case startWork(UUID)
}

/// Moving a task into its own git worktree.
///
/// `task.start-work` comes from the agent session that works on the task.
/// Toastty makes the worktree from a freshly fetched base and runs
/// `create_hook` while that agent finishes its turn. Then it forks the
/// agent's conversation into a new terminal in the worktree, waits until
/// the provider reports the new conversation, and closes the old session.
/// Each step is saved in the record's operation as it happens, so Retry
/// continues from the last finished step. If anything fails, the old
/// session stays.
extension TaskCoordinator {
    static let forkableAgents: Set<AgentKind> = [.claude, .codex]
    /// After the moving session's turn ends: Claude reports the end before
    /// the last of its transcript is on disk.
    static let transcriptSettleDelay: Duration = .milliseconds(500)

    // MARK: - Request

    /// Checks the request and starts the move. Returns once the record is
    /// saved; the move continues in the background.
    @discardableResult
    func startWork(_ request: TaskStartWorkRequest, caller: TaskCaller) throws -> TaskRecord {
        guard let sessionID = caller.sessionID, let sessions,
              let session = sessions.session(sessionID), session.isActive else {
            throw TaskError("task start-work runs from the agent session whose work moves into the worktree.")
        }
        guard let workspace = store.state.workspacesByID[session.workspaceID] else {
            throw TaskError("The session's workspace is closed.")
        }
        let config: TasksConfig
        do {
            config = try configLoader()
        } catch {
            throw TaskError(error.localizedDescription)
        }

        var record: TaskRecord
        var rootToSave: (workspaceID: UUID, path: String)?
        if let taskID = workspace.taskID, let existing = records.record(id: taskID) {
            guard existing.setup == .started else {
                throw TaskError("This task is still setting up.")
            }
            if let worktree = existing.worktree {
                throw TaskError("This task already works in the worktree \(worktree.path).")
            }
            switch existing.startWork?.state {
            case .running?:
                throw TaskError("This task is already moving into a worktree.")
            case .failed(let reason)?:
                throw TaskError("This task's move into a worktree failed: \(reason) Retry it with: toastty task retry \(existing.id.uuidString)")
            case .finished?, nil:
                break
            }
            record = existing
        } else {
            // A session in a top-level workspace never gets the task link, so
            // an earlier request from it is found by its source session.
            if let earlier = records.records.first(where: { $0.startWork?.source?.sessionID == sessionID }) {
                switch earlier.startWork?.state {
                case .running?:
                    throw TaskError("This session is already moving into a worktree for task \(earlier.id.uuidString).")
                case .failed(let reason)?:
                    throw TaskError("This session's move into a worktree failed: \(reason) Retry it with: toastty task retry \(earlier.id.uuidString)")
                case .finished?, nil:
                    break
                }
            }
            // A session that is not a task's yet. In a task space, that task
            // space becomes the task's; in a top-level workspace, the move
            // makes a new task space under it.
            let parentID = workspace.parentWorkspaceID
            let ownerID = parentID ?? workspace.id
            let root = try resolvedProjectRoot(workspaceID: ownerID)
            if root.isNew { rootToSave = (ownerID, root.path) }
            let (title, slug) = try titleAndSlug(
                pinnedTitle: request.title.flatMap(taskNonEmpty),
                pinnedSlug: request.slug,
                fallbacks: [session.title ?? "", parentID == nil ? "" : workspace.title]
            )
            record = TaskRecord(
                createdAt: now(),
                text: title,
                title: title,
                slug: slug,
                titleSetByUser: request.title.flatMap(taskNonEmpty) != nil,
                source: .agent(sessionID: sessionID),
                resolved: TaskFields(workspaceID: ownerID, agent: session.agent.rawValue),
                workspaceID: ownerID,
                projectRoot: root.path,
                setup: .started,
                operation: TaskOperation(
                    taskSpace: parentID == nil ? nil : TaskOperation.TaskSpace(workspaceID: workspace.id, panelID: session.panelID)
                )
            )
        }
        guard let projectRoot = record.projectRoot else {
            throw TaskError("The task has no project directory.")
        }
        // A session already in another checkout's worktree, such as one
        // made by an older workflow, would get a second worktree.
        if let cwd = session.cwd,
           let worktreeRoot = Self.linkedWorktreeRoot(containing: cwd, fileManager: fileManager),
           Self.samePath(worktreeRoot, projectRoot) == false {
            throw TaskError("This session already works in the git worktree \(worktreeRoot).")
        }
        record.startWork = try newStartWork(
            branchPrefix: request.branchPrefix,
            base: request.base,
            source: TaskStartWork.Source(
                sessionID: sessionID,
                panelID: session.panelID,
                agent: session.agent.rawValue,
                conversationID: session.nativeConversationID
            ),
            projectRoot: projectRoot,
            config: config
        )

        do {
            if records.record(id: record.id) == nil {
                try records.insert(record)
                if let taskSpace = record.operation.taskSpace {
                    _ = store.send(.setWorkspaceTaskID(workspaceID: taskSpace.workspaceID, taskID: record.id))
                    flushLayout()
                }
            } else {
                let startWork = record.startWork
                try records.save(id: record.id) { $0.startWork = startWork }
            }
        } catch {
            throw TaskError("Toastty could not save the task: \(error.localizedDescription)")
        }
        if let rootToSave {
            _ = store.send(.setWorkspaceRootDirectory(workspaceID: rootToSave.workspaceID, rootDirectory: rootToSave.path))
        }
        ToasttyLog.info("Moving a task into a worktree", category: .tasks, metadata: [
            "task_id": record.id.uuidString,
            "source_session_id": sessionID,
            "agent": session.agent.rawValue,
        ])
        startStartWork(taskID: record.id)
        return records.record(id: record.id) ?? record
    }

    /// A checked start-work request. The branch prefix comes from the
    /// caller, else the workspace's `branch_prefix`, else `task`.
    func newStartWork(
        branchPrefix: String?,
        base: String?,
        source: TaskStartWork.Source?,
        projectRoot: String,
        config: TasksConfig
    ) throws -> TaskStartWork {
        let prefix = branchPrefix.flatMap(taskNonEmpty)
            ?? config.workspace(forProjectRoot: projectRoot)?.branchPrefix
            ?? TaskStartWork.defaultBranchPrefix
        guard TaskStartWork.isValidBranchPrefix(prefix) else {
            throw TaskError("The branch prefix \(prefix) must be lowercase words of letters, digits and hyphens, joined by slashes.")
        }
        let base = base.flatMap(taskNonEmpty)
        if let base {
            try TaskWorktreeCreator.validateRefArgument(base, name: "The base")
        }
        guard fileManager.fileExists(atPath: (projectRoot as NSString).appendingPathComponent(".git")) else {
            throw TaskError("\(projectRoot) is not the root of a git repository, so the task cannot get a worktree.")
        }
        return TaskStartWork(branchPrefix: prefix, base: base, source: source, requestedAt: now())
    }

    // MARK: - Job

    func startStartWork(taskID: UUID) {
        let attempt = UUID()
        startWorkAttempts[taskID] = attempt
        startWorkTasks.removeValue(forKey: taskID)?.cancel()
        startWorkTasks[taskID] = Task { [weak self] in
            await self?.runStartWork(taskID: taskID, attempt: attempt)
        }
    }

    func isCurrent(_ job: TaskJob, taskID: UUID) -> Bool {
        switch job {
        case .setup(let attempt):
            return isCurrent(taskID: taskID, attempt: attempt)
        case .startWork(let attempt):
            return startWorkAttempts[taskID] == attempt
                && records.record(id: taskID)?.startWork?.state == .running
                && Task.isCancelled == false
        }
    }

    private func fail(_ job: TaskJob, taskID: UUID, reason: String) {
        switch job {
        case .setup(let attempt):
            setupFailed(taskID: taskID, attempt: attempt, reason: reason)
        case .startWork(let attempt):
            guard startWorkAttempts[taskID] == attempt else { return }
            startWorkAttempts[taskID] = nil
            startWorkTasks[taskID] = nil
            saveOrDefer(taskID: taskID) { $0.startWork?.state = .failed(reason: reason) }
            ToasttyLog.info("Moving a task into a worktree failed", category: .tasks, metadata: [
                "task_id": taskID.uuidString,
                "reason": reason,
            ])
        }
    }

    private func runStartWork(taskID: UUID, attempt: UUID) async {
        let job = TaskJob.startWork(attempt)
        guard isCurrent(job, taskID: taskID),
              let source = records.record(id: taskID)?.startWork?.source,
              let agent = AgentKind(rawValue: source.agent) else {
            fail(job, taskID: taskID, reason: "The task has no session to move. Delete the request and ask the agent again.")
            return
        }
        guard let sessions, let launcher else {
            fail(job, taskID: taskID, reason: "This Toastty instance cannot move agent sessions.")
            return
        }

        // 1–3. The worktree and its hook.
        guard let worktree = await prepareWorktree(taskID: taskID, job: job) else { return }
        let forked = Self.forkableAgents.contains(agent)

        // 4. A session that an earlier attempt launched, and that still
        // runs, continues; a relaunch restores it under a new ID in the same
        // terminal.
        var target = records.record(id: taskID)?.operation.worktreeSession
        if var launched = target, launched.sessionID != nil {
            if let live = liveWorktreeSession(launched, source: source, sessions: sessions) {
                launched.sessionID = live.sessionID
                if launched.forked, launched.nativeConversationID == nil,
                   let conversationID = live.nativeConversationID, conversationID != source.conversationID {
                    launched.nativeConversationID = conversationID
                }
            } else {
                launched.sessionID = nil
                launched.nativeConversationID = nil
            }
            let resolved = launched
            saveOrDefer(taskID: taskID) { $0.operation.worktreeSession = resolved }
            target = launched
        }

        if target?.sessionID == nil {
            // 5. The fork copies the conversation as it is on disk, so it
            // waits for the turn that asked for the move to end.
            guard await waitForSourceTurnToEnd(job: job, taskID: taskID, sessions: sessions) else { return }
            let current = currentSource(taskID: taskID, sessions: sessions)
            if forked, current == nil {
                fail(job, taskID: taskID, reason: "The session to move ended before Toastty could copy its conversation. The worktree is ready at \(worktree.path); start an agent there.")
                return
            }
            let discoveryDeadline = ContinuousClock.now.advanced(by: timing.sourceDiscoveryTimeout)
            if forked {
                guard await waitForSourceConversation(job: job, taskID: taskID, sessions: sessions, deadline: discoveryDeadline) else {
                    return
                }
            }

            // 6. A terminal in the worktree for the session that continues.
            guard var terminal = worktreeSessionTerminal(taskID: taskID, worktree: worktree, source: source, forked: forked, job: job),
                  let record = records.record(id: taskID) else {
                return
            }

            // 7. The session.
            let resolved = record.resolved?.agent == source.agent ? record.resolved : nil
            let prompt = TaskPrompt.movedToWorktree(record: record, worktree: worktree, base: record.operation.base, forked: forked)
            let forkSourceID = current?.sessionID
            let launchTarget = terminal
            let result: AgentLaunchResult
            do {
                result = try await Self.launchWhenSourceIsKnown(deadline: discoveryDeadline, pollInterval: timing.pollInterval) {
                    try await Self.launchWhenTerminalIsReady(timeout: terminalReadinessTimeout) {
                        try await launcher.launchTask(
                            profileID: source.agent,
                            workspaceID: launchTarget.workspaceID,
                            panelID: launchTarget.panelID,
                            cwd: worktree.path,
                            model: resolved?.model,
                            reasoningEffort: resolved?.effort,
                            initialPrompt: prompt,
                            parentSessionID: forked ? nil : forkSourceID,
                            forkFromSessionID: forked ? forkSourceID : nil,
                            beforeDispatch: { [weak self] in
                                guard let self, self.isCurrent(job, taskID: taskID) else {
                                    throw CancellationError()
                                }
                            }
                        )
                    }
                }
            } catch {
                if error is CancellationError || Task.isCancelled { return }
                if case .commandDeliveryUncertain? = error as? AgentLaunchError {
                    fail(job, taskID: taskID, reason: "The agent command may not have reached the worktree's terminal. Check the task space before you retry.")
                } else {
                    fail(job, taskID: taskID, reason: Self.launchFailureReason(for: error))
                }
                return
            }
            terminal.sessionID = result.sessionID
            let launched = terminal
            saveOrDefer(taskID: taskID) { $0.operation.worktreeSession = launched }
            target = launched
        }
        guard var target else { return }
        let sourceConversationID = records.record(id: taskID)?.startWork?.source?.conversationID
            ?? currentSource(taskID: taskID, sessions: sessions)?.nativeConversationID

        // 8. A fork counts once the provider reports a conversation of its
        // own; until then the old session is the only copy.
        if forked, target.nativeConversationID == nil, let sessionID = target.sessionID {
            guard let conversationID = await waitForFork(
                sessionID: sessionID,
                sourceConversationID: sourceConversationID,
                job: job,
                taskID: taskID,
                sessions: sessions
            ) else { return }
            target.nativeConversationID = conversationID
            let confirmed = target
            saveOrDefer(taskID: taskID) { $0.operation.worktreeSession = confirmed }
        }

        // 9. The old session.
        guard isCurrent(job, taskID: taskID), let record = records.record(id: taskID) else { return }
        let outcome: TaskOperation.SourceOutcome
        if let existing = record.operation.sourceOutcome {
            outcome = existing
        } else if forked == false {
            outcome = .kept(reason: "\(agent.displayName) sessions cannot be forked, so the conversation stays in this session.")
        } else {
            outcome = closeSource(
                currentSource(taskID: taskID, sessions: sessions),
                source: source,
                requestedAt: record.startWork?.requestedAt ?? .distantPast,
                sessions: sessions
            )
        }
        startWorkAttempts[taskID] = nil
        startWorkTasks[taskID] = nil
        saveOrDefer(taskID: taskID) {
            $0.operation.sourceOutcome = outcome
            $0.startWork?.state = .finished
        }
        ToasttyLog.info("Moved a task into its worktree", category: .tasks, metadata: [
            "task_id": taskID.uuidString,
            "session_id": target.sessionID ?? "",
            "forked": String(forked),
            "source": Self.logValue(outcome),
        ])
    }

    // MARK: - Worktree

    /// Makes the task's worktree and runs `create_hook` there, each step
    /// once: a retry skips what an earlier attempt finished. Returns `nil`
    /// after it reported a failure, or when the job is no longer current.
    func prepareWorktree(taskID: UUID, job: TaskJob) async -> TaskOperation.Worktree? {
        guard let record = records.record(id: taskID), let projectRoot = record.projectRoot else {
            fail(job, taskID: taskID, reason: "The task has no project directory.")
            return nil
        }
        var worktree = record.worktree
        if worktree == nil {
            do {
                let checkout = try await worktreeCreator.checkout(for: projectRoot)
                guard isCurrent(job, taskID: taskID) else { return nil }
                worktree = try await worktreeCreator.locks.run(checkout.commonDirectory) { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.addWorktree(taskID: taskID, checkout: checkout, job: job)
                }
            } catch {
                report(error, job: job, taskID: taskID)
                return nil
            }
        }
        guard let worktree else { return nil }

        if records.record(id: taskID)?.operation.hookFinishedAt == nil {
            do {
                let config: TasksConfig
                do {
                    config = try configLoader()
                } catch {
                    throw TaskError(error.localizedDescription)
                }
                if let hook = config.workspace(forProjectRoot: projectRoot)?.createHook {
                    ToasttyLog.info("Running a task's create_hook", category: .tasks, metadata: [
                        "task_id": taskID.uuidString,
                        "worktree": worktree.path,
                    ])
                    try await worktreeCreator.runHook(
                        hook,
                        worktree: worktree,
                        base: records.record(id: taskID)?.operation.base,
                        taskID: taskID,
                        slug: record.slug,
                        projectRoot: projectRoot
                    )
                }
            } catch {
                report(error, job: job, taskID: taskID)
                return nil
            }
            guard isCurrent(job, taskID: taskID) else { return nil }
            saveOrDefer(taskID: taskID) { $0.operation.hookFinishedAt = self.now() }
        }
        return worktree
    }

    /// Runs under the repository's lock: pins the base, reserves free
    /// names, and adds the worktree. A worktree that an add made before a
    /// crash is found and kept.
    private func addWorktree(taskID: UUID, checkout: TaskGitCheckout, job: TaskJob) async throws -> TaskOperation.Worktree {
        guard isCurrent(job, taskID: taskID), let record = records.record(id: taskID), let startWork = record.startWork else {
            throw CancellationError()
        }
        let base: TaskOperation.Base
        if let pinned = record.operation.base {
            base = pinned
        } else {
            base = try await worktreeCreator.pinBase(checkout, base: startWork.base)
            guard isCurrent(job, taskID: taskID) else { throw CancellationError() }
            try save(taskID: taskID) { $0.operation.base = base }
        }
        if var reserved = record.operation.worktree,
           await worktreeCreator.isWorktree(path: reserved.path, branch: reserved.branch) {
            reserved.added = true
            let added = reserved
            saveOrDefer(taskID: taskID) { $0.operation.worktree = added }
            return added
        }
        let names = try await worktreeCreator.freeNames(checkout, slug: record.slug, branchPrefix: startWork.branchPrefix)
        guard isCurrent(job, taskID: taskID) else { throw CancellationError() }
        var worktree = TaskOperation.Worktree(path: names.path, branch: names.branch, checkoutRoot: checkout.root, added: false)
        let reserved = worktree
        // Saved first: after a crash, a retry finds this worktree instead of
        // making a second one.
        try save(taskID: taskID) { $0.operation.worktree = reserved }
        try await worktreeCreator.addWorktree(checkout, path: worktree.path, branch: worktree.branch, sha: base.sha)
        worktree.added = true
        let added = worktree
        saveOrDefer(taskID: taskID) { $0.operation.worktree = added }
        ToasttyLog.info("Made a task's worktree", category: .tasks, metadata: [
            "task_id": taskID.uuidString,
            "branch": worktree.branch,
            "base": base.sha,
            "base_fetched": String(base.fetched),
        ])
        return worktree
    }

    // MARK: - Sessions

    private func waitForSourceTurnToEnd(
        job: TaskJob,
        taskID: UUID,
        sessions: any TaskSessionProviding
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timing.sourceTurnTimeout)
        var waited = false
        while true {
            guard isCurrent(job, taskID: taskID) else { return false }
            // A session that ended has nothing more to write; the launch
            // decides what that means.
            guard let session = currentSource(taskID: taskID, sessions: sessions), session.isInTurn else {
                if waited { try? await Task.sleep(for: Self.transcriptSettleDelay) }
                return isCurrent(job, taskID: taskID)
            }
            guard clock.now < deadline else {
                let minutes = Int(timing.sourceTurnTimeout.components.seconds / 60)
                fail(job, taskID: taskID, reason: "The session did not finish its turn within \(minutes) minutes, so its conversation was not copied. Retry once it is idle.")
                return false
            }
            waited = true
            try? await Task.sleep(for: timing.pollInterval)
        }
    }

    /// Waits until Toastty has identified the moving session's provider
    /// conversation, and saves it on the record. A move asked for in the
    /// session's first seconds can arrive before that.
    private func waitForSourceConversation(
        job: TaskJob,
        taskID: UUID,
        sessions: any TaskSessionProviding,
        deadline: ContinuousClock.Instant
    ) async -> Bool {
        while true {
            guard isCurrent(job, taskID: taskID) else { return false }
            guard let session = currentSource(taskID: taskID, sessions: sessions) else {
                fail(job, taskID: taskID, reason: "The session to move ended before Toastty could copy its conversation.")
                return false
            }
            if let conversationID = session.nativeConversationID {
                if records.record(id: taskID)?.startWork?.source?.conversationID == nil {
                    saveOrDefer(taskID: taskID) { $0.startWork?.source?.conversationID = conversationID }
                }
                return true
            }
            guard ContinuousClock.now < deadline else {
                fail(job, taskID: taskID, reason: "Toastty has not identified this session's conversation, so it cannot fork it. Retry in a moment.")
                return false
            }
            try? await Task.sleep(for: timing.pollInterval)
        }
    }

    /// Retries a fork that the launcher refused only because it has not
    /// confirmed the source's conversation yet; the binding Toastty waited
    /// for can arrive a moment before the launcher's own record of it.
    static func launchWhenSourceIsKnown(
        deadline: ContinuousClock.Instant,
        pollInterval: Duration,
        attempt: @MainActor () async throws -> AgentLaunchResult
    ) async throws -> AgentLaunchResult {
        while true {
            do {
                return try await attempt()
            } catch AgentLaunchError.invalidLaunchOverride(let parameter, let message)
                where parameter == "forkFromSessionID"
                && message.contains("no current confirmed native conversation")
                && ContinuousClock.now < deadline {
                try await Task.sleep(for: pollInterval)
            }
        }
    }

    /// The terminal the continuing session starts in: the one an earlier
    /// attempt made, else a new background tab in the task space, else a new
    /// task space whose terminal opens in the worktree.
    private func worktreeSessionTerminal(
        taskID: UUID,
        worktree: TaskOperation.Worktree,
        source: TaskStartWork.Source,
        forked: Bool,
        job: TaskJob
    ) -> TaskOperation.WorktreeSession? {
        guard let record = records.record(id: taskID) else { return nil }
        if let existing = record.operation.worktreeSession,
           let workspace = store.state.workspacesByID[existing.workspaceID],
           case .terminal? = workspace.panelState(for: existing.panelID) {
            return existing
        }
        if let workspaceID = record.operation.worktreeSession?.workspaceID ?? record.operation.taskSpace?.workspaceID,
           store.state.workspacesByID[workspaceID] != nil {
            let session = TaskOperation.WorktreeSession(workspaceID: workspaceID, panelID: UUID(), forked: forked)
            do {
                try save(taskID: taskID) { $0.operation.worktreeSession = session }
            } catch {
                report(error, job: job, taskID: taskID)
                return nil
            }
            guard store.send(.createBackgroundTerminalTab(
                workspaceID: workspaceID,
                tabID: UUID(),
                panelID: session.panelID,
                terminalCWD: worktree.path
            )) else {
                saveOrDefer(taskID: taskID) { $0.operation.worktreeSession = nil }
                fail(job, taskID: taskID, reason: "Toastty could not open a terminal in the task space.")
                return nil
            }
            flushLayout()
            return session
        }
        guard let workspaceID = record.workspaceID,
              let windowID = store.state.workspaceSelection(containingWorkspaceID: workspaceID)?.windowID else {
            fail(job, taskID: taskID, reason: "The task's workspace is closed. Open it, then retry.")
            return nil
        }
        let taskSpace = TaskOperation.TaskSpace(workspaceID: UUID(), panelID: UUID())
        let session = TaskOperation.WorktreeSession(workspaceID: taskSpace.workspaceID, panelID: taskSpace.panelID, forked: forked)
        do {
            try save(taskID: taskID) {
                $0.operation.taskSpace = taskSpace
                $0.operation.worktreeSession = session
            }
        } catch {
            report(error, job: job, taskID: taskID)
            return nil
        }
        guard store.send(.createTaskSpace(
            windowID: windowID,
            workspaceID: taskSpace.workspaceID,
            panelID: taskSpace.panelID,
            parentWorkspaceID: workspaceID,
            spawningSessionID: source.sessionID,
            taskID: taskID,
            title: record.slug,
            terminalCWD: worktree.path
        )) else {
            saveOrDefer(taskID: taskID) {
                $0.operation.taskSpace = nil
                $0.operation.worktreeSession = nil
            }
            fail(job, taskID: taskID, reason: "Toastty could not create the task space.")
            return nil
        }
        flushLayout()
        return session
    }

    /// Waits until the forked session reports a provider conversation that
    /// is not the source's. Returns its ID, or `nil` after a failure.
    private func waitForFork(
        sessionID: String,
        sourceConversationID: String?,
        job: TaskJob,
        taskID: UUID,
        sessions: any TaskSessionProviding
    ) async -> String? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timing.forkConfirmationTimeout)
        while true {
            guard isCurrent(job, taskID: taskID) else { return nil }
            guard let session = sessions.session(sessionID), session.isActive else {
                fail(job, taskID: taskID, reason: "The forked agent exited before its conversation started. The previous session stays open; retry to try again.")
                return nil
            }
            if let conversationID = session.nativeConversationID, conversationID != sourceConversationID {
                return conversationID
            }
            guard clock.now < deadline else {
                let seconds = Int(timing.forkConfirmationTimeout.components.seconds)
                fail(job, taskID: taskID, reason: "Toastty did not see the forked conversation start within \(seconds) seconds. The previous session stays open; check the worktree's terminal, then retry.")
                return nil
            }
            try? await Task.sleep(for: timing.pollInterval)
        }
    }

    /// Closes the session the conversation moved from, unless someone may
    /// still be using it.
    private func closeSource(
        _ session: TaskSessionInfo?,
        source: TaskStartWork.Source,
        requestedAt: Date,
        sessions: any TaskSessionProviding
    ) -> TaskOperation.SourceOutcome {
        guard let session, session.panelID == source.panelID else {
            return .kept(reason: "This session had already ended.")
        }
        if session.isInTurn {
            return .kept(reason: "This session started new work after the move began.")
        }
        if sessions.hasInput(panelID: source.panelID, since: requestedAt) {
            return .kept(reason: "Someone typed into this session after the move began.")
        }
        return sessions.closeMovedSessionPane(panelID: source.panelID, agent: session.agent)
    }

    /// The session the conversation moves from, as it runs now. After a
    /// relaunch, Toastty restores it under a new ID in the same pane; that
    /// session counts when it continues the same provider conversation, and
    /// the record follows it.
    private func currentSource(taskID: UUID, sessions: any TaskSessionProviding) -> TaskSessionInfo? {
        guard let source = records.record(id: taskID)?.startWork?.source else { return nil }
        if let session = sessions.session(source.sessionID), session.isActive {
            return session
        }
        guard let conversationID = source.conversationID,
              let restored = sessions.activeSession(panelID: source.panelID),
              restored.agent.rawValue == source.agent,
              restored.nativeConversationID == conversationID else {
            return nil
        }
        saveOrDefer(taskID: taskID) { $0.startWork?.source?.sessionID = restored.sessionID }
        return restored
    }

    /// The continuing session launched by an earlier attempt, if it still
    /// runs, under its own ID or restored in its terminal after a relaunch.
    private func liveWorktreeSession(
        _ launched: TaskOperation.WorktreeSession,
        source: TaskStartWork.Source,
        sessions: any TaskSessionProviding
    ) -> TaskSessionInfo? {
        if let sessionID = launched.sessionID, let session = sessions.session(sessionID), session.isActive {
            return session
        }
        guard let restored = sessions.activeSession(panelID: launched.panelID),
              restored.agent.rawValue == source.agent else {
            return nil
        }
        return restored
    }

    // MARK: - Helpers

    private func save(taskID: UUID, _ body: (inout TaskRecord) -> Void) throws {
        do {
            try records.save(id: taskID, body)
        } catch {
            throw TaskError("Toastty could not save the task: \(error.localizedDescription)")
        }
    }

    private func report(_ error: any Error, job: TaskJob, taskID: UUID) {
        guard error is CancellationError == false, isCurrent(job, taskID: taskID) else { return }
        let reason = (error as? TaskError)?.message ?? error.localizedDescription
        fail(job, taskID: taskID, reason: reason)
    }

    /// The root of the linked git worktree that contains `path`, or `nil`
    /// when `path` is in a main checkout or in no repository. A linked
    /// worktree has a `.git` file where a main checkout has a directory.
    static func linkedWorktreeRoot(containing path: String, fileManager: FileManager = .default) -> String? {
        var directory = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
        while true {
            var isDirectory: ObjCBool = false
            let marker = directory.appending(path: ".git", directoryHint: .notDirectory).path(percentEncoded: false)
            if fileManager.fileExists(atPath: marker, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? nil : directory.path(percentEncoded: false).trimmingTrailingSlash
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path(percentEncoded: false) != directory.path(percentEncoded: false) else { return nil }
            directory = parent
        }
    }

    static func samePath(_ first: String, _ second: String) -> Bool {
        func resolved(_ path: String) -> String {
            URL(filePath: path).resolvingSymlinksInPath().path(percentEncoded: false).trimmingTrailingSlash
        }
        return resolved(first) == resolved(second)
    }

    private static func logValue(_ outcome: TaskOperation.SourceOutcome) -> String {
        switch outcome {
        case .closed: "closed"
        case .exited: "exited"
        case .kept: "kept"
        }
    }
}

private extension String {
    var trimmingTrailingSlash: String {
        count > 1 && hasSuffix("/") ? String(dropLast()) : self
    }
}
