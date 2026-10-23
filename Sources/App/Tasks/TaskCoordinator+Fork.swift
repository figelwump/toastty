import CoreState
import Foundation

/// Starting a new task's agent as a fork of the conversation of the agent
/// session that created the task: `task create --fork`.
///
/// Setup makes the worktree, with `--start-work`, and the task space as
/// usual. Then, as a move into a worktree does, it waits for the creating
/// session's turn to end and for Toastty to identify its conversation,
/// forks that conversation into the task space's terminal, and waits until
/// the fork reports a conversation of its own. The creating session keeps
/// running: Toastty never closes it or types into it. Each step is saved as
/// it happens, so Retry continues from the last finished step.
extension TaskCoordinator {
    /// The calling session that `--fork` copies.
    func forkSourceSession(_ request: TaskCreateRequest, caller: TaskCaller) throws -> TaskSessionInfo {
        guard let sessionID = caller.sessionID, let session = sessions?.session(sessionID), session.isActive else {
            throw TaskError("--fork copies the conversation of the agent session that runs it, so it runs only from a Toastty-managed Claude Code or Codex session.")
        }
        guard Self.forkableAgents.contains(session.agent) else {
            throw TaskError("\(session.agent.displayName) sessions cannot be forked. --fork runs only from Claude Code and Codex sessions.")
        }
        if let agent = request.agent.flatMap(taskNonEmpty), agent != session.agent.rawValue {
            throw TaskError("A fork uses the calling session's agent, \(session.agent.rawValue). Leave out --agent, or name \(session.agent.rawValue).")
        }
        return session
    }

    /// The fields of a task whose agent forks the caller: the caller's
    /// agent, and the model and effort the caller's own task uses, as a
    /// move into a worktree keeps them, unless the request sets them. Triage
    /// and `[defaults]` do not apply: the fork continues a conversation.
    func forkFields(
        pinned: TaskFields,
        agent: String,
        workspaceID: UUID,
        parentTask: TaskRecord?,
        skill: String?
    ) throws -> TaskFields {
        let profile = try checkedProfile(agent)
        let inherited = parentTask?.resolved?.agent == agent ? parentTask?.resolved : nil
        var fields = TaskFields(workspaceID: workspaceID, agent: agent, prompt: pinned.prompt, skill: pinned.skill ?? skill)
        if let model = pinned.model {
            try checkModel(model, profile: profile)
            fields.model = model
        } else if profile.supportsModel {
            fields.model = inherited?.model
        }
        if let effort = pinned.effort {
            try checkEffort(effort, profile: profile)
            fields.effort = effort
        } else if profile.supportsReasoningEffort {
            fields.effort = inherited?.effort
        }
        return fields
    }

    /// Setup's agent step for a forked task. Returns `true` once the fork
    /// reported its own conversation; `false` after it reported a failure,
    /// or when the job is no longer current.
    func launchFork(
        taskID: UUID,
        attempt: UUID,
        taskSpace: TaskOperation.TaskSpace,
        directory: String,
        worktree: TaskOperation.Worktree?,
        launcher: any TaskAgentLaunching
    ) async -> Bool {
        let job = TaskJob.setup(attempt)
        guard let sessions else {
            fail(job, taskID: taskID, reason: "This Toastty instance cannot fork agent sessions.")
            return false
        }
        guard let record = records.record(id: taskID), let resolved = record.resolved, let agent = resolved.agent,
              record.forkSource?.agent == agent else {
            fail(job, taskID: taskID, reason: "The task has no session to fork. Delete it and create it again.")
            return false
        }

        // A fork that an earlier attempt launched, and that still runs,
        // continues. A relaunch restores it under a new ID in the same
        // terminal, possibly before its launch was saved; as for a task that
        // does not fork, an agent that runs in the task space's terminal
        // counts.
        let earlier = record.operation.agentLaunch
        if earlier?.forkConversationID != nil { return true }
        let live = earlier.flatMap { sessions.session($0.sessionID) }.flatMap { $0.isActive ? $0 : nil }
            ?? sessions.activeSession(panelID: taskSpace.panelID).flatMap { $0.agent.rawValue == agent ? $0 : nil }
        if let live {
            if earlier?.sessionID != live.sessionID {
                let adopted = TaskOperation.AgentLaunch(sessionID: live.sessionID, at: earlier?.at ?? now())
                saveOrDefer(taskID: taskID) { $0.operation.agentLaunch = adopted }
            }
        } else if earlier != nil {
            saveOrDefer(taskID: taskID) { $0.operation.agentLaunch = nil }
        }

        if records.record(id: taskID)?.operation.agentLaunch == nil {
            // The fork copies the conversation as it is on disk, so it waits
            // for the turn that created the task to end. Every fork asked
            // for in that turn copies the conversation as the turn left it.
            guard await waitForSourceTurnToEnd(job: job, taskID: taskID, sessions: sessions) else { return false }
            let discoveryDeadline = ContinuousClock.now.advanced(by: timing.sourceDiscoveryTimeout)
            guard await waitForSourceConversation(job: job, taskID: taskID, sessions: sessions, deadline: discoveryDeadline),
                  let source = currentSource(taskID: taskID, job: job, sessions: sessions),
                  let record = records.record(id: taskID) else {
                return false
            }
            let prompt = TaskPrompt.forkedTask(
                record: record,
                taskSpaceWorkspaceID: taskSpace.workspaceID,
                sourceWorkspaceID: store.state.workspaceSelection(containingPanelID: source.panelID)?.workspace.id,
                worktree: worktree,
                base: record.operation.base
            )
            let result: AgentLaunchResult
            do {
                result = try await Self.launchWhenSourceIsKnown(deadline: discoveryDeadline, pollInterval: timing.pollInterval) {
                    try await Self.launchWhenTerminalIsReady(timeout: terminalReadinessTimeout) {
                        try await launcher.launchTask(
                            profileID: agent,
                            workspaceID: taskSpace.workspaceID,
                            panelID: taskSpace.panelID,
                            cwd: directory,
                            model: resolved.model,
                            reasoningEffort: resolved.effort,
                            initialPrompt: prompt,
                            parentSessionID: nil,
                            forkFromSessionID: source.sessionID,
                            // As for any task: unscoped unless the session
                            // that made the task was scoped; then that scope,
                            // with this task space added.
                            scopedWorkspaceIDs: record.creatorScope.map { $0.union([taskSpace.workspaceID]) },
                            beforeDispatch: { [weak self] in
                                guard let self, self.isCurrent(job, taskID: taskID) else {
                                    throw CancellationError()
                                }
                            }
                        )
                    }
                }
            } catch {
                if error is CancellationError || Task.isCancelled { return false }
                if case .commandDeliveryUncertain? = error as? AgentLaunchError {
                    fail(job, taskID: taskID, reason: "The agent command may not have reached the terminal. Check the task space before you retry.")
                } else {
                    fail(job, taskID: taskID, reason: Self.launchFailureReason(for: error))
                }
                return false
            }
            saveOrDefer(taskID: taskID) {
                $0.operation.agentLaunch = TaskOperation.AgentLaunch(sessionID: result.sessionID, at: now())
            }
        }

        // The fork counts once the provider reports a conversation of its
        // own.
        guard let current = records.record(id: taskID), let launched = current.operation.agentLaunch,
              let conversationID = await waitForFork(
                  sessionID: launched.sessionID,
                  sourceConversationID: current.forkSource?.conversationID,
                  job: job,
                  taskID: taskID,
                  sessions: sessions
              ) else {
            return false
        }
        saveOrDefer(taskID: taskID) { $0.operation.agentLaunch?.forkConversationID = conversationID }
        ToasttyLog.info("Forked a task's agent from the session that created it", category: .tasks, metadata: [
            "task_id": taskID.uuidString,
            "session_id": launched.sessionID,
            "source_session_id": current.forkSource?.sessionID ?? "",
        ])
        return true
    }
}
