import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// How long a task has been in its state, as `task.get` and `task.list`
/// report it: the stage's time, a turn that a quit cut off, the user's last
/// input, and pending checks.
extension TaskAppControlTests {
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeBoard(
        _ fixture: TaskCoordinatorTests.Fixture,
        coordinator: TaskCoordinator,
        pullRequests: PullRequestStateCache? = nil
    ) -> TaskBoardStore {
        let board = TaskBoardStore(
            coordinator: coordinator,
            store: fixture.store,
            sessionRuntimeStore: fixture.sessionRuntimeStore,
            pullRequests: pullRequests ?? PullRequestStateCache(runner: OfflineGitHub()),
            refreshInterval: nil,
            releaseCheckInterval: nil
        )
        coordinator.board = board
        return board
    }

    private func startTask(_ fixture: TaskCoordinatorTests.Fixture) async throws -> TaskRecord {
        let created = try await fixture.coordinator.create(
            TaskCreateRequest(text: "Fix the unread dot", workspaceID: fixture.workspaceID, agent: "claude")
        )
        await fixture.waitForSetup(created.id)
        return try #require(fixture.record(created.id))
    }

    private func report(_ fixture: TaskCoordinatorTests.Fixture, _ sessionID: String, _ kind: SessionStatusKind) {
        fixture.sessionRuntimeStore.updateStatus(
            sessionID: sessionID, status: SessionStatus(kind: kind, summary: "\(kind)"), at: fixture.clock ?? Date()
        )
    }

    /// A new app launch over the saved records: a new coordinator with its
    /// own launch ID, reading what the last one wrote.
    private func relaunch(_ fixture: TaskCoordinatorTests.Fixture) -> TaskCoordinator {
        let coordinator = fixture.makeCoordinator(records: TaskRecordStore(fileURL: fixture.recordsFile))
        useLiveSessions(fixture, coordinator: coordinator)
        return coordinator
    }

    /// The agent Toastty restores in the task's pane after a relaunch: a new
    /// session at its prompt. Starting it ends the session it replaces.
    private func restoreAgent(_ fixture: TaskCoordinatorTests.Fixture, for record: TaskRecord, sessionID: String) throws {
        fixture.sessionRuntimeStore.startSession(
            sessionID: sessionID, agent: .claude,
            panelID: try #require(record.operation.taskSpace?.panelID),
            windowID: try #require(fixture.store.state.windows.first?.id),
            workspaceID: try #require(record.taskSpaceWorkspaceID),
            codexStatusTrackingSource: .externallyReported,
            cwd: fixture.projectRoot, repoRoot: fixture.projectRoot, at: fixture.clock ?? Date()
        )
    }

    private func object(_ value: AutomationJSONValue?) -> [String: AutomationJSONValue] {
        guard case .object(let object)? = value else { return [:] }
        return object
    }

    private func date(_ value: AutomationJSONValue?) -> Date? {
        guard case .string(let raw)? = value else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }

    private func get(_ executor: AppControlExecutor, _ taskID: UUID) throws -> [String: AutomationJSONValue] {
        try executor.runQuery(id: "task.get", args: ["taskID": .string(taskID.uuidString)])
    }

    private func listed(_ executor: AppControlExecutor, _ taskID: UUID, changedSince: String? = nil) throws -> [String: AutomationJSONValue]? {
        let args: [String: AutomationJSONValue] = changedSince.map { ["changedSince": .string($0)] } ?? [:]
        guard case .array(let tasks)? = try executor.runQuery(id: "task.list", args: args)["tasks"] else { return nil }
        return tasks.map(object).first { $0["taskID"] == .string(taskID.uuidString) }
    }

    private func cursor(_ executor: AppControlExecutor) throws -> String {
        guard case .string(let cursor)? = try executor.runQuery(id: "task.list", args: [:])["cursor"] else {
            throw TaskError("task.list has no cursor")
        }
        return cursor
    }

    // MARK: - Stage

    @Test func stageChangedAtFollowsTheStageThroughAFlickerAndARelaunch() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        fixture.clock = Self.t0
        func at(_ seconds: TimeInterval) -> Date { Self.t0.addingTimeInterval(seconds) }
        var board: TaskBoardStore? = makeBoard(fixture, coordinator: fixture.coordinator)
        var executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        let task = try await startTask(fixture)
        let session = try #require(task.operation.agentLaunch?.sessionID)
        func stage() throws -> [String: AutomationJSONValue] { object(try get(executor, task.id)["stage"]) }

        // The agent works on its first turn.
        report(fixture, session, .working)
        #expect(try stage()["group"] == .string("running"))
        #expect(date(try stage()["changedAt"]) == at(0))

        // Time passes; a later report of the same state changes nothing.
        fixture.clock = at(600)
        report(fixture, session, .working)
        #expect(date(try stage()["changedAt"]) == at(0))

        // The turn ends: the task is idle from now.
        report(fixture, session, .idle)
        #expect(try stage()["group"] == .string("idle"))
        #expect(date(try stage()["changedAt"]) == at(600))
        #expect(date(object(try listed(executor, task.id)?["stage"])["changedAt"]) == at(600))

        // A status that flickers and returns within the settle window keeps
        // the earlier time, as it sends no webhook event.
        fixture.clock = at(700)
        report(fixture, session, .working)
        #expect(try stage()["group"] == .string("running"))
        #expect(date(try stage()["changedAt"]) == at(700))
        fixture.clock = at(701)
        report(fixture, session, .idle)
        #expect(try stage()["group"] == .string("idle"))
        #expect(date(try stage()["changedAt"]) == at(600))

        // A turn that lasted is a real change, in both directions.
        fixture.clock = at(800)
        report(fixture, session, .working)
        #expect(date(try stage()["changedAt"]) == at(800))
        fixture.clock = at(900)
        report(fixture, session, .idle)
        #expect(date(try stage()["changedAt"]) == at(900))

        // After a relaunch the same stage keeps its earlier time.
        fixture.coordinator.records.flushForTesting()
        board = nil
        let relaunched = relaunch(fixture)
        board = makeBoard(fixture, coordinator: relaunched)
        executor = makeExecutor(fixture, coordinator: relaunched)
        fixture.clock = at(5000)
        #expect(try stage()["group"] == .string("idle"))
        #expect(date(try stage()["changedAt"]) == at(900))
        // A change after the relaunch starts a new time.
        report(fixture, session, .working)
        #expect(try stage()["group"] == .string("running"))
        #expect(date(try stage()["changedAt"]) == at(5000))

        // Toastty quits during that turn. The next launch restores the agent
        // idle: a turn that starts a second later is not the same Running.
        relaunched.records.flushForTesting()
        board = nil
        fixture.clock = at(6000)
        report(fixture, session, .idle)
        let again = relaunch(fixture)
        board = makeBoard(fixture, coordinator: again)
        executor = makeExecutor(fixture, coordinator: again)
        #expect(try stage()["group"] == .string("idle"))
        #expect(date(try stage()["changedAt"]) == at(6000))
        fixture.clock = at(6001)
        report(fixture, session, .working)
        #expect(try stage()["group"] == .string("running"))
        #expect(date(try stage()["changedAt"]) == at(6001))
        _ = board
    }

    @Test func theStageTimeIsRecordedWhenTheStageChangesNotWhenItIsRead() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        fixture.clock = Self.t0
        let board = makeBoard(fixture, coordinator: fixture.coordinator)
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        let task = try await startTask(fixture)
        let session = try #require(task.operation.agentLaunch?.sessionID)
        report(fixture, session, .working)
        _ = try get(executor, task.id)

        // The turn ends, and nobody asks for a while.
        fixture.clock = Self.t0.addingTimeInterval(60)
        report(fixture, session, .idle)
        let idleKey = TaskStageClock.Key(group: "idle")
        await fixture.waitUntil("the board records the stage change") {
            fixture.record(task.id)?.stateTimes?.stage?.since(idleKey) != nil
        }
        fixture.clock = Self.t0.addingTimeInterval(3600)
        #expect(date(object(try get(executor, task.id)["stage"])["changedAt"]) == Self.t0.addingTimeInterval(60))
        _ = board
    }

    @Test func aStageThatWaitsForGitHubsFirstAnswerDoesNotMoveTheStageTime() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        fixture.clock = Self.t0
        func at(_ seconds: TimeInterval) -> Date { Self.t0.addingTimeInterval(seconds) }
        var gitHub = PullRequestStateCache(runner: OfflineGitHub())
        var board: TaskBoardStore? = makeBoard(fixture, coordinator: fixture.coordinator, pullRequests: gitHub)
        var executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        let task = try await startTask(fixture)
        let session = try #require(task.operation.agentLaunch?.sessionID)
        func stage() throws -> [String: AutomationJSONValue] { object(try get(executor, task.id)["stage"]) }
        report(fixture, session, .working)
        report(fixture, session, .idle)
        #expect(try stage()["group"] == .string("idle"))

        // The agent linked a draft pull request. Until GitHub answers, a
        // linked pull request counts as waiting for review; that guess has
        // no time.
        let url = "https://github.com/toastty/toastty/pull/8"
        let link = try #require(WorkspacePullRequestLink(annotationURL: url))
        let draft = TaskPullRequestState(state: .open, isDraft: true, headSHA: "aaa")
        fixture.clock = at(100)
        _ = fixture.coordinator.records.update(id: task.id) { $0.pullRequestURL = url }
        #expect(try stage()["attention"] == .string("review"))
        #expect(try stage()["changedAt"] == .null)
        gitHub.store(draft, for: link, observedAt: at(100))
        #expect(try stage()["group"] == .string("idle"))
        #expect(date(try stage()["changedAt"]) == at(0))

        // After a relaunch Toastty has no answer yet, and guesses again.
        fixture.coordinator.records.flushForTesting()
        board = nil
        var relaunched = relaunch(fixture)
        gitHub = PullRequestStateCache(runner: OfflineGitHub())
        board = makeBoard(fixture, coordinator: relaunched, pullRequests: gitHub)
        executor = makeExecutor(fixture, coordinator: relaunched)
        fixture.clock = at(5000)
        #expect(try stage()["attention"] == .string("review"))
        #expect(try stage()["changedAt"] == .null)
        fixture.clock = at(5100)
        gitHub.store(draft, for: link, observedAt: at(5100))
        #expect(try stage()["group"] == .string("idle"))
        #expect(date(try stage()["changedAt"]) == at(0))

        // A record from before Toastty kept stage times has no time to keep:
        // the guess still gets none.
        board = nil
        _ = relaunched.records.update(id: task.id) { $0.stateTimes = nil }
        relaunched.records.flushForTesting()
        relaunched = relaunch(fixture)
        gitHub = PullRequestStateCache(runner: OfflineGitHub())
        board = makeBoard(fixture, coordinator: relaunched, pullRequests: gitHub)
        executor = makeExecutor(fixture, coordinator: relaunched)
        fixture.clock = at(7000)
        #expect(try stage()["attention"] == .string("review"))
        #expect(try stage()["changedAt"] == .null)
        #expect(relaunched.records.record(id: task.id)?.stateTimes?.stage == nil)
        fixture.clock = at(7100)
        gitHub.store(draft, for: link, observedAt: at(7100))
        #expect(try stage()["group"] == .string("idle"))
        #expect(date(try stage()["changedAt"]) == at(7100))

        // Without `gh` the request fails, and the guess is all there is.
        relaunched.records.flushForTesting()
        board = nil
        relaunched = relaunch(fixture)
        gitHub = PullRequestStateCache(runner: OfflineGitHub())
        board = makeBoard(fixture, coordinator: relaunched, pullRequests: gitHub)
        executor = makeExecutor(fixture, coordinator: relaunched)
        fixture.clock = at(9000)
        #expect(try stage()["attention"] == .string("review"))
        #expect(try stage()["changedAt"] == .null)
        await gitHub.refresh(link).value
        #expect(try stage()["attention"] == .string("review"))
        #expect(date(try stage()["changedAt"]) == at(9000))
        _ = board
    }

    // MARK: - Agent state and a turn cut off by a quit

    @Test func agentStateChangedAtIsWhenTheStateChangedNotWhenTheStatusWasLastReported() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        useLiveSessions(fixture)
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        let task = try await startTask(fixture)
        let session = try #require(task.operation.agentLaunch?.sessionID)
        func changedAt() throws -> Date? { date(object(try get(executor, task.id)["agentState"])["changedAt"]) }

        fixture.clock = Self.t0
        report(fixture, session, .working)
        fixture.clock = Self.t0.addingTimeInterval(30)
        report(fixture, session, .idle)
        #expect(try changedAt() == Self.t0.addingTimeInterval(30))

        fixture.clock = Self.t0.addingTimeInterval(100)
        report(fixture, session, .working)
        fixture.clock = Self.t0.addingTimeInterval(400)
        report(fixture, session, .working)
        #expect(object(try get(executor, task.id)["agentState"])["state"] == .string("busy"))
        #expect(try changedAt() == Self.t0.addingTimeInterval(100))
    }

    @Test func aTurnCutOffByACrashIsReportedUntilTheAgentStartsItsNextTurn() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        useLiveSessions(fixture)
        var executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        let task = try await startTask(fixture)
        let session = try #require(task.operation.agentLaunch?.sessionID)
        func agentState() throws -> [String: AutomationJSONValue] { object(try get(executor, task.id)["agentState"]) }

        report(fixture, session, .working)
        #expect(try agentState()["state"] == .string("busy"))
        #expect(try agentState()["interruptedAtQuit"] == .bool(false))
        // A crash writes nothing more: the turn's mark is on disk already.
        #expect(fixture.savedRecord(task.id)?.stateTimes?.turnLaunchID != nil)

        // Toastty relaunches and restores the agent at its prompt.
        let relaunched = relaunch(fixture)
        executor = makeExecutor(fixture, coordinator: relaunched)
        try restoreAgent(fixture, for: task, sessionID: "restored")
        #expect(try agentState()["state"] == .string("idle"))
        #expect(try agentState()["interruptedAtQuit"] == .bool(true))
        #expect(object(try listed(executor, task.id)?["agentState"])["interruptedAtQuit"] == .bool(true))
        // The idle agent of a cut-off turn raises the coordinator's alert.
        #expect(relaunched.alertFacts(for: [task.id])[task.id]?.interruptedAtQuit == true)

        // The next turn clears it, and it stays clear after that turn.
        report(fixture, "restored", .working)
        #expect(try agentState()["interruptedAtQuit"] == .bool(false))
        #expect(relaunched.alertFacts(for: [task.id])[task.id]?.interruptedAtQuit == false)
        report(fixture, "restored", .idle)
        #expect(try agentState()["interruptedAtQuit"] == .bool(false))
        #expect(relaunched.records.record(id: task.id)?.stateTimes?.turnLaunchID == nil)
    }

    @Test func aTurnCutOffByAQuitIsReportedAndATurnThatEndedBeforeTheQuitIsNot() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        useLiveSessions(fixture)
        var executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        let task = try await startTask(fixture)
        let session = try #require(task.operation.agentLaunch?.sessionID)
        func agentState() throws -> [String: AutomationJSONValue] { object(try get(executor, task.id)["agentState"]) }

        // The agent waits for an approval, inside its turn, when the user
        // quits. Its session stops while the app goes down.
        report(fixture, session, .working)
        report(fixture, session, .needsApproval)
        #expect(try agentState()["state"] == .string("waiting"))
        fixture.coordinator.prepareForTermination()
        fixture.sessionRuntimeStore.stopSession(sessionID: session, at: Date())
        fixture.coordinator.recordStateTimes()
        fixture.coordinator.records.flushForTesting()

        // After the relaunch no agent runs yet; the cut-off turn is known.
        var relaunched = relaunch(fixture)
        executor = makeExecutor(fixture, coordinator: relaunched)
        #expect(try agentState()["state"] == .string("notRunning"))
        #expect(try agentState()["interruptedAtQuit"] == .bool(true))
        // No agent to continue yet: no alert until it waits at its prompt.
        #expect(relaunched.alertFacts(for: [task.id])[task.id]?.interruptedAtQuit == false)

        // The restored agent finishes a turn; the next quit cuts nothing off.
        try restoreAgent(fixture, for: task, sessionID: "restored")
        report(fixture, "restored", .working)
        report(fixture, "restored", .idle)
        #expect(try agentState()["interruptedAtQuit"] == .bool(false))
        relaunched.prepareForTermination()
        relaunched = relaunch(fixture)
        executor = makeExecutor(fixture, coordinator: relaunched)
        #expect(try agentState()["interruptedAtQuit"] == .bool(false))
    }

    // MARK: - The user's input

    @Test func onlyThePersonsInputCountsAsUserInput() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        // Input reaches the session store through the terminal registry, as
        // in the app: keys and pastes from the terminal view, and typed text
        // from `task send` and `terminal.send-text`.
        let terminals = TerminalRuntimeRegistry()
        terminals.bind(sessionLifecycleTracker: fixture.sessionRuntimeStore)
        fixture.coordinator.sessions = LiveTaskSessions(
            sessionRuntimeStore: fixture.sessionRuntimeStore,
            closeController: SessionCloseController(
                store: fixture.store,
                sessionRuntimeStore: fixture.sessionRuntimeStore,
                focusedPanelCommandController: FocusedPanelCommandController(
                    store: fixture.store, runtimeRegistry: terminals, slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
                ),
                terminalCloseAssessment: { _ in nil },
                localDocumentCloseConfirmationState: { _ in nil },
                shouldBypassConfirmation: true
            ),
            exitController: nil,
            sendText: { text, panelID in
                _ = terminals.sendText(text, submit: true, panelID: panelID, focusPolicy: .preserveFirstResponder)
                return true
            }
        )
        fixture.sessionRuntimeStore.taskCoordinator = fixture.coordinator
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        let task = try await startTask(fixture)
        let other = try await startTask(fixture)
        let panel = try #require(task.operation.taskSpace?.panelID)
        func lastUserInputAt(_ id: UUID) throws -> Date? { date(try get(executor, id)["lastUserInputAt"]) }
        #expect(try get(executor, task.id)["lastUserInputAt"] == .null)

        // Another agent's message is typed into the terminal, but no person
        // typed it.
        _ = try executor.runAction(
            id: "task.send", args: ["taskID": .string(task.id.uuidString), "text": .string("Rebase on main, please")], context: context()
        )
        #expect(fixture.sessionRuntimeStore.lastLocalInputAt(panelID: panel) != nil)
        #expect(try get(executor, task.id)["lastUserInputAt"] == .null)

        // The user types into the task's terminal. Nothing else changes and
        // nobody asks, and the time is still saved for the next launch.
        let before = Date()
        terminals.handleLocalInput(for: panel, kind: .key)
        await fixture.waitUntil("the typing is saved") {
            fixture.record(task.id)?.stateTimes?.lastUserInputAt != nil
        }
        let typedAt = try #require(try lastUserInputAt(task.id))
        #expect(typedAt.timeIntervalSince(before) > -1)
        #expect(date(try listed(executor, task.id)?["lastUserInputAt"]) == typedAt)
        // The other task's terminal saw nothing.
        #expect(try get(executor, other.id)["lastUserInputAt"] == .null)

        // A paste counts as well, and a later `task send` does not move it.
        terminals.handleLocalInput(for: try #require(other.operation.taskSpace?.panelID), kind: .paste)
        #expect(try lastUserInputAt(other.id) != nil)
        let typed = try get(executor, task.id)["lastUserInputAt"]
        _ = try executor.runAction(
            id: "task.send", args: ["taskID": .string(task.id.uuidString), "text": .string("status?")], context: context()
        )
        #expect(try get(executor, task.id)["lastUserInputAt"] == typed)
    }

    /// What Remote Access reports about phone input for a panel.
    @MainActor
    private final class PhoneInput: SessionRemoteInputProbe {
        var sentAt: [UUID: Date] = [:]
        func hasRemoteInput(panelID _: UUID, since _: Date) -> Bool { false }
        func lastRemoteUserInputAt(panelID: UUID) -> Date? { sentAt[panelID] }
    }

    @Test func aPhoneMessageCountsAsUserInputAndTheTimeSurvivesARelaunch() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let closeController = SessionCloseController(
            store: fixture.store,
            sessionRuntimeStore: fixture.sessionRuntimeStore,
            focusedPanelCommandController: FocusedPanelCommandController(
                store: fixture.store, runtimeRegistry: TerminalRuntimeRegistry(), slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
            ),
            terminalCloseAssessment: { _ in nil },
            localDocumentCloseConfirmationState: { _ in nil },
            shouldBypassConfirmation: true
        )
        let exitController = SessionExitController(
            store: fixture.store, sessionRuntimeStore: fixture.sessionRuntimeStore,
            sessionCloseController: closeController, sendText: { _, _ in true }
        )
        let phone = PhoneInput()
        exitController.remoteInputProbe = phone
        fixture.coordinator.sessions = LiveTaskSessions(
            sessionRuntimeStore: fixture.sessionRuntimeStore, closeController: closeController,
            exitController: exitController, sendText: { _, _ in true }
        )
        var executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        let task = try await startTask(fixture)
        let panel = try #require(task.operation.taskSpace?.panelID)
        #expect(try get(executor, task.id)["lastUserInputAt"] == .null)

        let sentAt = Date(timeIntervalSince1970: 1_800_000_000)
        phone.sentAt[panel] = sentAt
        #expect(date(try get(executor, task.id)["lastUserInputAt"]) == sentAt)

        // The time is saved with the record, so a relaunch keeps it.
        fixture.coordinator.records.flushForTesting()
        let relaunched = relaunch(fixture)
        executor = makeExecutor(fixture, coordinator: relaunched)
        #expect(date(try get(executor, task.id)["lastUserInputAt"]) == sentAt)
        // The sessions hold these weakly.
        withExtendedLifetime((exitController, phone)) {}
    }

    @Test func outputAndInputTimesDoNotListATaskAsChanged() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let sessions = TaskStartWorkTests.FakeSessions()
        fixture.coordinator.sessions = sessions
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        let task = try await startTask(fixture)
        let session = try #require(task.operation.agentLaunch?.sessionID)
        let panel = try #require(task.operation.taskSpace?.panelID)
        sessions.sessions[session] = TaskSessionInfo(
            sessionID: session, agent: .claude, panelID: panel, workspaceID: try #require(task.taskSpaceWorkspaceID),
            cwd: nil, isActive: true, isInTurn: true, nativeConversationID: nil, title: nil,
            status: SessionStatus(kind: .working, summary: "Working")
        )
        let start = try cursor(executor)

        // The agent writes to its transcript and the user types, a minute
        // apart; the state stays the same.
        let wroteAt = Date(timeIntervalSince1970: 1_800_000_100)
        sessions.outputAt[session] = wroteAt
        sessions.userInputAt[panel] = wroteAt.addingTimeInterval(120)
        #expect(try listed(executor, task.id, changedSince: start) == nil)
        // A full list and `task.get` report both times.
        let full = try #require(try listed(executor, task.id))
        #expect(date(object(full["agentState"])["lastOutputAt"]) == wroteAt)
        #expect(date(full["lastUserInputAt"]) == wroteAt.addingTimeInterval(120))
        #expect(date(object(try get(executor, task.id)["agentState"])["lastOutputAt"]) == wroteAt)
    }

    @Test func lastOutputAtIsTheTranscriptsModificationTime() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        useLiveSessions(fixture)
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        let task = try await startTask(fixture)
        let session = try #require(task.operation.agentLaunch?.sessionID)
        func lastOutputAt() throws -> AutomationJSONValue? { object(try get(executor, task.id)["agentState"])["lastOutputAt"] }
        // Null until Toastty has confirmed the session's transcript.
        #expect(try lastOutputAt() == .null)

        let transcript = fixture.root.appendingPathComponent("transcript.jsonl")
        try Data("{}\n".utf8).write(to: transcript)
        let wroteAt = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: wroteAt], ofItemAtPath: transcript.path)
        #expect(fixture.sessionRuntimeStore.confirmNativeSessionBinding(
            managedSessionID: session, panelID: try #require(task.operation.taskSpace?.panelID),
            record: ManagedAgentResumeRecord(
                agent: .claude, nativeSessionID: "native-1", sessionFilePath: transcript.path,
                cwd: fixture.projectRoot, capturedAt: Date()
            )
        ))
        #expect(date(try lastOutputAt()) == wroteAt)
    }

    // MARK: - Pending checks

    @Test func pendingChecksReportWhenToasttyFirstSawThemPending() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        fixture.clock = Self.t0
        func at(_ seconds: TimeInterval) -> Date { Self.t0.addingTimeInterval(seconds) }
        let gitHub = PullRequestStateCache(runner: OfflineGitHub())
        var board: TaskBoardStore? = makeBoard(fixture, coordinator: fixture.coordinator, pullRequests: gitHub)
        var executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        let task = try await startTask(fixture)
        func pullRequest() throws -> AutomationJSONValue? { try get(executor, task.id)["pullRequest"] }
        #expect(try pullRequest() == .null)

        let url = "https://github.com/toastty/toastty/pull/7"
        let link = try #require(WorkspacePullRequestLink(annotationURL: url))
        _ = fixture.coordinator.records.update(id: task.id) { $0.pullRequestURL = url }
        // Linked, but GitHub has not answered yet.
        #expect(try pullRequest() == .null)

        func answer(checks: PullRequestMergeability.Checks?, head: String, mergeState: PullRequestMergeability.MergeState = .blocked, at date: Date) {
            gitHub.store(
                TaskPullRequestState(
                    state: .open, isDraft: true, headSHA: head,
                    mergeability: PullRequestMergeability(mergeState: mergeState, checks: checks)
                ),
                for: link, observedAt: date
            )
        }
        answer(checks: .running, head: "aaa", at: at(10))
        #expect(try pullRequest() == .object([
            "state": .string("open"), "isDraft": .bool(true), "mergeStateStatus": .string("BLOCKED"),
            "checks": .string("pending"), "checksPendingSince": .string(ISO8601DateFormatter().string(from: at(10))),
        ]))

        // A later answer for the same commit keeps the time.
        fixture.clock = at(300)
        answer(checks: .running, head: "aaa", mergeState: .unstable, at: at(300))
        #expect(date(object(try pullRequest())["checksPendingSince"]) == at(10))
        #expect(object(try pullRequest())["mergeStateStatus"] == .string("UNSTABLE"))

        // So does a relaunch, once GitHub answers again.
        fixture.coordinator.records.flushForTesting()
        board = nil
        let relaunched = relaunch(fixture)
        board = makeBoard(fixture, coordinator: relaunched, pullRequests: gitHub)
        executor = makeExecutor(fixture, coordinator: relaunched)
        fixture.clock = at(900)
        answer(checks: .running, head: "aaa", at: at(900))
        #expect(date(object(try pullRequest())["checksPendingSince"]) == at(10))

        // A push starts the time again; a result ends it.
        answer(checks: .running, head: "bbb", at: at(1000))
        #expect(date(object(try pullRequest())["checksPendingSince"]) == at(1000))
        answer(checks: .failing, head: "bbb", at: at(1100))
        #expect(object(try pullRequest())["checks"] == .string("failing"))
        #expect(object(try pullRequest())["checksPendingSince"] == .null)
        answer(checks: .passing, head: "bbb", mergeState: .clean, at: at(1200))
        #expect(object(try pullRequest())["checks"] == .string("passing"))
        #expect(object(try pullRequest())["mergeStateStatus"] == .string("CLEAN"))

        // After the next push GitHub has not worked out the merge state yet.
        // The Merge button keeps the last known answer; the report gives the
        // new commit's checks.
        answer(checks: .running, head: "ccc", mergeState: .unknown, at: at(1300))
        #expect(gitHub.state(for: link)?.mergeability?.checks == .passing)
        #expect(object(try pullRequest())["checks"] == .string("pending"))
        #expect(object(try pullRequest())["mergeStateStatus"] == .string("UNKNOWN"))
        #expect(date(object(try pullRequest())["checksPendingSince"]) == at(1300))
        _ = board
    }

    // MARK: - Alert facts

    @Test func alertFactsAreTheAgentStateAndTheChecksThatTaskGetReports() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        fixture.clock = Self.t0
        func at(_ seconds: TimeInterval) -> Date { Self.t0.addingTimeInterval(seconds) }
        let sessions = TaskStartWorkTests.FakeSessions()
        fixture.coordinator.sessions = sessions
        let gitHub = PullRequestStateCache(runner: OfflineGitHub())
        let board = makeBoard(fixture, coordinator: fixture.coordinator, pullRequests: gitHub)
        let task = try await startTask(fixture)
        let session = try #require(task.operation.agentLaunch?.sessionID)
        func facts() throws -> TaskAlertFacts { try #require(fixture.coordinator.alertFacts(for: [task.id])[task.id]) }
        func agent(_ kind: SessionStatusKind) throws {
            sessions.sessions[session] = TaskSessionInfo(
                sessionID: session, agent: .claude, panelID: try #require(task.operation.taskSpace?.panelID),
                workspaceID: try #require(task.taskSpaceWorkspaceID), cwd: nil, isActive: true,
                isInTurn: kind == .working || kind == .needsApproval, nativeConversationID: nil, title: nil,
                status: SessionStatus(kind: kind, summary: "\(kind)")
            )
        }

        // A busy agent, with the time its transcript last changed.
        try agent(.working)
        sessions.outputAt[session] = at(5)
        #expect(try facts() == TaskAlertFacts(agentBusy: true, lastOutputAt: at(5), checks: .none))
        // Waiting for an approval, or at its prompt: not busy.
        try agent(.needsApproval)
        #expect(try facts().agentBusy == false)
        try agent(.idle)
        #expect(try facts() == TaskAlertFacts(agentBusy: false, lastOutputAt: nil, checks: .none))
        #expect(fixture.coordinator.alertFacts(for: [UUID()]).isEmpty)

        // A linked pull request GitHub has not answered for: unknown.
        let url = "https://github.com/toastty/toastty/pull/7"
        let link = try #require(WorkspacePullRequestLink(annotationURL: url))
        _ = fixture.coordinator.records.update(id: task.id) { $0.pullRequestURL = url }
        #expect(try facts().checks == .unknown)
        func answer(_ checks: PullRequestMergeability.Checks?, head: String, state: TaskPullRequestState.State = .open, at date: Date) {
            gitHub.store(
                TaskPullRequestState(state: state, headSHA: head, mergeability: PullRequestMergeability(mergeState: .blocked, checks: checks)),
                for: link, observedAt: date
            )
        }
        // Pending since Toastty first saw them pending on this commit, as
        // `checksPendingSince` reports.
        answer(.running, head: "aaa", at: at(10))
        fixture.coordinator.recordStateTimes()
        #expect(try facts().checks == .pending(since: at(10)))
        // A push that the saved time does not belong to yet: no time.
        answer(.running, head: "bbb", at: at(1000))
        #expect(try facts().checks == .pending(since: nil))
        fixture.coordinator.recordStateTimes()
        #expect(try facts().checks == .pending(since: at(1000)))
        answer(.failing, head: "bbb", at: at(1100))
        #expect(try facts().checks == .failing)
        answer(.passing, head: "bbb", at: at(1200))
        #expect(try facts().checks == .passing)
        answer(nil, head: "ccc", at: at(1300))
        #expect(try facts().checks == .none)
        // A closed or merged pull request has no checks to tell.
        answer(.failing, head: "ccc", state: .closed, at: at(1400))
        #expect(try facts().checks == .none)
        answer(.failing, head: "ccc", at: at(1500))
        _ = fixture.coordinator.records.update(id: task.id) { $0.mergedAt = at(1500) }
        #expect(try facts().checks == .none)
        _ = board
    }
}
