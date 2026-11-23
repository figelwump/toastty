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

    /// Types `text` into the task's agent and submits it.
    @discardableResult
    func send(taskID: UUID, text: String) throws -> TaskSessionInfo {
        let (record, session) = try sendTarget(taskID: taskID, text: text)
        try submitTaskMessage(text, to: session, for: record)
        return session
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

    /// Gives `text` to the task's agent whatever it does now, without
    /// typing into a permission prompt or a question: see
    /// `TaskSessionProviding.deliverSteering`. The message is the sender's,
    /// not the user's typing, so the task's last user input does not move.
    func sendSteering(taskID: UUID, text: String) async throws -> (session: TaskSessionInfo, delivery: TaskSteerDelivery) {
        let (record, session) = try sendTarget(taskID: taskID, text: text)
        let text = AgentPasteText.keepingImagePathsAsText(text)
        let result = await sessions?.deliverSteering(text, panelID: session.panelID) ?? .failure(.stateUnknown)
        var metadata = [
            "task_id": taskID.uuidString,
            "session_id": session.sessionID,
            "utf8_count": String(text.utf8.count),
        ]
        switch result {
        case .success(let delivery):
            metadata["delivery"] = delivery.name
            ToasttyLog.info("Sent a message to a task under the input checks", category: .tasks, metadata: metadata)
            return (session, delivery)
        case .failure(let failure):
            metadata["failure"] = String(describing: failure)
            ToasttyLog.warning("A message to a task was not sent under the input checks", category: .tasks, metadata: metadata)
            switch failure {
            case .stateUnknown:
                throw TaskError(
                    "Toastty cannot tell what task \(record.title)'s agent does now, so it typed nothing. Send the message again when the agent is idle."
                )
            case .unavailable:
                throw Self.unavailableSendError(record)
            case .uncertain:
                throw Self.uncertainSendError(record)
            case .typedInTerminal:
                throw TaskError(
                    "Someone typed in task \(record.title)'s terminal since its agent's latest turn started, and that text can still be in the agent's prompt. Toastty typed nothing, so the two do not mix. Send the message again after the agent's next turn starts, or type it in the task."
                )
            case .queueFull:
                throw TaskError(
                    "Task \(record.title) already has \(TaskSteerSender.maximumHeldMessages) messages that wait for its agent's next prompt. Nothing was added."
                )
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
    private func deliver(
        _ text: String, to session: TaskSessionInfo, taskID: UUID, automaticPromptTurnEnd: Date? = nil
    ) -> TerminalInputDeliveryResult {
        let text = AgentPasteText.keepingImagePathsAsText(text)
        let result = sessions?.deliver(text, panelID: session.panelID) ?? .unavailable
        if result == .uncertain {
            // The text may still be at the prompt, even after a manual send.
            automaticPromptDeliveryTurnEnds[session.sessionID] = session.lastTurnEndedAt ?? .distantPast
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
            mergeFailure: record.mergedAt == nil ? record.mergeFailure?.reason : nil
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
    /// hold, and delivers fired messages that have not gone out yet.
    func evaluateWatches() {
        let at = now()
        automaticPromptDeliveryTurnEnds = automaticPromptDeliveryTurnEnds.filter {
            sessions?.session($0.key)?.isActive == true
        }
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
    }

    /// The open prompt a watch, wake or merge message can use. A provider
    /// can show an interaction while its hooks report ready, or keep
    /// reporting ready after an automatic submission starts the next turn.
    func automaticPromptTurnEnd(for session: TaskSessionInfo) -> Date? {
        guard let sessions, let kind = session.status?.kind, kind == .idle || kind == .ready,
              sessions.hasPendingInteractionOrUserDraft(in: session) == false else { return nil }
        let turnEnd = session.lastTurnEndedAt ?? .distantPast
        if let typedAt = sessions.lastUserInputAt(panelID: session.panelID), typedAt > turnEnd { return nil }
        if let previous = automaticPromptDeliveryTurnEnds[session.sessionID], turnEnd <= previous { return nil }
        return turnEnd
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

    /// Checks watches once a second while any is waiting. Record and status
    /// changes are frequent and spread across the app; a short poll over the
    /// few tasks with watches is simpler than hooking each of them.
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

    private var hasActiveWatches: Bool {
        waitWatches.isEmpty == false || records.records.contains { $0.activeWatches.isEmpty == false }
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
            // in it, which clears a done mark. The sidebar's done box marks
            // only the task space. A mark that records a merge's acceptance
            // is not finished work: new work keeps it while the merge waits.
            let taskSpaceDone = record.taskSpaceWorkspaceID.flatMap { id in
                TaskBoard.isInMergeFlow(record, request: merges?.request(workspaceID: id))
                    ? nil : store.state.workspacesByID[id]?.doneAt
            } != nil
            if record.archivedAt != nil || record.doneAt != nil || record.shippedAt != nil || record.mergedAt != nil
                || taskSpaceDone {
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
}
