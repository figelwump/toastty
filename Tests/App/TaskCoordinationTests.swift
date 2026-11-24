import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

/// `task.send` and `task.watch` in the coordinator: finding a task's agent
/// after relaunches and moves, and waking a waiting task once.
@MainActor
struct TaskCoordinationTests {
    typealias Fixture = TaskStartWorkTests.Fixture

    private func sessionID(_ record: TaskRecord) throws -> String {
        try #require(record.operation.agentLaunch?.sessionID)
    }

    private func panelID(_ record: TaskRecord) throws -> UUID {
        try #require(record.operation.taskSpace?.panelID)
    }

    private func messages(_ fixture: Fixture, to record: TaskRecord) throws -> [String] {
        let panel = try panelID(record)
        return fixture.sessions.delivered.filter { $0.panelID == panel }.map(\.text)
    }

    // MARK: - Send

    @Test func sendReachesTheSessionRestoredInTheTasksPaneAfterARelaunch() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask()
        let panel = try panelID(task)
        fixture.sessions.stop(try sessionID(task))
        fixture.sessions.sessions["restored"] = TaskSessionInfo(
            sessionID: "restored", agent: .claude, panelID: panel, workspaceID: try #require(task.taskSpaceWorkspaceID),
            cwd: nil, isActive: true, isInTurn: false, nativeConversationID: nil, title: nil
        )

        let reached = try fixture.coordinator.send(taskID: task.id, text: "Rebase on main, please")
        #expect(reached.sessionID == "restored")
        #expect(try messages(fixture, to: task) == ["Rebase on main, please"])
    }

    @Test func sendFollowsTheTaskIntoItsWorktreeSession() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask()
        let worktreePanel = UUID()
        let taskSpace = try #require(task.taskSpaceWorkspaceID)
        try fixture.coordinator.records.save(id: task.id) {
            $0.operation.worktreeSession = TaskOperation.WorktreeSession(
                workspaceID: taskSpace, panelID: worktreePanel, sessionID: "moved", forked: true
            )
        }
        fixture.sessions.sessions["moved"] = TaskSessionInfo(
            sessionID: "moved", agent: .claude, panelID: worktreePanel, workspaceID: taskSpace,
            cwd: nil, isActive: true, isInTurn: false, nativeConversationID: nil, title: nil
        )

        let reached = try fixture.coordinator.send(taskID: task.id, text: "status?")
        #expect(reached.sessionID == "moved")
        #expect(fixture.sessions.delivered.map(\.panelID) == [worktreePanel])
    }

    @Test func sendFallsBackToTheOriginalAgentWhenTheForkDidNotRun() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask()
        let taskSpace = try #require(task.taskSpaceWorkspaceID)
        try fixture.coordinator.records.save(id: task.id) {
            $0.operation.worktreeSession = TaskOperation.WorktreeSession(
                workspaceID: taskSpace, panelID: UUID(), sessionID: "fork-that-exited", forked: true
            )
        }
        let reached = try fixture.coordinator.send(taskID: task.id, text: "status?")
        #expect(reached.sessionID == (try sessionID(task)))
    }

    @Test func aRecoveredTaskReachesItsMostRecentlyActiveAgent() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask()
        let taskSpace = try #require(task.taskSpaceWorkspaceID)
        let savedPanel = try panelID(task)
        // As a rebuilt record has it: a task space and some pane, no launch.
        try fixture.coordinator.records.save(id: task.id) { $0.operation.agentLaunch = nil }
        fixture.sessions.report(try sessionID(task), .ready, at: Date().addingTimeInterval(-600))
        let newer = UUID()
        fixture.sessions.sessions["newer"] = TaskSessionInfo(
            sessionID: "newer", agent: .codex, panelID: newer, workspaceID: taskSpace,
            cwd: nil, isActive: true, isInTurn: false, nativeConversationID: nil, title: nil,
            statusUpdatedAt: Date()
        )
        let reached = try fixture.coordinator.send(taskID: task.id, text: "status?")
        #expect(reached.sessionID == "newer")
        #expect(fixture.sessions.delivered.map(\.panelID) == [newer])
        #expect(savedPanel != newer)
    }

    @Test func aMessageThatMayNotHaveBeenSubmittedIsNotTypedAgain() async throws {
        let fixture = try Fixture()
        let target = try await fixture.startedTask()
        let watcher = try await fixture.startedTask()
        let watcherSession = try sessionID(watcher)
        fixture.sessions.report(watcherSession, .idle)
        fixture.sessions.deliveryResult = .uncertain
        #expect(throws: TaskError("Toastty typed the message into task \(watcher.title)'s terminal but may not have submitted it. Check that terminal before you send it again.")) {
            try fixture.coordinator.send(taskID: watcher.id, text: "status?")
        }
        // Another sender's message does not go in after it either.
        #expect(throws: unconfirmedMessageError(watcher)) {
            try fixture.coordinator.send(taskID: watcher.id, text: "another")
        }

        _ = try fixture.coordinator.addWatch(targetTaskID: target.id, condition: .waiting, notifyTaskID: watcher.id)
        fixture.sessions.report(try sessionID(target), .needsApproval)
        fixture.coordinator.evaluateWatches()
        #expect(try messages(fixture, to: watcher) == ["status?"])

        fixture.sessions.report(watcherSession, .working)
        fixture.sessions.report(watcherSession, .ready)
        fixture.coordinator.evaluateWatches()
        fixture.coordinator.evaluateWatches()
        #expect(try messages(fixture, to: watcher).filter { $0.hasPrefix("[Toastty watch") }.count == 1)
        guard case .fired(_, _, _, true)? = fixture.record(watcher.id)?.watches?.first?.state else {
            Issue.record("an uncertain delivery should not be retried")
            return
        }

        // A turn that starts after the last unconfirmed message took it.
        #expect(throws: unconfirmedMessageError(watcher)) {
            try fixture.coordinator.send(taskID: watcher.id, text: "another")
        }
        fixture.sessions.deliveryResult = .delivered
        fixture.sessions.report(watcherSession, .working)
        try fixture.coordinator.send(taskID: watcher.id, text: "another")
        #expect(try messages(fixture, to: watcher).last == "another")
    }

    private func interactionError(_ task: TaskRecord) -> TaskError {
        TaskError(
            "Task \(task.title)'s agent waits for an answer to a permission prompt, a question or a dialog, and a typed message could answer it. Toastty typed nothing. Send the message again when the agent's prompt is open, or send it with --steer, which holds it until then."
        )
    }

    private func typedTextError(_ task: TaskRecord) -> TaskError {
        TaskError(
            "Someone typed in task \(task.title)'s terminal since its agent's latest turn started, and that text can still be in the agent's prompt. Toastty typed nothing, so the two do not mix. Send the message again after the agent's next turn starts, or type it in the task."
        )
    }

    private func unconfirmedMessageError(_ task: TaskRecord) -> TaskError {
        TaskError(
            "An earlier message to task \(task.title) can still be in its agent's prompt: Toastty typed it, but the terminal did not confirm its Return. Toastty typed nothing. Send the message again after the agent's next turn starts."
        )
    }

    /// A plain send types nothing where its text and Return would join or
    /// answer something at the agent's prompt, and says why. Once the
    /// prompt is free it types, at rest or into a running turn.
    @Test func aPlainSendLeavesAnOccupiedPromptUntouched() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask()
        let session = try sessionID(task)
        let panel = try panelID(task)
        let start = Date()
        fixture.sessions.report(session, .working, at: start)
        fixture.sessions.report(session, .ready, at: start.addingTimeInterval(10))
        func send(_ text: String) throws { try fixture.coordinator.send(taskID: task.id, text: text) }

        // A permission prompt or a question that the hooks report, and a
        // dialog or an interaction that only the screen or the followed
        // conversation shows.
        fixture.sessions.report(session, .needsApproval, at: start.addingTimeInterval(11))
        #expect(throws: interactionError(task)) { try send("status?") }
        fixture.sessions.report(session, .ready, at: start.addingTimeInterval(12))
        fixture.sessions.sessionsShowingInteraction.insert(session)
        #expect(throws: interactionError(task)) { try send("status?") }
        fixture.sessions.sessionsShowingInteraction.remove(session)

        // A person typed during the turn and did not submit it. Only a
        // conversation that Toastty followed from before that turn started
        // can tell that the agent recorded that text: following that began
        // during the turn can miss the typing.
        fixture.sessions.userInputAt[panel] = start.addingTimeInterval(5)
        #expect(throws: typedTextError(task)) { try send("status?") }
        fixture.sessions.openPromptFollowedSince[session] = start.addingTimeInterval(1)
        #expect(throws: typedTextError(task)) { try send("status?") }
        fixture.sessions.openPromptFollowedSince[session] = start.addingTimeInterval(-60)
        try send("first")
        fixture.sessions.openPromptFollowedSince[session] = nil

        // Typing at the open prompt, then a turn that submits it: a running
        // turn takes a message, until someone types into that turn.
        fixture.sessions.userInputAt[panel] = start.addingTimeInterval(13)
        #expect(throws: typedTextError(task)) { try send("status?") }
        fixture.sessions.report(session, .working, at: start.addingTimeInterval(14))
        try send("second")
        fixture.sessions.userInputAt[panel] = start.addingTimeInterval(15)
        fixture.sessions.openPromptFollowedSince[session] = start.addingTimeInterval(-60)
        #expect(throws: typedTextError(task)) { try send("status?") }
        #expect(try messages(fixture, to: task) == ["first", "second"])
    }

    @Test func sendFailsWhenTheTaskHasNoRunningAgent() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask()
        fixture.sessions.stop(try sessionID(task))
        #expect(throws: TaskError("Task \(task.title) has no running agent.")) {
            try fixture.coordinator.send(taskID: task.id, text: "status?")
        }
        #expect(throws: TaskError("The message is empty.")) {
            try fixture.coordinator.send(taskID: task.id, text: "  \n")
        }
    }

    @Test func aCheckedSendGoesToTheTasksAgentAndSaysHowItWasGiven() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask()
        let panel = try panelID(task)

        fixture.sessions.steerResult = .success(.queued(position: 2))
        let reached = try await fixture.coordinator.sendSteering(taskID: task.id, text: "Use the new name")
        #expect(reached.session.sessionID == (try sessionID(task)))
        #expect(reached.delivery == .queued(position: 2))
        #expect(fixture.sessions.steered.map(\.panelID) == [panel])
        #expect(fixture.sessions.steered.map(\.text) == ["Use the new name"])
        // Nothing went through the unchecked path.
        #expect(try messages(fixture, to: task).isEmpty)

        // A send that types nothing says so, with the reason.
        fixture.sessions.steerResult = .failure(.stateUnknown)
        await #expect(throws: TaskError("Toastty cannot tell what task \(task.title)'s agent does now, so it typed nothing. Send the message again when the agent is idle.")) {
            try await fixture.coordinator.sendSteering(taskID: task.id, text: "Use the new name")
        }
        fixture.sessions.steerResult = .failure(.queueFull)
        await #expect(throws: TaskError("Task \(task.title) already has 5 messages that wait for its agent's next prompt. Nothing was added.")) {
            try await fixture.coordinator.sendSteering(taskID: task.id, text: "Use the new name")
        }
        fixture.sessions.stop(try sessionID(task))
        await #expect(throws: TaskError("Task \(task.title) has no running agent.")) {
            try await fixture.coordinator.sendSteering(taskID: task.id, text: "Use the new name")
        }
    }

    /// Claude Code drops a Return typed while it reads a pasted image path,
    /// so both sends type such a path as text.
    @Test func bothSendsTypeAnImagePathAsTextSoTheReturnSubmitsIt() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask()
        let text = "See the screenshot:\n/Users/me/attachments/shot.jpg"
        let typed = "See the screenshot:\n`/Users/me/attachments/shot.jpg`"

        try fixture.coordinator.send(taskID: task.id, text: text)
        #expect(try messages(fixture, to: task) == [typed])

        fixture.sessions.steerResult = .success(.steered)
        _ = try await fixture.coordinator.sendSteering(taskID: task.id, text: text)
        #expect(fixture.sessions.steered.map(\.text) == [typed])
    }

    @Test func taskSessionsAreUnscopedUnlessTheirCreatorWasScoped() async throws {
        let fixture = try Fixture()
        _ = try await fixture.startedTask()
        #expect(fixture.launcher.calls.last?.scopedWorkspaceIDs == nil)

        let assigned: Set<UUID> = [fixture.workspaceID]
        fixture.sessions.sessions["coordinator"] = TaskSessionInfo(
            sessionID: "coordinator", agent: .claude, panelID: UUID(), workspaceID: fixture.workspaceID,
            cwd: nil, isActive: true, isInTurn: true, nativeConversationID: nil, title: nil
        )
        fixture.sessions.scopes["coordinator"] = assigned
        let created = try await fixture.coordinator.create(
            TaskCreateRequest(text: "Split out the parser", workspaceID: fixture.workspaceID, agent: "codex"),
            caller: TaskCaller(sessionID: "coordinator", workspaceID: fixture.workspaceID)
        )
        // The scope is saved with the task, so a setup that runs after the
        // creator ended, or a retry after a relaunch, still applies it.
        #expect(fixture.record(created.id)?.creatorScope == assigned)
        await fixture.waitUntil("setup ends") { fixture.record(created.id)?.setup != .settingUp }
        let taskSpace = try #require(fixture.record(created.id)?.taskSpaceWorkspaceID)
        #expect(fixture.launcher.calls.last?.scopedWorkspaceIDs == assigned.union([taskSpace]))
    }

    // MARK: - Wakes of waiting tasks

    /// `task waiting --wake`: at the time the agent set, its own agent gets
    /// one line while it waits at its prompt, and the turn that line starts
    /// clears the mark.
    @Test(arguments: [false, true])
    func aDueWakeGoesOnceToTheTasksIdleAgentAndItsTurnClearsTheMark(submissionUncertain: Bool) async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask()
        let session = try sessionID(task)
        let panel = try panelID(task)
        let taskSpace = try #require(task.taskSpaceWorkspaceID)
        let coordinator = fixture.coordinator!
        func waiting() -> TaskWaiting? { fixture.record(task.id)?.waiting }
        func wakes() throws -> [String] { try messages(fixture, to: task).filter { $0.hasPrefix("[Toastty wake] ") } }
        func comeDue() throws {
            try coordinator.records.save(id: task.id) { $0.waiting?.wakeAt = Date().addingTimeInterval(-1) }
            coordinator.wakeRetryAt = [:]
        }

        // The agent marks the wait and ends its turn. The wake is weeks away:
        // nothing goes, and the monitor looks again within a minute.
        _ = try coordinator.setWaiting(taskID: task.id, reason: "email replies", wakeAt: Date().addingTimeInterval(14 * 86_400))
        fixture.sessions.report(session, .ready)
        #expect(coordinator.evaluateWakes() == TaskCoordinator.wakeCheckMaximumInterval)
        #expect(try wakes().isEmpty)

        // The time comes while a question waits for the user, while the
        // agent works, while a person's typing since its last turn can still
        // be in its prompt, or while its terminal takes no text: the wake
        // waits and tries again later.
        try comeDue()
        _ = try coordinator.needsReply(taskID: task.id, question: "Send the draft?")
        #expect(coordinator.evaluateWakes() == TaskCoordinator.wakeRetryInterval)
        try coordinator.records.save(id: task.id) { $0.replyRequest = nil }
        coordinator.wakeRetryAt = [:]
        fixture.sessions.report(session, .working)
        #expect(coordinator.evaluateWakes() == TaskCoordinator.wakeRetryInterval)
        fixture.sessions.report(session, .ready)
        // A tracked interaction can still occupy the prompt while the
        // session reports ready and there is no recent user input.
        fixture.sessions.sessionsShowingInteraction.insert(session)
        coordinator.wakeRetryAt = [:]
        #expect(coordinator.evaluateWakes() == TaskCoordinator.wakeRetryInterval)
        #expect(try wakes().isEmpty)
        #expect(waiting()?.wokenAt == nil)
        fixture.sessions.sessionsShowingInteraction.remove(session)

        fixture.sessions.userInputAt[panel] = Date()
        coordinator.wakeRetryAt = [:]
        #expect(coordinator.evaluateWakes() == TaskCoordinator.wakeRetryInterval)
        fixture.sessions.userInputAt[panel] = nil
        fixture.sessions.deliveryResult = .unavailable
        coordinator.wakeRetryAt = [:]
        #expect(coordinator.evaluateWakes() == TaskCoordinator.wakeRetryInterval)
        #expect(try wakes().isEmpty)
        #expect(waiting()?.wokenAt == nil)

        // At its prompt the agent gets one line that says what it waited for.
        fixture.sessions.deliveryResult = submissionUncertain ? .uncertain : .delivered
        coordinator.wakeRetryAt = [:]
        #expect(coordinator.evaluateWakes() == nil)
        let lines = try wakes()
        #expect(lines.count == 1)
        #expect(lines.first?.contains("The task waited for: email replies.") == true)
        #expect(lines.first?.contains("\n") == false)
        #expect(waiting()?.wokenAt != nil)
        #expect(coordinator.evaluateWakes() == nil)
        #expect(try wakes().count == 1)

        // Another agent's turn in the task space does not clear the mark;
        // the turn of the task's own agent does.
        coordinator.clearMarksForNewWork(taskSpaceWorkspaceID: taskSpace, sessionID: "helper")
        #expect(waiting() != nil)
        coordinator.clearMarksForNewWork(taskSpaceWorkspaceID: taskSpace, sessionID: session)
        #expect(waiting() == nil)
    }

    /// A finished task waits on nothing: its wake is dropped, not sent,
    /// since the turn it would start reopens a done task.
    @Test func aWakeIsDroppedForATaskMarkedDone() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask()
        let session = try sessionID(task)
        let taskSpace = try #require(task.taskSpaceWorkspaceID)
        let coordinator = fixture.coordinator!
        fixture.sessions.report(session, .ready)
        _ = try coordinator.setWaiting(taskID: task.id, reason: "email replies", wakeAt: Date().addingTimeInterval(3600))
        // The sidebar's done box marks only the task space.
        _ = fixture.store.send(.setWorkspaceDone(workspaceID: taskSpace, doneAt: Date()))
        try coordinator.records.save(id: task.id) { $0.waiting?.wakeAt = Date().addingTimeInterval(-1) }
        #expect(coordinator.evaluateWakes() == nil)
        #expect(fixture.sessions.delivered.isEmpty)
        #expect(fixture.record(task.id)?.waiting == nil)

        // So is the wake of a shipped task.
        _ = try coordinator.setWaiting(taskID: task.id, reason: "email replies", wakeAt: Date().addingTimeInterval(3600))
        _ = fixture.store.send(.setWorkspaceDone(workspaceID: taskSpace, doneAt: nil))
        try coordinator.records.save(id: task.id) {
            $0.shippedAt = Date()
            $0.waiting?.wakeAt = Date().addingTimeInterval(-1)
        }
        #expect(coordinator.evaluateWakes() == nil)
        #expect(fixture.record(task.id)?.waiting == nil)
        try coordinator.records.save(id: task.id) { $0.shippedAt = nil }
        #expect(fixture.sessions.delivered.isEmpty)

        // Mark Done and archive clear the mark themselves.
        _ = try coordinator.setWaiting(taskID: task.id, reason: "email replies", wakeAt: nil)
        _ = try coordinator.markDone(taskID: task.id)
        #expect(fixture.record(task.id)?.waiting == nil)

        // A done mark that records the acceptance of a merge under way is
        // not finished work: a wake set while the merge waits still goes.
        try coordinator.records.save(id: task.id) {
            $0.doneAt = nil
            $0.mergeRequestedAt = Date()
        }
        _ = try coordinator.setWaiting(taskID: task.id, reason: "test runs", wakeAt: Date().addingTimeInterval(3600))
        try coordinator.records.save(id: task.id) { $0.waiting?.wakeAt = Date().addingTimeInterval(-1) }
        #expect(fixture.store.state.workspacesByID[taskSpace]?.doneAt != nil)
        #expect(coordinator.evaluateWakes() == nil)
        #expect(fixture.sessions.delivered.isEmpty == false)
        #expect(fixture.record(task.id)?.waiting?.wokenAt != nil)
    }

    // MARK: - Watch

    @Test func anIdleWatchWakesTheWatcherOnceAfterTheTargetsNextTurn() async throws {
        let fixture = try Fixture()
        let target = try await fixture.startedTask()
        let watcher = try await fixture.startedTask()
        fixture.sessions.report(try sessionID(watcher), .idle)
        // The target finished a turn before anyone watched it.
        fixture.sessions.report(try sessionID(target), .ready, at: Date().addingTimeInterval(-30))

        let watch = try fixture.coordinator.addWatch(targetTaskID: target.id, condition: .idle, notifyTaskID: watcher.id)
        fixture.coordinator.evaluateWatches()
        #expect(try messages(fixture, to: watcher).isEmpty)
        #expect(fixture.record(watcher.id)?.watches?.first?.isPending == true)

        fixture.sessions.report(try sessionID(target), .working)
        fixture.coordinator.evaluateWatches()
        #expect(try messages(fixture, to: watcher).isEmpty)

        fixture.sessions.report(try sessionID(target), .ready, at: Date().addingTimeInterval(1))
        fixture.coordinator.evaluateWatches()
        fixture.coordinator.evaluateWatches()
        let sent = try messages(fixture, to: watcher)
        #expect(sent.count == 1)
        #expect(sent.first?.contains("[Toastty watch \(watch.id.uuidString)]") == true)
        #expect(sent.first?.contains("is idle. Read it with: toastty task get \(target.id.uuidString)") == true)
        #expect(sent.first?.contains("\n") == false)
        guard case .fired(_, _, false, true)? = fixture.record(watcher.id)?.watches?.first?.state else {
            Issue.record("expected a delivered watch, got \(String(describing: fixture.record(watcher.id)?.watches))")
            return
        }
    }

    @Test(arguments: [SessionStatusKind.working, .needsApproval, .error])
    func aFiredWatchWaitsForAPrompt(_ status: SessionStatusKind) async throws {
        let fixture = try Fixture()
        let target = try await fixture.startedTask()
        let watcher = try await fixture.startedTask()
        let watcherSession = try sessionID(watcher)
        fixture.sessions.report(watcherSession, status)
        let watch = try fixture.coordinator.addWatch(targetTaskID: target.id, condition: .waiting, notifyTaskID: watcher.id)

        fixture.sessions.report(try sessionID(target), .needsApproval)
        fixture.coordinator.evaluateWatches()
        #expect(try messages(fixture, to: watcher).isEmpty)
        guard case .fired(_, _, false, false)? = fixture.coordinator.watch(id: watch.id)?.watch.state else {
            Issue.record("expected a fired watch waiting for a prompt")
            return
        }

        // A provider can still show an interaction while its hooks say ready.
        fixture.sessions.sessionsShowingInteraction.insert(watcherSession)
        fixture.sessions.report(watcherSession, .ready)
        fixture.coordinator.evaluateWatches()
        #expect(try messages(fixture, to: watcher).isEmpty)

        fixture.sessions.sessionsShowingInteraction.remove(watcherSession)
        await fixture.waitUntil("the watch is delivered after the interaction closes", timeout: .seconds(5)) {
            (try? messages(fixture, to: watcher).count) == 1
        }
        fixture.coordinator.evaluateWatches()
        #expect(try messages(fixture, to: watcher).count == 1)
    }

    @Test func aFiredWatchLeavesADraftAndRetriesUnavailableDelivery() async throws {
        let fixture = try Fixture()
        let target = try await fixture.startedTask()
        let watcher = try await fixture.startedTask()
        let watcherSession = try sessionID(watcher)
        let at = Date()
        fixture.sessions.report(watcherSession, .ready, at: at)
        fixture.sessions.userInputAt[try panelID(watcher)] = at.addingTimeInterval(1)
        fixture.sessions.report(try sessionID(target), .needsApproval)
        let watch = try fixture.coordinator.addWatch(targetTaskID: target.id, condition: .waiting, notifyTaskID: watcher.id)
        fixture.coordinator.evaluateWatches()
        #expect(try messages(fixture, to: watcher).isEmpty)
        guard case .fired(_, _, false, false)? = fixture.coordinator.watch(id: watch.id)?.watch.state else {
            Issue.record("expected a fired watch waiting behind a draft")
            return
        }

        fixture.sessions.report(watcherSession, .working, at: at.addingTimeInterval(2))
        fixture.sessions.report(watcherSession, .idle, at: at.addingTimeInterval(3))
        fixture.sessions.deliveryResult = .unavailable
        fixture.coordinator.evaluateWatches()
        guard case .fired(_, _, false, false)? = fixture.coordinator.watch(id: watch.id)?.watch.state else {
            Issue.record("expected a fired watch after unavailable delivery")
            return
        }
        #expect(try messages(fixture, to: watcher).isEmpty)

        fixture.sessions.deliveryResult = .delivered
        fixture.coordinator.evaluateWatches()
        fixture.coordinator.evaluateWatches()
        #expect(try messages(fixture, to: watcher).count == 1)
    }

    @Test func aFiredMessageWaitsForTheWatchersAgentToRun() async throws {
        let fixture = try Fixture()
        let target = try await fixture.startedTask()
        let watcher = try await fixture.startedTask()
        fixture.sessions.stop(try sessionID(watcher))
        _ = try fixture.coordinator.addWatch(targetTaskID: target.id, condition: .waiting, notifyTaskID: watcher.id)

        fixture.sessions.report(try sessionID(target), .needsApproval)
        fixture.coordinator.evaluateWatches()
        guard case .fired(_, _, _, false)? = fixture.record(watcher.id)?.watches?.first?.state else {
            Issue.record("expected an undelivered fired watch")
            return
        }

        // The watcher's agent comes back in its pane, as after a relaunch.
        fixture.sessions.sessions["back"] = TaskSessionInfo(
            sessionID: "back", agent: .claude, panelID: try panelID(watcher), workspaceID: try #require(watcher.taskSpaceWorkspaceID),
            cwd: nil, isActive: true, isInTurn: false, nativeConversationID: nil, title: nil
        )
        fixture.coordinator.evaluateWatches()
        #expect(try messages(fixture, to: watcher).isEmpty)
        fixture.sessions.report("back", .idle)
        fixture.coordinator.evaluateWatches()
        #expect(try messages(fixture, to: watcher).count == 1)
        #expect(try messages(fixture, to: watcher).first?.contains("is waiting for input") == true)
    }

    @Test func aDeletedTargetTellsTheWatcherItCanNeverFire() async throws {
        let fixture = try Fixture()
        let target = try await fixture.startedTask()
        let watcher = try await fixture.startedTask()
        fixture.sessions.report(try sessionID(watcher), .idle)
        _ = try fixture.coordinator.addWatch(targetTaskID: target.id, condition: .merged, notifyTaskID: watcher.id)

        try fixture.coordinator.delete(taskID: target.id)
        fixture.coordinator.evaluateWatches()
        let sent = try messages(fixture, to: watcher)
        #expect(sent.count == 1)
        #expect(sent.first?.contains("Task \(target.id.uuidString) was deleted, so your watch until merged can never fire.") == true)
    }

    @Test func aSavedWatchStillFiresAfterARelaunch() async throws {
        let fixture = try Fixture()
        let target = try await fixture.startedTask()
        let watcher = try await fixture.startedTask()
        _ = try fixture.coordinator.addWatch(targetTaskID: target.id, condition: .idle, notifyTaskID: watcher.id)

        // A relaunch: a new coordinator over the saved records, and both
        // agents restored in their panes under new session IDs.
        for task in [target, watcher] {
            fixture.sessions.stop(try sessionID(task))
            fixture.sessions.sessions["restored-\(task.id)"] = TaskSessionInfo(
                sessionID: "restored-\(task.id)", agent: .claude, panelID: try panelID(task),
                workspaceID: try #require(task.taskSpaceWorkspaceID),
                cwd: nil, isActive: true, isInTurn: false, nativeConversationID: nil, title: nil
            )
        }
        let relaunched = fixture.makeCoordinator(records: TaskRecordStore(fileURL: fixture.recordsFile))
        fixture.replaceCoordinator(relaunched)
        relaunched.reconcileAfterLaunch()

        fixture.sessions.report("restored-\(watcher.id)", .idle)
        fixture.sessions.report("restored-\(target.id)", .working)
        fixture.sessions.report("restored-\(target.id)", .ready, at: Date().addingTimeInterval(1))
        // The monitor that reconcileAfterLaunch started picks it up.
        await fixture.waitUntil("the watcher is told", timeout: .seconds(5)) {
            (try? messages(fixture, to: watcher).count) == 1
        }
    }

    @Test func anUndeliveredFiredWatchSurvivesRelaunch() async throws {
        let fixture = try Fixture()
        let target = try await fixture.startedTask()
        let watcher = try await fixture.startedTask()
        let watcherSession = try sessionID(watcher)
        fixture.sessions.report(watcherSession, .needsApproval)
        fixture.sessions.report(try sessionID(target), .needsApproval)
        let watch = try fixture.coordinator.addWatch(targetTaskID: target.id, condition: .waiting, notifyTaskID: watcher.id)
        #expect(try messages(fixture, to: watcher).isEmpty)
        fixture.sessions.report(try sessionID(target), .ready)

        let relaunched = fixture.makeCoordinator(records: TaskRecordStore(fileURL: fixture.recordsFile))
        fixture.replaceCoordinator(relaunched)
        relaunched.reconcileAfterLaunch()
        guard case .fired(_, _, false, false)? = relaunched.watch(id: watch.id)?.watch.state else {
            Issue.record("expected the fired watch to be restored from disk")
            return
        }
        #expect(try messages(fixture, to: watcher).isEmpty)

        fixture.sessions.report(watcherSession, .ready)
        await fixture.waitUntil("the restored watch is delivered", timeout: .seconds(5)) {
            (try? messages(fixture, to: watcher).count) == 1
        }
        let reopened = fixture.makeCoordinator(records: TaskRecordStore(fileURL: fixture.recordsFile))
        fixture.replaceCoordinator(reopened)
        reopened.reconcileAfterLaunch()
        #expect(try messages(fixture, to: watcher).count == 1)
    }

    @Test func stageWatchesFireOnceTheTaskBoardShowsTheStageOrALaterOne() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let gitHub = TaskBoardTests.FakeGitHub()
        // The coordinator holds its board weakly, as the app does.
        let board = TaskBoardStore(
            coordinator: fixture.coordinator,
            store: fixture.store,
            sessionRuntimeStore: fixture.sessionRuntimeStore,
            pullRequests: PullRequestStateCache(runner: gitHub),
            refreshInterval: nil
        )
        fixture.coordinator.board = board
        let created = try await fixture.coordinator.create(TaskCreateRequest(
            text: "The unread dot stays on",
            workspaceID: fixture.workspaceID,
            agent: "codex",
            model: "gpt-6.1-sol",
            effort: "high",
            prompt: "Fix it."
        ))
        await fixture.waitForSetup(created.id)
        let task = try #require(fixture.record(created.id))
        let taskSpace = try #require(task.taskSpaceWorkspaceID)
        func watch(_ condition: TaskWatchCondition) throws -> UUID {
            try fixture.coordinator.addWatch(targetTaskID: task.id, condition: condition, notifyTaskID: nil).id
        }
        func outcome(_ id: UUID) -> String? {
            guard case .fired(_, let reason, _, _)? = fixture.coordinator.watch(id: id)?.watch.state else { return nil }
            return reason
        }
        let review = try watch(.readyForReview)
        let merged = try watch(.merged)
        let toShip = try watch(.toShip)
        let done = try watch(.done)
        #expect([review, merged, toShip, done].allSatisfy { outcome($0) == nil })

        // The agent finishes the turn its launch started.
        let session = try #require(task.operation.agentLaunch?.sessionID)
        for kind in [SessionStatusKind.working, .idle] {
            fixture.sessionRuntimeStore.updateStatus(sessionID: session, status: SessionStatus(kind: kind, summary: "\(kind)"), at: Date())
        }

        // A linked pull request and no working agent: it waits for review.
        let url = "https://github.com/example/toastty/pull/124"
        _ = fixture.store.send(.setWorkspaceAnnotation(
            workspaceID: taskSpace, key: "github-pr", annotation: WorkspaceAnnotation(text: "PR #124", url: url)
        ))
        fixture.coordinator.evaluateWatches()
        #expect(outcome(review) == "is ready for review")
        #expect([merged, toShip, done].allSatisfy { outcome($0) == nil })

        // Without release tags a merge goes straight to Done, past To ship.
        gitHub.answer(url, state: "MERGED", mergeCommit: "abc123")
        await board.pullRequests?.refresh(try #require(WorkspacePullRequestLink(annotationURL: url))).value
        fixture.coordinator.evaluateWatches()
        #expect(outcome(merged) == "is merged")
        #expect(outcome(toShip) == "is done")
        #expect(outcome(done) == "is done")
        // A watch for a stage the task has passed fires as soon as it is made.
        #expect(outcome(try watch(.readyForReview)) == "is done")
    }

    @Test func archivingATaskFiresItsWatchesAndRejectsNewOnes() async throws {
        let fixture = try Fixture()
        let target = try await fixture.startedTask()
        let watcher = try await fixture.startedTask()
        let watcherSession = try sessionID(watcher)
        fixture.sessions.report(watcherSession, .idle)
        let done = try fixture.coordinator.addWatch(targetTaskID: target.id, condition: .done, notifyTaskID: watcher.id)
        let archived = try fixture.coordinator.addWatch(targetTaskID: target.id, condition: .archived, notifyTaskID: watcher.id)
        let idle = try fixture.coordinator.addWatch(targetTaskID: target.id, condition: .idle, notifyTaskID: watcher.id)

        // The agent also finishes a turn: the archive still wins.
        fixture.sessions.report(try sessionID(target), .working, at: Date().addingTimeInterval(1))
        fixture.sessions.report(try sessionID(target), .ready, at: Date().addingTimeInterval(2))
        try fixture.coordinator.records.save(id: target.id) { $0.archivedAt = Date() }
        fixture.coordinator.evaluateWatches()
        fixture.coordinator.evaluateWatches()
        #expect(try messages(fixture, to: watcher).count == 1)
        for _ in 0..<2 {
            fixture.sessions.report(watcherSession, .working)
            fixture.sessions.report(watcherSession, .ready)
            fixture.coordinator.evaluateWatches()
        }
        let sent = try messages(fixture, to: watcher)
        #expect(sent.count == 3)
        let link = "[\(target.title)](toastty://task/\(target.id.uuidString))"
        #expect(sent.contains("[Toastty watch \(done.id.uuidString)] Task \(link) was archived, so your watch until done can never fire."))
        #expect(sent.contains { $0.hasPrefix("[Toastty watch \(idle.id.uuidString)] Task \(link) was archived,") })
        #expect(sent.contains { $0.hasPrefix("[Toastty watch \(archived.id.uuidString)] Task \(link) is archived.") })
        #expect(throws: TaskError("Task \(target.title) was archived, so it can never be done.")) {
            try fixture.coordinator.addWatch(targetTaskID: target.id, condition: .done, notifyTaskID: watcher.id)
        }
    }

    @Test func watchesCanBeListedAndCancelled() async throws {
        let fixture = try Fixture()
        let target = try await fixture.startedTask()
        let watcher = try await fixture.startedTask()
        #expect(throws: TaskError("A task cannot watch itself.")) {
            try fixture.coordinator.addWatch(targetTaskID: target.id, condition: .idle, notifyTaskID: target.id)
        }
        let saved = try fixture.coordinator.addWatch(targetTaskID: target.id, condition: .idle, notifyTaskID: watcher.id)
        let polled = try fixture.coordinator.addWatch(targetTaskID: target.id, condition: .waiting, notifyTaskID: nil)
        #expect(fixture.coordinator.allWatches().map(\.watch.id) == [saved.id, polled.id])
        #expect(fixture.coordinator.watch(id: saved.id)?.notifyTaskID == watcher.id)

        try fixture.coordinator.cancelWatch(id: saved.id)
        try fixture.coordinator.cancelWatch(id: polled.id)
        #expect(fixture.coordinator.allWatches().isEmpty)
        #expect(fixture.record(watcher.id)?.watches == nil)
        #expect(throws: TaskError("No watch has ID \(saved.id.uuidString).")) {
            try fixture.coordinator.cancelWatch(id: saved.id)
        }
    }
}

/// Which tasks `task.list changedSince` reports.
@MainActor
struct TaskChangeFeedTests {
    private let a = UUID()
    private let b = UUID()
    private let visible = TaskChangeFeed.Visibility(workspaceIDs: [], creatorSessionID: nil)

    private func entries(_ values: [UUID: String]) -> [UUID: TaskChangeFeed.Entry] {
        values.mapValues { TaskChangeFeed.Entry(snapshot: .string($0), visibility: visible) }
    }

    @Test func aCursorReturnsOnlyLaterChangesAndDeletions() {
        let feed = TaskChangeFeed(launchID: "launch")
        let first = feed.observe(entries([a: "a1", b: "b1"]), since: nil)
        #expect(first.reset)

        let unchanged = feed.observe(entries([a: "a1", b: "b1"]), since: first.cursor)
        #expect(unchanged.changedTaskIDs.isEmpty && unchanged.deletedTasks.isEmpty && unchanged.reset == false)
        #expect(unchanged.cursor == first.cursor)

        let changed = feed.observe(entries([a: "a2"]), since: first.cursor)
        #expect(changed.changedTaskIDs == [a])
        #expect(changed.deletedTasks.map(\.id) == [b])
        let after = feed.observe(entries([a: "a2"]), since: changed.cursor)
        #expect(after.changedTaskIDs.isEmpty && after.deletedTasks.isEmpty)
    }

    @Test func onePollerDoesNotHideAChangeFromAnother() {
        let feed = TaskChangeFeed(launchID: "launch")
        let start = feed.observe(entries([a: "a1"]), since: nil).cursor
        // Poller one sees the change first.
        let one = feed.observe(entries([a: "a2"]), since: start)
        #expect(one.changedTaskIDs == [a])
        // Poller two, still at the old cursor, sees it too.
        #expect(feed.observe(entries([a: "a2"]), since: start).changedTaskIDs == [a])
    }

    @Test func aCursorFromAnotherLaunchStartsOver() {
        let feed = TaskChangeFeed(launchID: "second")
        let changes = feed.observe(entries([a: "a1"]), since: "first.7")
        #expect(changes.reset)
        #expect(changes.changedTaskIDs == [a])
        #expect(feed.observe(entries([a: "a1"]), since: "nonsense").reset)
        #expect(feed.observe(entries([a: "a1"]), since: "second.99").reset)
    }

    @Test func aCursorOlderThanDroppedDeletionsStartsOver() {
        let feed = TaskChangeFeed(launchID: "launch")
        let many = Dictionary(uniqueKeysWithValues: (0...TaskChangeFeed.maximumTombstones).map { (UUID(), "t\($0)") })
        let before = feed.observe(entries(many), since: nil).cursor
        // Every task is deleted at once: more deletions than the feed keeps.
        let all = feed.observe([:], since: before)
        #expect(all.reset)
        #expect(feed.observe([:], since: all.cursor).reset == false)
    }
}

/// The last reply as `task.get` reads it from a transcript.
@MainActor
struct TaskAgentReplyReaderTests {
    private func claudeLine(_ text: String, uuid: String = UUID().uuidString) -> String {
        let message: [String: Any] = ["role": "assistant", "content": [["type": "text", "text": text]]]
        let line: [String: Any] = [
            "type": "assistant", "uuid": uuid, "timestamp": "2026-10-20T10:00:00.000Z", "message": message,
        ]
        let data = try! JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    @Test func theLastAssistantMessageWinsAndAPartialFirstLineIsSkipped() {
        let transcript = [
            #"partial line from the middle of {"type":"assistant""#,
            claudeLine("First answer"),
            #"{"type":"user","uuid":"u2","timestamp":"2026-10-20T10:00:01.000Z","message":{"content":"thanks"}}"#,
            claudeLine("Done: PR #172 is open."),
        ].joined(separator: "\n")
        let reply = TaskAgentReplyReader.lastReply(agent: .claude, inTranscript: transcript, startsMidLine: true)
        #expect(reply?.text == "Done: PR #172 is open.")
        #expect(reply?.truncated == false)
        #expect(TaskAgentReplyReader.lastReply(agent: .claude, inTranscript: "", startsMidLine: false) == nil)
    }

    @Test func aReplyFileIsReadFromItsEndAndCached() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("reply-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let filler = (0..<4000).map { claudeLine("old \($0) " + String(repeating: "x", count: 200)) }
        try (filler + [claudeLine("The latest reply")]).joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        let reader = TaskAgentReplyReader()
        #expect(reader.lastReply(agent: .claude, transcriptPath: file.path)?.text == "The latest reply")

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        handle.write(Data((claudeLine("A newer reply") + "\n").utf8))
        try handle.close()
        #expect(reader.lastReply(agent: .claude, transcriptPath: file.path)?.text == "A newer reply")
        #expect(reader.lastReply(agent: .cursor, transcriptPath: file.path) == nil)
    }

    @Test func aLongReplyIsCutAtACharacterBoundary() {
        let text = String(repeating: "é", count: TaskAgentReplyReader.maximumTextBytes)
        let (capped, truncated) = TaskAgentReplyReader.cap(text)
        #expect(truncated)
        #expect(capped.utf8.count <= TaskAgentReplyReader.maximumTextBytes)
        #expect(capped.allSatisfy { $0 == "é" })
        #expect(TaskAgentReplyReader.cap("short") == ("short", false))
    }
}
