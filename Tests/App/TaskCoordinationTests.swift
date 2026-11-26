import CoreState
import CryptoKit
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

    @Test func checkedApprovalWaitsForAnOpenPromptAndIsOnlyTypedOnce() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask()
        let session = try sessionID(task)
        let coordinator = fixture.coordinator!
        let request = try coordinator.needsReply(taskID: task.id, question: "Read the release receipt?", approval: true)
        let questionID = try #require(request.replyRequest?.approvalID)
        fixture.sessions.report(session, .ready)
        fixture.sessions.sessionsShowingInteraction.insert(session)
        let answer = try coordinator.answerApproval(taskID: task.id, questionID: questionID, decision: .approve)
        #expect(answer.delivery == .queued)
        #expect(try messages(fixture, to: task).isEmpty)
        #expect(throws: TaskError.self) {
            try coordinator.answerApproval(taskID: task.id, questionID: questionID, decision: .decline)
        }

        fixture.sessions.sessionsShowingInteraction.remove(session)
        fixture.sessions.deliveryResult = .uncertain
        coordinator.evaluateWatches()
        coordinator.evaluateWatches()
        let sent = try #require(fixture.record(task.id)?.lastApprovalAnswer)
        #expect(sent.sessionID == session)
        #expect(sent.delivery == .sentUnconfirmed)
        #expect(try messages(fixture, to: task) == ["\(answer.messageHeader)\nApproved by you.\nRead the release receipt?"])
    }

    /// A turn that a saved `--steer` message starts would clear the task's
    /// question, so the answer to it takes the open prompt first.
    @Test func anAnswerToTheTasksQuestionGoesBeforeASavedSteerMessage() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask()
        let session = try sessionID(task)
        let coordinator = fixture.coordinator!
        let request = try coordinator.needsReply(taskID: task.id, question: "Read the release receipt?", approval: true)
        let questionID = try #require(request.replyRequest?.approvalID)
        fixture.sessions.report(session, .working)
        fixture.sessions.steerResult = .success(.mustWait)
        _ = try await coordinator.sendSteering(taskID: task.id, text: "The user says: use 300 ms", from: "the coordinator")
        let answer = try coordinator.answerApproval(taskID: task.id, questionID: questionID, decision: .approve)
        #expect(try messages(fixture, to: task).isEmpty)

        fixture.sessions.report(session, .ready)
        coordinator.evaluateWatches()
        coordinator.evaluateWatches()
        let approved = "\(answer.messageHeader)\nApproved by you.\nRead the release receipt?"
        #expect(try messages(fixture, to: task) == [approved])
        #expect(fixture.record(task.id)?.lastApprovalAnswer?.delivery == .sent)

        fixture.sessions.report(session, .working)
        fixture.sessions.report(session, .ready)
        coordinator.evaluateWatches()
        #expect(try messages(fixture, to: task) == [approved, "The user says: use 300 ms"])
    }

    @Test func replacingOrExpiringAQuestionLeavesItsOldAnswerUndelivered() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask()
        let session = try sessionID(task)
        let coordinator = fixture.coordinator!
        let first = try coordinator.needsReply(taskID: task.id, question: "Read the first receipt?", approval: true)
        let firstID = try #require(first.replyRequest?.approvalID)
        fixture.sessions.report(session, .working)
        try coordinator.answerApproval(taskID: task.id, questionID: firstID, decision: .approve)
        let next = try coordinator.needsReply(taskID: task.id, question: "Read the second receipt?", approval: true)
        let nextID = try #require(next.replyRequest?.approvalID)
        #expect(throws: TaskError.self) {
            try coordinator.answerApproval(taskID: task.id, questionID: firstID, decision: .approve)
        }
        try coordinator.answerApproval(taskID: task.id, questionID: nextID, decision: .decline)
        let deadline = try #require(next.replyRequest?.askedAt).addingTimeInterval(TaskApprovalAnswer.questionLifetime)
        fixture.sessions.report(session, .ready)
        coordinator.deliverApprovalAnswers(at: deadline)
        #expect(try messages(fixture, to: task).isEmpty)
        #expect(fixture.record(task.id)?.lastApprovalAnswer?.delivery == .cancelled)
    }

    @Test func aSignedBotAnswerRequiresTheOwnersGrantAndMatchingFleet() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask()
        let session = try sessionID(task)
        let coordinator = fixture.coordinator!
        try coordinator.records.save(id: task.id) { $0.release = TaskRelease(childTaskIDs: []) }
        let webhooks = TaskWebhookService(webhooksFileURL: nil, outboxFileURL: nil, secrets: InMemoryTaskWebhookSecretStore())
        let secret = "disposable-bot-test-key"
        let webhook = try webhooks.add(
            name: "test-bot", settings: .init(url: "https://bot.example.test/events", auth: .hmac),
            secret: secret, requester: .init()
        )
        try webhooks.approve(id: webhook.id, shownDigest: webhook.settingsDigest)
        coordinator.webhooks = webhooks
        let scope = try #require(TaskFleetChecks(version: "0.2.12", targets: ["computer-one"]))
        let request = try coordinator.needsReply(taskID: task.id, question: nil, approval: true, fleetChecks: scope)
        let questionID = try #require(request.replyRequest?.approvalID)
        let approvedWebhook = try #require(webhooks.webhook(named: webhook.name))
        let grant = try #require(webhooks.fleetAnswerGrant(for: approvedWebhook, task: request, scope: scope))
        func submit(_ id: UUID, signedDecision: String = "approve") throws -> TaskApprovalAnswer {
            let input = "toastty-task-answer-v1\n\(webhook.id.uuidString)\n\(task.id.uuidString)\n\(id.uuidString)\n\(signedDecision)"
            let signature = HMAC<SHA256>.authenticationCode(
                for: Data(input.utf8), using: SymmetricKey(data: Data(secret.utf8))
            ).map { String(format: "%02x", $0) }.joined()
            return try coordinator.answerApproval(taskID: task.id, questionID: id, decision: .approve, bot: (webhook.id, signature))
        }
        #expect(throws: TaskError.self) { try submit(questionID) }
        try coordinator.grantFleetAnswers(taskID: task.id, questionID: questionID, grant: grant)
        #expect(throws: TaskError.self) { try submit(questionID, signedDecision: "decline") }
        fixture.sessions.report(session, .working)
        let answer = try submit(questionID)
        #expect(answer.delivery == .queued)
        #expect(throws: TaskError.self) { try submit(questionID) }
        fixture.sessions.report(session, .ready)
        coordinator.webhooks = nil
        coordinator.evaluateWatches()
        #expect(fixture.record(task.id)?.lastApprovalAnswer?.delivery == .queued)
        #expect(try messages(fixture, to: task).isEmpty)
        coordinator.webhooks = webhooks
        coordinator.evaluateWatches()
        let sent = try #require(fixture.record(task.id)?.lastApprovalAnswer)
        #expect(sent.delivery == .sent)
        #expect(try messages(fixture, to: task) == ["\(answer.messageHeader)\nApproved via test-bot.\n\(scope.question) \(scope.detail)"])

        let different = try #require(TaskFleetChecks(version: "0.2.12", targets: ["computer-two"]))
        let next = try coordinator.needsReply(taskID: task.id, question: nil, approval: true, fleetChecks: different)
        let nextID = try #require(next.replyRequest?.approvalID)
        #expect(throws: TaskError.self) { try submit(nextID) }
        let nextGrant = try #require(webhooks.fleetAnswerGrant(for: approvedWebhook, task: next, scope: different))
        try coordinator.grantFleetAnswers(taskID: task.id, questionID: nextID, grant: nextGrant)
        #expect(try submit(nextID).delivery == .queued)
        try coordinator.revokeFleetAnswers(taskID: task.id, grant: try #require(fixture.record(task.id)?.fleetAnswerGrant))
        #expect(fixture.record(task.id)?.lastApprovalAnswer?.delivery == .cancelled)
        let renewed = try #require(fixture.record(task.id)?.replyRequest?.approvalID)
        try coordinator.grantFleetAnswers(taskID: task.id, questionID: renewed, grant: nextGrant)
        #expect(throws: TaskError.self) { try submit(nextID) }
        #expect(try messages(fixture, to: task).count == 1)
    }

    @Test(arguments: [true, false])
    func queuedApprovalFollowsOnlyTheOriginalConversation(restored: Bool) async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask()
        let session = try sessionID(task)
        let coordinator = fixture.coordinator!
        fixture.sessions.report(session, .working)
        var agent = try #require(fixture.sessions.sessions[session])
        agent.nativeConversationID = "original-conversation"
        fixture.sessions.sessions[session] = agent
        let request = try coordinator.needsReply(taskID: task.id, question: "Read the test receipt?", approval: true)
        let questionID = try #require(request.replyRequest?.approvalID)
        #expect(try coordinator.answerApproval(taskID: task.id, questionID: questionID, decision: .approve).delivery == .queued)
        let reloaded = fixture.makeCoordinator(records: TaskRecordStore(fileURL: fixture.recordsFile))
        fixture.replaceCoordinator(reloaded)

        fixture.sessions.stop(session)
        agent.sessionID = "new-session"
        agent.nativeConversationID = restored ? "original-conversation" : "another-conversation"
        fixture.sessions.sessions[agent.sessionID] = agent
        fixture.sessions.report(agent.sessionID, .ready)
        reloaded.evaluateWatches()

        let answer = try #require(fixture.record(task.id)?.lastApprovalAnswer)
        #expect(answer.delivery == (restored ? .sent : .cancelled))
        #expect(try messages(fixture, to: task).count == (restored ? 1 : 0))
        if restored { #expect(answer.sessionID == agent.sessionID) }
    }

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

        fixture.sessions.steerResult = .success(.steered)
        let reached = try await fixture.coordinator.sendSteering(taskID: task.id, text: "Use the new name", from: "a")
        guard case .typed(.steered, let session) = reached else {
            Issue.record("Expected a typed message, got \(reached)")
            return
        }
        #expect(session.sessionID == (try sessionID(task)))
        #expect(fixture.sessions.steered.map(\.panelID) == [panel])
        #expect(fixture.sessions.steered.map(\.text) == ["Use the new name"])
        // Nothing went through the unchecked path, and nothing was saved.
        #expect(try messages(fixture, to: task).isEmpty)
        #expect(fixture.record(task.id)?.queuedMessages == nil)

        // A send that types nothing says so, with the reason.
        fixture.sessions.steerResult = .failure(.stateUnknown)
        await #expect(throws: TaskError("Toastty cannot tell what task \(task.title)'s agent does now, so it typed nothing. Send the message again when the agent is idle.")) {
            try await fixture.coordinator.sendSteering(taskID: task.id, text: "Use the new name", from: "a")
        }
        #expect(fixture.record(task.id)?.queuedMessages == nil)
        fixture.sessions.stop(try sessionID(task))
        await #expect(throws: TaskError("Task \(task.title) has no running agent.")) {
            try await fixture.coordinator.sendSteering(taskID: task.id, text: "Use the new name", from: "a")
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
        _ = try await fixture.coordinator.sendSteering(taskID: task.id, text: text, from: "a")
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

    // MARK: - Queued messages

    /// The coordinator's case: facts for an agent that stays busy reach it
    /// when its turn ends, once, and never inside a permission prompt or a
    /// question, or at the prompt of a turn that stopped with an error.
    @Test func aQueuedMessageWaitsForTheTurnToEndAndIsTypedOnce() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask()
        let session = try sessionID(task)
        let coordinator = fixture.coordinator!
        fixture.sessions.report(session, .working)

        let (queued, position) = try coordinator.queueMessage(taskID: task.id, text: "Logs show the crash", from: "the coordinator")
        #expect(queued.isWaiting && position == 1)
        #expect(try messages(fixture, to: task).isEmpty)

        fixture.sessions.report(session, .error, at: Date().addingTimeInterval(1))
        coordinator.evaluateWatches()
        fixture.sessions.report(session, .working)
        fixture.sessions.report(session, .needsApproval)
        coordinator.evaluateWatches()
        // A provider can still show a question while its hooks say ready.
        fixture.sessions.sessionsShowingInteraction.insert(session)
        fixture.sessions.report(session, .ready, at: Date().addingTimeInterval(2))
        coordinator.evaluateWatches()
        #expect(try messages(fixture, to: task).isEmpty)
        #expect(fixture.record(task.id)?.waitingMessages.count == 1)

        // Text that a person typed during that turn can still be in the
        // prompt: the message keeps waiting.
        let panel = try panelID(task)
        fixture.sessions.sessionsShowingInteraction.remove(session)
        fixture.sessions.userInputAt[panel] = Date()
        coordinator.evaluateWatches()
        #expect(try messages(fixture, to: task).isEmpty)
        #expect(fixture.record(task.id)?.waitingMessages.count == 1)

        // The person sends that text, and the turn it starts ends.
        fixture.sessions.report(session, .working, at: Date().addingTimeInterval(3))
        fixture.sessions.report(session, .ready, at: Date().addingTimeInterval(4))
        coordinator.evaluateWatches()
        coordinator.evaluateWatches()
        #expect(try messages(fixture, to: task) == ["Logs show the crash"])
        let sent = try #require(fixture.record(task.id)?.queuedMessages?.first)
        #expect(sent.outcome?.kind == .sent)
        #expect(sent.outcome?.sessionID == session)
        #expect(sent.text.isEmpty)
        #expect(sent.from == "the coordinator")

        // A queued send to a prompt that holds typed text is saved, not
        // refused as a plain send is, and waits.
        fixture.sessions.userInputAt[panel] = Date().addingTimeInterval(5)
        let occupied = try coordinator.queueMessage(taskID: task.id, text: "More logs", from: "the coordinator")
        #expect(occupied.message.isWaiting && occupied.position == 1)
        #expect(try messages(fixture, to: task).count == 1)
    }

    /// One message of Toastty's for each open prompt: a `--steer` message
    /// that had to wait first, then a watch's line, then queued messages,
    /// oldest first. An agent at its open prompt gets the first at once.
    @Test func queuedMessagesTakeOneOpenPromptEachInOrder() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask()
        let other = try await fixture.startedTask()
        let session = try sessionID(task)
        let panel = try panelID(task)
        let coordinator = fixture.coordinator!
        let start = Date()
        fixture.sessions.report(session, .working, at: start)
        fixture.sessions.report(session, .ready, at: start)

        let first = try coordinator.queueMessage(taskID: task.id, text: "First", from: "a")
        #expect(first.message.outcome?.kind == .sent && first.position == nil)
        let second = try coordinator.queueMessage(taskID: task.id, text: "Second", from: "a")
        let third = try coordinator.queueMessage(taskID: task.id, text: "Third", from: "a")
        #expect(second.message.isWaiting && second.position == 1)
        #expect(third.message.isWaiting && third.position == 2)
        coordinator.evaluateWatches()
        #expect(try messages(fixture, to: task) == ["First"])

        func endTurn(_ offset: TimeInterval) {
            fixture.sessions.report(session, .working, at: start.addingTimeInterval(offset - 0.5))
            fixture.sessions.report(session, .ready, at: start.addingTimeInterval(offset))
            coordinator.evaluateWatches()
            coordinator.evaluateWatches()
        }
        _ = try coordinator.addWatch(targetTaskID: other.id, condition: .waiting, notifyTaskID: task.id)
        fixture.sessions.report(try sessionID(other), .needsApproval)
        // The prompt that took "First" is still reported open: a `--steer`
        // send that cannot type now is saved, ahead of the queued messages.
        fixture.sessions.steerResult = .success(.mustWait)
        let steered = try await coordinator.sendSteering(taskID: task.id, text: "Use the new name", from: "the coordinator")
        guard case .saved(let saved, let position, _) = steered else {
            Issue.record("Expected a saved message, got \(steered)")
            return
        }
        #expect(saved.isSteer && saved.isWaiting && position == 1)
        // A send that waited for the agent's state may not type at this
        // prompt either: "First" took it.
        let mayTypeAtPrompt = try #require(fixture.sessions.mayTypeAtPrompt)
        #expect(mayTypeAtPrompt() == false)
        // A second one waits behind it, without a try to type it first.
        let behind = try await coordinator.sendSteering(taskID: task.id, text: "And the new path", from: "the coordinator")
        guard case .saved(_, .some(2), _) = behind else {
            Issue.record("Expected the second saved message, got \(behind)")
            return
        }
        #expect(fixture.sessions.steered.count == 1)
        #expect(try messages(fixture, to: task) == ["First"])

        // They go before the watch's line, one for each open prompt.
        endTurn(1)
        #expect(try messages(fixture, to: task) == ["First", "Use the new name"])
        endTurn(2)
        #expect(try messages(fixture, to: task) == ["First", "Use the new name", "And the new path"])

        // A `--steer` message typed at once took the next prompt, also
        // while the hooks still report it open.
        fixture.sessions.report(session, .working, at: start.addingTimeInterval(2.5))
        fixture.sessions.report(session, .ready, at: start.addingTimeInterval(3))
        fixture.sessions.steerTypedAt[panel] = start.addingTimeInterval(3.2)
        coordinator.evaluateWatches()
        #expect(try messages(fixture, to: task).count == 3)
        endTurn(4)
        let typed = try messages(fixture, to: task)
        #expect(typed.count == 4)
        #expect(typed.last?.hasPrefix("[Toastty watch") == true)
        endTurn(5)
        endTurn(6)
        #expect(try messages(fixture, to: task).suffix(2) == ["Second", "Third"])
        #expect(try messages(fixture, to: task).count == 6)
        // A prompt that nothing took and no message waits for is free.
        fixture.sessions.report(session, .working, at: start.addingTimeInterval(6.5))
        fixture.sessions.report(session, .ready, at: start.addingTimeInterval(7))
        #expect(mayTypeAtPrompt())
    }

    /// A merge prompt or a due wake that waits for the same open prompt
    /// goes first.
    @Test func aQueuedMessageLeavesThePromptToAWaitingMergeOrWake() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask()
        let session = try sessionID(task)
        let coordinator = fixture.coordinator!
        let start = Date()
        fixture.sessions.report(session, .working, at: start)
        _ = try coordinator.queueMessage(taskID: task.id, text: "Facts", from: "a")

        coordinator.mergeDeliveryTasks[task.id] = Task {}
        fixture.sessions.report(session, .ready, at: start.addingTimeInterval(1))
        coordinator.evaluateWatches()
        #expect(try messages(fixture, to: task).isEmpty)
        coordinator.mergeDeliveryTasks[task.id] = nil

        _ = try coordinator.setWaiting(taskID: task.id, reason: "email replies", wakeAt: Date().addingTimeInterval(3600))
        try coordinator.records.save(id: task.id) { $0.waiting?.wakeAt = Date().addingTimeInterval(-1) }
        coordinator.evaluateWatches()
        #expect(try messages(fixture, to: task).isEmpty)
        coordinator.evaluateWakes()
        #expect(try messages(fixture, to: task).count == 1)
        #expect(try messages(fixture, to: task).first?.hasPrefix("[Toastty wake]") == true)

        fixture.sessions.report(session, .working, at: start.addingTimeInterval(2))
        fixture.sessions.report(session, .ready, at: start.addingTimeInterval(3))
        coordinator.evaluateWatches()
        #expect(try messages(fixture, to: task).last == "Facts")
    }

    /// A queued message is saved with the task: it survives a relaunch and
    /// reaches the agent restored in the task's pane. It waits while a turn
    /// that the quit cut off has not gone on, and while the task's question
    /// waits for the user, since a new turn would hide both.
    @Test func aQueuedMessageSurvivesARelaunchAndWaitsForACutOffTurn() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask()
        fixture.sessions.report(try sessionID(task), .working)
        _ = try fixture.coordinator.queueMessage(taskID: task.id, text: "Review points", from: "the coordinator")
        // The launch that quits saw the turn run.
        let quitLaunch = fixture.coordinator.launchID
        try fixture.coordinator.records.save(id: task.id) {
            $0.stateTimes = TaskStateTimes()
            $0.stateTimes?.turnLaunchID = quitLaunch
        }

        fixture.sessions.stop(try sessionID(task))
        fixture.sessions.sessions["restored"] = TaskSessionInfo(
            sessionID: "restored", agent: .claude, panelID: try panelID(task), workspaceID: try #require(task.taskSpaceWorkspaceID),
            cwd: nil, isActive: true, isInTurn: false, nativeConversationID: nil, title: nil
        )
        let relaunched = fixture.makeCoordinator(records: TaskRecordStore(fileURL: fixture.recordsFile))
        fixture.replaceCoordinator(relaunched)
        relaunched.reconcileAfterLaunch()
        fixture.sessions.report("restored", .idle)
        relaunched.evaluateWatches()
        #expect(relaunched.wasInterruptedAtQuit(try #require(fixture.record(task.id))))
        #expect(try messages(fixture, to: task).isEmpty)

        // The cut-off turn went on and ended; now the task asks the user.
        try relaunched.records.save(id: task.id) {
            $0.stateTimes?.turnLaunchID = nil
            $0.replyRequest = TaskReplyRequest(askedAt: Date(), question: "Which name?")
        }
        relaunched.evaluateWatches()
        #expect(try messages(fixture, to: task).isEmpty)

        try relaunched.records.save(id: task.id) { $0.replyRequest = nil }
        // The monitor that reconcileAfterLaunch started picks it up.
        await fixture.waitUntil("the saved message is typed", timeout: .seconds(5)) {
            (try? messages(fixture, to: task)) == ["Review points"]
        }
        #expect(fixture.record(task.id)?.queuedMessages?.first?.outcome?.sessionID == "restored")
    }

    /// A `--steer` message that had to wait is saved on the task, so it
    /// survives a relaunch. Unlike a `--queue` message, it does not wait for
    /// a turn that the quit cut off, for the task's question, or for a task
    /// that merged: a `--steer` send to an open prompt types at once there
    /// too. Only an archived task drops it.
    @Test func aSteerMessageThatWaitsSurvivesARelaunch() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask()
        fixture.sessions.report(try sessionID(task), .working)
        fixture.sessions.steerResult = .success(.mustWait)
        _ = try await fixture.coordinator.sendSteering(taskID: task.id, text: "The user says: use 300 ms", from: "the coordinator")
        _ = try fixture.coordinator.queueMessage(taskID: task.id, text: "Review points", from: "the coordinator")
        let quitLaunch = fixture.coordinator.launchID
        try fixture.coordinator.records.save(id: task.id) {
            $0.stateTimes = TaskStateTimes()
            $0.stateTimes?.turnLaunchID = quitLaunch
            $0.replyRequest = TaskReplyRequest(askedAt: Date(), question: "Which delay?")
            $0.mergedAt = Date()
        }

        fixture.sessions.stop(try sessionID(task))
        fixture.sessions.sessions["restored"] = TaskSessionInfo(
            sessionID: "restored", agent: .claude, panelID: try panelID(task), workspaceID: try #require(task.taskSpaceWorkspaceID),
            cwd: nil, isActive: true, isInTurn: false, nativeConversationID: nil, title: nil
        )
        let relaunched = fixture.makeCoordinator(records: TaskRecordStore(fileURL: fixture.recordsFile))
        fixture.replaceCoordinator(relaunched)
        relaunched.reconcileAfterLaunch()
        fixture.sessions.report("restored", .idle)
        #expect(relaunched.wasInterruptedAtQuit(try #require(fixture.record(task.id))))
        // The monitor that reconcileAfterLaunch started types it.
        await fixture.waitUntil("the saved --steer message is typed", timeout: .seconds(5)) {
            (try? messages(fixture, to: task)) == ["The user says: use 300 ms"]
        }
        let saved = try #require(fixture.record(task.id)?.queuedMessages)
        #expect(saved.first?.isSteer == true)
        #expect(saved.first?.outcome?.kind == .sent)
        #expect(saved.first?.outcome?.sessionID == "restored")
        // The `--queue` message was dropped: the task merged.
        #expect(saved.last?.outcome?.kind == .dropped)
        #expect(saved.last?.outcome?.reason == "the task merged")

        // An archived task drops one that waits.
        fixture.sessions.report("restored", .working)
        _ = try await relaunched.sendSteering(taskID: task.id, text: "Too late", from: "the coordinator")
        try relaunched.records.save(id: task.id) { $0.archivedAt = Date() }
        relaunched.evaluateWatches()
        #expect(fixture.record(task.id)?.queuedMessages?.last?.outcome?.reason == "the task was archived")
        await #expect(throws: TaskError("Toastty cannot hold a message for task \(task.title): the task was archived. Nothing was typed.")) {
            try await relaunched.sendSteering(taskID: task.id, text: "Later still", from: "the coordinator")
        }
    }

    /// What a sender learns: an idle watch made after a queued send fires
    /// after the turn that read the message, and a message for a task that
    /// finished first is dropped with the reason.
    @Test func aSenderLearnsWhenItsQueuedMessageWasReadOrDropped() async throws {
        let fixture = try Fixture()
        let target = try await fixture.startedTask()
        let watcher = try await fixture.startedTask()
        let coordinator = fixture.coordinator!
        let session = try sessionID(target)
        fixture.sessions.report(try sessionID(watcher), .idle)
        fixture.sessions.report(session, .working)
        _ = try coordinator.queueMessage(taskID: target.id, text: "Check the logs", from: "a")
        _ = try coordinator.addWatch(targetTaskID: target.id, condition: .idle, notifyTaskID: watcher.id)

        // The turn ends: the message goes to its prompt, and the watch waits
        // while the hooks still report that earlier turn's end.
        fixture.sessions.report(session, .ready)
        coordinator.evaluateWatches()
        coordinator.evaluateWatches()
        #expect(try messages(fixture, to: target) == ["Check the logs"])
        #expect(try messages(fixture, to: watcher).isEmpty)
        fixture.sessions.report(session, .working)
        fixture.sessions.report(session, .ready, at: Date().addingTimeInterval(1))
        coordinator.evaluateWatches()
        coordinator.evaluateWatches()
        #expect(try messages(fixture, to: watcher).count == 1)

        // Up to 10 messages wait. The task merges before its turn ends.
        fixture.sessions.report(session, .working)
        for index in 1...TaskRecord.maximumWaitingMessages {
            _ = try coordinator.queueMessage(taskID: target.id, text: "Fact \(index)", from: "a")
        }
        let title = try #require(fixture.record(target.id)).title
        #expect(throws: TaskError(
            "Task \(title) already has 10 messages that wait for its agent's next prompt. Nothing was added."
        )) {
            try coordinator.queueMessage(taskID: target.id, text: "One more", from: "a")
        }
        try coordinator.records.save(id: target.id) { $0.mergedAt = Date() }
        fixture.sessions.report(session, .ready, at: Date().addingTimeInterval(2))
        coordinator.evaluateWatches()
        #expect(try messages(fixture, to: target) == ["Check the logs"])
        let outcomes = fixture.record(target.id)?.queuedMessages?.dropFirst().map(\.outcome)
        #expect(outcomes?.count == 10)
        #expect(outcomes?.allSatisfy { $0?.kind == .dropped && $0?.reason == "the task merged" } == true)
        #expect(throws: TaskError(
            "Toastty queues no message for task \(title): the task merged. A send without --queue types it at once and reopens the task."
        )) {
            try coordinator.queueMessage(taskID: target.id, text: "Too late", from: "a")
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
