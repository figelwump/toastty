import CoreState
import Foundation
import RemoteProtocol

/// What `task.get` and `task.list` report about a task's agent.
struct TaskAgentStatus: Equatable {
    var activity: TaskAgentState
    var session: TaskSessionInfo?

    /// When the agent entered `activity`. `nil` when no agent runs.
    var changedAt: Date? { session?.stateChangedAt }
}

/// A `toastty task watch --wait` watch: kept in memory, read by polling.
struct TaskWaitWatch: Equatable {
    var watch: TaskWatch
    /// Updated by each `task.watches` read of this watch. A pending watch
    /// nobody reads, because its caller quit, is dropped.
    var lastReadAt: Date
    var firedAt: Date? {
        if case .fired(let at, _, _, _) = watch.state { return at }
        return nil
    }
}

extension TaskCoordinator {
    static let watchPollInterval: Duration = .seconds(1)
    /// How long a fired `--wait` watch stays readable.
    static let firedWaitWatchLifetime: TimeInterval = 600
    /// How long a pending `--wait` watch lasts without being read.
    static let unreadWaitWatchLifetime: TimeInterval = 60

    // MARK: - The task's agent

    /// The agent session that works on the task now. Session IDs change
    /// when Toastty relaunches and restores a session in its pane, and when
    /// start-work moves the task, so this follows the record's panes rather
    /// than trusting a saved ID.
    func liveAgentSession(of record: TaskRecord) -> TaskSessionInfo? {
        liveAgentSession(of: record, ownAgentOnly: false)
    }

    /// The same. With `ownAgentOnly`, never another agent of the task
    /// space: a task Toastty did not start gets only the agent in the pane
    /// its record saved, as when it was adopted.
    func liveAgentSession(of record: TaskRecord, ownAgentOnly: Bool) -> TaskSessionInfo? {
        guard let sessions else { return nil }
        func live(sessionID: String?, panelID: UUID?) -> TaskSessionInfo? {
            if let sessionID, let session = sessions.session(sessionID), session.isActive, session.agent != .processWatch {
                return session
            }
            if let panelID, let session = sessions.activeSession(panelID: panelID), session.agent != .processWatch {
                return session
            }
            return nil
        }
        if let moved = record.operation.worktreeSession, moved.sessionID != nil,
           let session = live(sessionID: moved.sessionID, panelID: moved.panelID) {
            return session
        }
        // The session setup started, then the one a move came from: both stay
        // when a move fails or the agent cannot be forked.
        if let launch = record.operation.agentLaunch,
           let session = live(sessionID: launch.sessionID, panelID: record.operation.taskSpace?.panelID) {
            return session
        }
        if let source = record.startWork?.source, let session = live(sessionID: source.sessionID, panelID: source.panelID) {
            return session
        }
        // Only the agent in the task's own pane, such as the pane an adopted
        // task saved.
        if ownAgentOnly {
            return live(sessionID: nil, panelID: record.operation.taskSpace?.panelID)
        }
        // A task Toastty did not start (rebuilt or adopted), whose saved pane
        // may hold any agent: the agent most recently active in its task
        // space.
        guard let workspaceID = record.taskSpaceWorkspaceID else { return nil }
        return sessions.activeSessions(workspaceID: workspaceID)
            .max { ($0.statusUpdatedAt ?? .distantPast) < ($1.statusUpdatedAt ?? .distantPast) }
    }

    func agentStatus(of record: TaskRecord) -> TaskAgentStatus {
        guard let session = liveAgentSession(of: record) else {
            return TaskAgentStatus(activity: .notRunning, session: nil)
        }
        return TaskAgentStatus(activity: TaskAgentState(statusKind: session.status?.kind), session: session)
    }

    func lastReply(of record: TaskRecord) -> TaskAgentReply? {
        guard let session = liveAgentSession(of: record) else { return nil }
        return sessions?.lastReply(sessionID: session.sessionID)
    }

    /// The task whose task space holds `workspaceID`, if any: how a calling
    /// agent finds its own task, under any session ID.
    func task(inWorkspace workspaceID: UUID?) -> TaskRecord? {
        guard let workspaceID,
              let taskID = store.state.workspacesByID[workspaceID]?.taskID else { return nil }
        return records.record(id: taskID)
    }

    // MARK: - Send

    /// `task send`: gives `text` to the task's agent as soon as the agent
    /// can read it, without typing into a permission prompt, a question, a
    /// dialog, or text that can be in the agent's prompt: see
    /// `TaskSessionProviding.deliverSteering`. It types at the agent's open
    /// prompt, or into a running turn that can read it. When the agent
    /// cannot take it now, or Toastty cannot tell, the message is saved on
    /// the task, as `queueMessage` saves one, so that it waits across a
    /// relaunch, and goes before Toastty's other messages at the next open
    /// prompt (`TaskQueuedMessage.steer`). A message behind an earlier one
    /// that waits waits too, so they keep their order. The message is the
    /// sender's, not the user's typing, so the task's last user input does
    /// not move.
    func send(taskID: UUID, text: String, from: String) async throws -> TaskSteerSendOutcome {
        let (record, session) = try sendTarget(taskID: taskID, text: text)
        if record.waitingMessages.contains(where: \.isSteer) == false,
           let typed = try await typeNow(record: record, session: session, text: text) {
            return typed
        }
        let (message, position) = try queueMessage(taskID: taskID, text: text, from: from, steer: true)
        // The task can have moved to another agent while the send waited.
        let current = records.record(id: taskID).flatMap { liveAgentSession(of: $0) } ?? session
        return .saved(message, position: position, session: current)
    }

    /// What is at the agent's prompt that a typed message and its Return
    /// would join or answer, or `nil` when the prompt is free.
    ///
    /// Text is in the prompt from the first key until a submit sends it,
    /// and that submit starts a turn. So text typed after the latest turn
    /// started can still be there. The conversation that Toastty follows
    /// can tell, when it followed the panel from before that turn started:
    /// an agent at rest records sent text in its transcript. Within the
    /// turn in which following began, it can miss the typing.
    func promptOccupant(of session: TaskSessionInfo) -> TaskPromptOccupant? {
        guard let sessions else { return nil }
        let view = sessions.promptView(in: session)
        if session.status?.kind == .needsApproval || view.showsInteraction {
            return .interaction
        }
        let latestTurnStartedAt = session.latestTurnStartedAt ?? .distantPast
        if let typedAt = unconfirmedDeliveryTimes[session.sessionID], typedAt > latestTurnStartedAt {
            return .unconfirmedMessage
        }
        guard let typedAt = sessions.lastPromptInputAt(panelID: session.panelID), typedAt > latestTurnStartedAt else {
            return nil
        }
        let isAtRest = session.status?.kind == .idle || session.status?.kind == .ready
        if isAtRest, let followedSince = view.openPromptFollowedSince, followedSince < latestTurnStartedAt {
            return nil
        }
        return .typedText
    }

    func submitTaskMessage(
        _ text: String, to session: TaskSessionInfo, for record: TaskRecord, automaticPromptTurnEnd: Date? = nil
    ) throws {
        switch deliver(text, to: session, taskID: record.id, automaticPromptTurnEnd: automaticPromptTurnEnd) {
        case .delivered:
            break
        case .uncertain:
            throw Self.uncertainSendError(record)
        case .unavailable:
            throw Self.unavailableSendError(record)
        }
    }

    /// `send`'s try to type at once. `nil` when the message must wait.
    private func typeNow(record: TaskRecord, session: TaskSessionInfo, text: String) async throws -> TaskSteerSendOutcome? {
        let taskID = record.id
        let text = AgentPasteText.keepingImagePathsAsText(text)
        // The send can wait for the agent's state. Meanwhile the task can
        // move to another agent, as start-work moves it, and another send
        // can save a message, which then goes first. A message that Toastty
        // typed at this prompt meanwhile keeps the prompt.
        let sessionID = session.sessionID
        let result = await sessions?.deliverSteering(text, panelID: session.panelID) { [weak self] target in
            guard let self, let record = self.records.record(id: taskID),
                  let current = self.liveAgentSession(of: record), current.sessionID == sessionID,
                  record.waitingMessages.contains(where: \.isSteer) == false else { return false }
            switch target {
            case .openPrompt: return self.automaticPromptTurnEnd(for: current, rest: .shownByConversation) != nil
            case .runningTurn: return true
            }
        } ?? .success(.mustWait)
        var metadata = [
            "task_id": taskID.uuidString,
            "session_id": session.sessionID,
            "utf8_count": String(text.utf8.count),
        ]
        switch result {
        case .success(.mustWait):
            return nil
        case .success(let delivery):
            metadata["delivery"] = delivery.name
            ToasttyLog.info("Sent a message to a task under the input checks", category: .tasks, metadata: metadata)
            return .typed(delivery, session: session)
        case .failure(let failure):
            metadata["failure"] = String(describing: failure)
            ToasttyLog.warning("A message to a task was not sent under the input checks", category: .tasks, metadata: metadata)
            switch failure {
            case .unavailable:
                throw Self.unavailableSendError(record)
            case .uncertain:
                throw Self.uncertainSendError(record)
            }
        }
    }

    /// The task and its running agent, for a message that is not empty.
    private func sendTarget(taskID: UUID, text: String) throws -> (TaskRecord, TaskSessionInfo) {
        guard let record = records.record(id: taskID) else {
            throw TaskError("No task has ID \(taskID.uuidString).")
        }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard message.isEmpty == false else {
            throw TaskError("The message is empty.")
        }
        guard let session = liveAgentSession(of: record) else {
            throw TaskError("Task \(record.title) has no running agent.")
        }
        return (record, session)
    }

    private static func uncertainSendError(_ record: TaskRecord) -> TaskError {
        TaskError(
            "Toastty typed the message into task \(record.title)'s terminal but may not have submitted it. Check that terminal before you send it again."
        )
    }

    private static func unavailableSendError(_ record: TaskRecord) -> TaskError {
        TaskError("Toastty could not type into task \(record.title)'s terminal.")
    }

    /// Types `text` and presses Return, with image paths kept as text so
    /// that the Return submits it (`AgentPasteText`).
    func deliver(
        _ text: String, to session: TaskSessionInfo, taskID: UUID, automaticPromptTurnEnd: Date? = nil
    ) -> TerminalInputDeliveryResult {
        let text = AgentPasteText.keepingImagePathsAsText(text)
        let result = sessions?.deliver(text, panelID: session.panelID) ?? .unavailable
        if result == .uncertain {
            // The text may still be at the prompt, even after a manual send.
            automaticPromptDeliveryTurnEnds[session.sessionID] = session.lastTurnEndedAt ?? .distantPast
            unconfirmedDeliveryTimes[session.sessionID] = now()
        } else if result == .delivered, let automaticPromptTurnEnd {
            automaticPromptDeliveryTurnEnds[session.sessionID] = automaticPromptTurnEnd
        }
        let metadata = [
            "task_id": taskID.uuidString,
            "session_id": session.sessionID,
            "utf8_count": String(text.utf8.count),
        ]
        switch result {
        case .delivered:
            ToasttyLog.info("Sent a message to a task", category: .tasks, metadata: metadata)
        case .uncertain:
            ToasttyLog.warning("A message to a task may not have been submitted", category: .tasks, metadata: metadata)
        case .unavailable:
            break
        }
        return result
    }

    // MARK: - Watch

    /// A single continuation on Opus, for the exact stopped task the
    /// coordinator saw. Keep the provider conversation and worktree.
    func recoverFableTask(taskID: UUID, expectedSessionID: String) throws {
        guard let launcher = launcher as? AgentLaunchService,
              let task = records.record(id: taskID), task.setup.isStarted,
              task.doneAt == nil, task.archivedAt == nil, task.replyRequest == nil,
              task.mergeFailure == nil, task.startWork?.state != .running,
              let session = liveAgentSession(of: task, ownAgentOnly: true),
              session.workspaceID == task.taskSpaceWorkspaceID,
              [task.operation.taskSpace?.panelID, task.operation.worktreeSession?.panelID].contains(session.panelID),
              session.sessionID == expectedSessionID, !session.hasBackgroundWork,
              let source = launcher.claudeRecoverySource(sessionID: session.sessionID),
              let quota = source.status?.claudeFableQuota,
              let access = launcher.quotaRecoveryConversationAccess else {
            throw TaskError("The selected task has no confirmed, recoverable Fable quota failure.")
        }
        guard recoveringFableTasks.insert(taskID).inserted else {
            throw TaskError("Toastty is already recovering this task.")
        }
        recoveringFableTaskPanels[taskID] = source.panelID
        let oldSubscription = access.subscribeToConversation(inPanel: source.panelID)
        Task { @MainActor [weak self, weak launcher] in
            defer {
                oldSubscription.cancel()
                self?.recoveringFableTasks.remove(taskID)
                self?.recoveringFableTaskPanels.removeValue(forKey: taskID)
            }
            guard let self, let launcher else { return }
            do {
                // Without a phone connection or an open chat, this may be
                // the first follower of the task. Replaying its StopFailure
                // opens the composer only after the provider settle window.
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(3))
                while clock.now < deadline {
                    let availability = access.inputAvailability(panelID: source.panelID, sessionID: source.sessionID)
                    guard availability == nil || availability == .unavailable(reason: .interrupted)
                            || availability == .unavailable(reason: .unknownProviderState) else { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                let launch = try await launcher.resumeClaudeAfterQuota(
                    source: source, nativeID: quota.nativeSessionID,
                    model: ClaudeFableQuota.fallbackModel, effort: ClaudeFableQuota.fallbackEffort,
                    isStillEligible: {
                        guard !self.isTerminating, let record = self.records.record(id: taskID),
                              record.doneAt == nil, record.archivedAt == nil, record.replyRequest == nil,
                              record.mergeFailure == nil, record.startWork?.state != .running,
                              self.liveAgentSession(of: record, ownAgentOnly: true)?.sessionID == expectedSessionID,
                              self.promptOccupant(of: session) == nil,
                              !self.hasWaitingSteerMessage(for: session) else { return false }
                        return launcher.claudeRecoveryPromptIsFree(source: source)
                    },
                    adoptPanel: { panelID, sessionID in
                        try self.records.save(id: taskID) { record in
                            if record.operation.worktreeSession?.panelID == source.panelID {
                                record.operation.worktreeSession?.panelID = panelID
                                record.operation.worktreeSession?.sessionID = sessionID
                            }
                            if record.operation.taskSpace?.panelID == source.panelID {
                                record.operation.taskSpace?.panelID = panelID
                                record.operation.agentLaunch?.sessionID = sessionID
                            }
                        }
                        self.recoveringFableTaskPanels[taskID] = panelID
                    }
                )
                self.flushLayout()
                let (subscription, summary) = try await launcher.waitForRecoveredClaude(
                    launch, nativeID: quota.nativeSessionID, model: ClaudeFableQuota.fallbackModel
                )
                defer { subscription.cancel() }
                guard let record = self.records.record(id: taskID), record.replyRequest == nil,
                      record.doneAt == nil, record.archivedAt == nil,
                      let current = self.liveAgentSession(of: record, ownAgentOnly: true),
                      current.sessionID == launch.sessionID, current.lastTurnEndedAt == nil,
                      case .openPrompt(let epoch) = summary.inputAvailability else { return }
                self.saveOrDefer(taskID: taskID) { record in
                    record.resolved?.model = ClaudeFableQuota.fallbackModel
                    record.resolved?.effort = ClaudeFableQuota.fallbackEffort
                }
                _ = subscription.send(RemoteMessageSendRequest(
                    conversationID: summary.conversationID, clientRequestID: UUID().uuidString,
                    expectedInputEpoch: epoch,
                    text: "Fable reached its usage limit. Continue the task on Opus 5.5 at high effort. Check the effects of any action already taken before retrying it."
                ), byUser: false)
            } catch {
                ToasttyLog.warning("Fable task recovery stopped", category: .tasks, metadata: [
                    "task_id": taskID.uuidString, "reason": error.localizedDescription,
                ])
            }
        }
    }

    /// Saves a watch on `notifyTaskID`'s record, or keeps it in memory for
    /// a caller that polls, when `notifyTaskID` is `nil`.
    func addWatch(targetTaskID: UUID, condition: TaskWatchCondition, notifyTaskID: UUID?) throws -> TaskWatch {
        guard let target = records.record(id: targetTaskID) else {
            throw TaskError("No task has ID \(targetTaskID.uuidString).")
        }
        if let notifyTaskID {
            guard records.record(id: notifyTaskID) != nil else {
                throw TaskError("No task has ID \(notifyTaskID.uuidString).")
            }
            guard notifyTaskID != targetTaskID else {
                throw TaskError("A task cannot watch itself.")
            }
        }
        if let reason = TaskWatchEvaluation.impossibility(condition, facts: watchFacts(target, stages: [:])) {
            throw TaskError("Task \(target.title) \(reason), so it can never be \(condition.rawValue).")
        }
        let watch = TaskWatch(targetTaskID: targetTaskID, condition: condition, createdAt: now())
        if let notifyTaskID {
            do {
                try records.save(id: notifyTaskID) { record in
                    record.watches = (record.watches ?? []) + [watch]
                }
            } catch {
                throw TaskError("Toastty could not save the watch: \(error.localizedDescription)")
            }
        } else {
            waitWatches[watch.id] = TaskWaitWatch(watch: watch, lastReadAt: now())
        }
        ToasttyLog.info("Added a task watch", category: .tasks, metadata: [
            "watch_id": watch.id.uuidString,
            "target_task_id": targetTaskID.uuidString,
            "notify_task_id": notifyTaskID?.uuidString ?? "none",
            "condition": condition.rawValue,
        ])
        evaluateWatches()
        startWatchMonitorIfNeeded()
        return watch
    }

    /// Notes that a `--wait` caller read the watch, so it is still waiting.
    func noteWaitWatchRead(id: UUID) {
        waitWatches[id]?.lastReadAt = now()
    }

    /// The watch with this ID and the task it notifies (`nil` for `--wait`).
    func watch(id: UUID) -> (watch: TaskWatch, notifyTaskID: UUID?)? {
        if let wait = waitWatches[id] { return (wait.watch, nil) }
        for record in records.records {
            if let watch = record.watches?.first(where: { $0.id == id }) { return (watch, record.id) }
        }
        return nil
    }

    /// Every saved watch with the task it notifies, then `--wait` watches.
    func allWatches() -> [(watch: TaskWatch, notifyTaskID: UUID?)] {
        records.records.flatMap { record in (record.watches ?? []).map { ($0, Optional(record.id)) } }
            + waitWatches.values.sorted { $0.watch.createdAt < $1.watch.createdAt }.map { ($0.watch, nil) }
    }

    func cancelWatch(id: UUID) throws {
        if waitWatches.removeValue(forKey: id) != nil { return }
        guard let holder = records.records.first(where: { $0.watches?.contains { $0.id == id } == true }) else {
            throw TaskError("No watch has ID \(id.uuidString).")
        }
        do {
            try records.save(id: holder.id) { record in
                record.watches = record.watches?.filter { $0.id != id }
                if record.watches?.isEmpty == true { record.watches = nil }
            }
        } catch {
            throw TaskError("Toastty could not save the task: \(error.localizedDescription)")
        }
    }

    /// What a watch on `record` reads now. `stages` comes from
    /// `stageConditionsByTaskID()`, read once per pass over the watches. The
    /// archive is read from the record itself, so a watch of any condition
    /// learns that its task was archived without building the board.
    func watchFacts(_ record: TaskRecord, stages: [UUID: Set<TaskWatchCondition>]) -> TaskWatchFacts {
        let status = agentStatus(of: record)
        return TaskWatchFacts(
            activity: status.activity,
            activityChangedAt: status.session?.statusUpdatedAt,
            turnEndedAt: status.session?.lastTurnEndedAt,
            stages: record.archivedAt != nil ? [.archived] : stages[record.id] ?? [],
            // A pull request merged on GitHub after a failed merge.
            mergeFailure: record.mergedAt == nil ? record.mergeFailure?.reason : nil,
            messagesWaiting: record.waitingMessages.isEmpty == false,
            messageTypedAt: record.queuedMessages?.compactMap { message in
                message.outcome.flatMap { $0.kind == .dropped ? nil : $0.at }
            }.max()
        )
    }

    /// The stage conditions each task meets now, from the stages the task
    /// board works out. Empty without a board, so stage watches then wait.
    func stageConditionsByTaskID() -> [UUID: Set<TaskWatchCondition>] {
        guard let board else { return [:] }
        var result: [UUID: Set<TaskWatchCondition>] = [:]
        for item in board.items() {
            guard let record = item.record else { continue }
            // A task that finished through its child tasks merged with them.
            result[record.id] = TaskWatchEvaluation.stageConditions(stage: item.stage, merged: item.hasMerged)
        }
        return result
    }

    /// Fires every pending watch whose condition holds or can no longer
    /// hold, delivers fired messages that have not gone out yet, then
    /// types the queued messages that an open prompt can take. A watch's
    /// line goes first: its agent ended its turn to wait for it.
    func evaluateWatches() {
        let at = now()
        automaticPromptDeliveryTurnEnds = automaticPromptDeliveryTurnEnds.filter {
            sessions?.session($0.key)?.isActive == true
        }
        unconfirmedDeliveryTimes = unconfirmedDeliveryTimes.filter { sessions?.session($0.key)?.isActive == true }
        // An answer to the task's question goes first: a turn that another
        // message starts would clear the question. A `task send` message
        // was meant for the agent's turn, so it goes before a watch's line.
        deliverApprovalAnswers(at: at)
        deliverQueuedMessages(at: at, steer: true)
        // Building the board walks every task, so only a pass with a pending
        // watch that needs it does so, and only once. Archived is read from
        // the record.
        func needsBoard(_ watch: TaskWatch) -> Bool {
            watch.isPending && watch.condition.isStageCondition && watch.condition != .archived
        }
        let hasPendingStageWatch = waitWatches.values.contains { needsBoard($0.watch) }
            || records.records.contains { $0.watches?.contains(where: needsBoard) == true }
        let stages = hasPendingStageWatch ? stageConditionsByTaskID() : [:]
        for holder in records.records where holder.watches?.isEmpty == false {
            guard holder.activeWatches.isEmpty == false else {
                pruneFiredWatches(of: holder, at: at)
                continue
            }
            var updated = holder.watches ?? []
            for index in updated.indices {
                let watch = updated[index]
                if watch.isPending, let fired = firing(watch, at: at, stages: stages) {
                    updated[index].state = fired
                    ToasttyLog.info("Fired a task watch", category: .tasks, metadata: [
                        "watch_id": watch.id.uuidString,
                        "notify_task_id": holder.id.uuidString,
                    ])
                }
                guard case .fired(let firedAt, let reason, let impossible, false) = updated[index].state,
                      let session = liveAgentSession(of: holder),
                      let turnEnd = automaticPromptTurnEnd(for: session) else { continue }
                let message = Self.watchMessage(updated[index], targetTitle: records.record(id: watch.targetTaskID)?.title)
                // A message that may have been typed without its Return is not
                // sent again: a second copy would land in the same prompt.
                if deliver(message, to: session, taskID: holder.id, automaticPromptTurnEnd: turnEnd) != .unavailable {
                    updated[index].state = .fired(at: firedAt, reason: reason, impossible: impossible, delivered: true)
                }
            }
            guard updated != holder.watches ?? [] else { continue }
            saveOrDefer(taskID: holder.id) { record in
                // Merge by ID: a watch added or cancelled since the read wins.
                record.watches = record.watches?.map { saved in updated.first { $0.id == saved.id } ?? saved }
                record.pruneFiredWatches(now: at)
            }
        }
        for (id, wait) in waitWatches {
            if wait.watch.isPending, at.timeIntervalSince(wait.lastReadAt) > Self.unreadWaitWatchLifetime {
                waitWatches[id] = nil
            } else if wait.watch.isPending, let fired = firing(wait.watch, at: at, stages: stages) {
                if case .fired(let firedAt, let reason, let impossible, _) = fired {
                    waitWatches[id]?.watch.state = .fired(at: firedAt, reason: reason, impossible: impossible, delivered: true)
                }
            } else if let firedAt = wait.firedAt, at.timeIntervalSince(firedAt) > Self.firedWaitWatchLifetime {
                waitWatches[id] = nil
            }
        }
        deliverQueuedMessages(at: at, steer: false)
    }

    /// The open prompt a watch, wake, merge or queued message can use, one
    /// message for each open prompt. A provider can show an interaction
    /// while its hooks report ready, or keep reporting ready after an
    /// automatic submission starts the next turn. A `task send` message
    /// that waits takes the prompt first, unless `yieldsToSteer` is false:
    /// for the call that types it, and for an answer to the task's
    /// question, which goes before it. One that `task send` typed there
    /// took the prompt. `rest` says what shows that the agent rests at its
    /// prompt.
    func automaticPromptTurnEnd(
        for session: TaskSessionInfo, yieldsToSteer: Bool = true, rest: TaskPromptRest = .reported
    ) -> Date? {
        guard let sessions, rest.holds(for: session.status?.kind),
              !recoveringFableTaskPanels.values.contains(session.panelID),
              promptOccupant(of: session) == nil,
              yieldsToSteer == false || hasWaitingSteerMessage(for: session) == false else { return nil }
        let turnEnd = session.lastTurnEndedAt ?? .distantPast
        if let steeredAt = sessions.lastSteerTypedAt(panelID: session.panelID), steeredAt > turnEnd { return nil }
        if let previous = automaticPromptDeliveryTurnEnds[session.sessionID], turnEnd <= previous { return nil }
        return turnEnd
    }

    /// Whether a `task send` message waits for the session's prompt: the
    /// task it works on has one.
    private func hasWaitingSteerMessage(for session: TaskSessionInfo) -> Bool {
        records.records.contains { record in
            record.waitingMessages.contains(where: \.isSteer)
                && liveAgentSession(of: record)?.sessionID == session.sessionID
        }
    }

    /// Drops delivered watches past their time, for a task with nothing
    /// left to deliver.
    private func pruneFiredWatches(of holder: TaskRecord, at: Date) {
        var pruned = holder
        pruned.pruneFiredWatches(now: at)
        guard pruned.watches != holder.watches else { return }
        saveOrDefer(taskID: holder.id) { $0.pruneFiredWatches(now: at) }
    }

    private func firing(_ watch: TaskWatch, at: Date, stages: [UUID: Set<TaskWatchCondition>]) -> TaskWatchState? {
        guard let target = records.record(id: watch.targetTaskID) else {
            return .fired(at: at, reason: "was deleted", impossible: true, delivered: false)
        }
        let facts = watchFacts(target, stages: stages)
        // An archived task ends every watch but one until archived, even one
        // whose agent happens to be idle or waiting.
        if let reason = TaskWatchEvaluation.impossibility(watch.condition, facts: facts) {
            return .fired(at: at, reason: reason, impossible: true, delivered: false)
        }
        if TaskWatchEvaluation.holds(watch.condition, createdAt: watch.createdAt, facts: facts) {
            let reason = TaskWatchEvaluation.reason(watch.condition, facts: facts)
            return .fired(at: at, reason: reason, impossible: false, delivered: false)
        }
        return nil
    }

    /// The message a fired watch sends: one line, so no agent reads part of
    /// it as a separate message.
    static func watchMessage(_ watch: TaskWatch, targetTitle: String?) -> String {
        guard case .fired(_, let reason, let impossible, _) = watch.state else { return "" }
        let target = watch.targetTaskID.uuidString
        // The title as a link, for the agent to name the task by; the ID
        // stays in the command.
        let name = targetTitle.map { CoordinatorTaskLink.markdown(taskID: watch.targetTaskID, title: $0) } ?? target
        let prefix = "[Toastty watch \(watch.id.uuidString)] Task \(name) \(reason)"
        if impossible {
            return "\(prefix), so your watch until \(watch.condition.rawValue) can never fire."
        }
        return "\(prefix). Read it with: toastty task get \(target)"
    }

    /// Checks watches and queued messages once a second while any is
    /// waiting. Record and status changes are frequent and spread across
    /// the app; a short poll over the few tasks with watches or queued
    /// messages is simpler than hooking each of them.
    func startWatchMonitorIfNeeded() {
        guard watchMonitor == nil, hasActiveWatches else { return }
        watchMonitor = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: Self.watchPollInterval)
                guard let self else { return }
                self.evaluateWatches()
                if self.hasActiveWatches == false {
                    self.watchMonitor = nil
                    return
                }
            }
        }
    }

    /// Whether a watch or a queued message still has a line to type.
    private var hasActiveWatches: Bool {
        waitWatches.isEmpty == false
            || records.records.contains {
                $0.activeWatches.isEmpty == false || $0.waitingMessages.isEmpty == false || $0.lastApprovalAnswer?.delivery == .queued
            }
    }

    // MARK: - Wakes of waiting tasks

    /// How long a due wake waits before Toastty tries it again, when the
    /// task's agent was busy, asked something, or could not take the line.
    static let wakeRetryInterval: TimeInterval = 30
    /// The longest the wake monitor sleeps, so that a mark set while it
    /// sleeps is late by at most this.
    static let wakeCheckMaximumInterval: TimeInterval = 60

    /// Runs while a `task waiting` mark has a wake to come. It sleeps until
    /// the earliest wake, at most a minute, rather than polling each second
    /// for a date that can be months away.
    func startWakeMonitorIfNeeded() {
        guard wakeMonitor == nil, records.records.contains(where: { $0.waiting?.hasPendingWake == true }) else { return }
        wakeMonitor = Task { [weak self] in
            while Task.isCancelled == false {
                // No strong reference across the sleep.
                guard let delay = self?.evaluateWakes() else {
                    self?.wakeMonitor = nil
                    return
                }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// Starts the wake of each waiting task whose time came, and returns
    /// the seconds until the next check, or `nil` when no wake is to come.
    @discardableResult
    func evaluateWakes() -> TimeInterval? {
        let at = now()
        var next: TimeInterval?
        func checkAgain(in seconds: TimeInterval) {
            let seconds = min(max(seconds, 1), Self.wakeCheckMaximumInterval)
            next = min(next ?? seconds, seconds)
        }
        for record in records.records {
            guard let waiting = record.waiting, waiting.hasPendingWake, let wakeAt = waiting.wakeAt else { continue }
            guard waiting.wakeIsDue(at: at) else {
                checkAgain(in: wakeAt.timeIntervalSince(at))
                continue
            }
            // A finished task waits on nothing: a wake would start new work
            // in it, which clears a done mark.
            if finishedReason(record) != nil {
                saveOrDefer(taskID: record.id) { $0.waiting = nil }
                continue
            }
            if let retryAt = wakeRetryAt[record.id], retryAt > at {
                checkAgain(in: retryAt.timeIntervalSince(at))
                continue
            }
            guard sendWake(record, waiting: waiting, at: at) else {
                wakeRetryAt[record.id] = at.addingTimeInterval(Self.wakeRetryInterval)
                checkAgain(in: Self.wakeRetryInterval)
                continue
            }
            wakeRetryAt[record.id] = nil
        }
        return next
    }

    /// Types the waiting task's wake line into its own agent's terminal, as
    /// a watch's line goes, and submits it. A question from the task for
    /// the user also blocks the wake, since its turn would clear the
    /// question. The checks, typing and mark happen in one step. Returns
    /// false when the wake must wait.
    private func sendWake(_ record: TaskRecord, waiting: TaskWaiting, at: Date) -> Bool {
        guard record.replyRequest == nil,
              let session = liveAgentSession(of: record, ownAgentOnly: true),
              let turnEnd = automaticPromptTurnEnd(for: session) else { return false }
        // Marked first, so that the turn the line starts clears the mark
        // (`clearMarksForNewWork`), and no second line goes.
        saveOrDefer(taskID: record.id) { $0.waiting?.wokenAt = at }
        let result = deliver(Self.wakeMessage(waiting), to: session, taskID: record.id, automaticPromptTurnEnd: turnEnd)
        let metadata = ["task_id": record.id.uuidString, "session_id": session.sessionID, "delivery": "\(result)"]
        guard result != .unavailable else {
            ToasttyLog.info("A waiting task's wake must wait", category: .tasks, metadata: metadata)
            saveOrDefer(taskID: record.id) { saved in
                if saved.waiting?.wokenAt == at { saved.waiting?.wokenAt = nil }
            }
            return false
        }
        // `.uncertain` counts as sent: a second copy would land in the same
        // prompt.
        ToasttyLog.info("Sent a waiting task its wake", category: .tasks, metadata: metadata)
        return true
    }

    /// The line a wake sends: one line, so no agent reads part of it as a
    /// separate message.
    static func wakeMessage(_ waiting: TaskWaiting) -> String {
        let time = waiting.wakeAt.map { ISO8601DateFormatter().string(from: $0) } ?? "now"
        return "[Toastty wake] The time you set with toastty task waiting has come (\(time)). "
            + "The task waited for: \(waiting.on). Go on with that work. "
            + "If the task still waits when this turn ends, run toastty task waiting again."
    }

    // MARK: - Queued messages

    /// Why the task's work is finished, if it is: it merged (a task that is
    /// not a release), shipped, was marked Done or was archived, or it
    /// finished through its child tasks (`TaskStage.derivation`). New work
    /// in it would reopen it. The sidebar's done box marks only the task
    /// space. A mark that records a merge's acceptance is not finished
    /// work: new work keeps it while the merge waits.
    func finishedReason(_ record: TaskRecord) -> String? {
        if record.archivedAt != nil { return "the task was archived" }
        if record.shippedAt != nil { return "the task shipped" }
        if record.release == nil, record.mergedAt != nil { return "the task merged" }
        let taskSpaceDone = record.taskSpaceWorkspaceID.flatMap { id in
            TaskBoard.isInMergeFlow(record, request: merges?.request(workspaceID: id))
                ? nil : store.state.workspacesByID[id]?.doneAt
        } != nil
        if record.doneAt != nil || taskSpaceDone { return "the task was marked Done" }
        // Only the board works this out. It is kept between passes, and
        // only a task with child tasks asks for it.
        if records.records.contains(where: { $0.parentTaskID == record.id }),
           board?.item(taskID: record.id)?.finishedThroughChildren == true {
            return "the task finished through its child tasks"
        }
        return nil
    }

    /// `task send --queue`: leaves `text` for the task's agent, typed at
    /// its next open prompt, after the messages that already wait. The
    /// prompt can be open now, and then Toastty types the oldest waiting
    /// message at once. Returns the message as it is after that, and its
    /// place in the queue while it waits. With `steer`, the message is one
    /// that `send` could not type now (`TaskQueuedMessage.steer`).
    func queueMessage(
        taskID: UUID, text: String, from: String, steer: Bool = false
    ) throws -> (message: TaskQueuedMessage, position: Int?) {
        let (record, _) = try sendTarget(taskID: taskID, text: text)
        if let reason = steer ? Self.steerDropReason(record) : finishedReason(record) {
            throw TaskError(
                steer
                    ? "Toastty cannot hold a message for task \(record.title): \(reason). Nothing was typed."
                    : "Toastty queues no message for task \(record.title): \(reason). A send without --queue gives it to the agent and reopens the task."
            )
        }
        guard record.waitingMessages.count < TaskRecord.maximumWaitingMessages else {
            throw TaskError(
                "Task \(record.title) already has \(TaskRecord.maximumWaitingMessages) messages that wait for its agent's next prompt. Nothing was added."
            )
        }
        let message = TaskQueuedMessage(text: text, from: from, queuedAt: now(), steer: steer)
        do {
            try records.save(id: taskID) { $0.queuedMessages = ($0.queuedMessages ?? []) + [message] }
        } catch {
            throw TaskError("Toastty could not save the message: \(error.localizedDescription)")
        }
        ToasttyLog.info("Queued a message for a task's agent", category: .tasks, metadata: [
            "task_id": taskID.uuidString,
            "message_id": message.id.uuidString,
            "utf8_count": String(text.utf8.count),
            "steer": String(steer),
        ])
        evaluateWatches()
        startWatchMonitorIfNeeded()
        let saved = records.record(id: taskID)
        // The place in the order Toastty types them: `task send` messages
        // first, then `--queue` messages.
        let order = (saved?.waitingMessages ?? []).filter(\.isSteer) + (saved?.waitingMessages ?? []).filter { $0.isSteer == false }
        let position = order.firstIndex { $0.id == message.id }.map { $0 + 1 }
        return (saved?.queuedMessages?.first { $0.id == message.id } ?? message, position)
    }

    /// Why a waiting `task send` message is dropped: only an archived task.
    /// A `task send` to an open prompt types at once also in a task that
    /// merged or is Done, so one that waits is typed there too.
    private static func steerDropReason(_ record: TaskRecord) -> String? {
        record.archivedAt != nil ? "the task was archived" : nil
    }

    /// Types the oldest waiting message of each task whose agent has an
    /// open prompt that no other message of Toastty's took, and drops the
    /// waiting messages of a task that finished. `steer` picks the
    /// `task send` messages that had to wait, which go before Toastty's
    /// other messages, or the `--queue` messages, which go after them.
    ///
    /// A `task send` message also takes the prompt of an agent whose turn
    /// an error ended: the agent waits at its prompt, and such a message
    /// often tells it to continue.
    ///
    /// `--queue` messages also wait while the task's question waits for the
    /// user, since the turn a message starts clears the question, as a wake
    /// waits; and while a quit cut off the agent's turn, since that turn
    /// still needs to go on and a new turn hides that it was cut off.
    private func deliverQueuedMessages(at: Date, steer: Bool) {
        for record in records.records where record.queuedMessages?.isEmpty == false {
            let waiting = record.waitingMessages
            guard waiting.isEmpty == false else {
                guard steer == false else { continue }
                var pruned = record
                pruned.pruneSettledMessages(now: at)
                if pruned.queuedMessages != record.queuedMessages {
                    saveOrDefer(taskID: record.id) { $0.pruneSettledMessages(now: at) }
                }
                continue
            }
            guard let message = waiting.first(where: { $0.isSteer == steer }) else { continue }
            if let reason = steer ? Self.steerDropReason(record) : finishedReason(record) {
                saveOrDefer(taskID: record.id) { $0.dropWaitingMessages(reason: reason, at: at) { $0.isSteer == steer } }
                ToasttyLog.info("Dropped the queued messages of a finished task", category: .tasks, metadata: [
                    "task_id": record.id.uuidString,
                    "count": String(waiting.filter { $0.isSteer == steer }.count),
                    "reason": reason,
                    "steer": String(steer),
                ])
                continue
            }
            // A merge prompt or a due wake that waits for the same prompt
            // goes before a `--queue` message.
            if steer == false {
                guard record.replyRequest == nil, wasInterruptedAtQuit(record) == false,
                      mergeDeliveryTasks[record.id] == nil, record.waiting?.wakeIsDue(at: at) != true else { continue }
            }
            guard let session = liveAgentSession(of: record),
                  let turnEnd = automaticPromptTurnEnd(
                      for: session, yieldsToSteer: steer == false, rest: steer ? .reportedOrStopped : .reported
                  ) else { continue }
            // Marked first, as a wake is, so that a quit between the typing
            // and the save never types it again.
            func settle(_ outcome: TaskQueuedMessage.Outcome?) {
                saveOrDefer(taskID: record.id) { saved in
                    saved.queuedMessages = saved.queuedMessages?.map { entry in
                        guard entry.id == message.id else { return entry }
                        return outcome.map(message.settled) ?? message
                    }
                    saved.pruneSettledMessages(now: at)
                }
            }
            settle(.init(kind: .sentUnconfirmed, at: at, sessionID: session.sessionID))
            let result = deliver(message.text, to: session, taskID: record.id, automaticPromptTurnEnd: turnEnd)
            guard result != .unavailable else {
                // Nothing was typed: it waits again.
                settle(nil)
                continue
            }
            // `.uncertain` stays typed: a second copy would land in the same
            // prompt.
            let outcome = TaskQueuedMessage.Outcome(
                kind: result == .delivered ? .sent : .sentUnconfirmed, at: at, sessionID: session.sessionID
            )
            if outcome.kind == .sent { settle(outcome) }
            ToasttyLog.info("Typed a queued message for a task's agent", category: .tasks, metadata: [
                "task_id": record.id.uuidString,
                "message_id": message.id.uuidString,
                "session_id": session.sessionID,
                "outcome": outcome.kind.rawValue,
                "steer": String(steer),
            ])
        }
    }
}
