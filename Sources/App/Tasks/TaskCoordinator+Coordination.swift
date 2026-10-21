import CoreState
import Foundation

/// What `task.get` and `task.list` report about a task's agent.
struct TaskAgentStatus: Equatable {
    var activity: TaskAgentState
    var session: TaskSessionInfo?

    var changedAt: Date? { session?.statusUpdatedAt }
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
        let activity: TaskAgentState
        switch session.status?.kind {
        case .working?: activity = .busy
        case .needsApproval?: activity = .waiting
        case .error?: activity = .error
        // A session that has not reported a status yet sits at its prompt.
        case .idle?, .ready?, nil: activity = .idle
        }
        return TaskAgentStatus(activity: activity, session: session)
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
        switch deliver(text, to: session, taskID: taskID) {
        case .delivered:
            return session
        case .uncertain:
            throw TaskError(
                "Toastty typed the message into task \(record.title)'s terminal but may not have submitted it. Check that terminal before you send it again."
            )
        case .unavailable:
            throw TaskError("Toastty could not type into task \(record.title)'s terminal.")
        }
    }

    private func deliver(_ text: String, to session: TaskSessionInfo, taskID: UUID) -> TerminalInputDeliveryResult {
        let result = sessions?.deliver(text, panelID: session.panelID) ?? .unavailable
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
        if let reason = TaskWatchEvaluation.impossibility(condition, facts: watchFacts(target)) {
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

    /// What a watch on `record` reads now.
    func watchFacts(_ record: TaskRecord) -> TaskWatchFacts {
        let status = agentStatus(of: record)
        return TaskWatchFacts(
            activity: status.activity,
            activityChangedAt: status.changedAt,
            turnEndedAt: status.session?.lastTurnEndedAt,
            stages: stageConditions(record)
        )
    }

    /// Fires every pending watch whose condition holds or can no longer
    /// hold, and delivers fired messages that have not gone out yet.
    func evaluateWatches() {
        let at = now()
        for holder in records.records where holder.watches?.isEmpty == false {
            guard holder.activeWatches.isEmpty == false else {
                pruneFiredWatches(of: holder, at: at)
                continue
            }
            var updated = holder.watches ?? []
            for index in updated.indices {
                let watch = updated[index]
                if watch.isPending, let fired = firing(watch, at: at) {
                    updated[index].state = fired
                    ToasttyLog.info("Fired a task watch", category: .tasks, metadata: [
                        "watch_id": watch.id.uuidString,
                        "notify_task_id": holder.id.uuidString,
                    ])
                }
                guard case .fired(let firedAt, let reason, let impossible, false) = updated[index].state,
                      let session = liveAgentSession(of: holder) else { continue }
                let message = Self.watchMessage(updated[index], targetTitle: records.record(id: watch.targetTaskID)?.title)
                // A message that may have been typed without its Return is not
                // sent again: a second copy would land in the same prompt.
                if deliver(message, to: session, taskID: holder.id) != .unavailable {
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
            } else if wait.watch.isPending, let fired = firing(wait.watch, at: at) {
                if case .fired(let firedAt, let reason, let impossible, _) = fired {
                    waitWatches[id]?.watch.state = .fired(at: firedAt, reason: reason, impossible: impossible, delivered: true)
                }
            } else if let firedAt = wait.firedAt, at.timeIntervalSince(firedAt) > Self.firedWaitWatchLifetime {
                waitWatches[id] = nil
            }
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

    private func firing(_ watch: TaskWatch, at: Date) -> TaskWatchState? {
        guard let target = records.record(id: watch.targetTaskID) else {
            return .fired(at: at, reason: "was deleted", impossible: true, delivered: false)
        }
        let facts = watchFacts(target)
        if TaskWatchEvaluation.holds(watch.condition, createdAt: watch.createdAt, facts: facts) {
            return .fired(at: at, reason: watch.condition.phrase, impossible: false, delivered: false)
        }
        if let reason = TaskWatchEvaluation.impossibility(watch.condition, facts: facts) {
            return .fired(at: at, reason: reason, impossible: true, delivered: false)
        }
        return nil
    }

    /// The message a fired watch sends: one line, so no agent reads part of
    /// it as a separate message.
    static func watchMessage(_ watch: TaskWatch, targetTitle: String?) -> String {
        guard case .fired(_, let reason, let impossible, _) = watch.state else { return "" }
        let target = watch.targetTaskID.uuidString
        let name = targetTitle.map { "\"\($0.replacingOccurrences(of: "\n", with: " "))\" (\(target))" } ?? target
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
}
