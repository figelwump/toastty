import CoreState
import Foundation

extension TaskCoordinator {
    /// Brings every task's `stateTimes` up to date with what Toastty sees
    /// now, and returns the board items it read. The task board runs it
    /// after each change of what a stage depends on, so a time is recorded
    /// when the state changes. `task.get` and `task.list` run it again
    /// before they answer, so a reported time always belongs to the state
    /// reported with it, also after a change no event announced.
    ///
    /// A turn's start is saved at once, so a crash during the turn leaves
    /// its mark. Everything else is saved with the next delayed write.
    @discardableResult
    func recordStateTimes() -> [TaskBoardItem] {
        let at = now()
        let items = board?.items() ?? []
        let itemsByTaskID = Dictionary(
            items.compactMap { item in item.taskID.map { ($0, item) } },
            uniquingKeysWith: { first, _ in first }
        )
        var changed: [UUID: TaskStateTimes] = [:]
        var turnStarted = false
        for record in records.records {
            var times = record.stateTimes ?? TaskStateTimes()
            if let item = itemsByTaskID[record.id] {
                let key = TaskStageClock.Key(item.stage)
                if stageAwaitsGitHub(item) {
                    // A guess has no time; see `stageAwaitsGitHub`.
                } else if times.stage == nil {
                    times.stage = TaskStageClock(key: key, since: at)
                    stageSeenTaskIDs.insert(record.id)
                } else {
                    times.stage?.observe(key, now: at, afterRelaunch: stageSeenTaskIDs.insert(record.id).inserted)
                }
                times.checksPending = checksPending(saved: times.checksPending, item: item, at: at)
            }

            let agent = agentStatus(of: record)
            if agent.activity == .busy || agent.activity == .waiting {
                if times.turnLaunchID != launchID {
                    times.turnLaunchID = launchID
                    turnStarted = true
                }
            } else if times.turnLaunchID == launchID {
                // The turn ended in this launch.
                if isTerminating == false { times.turnLaunchID = nil }
            } else if agent.session?.lastTurnEndedAt != nil {
                // A mark from an earlier launch stays until the agent starts
                // its next turn. This one started and ended between two
                // passes: only a session of this launch has a turn's end.
                times.turnLaunchID = nil
            }

            if let typedAt = liveUserInputAt(of: record, agentSession: agent.session),
               typedAt.timeIntervalSince(times.lastUserInputAt ?? .distantPast) >= TaskStateTimes.userInputSaveInterval {
                times.lastUserInputAt = typedAt
            }

            if times != record.stateTimes ?? TaskStateTimes() {
                changed[record.id] = times
            }
        }
        guard changed.isEmpty == false else { return items }
        records.updateEach { record in
            if let times = changed[record.id] { record.stateTimes = times }
        }
        if turnStarted {
            do {
                try records.flush()
            } catch {
                ToasttyLog.warning("Failed saving a task's turn start at once", category: .tasks, metadata: [
                    "error": error.localizedDescription,
                ])
            }
        }
        return items
    }

    /// Whether the item's stage is only a guess until GitHub answers: a
    /// linked pull request counts as waiting for review before Toastty has
    /// asked about it, as after a relaunch. The stage clock waits for the
    /// answer, so a draft pull request does not look like a review that
    /// started at the relaunch, and the stage it returns to keeps its time.
    /// A request that failed is an answer: without `gh`, the guess stays.
    private func stageAwaitsGitHub(_ item: TaskBoardItem) -> Bool {
        guard item.stage == .needsYou(.review), let link = item.pullRequest, item.pullRequestState == nil else {
            return false
        }
        return board?.pullRequests?.entries[link.url] == nil
    }

    /// The pending mark after GitHub's last answer. Without an answer, as
    /// after a relaunch, the saved mark stays, so checks that are still
    /// pending for the same commit keep their earlier time.
    private func checksPending(saved: TaskChecksPending?, item: TaskBoardItem, at: Date) -> TaskChecksPending? {
        guard let link = item.pullRequest else { return nil }
        guard let state = board?.pullRequests?.answer(for: link) else { return saved }
        guard state.state == .open, state.mergeability?.checks == .running else { return nil }
        if let saved, saved.headSHA == state.headSHA { return saved }
        // The time Toastty asked GitHub, which is when it saw them pending.
        return TaskChecksPending(since: board?.pullRequests?.entries[link.url]?.answeredAt ?? at, headSHA: state.headSHA)
    }

    /// When the task's stage last changed, for the stage the board reports
    /// now. `nil` until `recordStateTimes` has seen that stage.
    static func stageChangedAt(_ record: TaskRecord, stage: TaskStage) -> Date? {
        record.stateTimes?.stage?.since(TaskStageClock.Key(stage))
    }

    /// Whether the task's agent was in a turn (busy, or waiting for an
    /// approval) when Toastty last quit or crashed, and has not started a
    /// turn since.
    func wasInterruptedAtQuit(_ record: TaskRecord) -> Bool {
        guard let turnLaunchID = record.stateTimes?.turnLaunchID else { return false }
        return turnLaunchID != launchID
    }

    /// When the transcript of the task's agent last changed. `nil` when no
    /// agent runs, or Toastty has not confirmed its transcript.
    func lastOutputAt(of record: TaskRecord) -> Date? {
        guard let session = liveAgentSession(of: record) else { return nil }
        return sessions?.lastOutputAt(sessionID: session.sessionID)
    }

    /// What Toastty reads to find these tasks' alerts (`TaskAlert`): whether
    /// the task's agent is busy, when it last wrote, whether a quit cut off
    /// its turn while it now waits at its prompt, and GitHub's last answer
    /// about the checks of the task's open pull request. These are the
    /// facts `task get` reports as `agentState` and `pullRequest`.
    func alertFacts(for taskIDs: Set<UUID>) -> [UUID: TaskAlertFacts] {
        var facts: [UUID: TaskAlertFacts] = [:]
        for record in records.records where taskIDs.contains(record.id) {
            let agent = agentStatus(of: record)
            let busy = agent.activity == .busy
            facts[record.id] = TaskAlertFacts(
                agentBusy: busy,
                lastOutputAt: busy ? agent.session.flatMap { sessions?.lastOutputAt(sessionID: $0.sessionID) } : nil,
                checks: checks(of: record),
                interruptedAtQuit: agent.activity == .idle && wasInterruptedAtQuit(record)
            )
        }
        return facts
    }

    /// The checks of the task's open pull request, from GitHub's last
    /// answer for its head commit. A pull request Toastty has no answer for
    /// yet, also when every request failed, is unknown.
    private func checks(of record: TaskRecord) -> TaskAlertFacts.Checks {
        guard let url = record.pullRequestURL, record.mergedAt == nil else { return .none }
        guard let answer = board?.pullRequests?.entries[url]?.answer else { return .unknown }
        guard answer.state == .open else { return .none }
        switch answer.mergeability?.checks {
        case .failing?: return .failing
        case .passing?: return .passing
        case .running?:
            let pending = record.stateTimes?.checksPending
            return .pending(since: pending?.headSHA == answer.headSHA ? pending?.since : nil)
        case nil: return .none
        }
    }

    /// When the user last worked in the task: the live time, or the saved
    /// one after a relaunch.
    func lastUserInputAt(of record: TaskRecord) -> Date? {
        [
            liveUserInputAt(of: record, agentSession: liveAgentSession(of: record)),
            record.stateTimes?.lastUserInputAt,
        ].compactMap { $0 }.max()
    }

    /// The user's latest input in this app run, into any terminal of the
    /// task space, or into the agent's terminal when that is elsewhere.
    private func liveUserInputAt(of record: TaskRecord, agentSession: TaskSessionInfo?) -> Date? {
        guard let sessions else { return nil }
        var panelIDs: Set<UUID> = []
        if let workspaceID = record.taskSpaceWorkspaceID, let workspace = store.state.workspacesByID[workspaceID] {
            panelIDs.formUnion(workspace.allTerminalPanelIDs)
        }
        if let agentSession {
            panelIDs.insert(agentSession.panelID)
        }
        return panelIDs.compactMap { sessions.lastUserInputAt(panelID: $0) }.max()
    }

    /// Before the app quits: sessions that stop from here on keep their
    /// turn marks, and the latest times are written.
    func prepareForTermination() {
        recordStateTimes()
        isTerminating = true
        try? records.flush()
    }
}
