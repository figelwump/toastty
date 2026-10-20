import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

/// Moving a task into its own git worktree, and creating a task straight
/// into one: the real reducer, store and git, with a fake launcher and fake
/// sessions in place of agents.
@MainActor
struct TaskStartWorkTests {
    /// Records launches. Each launch adds a session to `sessions`: a fork
    /// starts without a conversation until the test confirms it; a fresh
    /// agent reports one at once.
    @MainActor
    final class FakeLauncher: TaskAgentLaunching {
        struct Call {
            var profileID: String
            var workspaceID: UUID
            var panelID: UUID
            var cwd: String
            var model: String?
            var prompt: String
            var forkFromSessionID: String?
        }

        private(set) var calls: [Call] = []
        weak var sessions: FakeSessions?

        func launchProfileSummaries() -> [AgentLaunchProfileSummary] {
            ["claude", "codex", "cursor"].map { id in
                AgentLaunchProfileSummary(
                    profileID: id,
                    displayName: id,
                    agent: AgentKind(rawValue: id)!,
                    isInstalled: true,
                    acceptsInitialPrompt: true,
                    acceptsLeadingDashPrompt: true,
                    supportsModel: true,
                    supportsReasoningEffort: true
                )
            }
        }

        func launchTask(
            profileID: String,
            workspaceID: UUID,
            panelID: UUID,
            cwd: String,
            model: String?,
            reasoningEffort: String?,
            initialPrompt: String,
            parentSessionID: String?,
            forkFromSessionID: String?,
            beforeDispatch: @escaping @MainActor () throws -> Void
        ) async throws -> AgentLaunchResult {
            try beforeDispatch()
            calls.append(Call(
                profileID: profileID,
                workspaceID: workspaceID,
                panelID: panelID,
                cwd: cwd,
                model: model,
                prompt: initialPrompt,
                forkFromSessionID: forkFromSessionID
            ))
            let sessionID = "launched-\(calls.count)"
            let agent = AgentKind(rawValue: profileID)!
            sessions?.sessions[sessionID] = TaskSessionInfo(
                sessionID: sessionID,
                agent: agent,
                panelID: panelID,
                workspaceID: workspaceID,
                cwd: cwd,
                isActive: true,
                isInTurn: true,
                nativeConversationID: forkFromSessionID == nil ? "conversation-\(sessionID)" : nil
            )
            return AgentLaunchResult(
                agent: agent,
                displayName: profileID,
                sessionID: sessionID,
                windowID: UUID(),
                workspaceID: workspaceID,
                panelID: panelID,
                cwd: cwd,
                repoRoot: nil,
                commandLine: profileID
            )
        }
    }

    @MainActor
    final class FakeSessions: TaskSessionProviding {
        var sessions: [String: TaskSessionInfo] = [:]
        var inputAt: [UUID: Date] = [:]
        var closeOutcome: TaskOperation.SourceOutcome = .closed
        private(set) var closedPanels: [UUID] = []

        func session(_ sessionID: String) -> TaskSessionInfo? { sessions[sessionID] }

        func activeSession(panelID: UUID) -> TaskSessionInfo? {
            sessions.values.first { $0.panelID == panelID && $0.isActive }
        }

        func hasInput(panelID: UUID, since date: Date) -> Bool {
            inputAt[panelID].map { $0 > date } ?? false
        }

        func closeMovedSessionPane(panelID: UUID, agent: AgentKind) -> TaskOperation.SourceOutcome {
            closedPanels.append(panelID)
            return closeOutcome
        }

        func endTurn(_ sessionID: String) { sessions[sessionID]?.isInTurn = false }
        func confirm(_ sessionID: String) { sessions[sessionID]?.nativeConversationID = "conversation-\(sessionID)" }
        func stop(_ sessionID: String) { sessions[sessionID]?.isActive = false }
    }

    @MainActor
    final class Fixture {
        let repository: TaskGitTestRepository
        let store = AppStore(persistTerminalFontPreference: false)
        let launcher = FakeLauncher()
        let sessions = FakeSessions()
        let recordsFile: URL
        let workspaceID: UUID
        var config = TasksConfig()
        private(set) var coordinator: TaskCoordinator!

        init() throws {
            repository = try TaskGitTestRepository()
            recordsFile = repository.root.appendingPathComponent("task-records.json")
            let workspace = try #require(store.selectedWorkspace)
            workspaceID = workspace.id
            _ = store.send(.updateTerminalPanelMetadata(
                panelID: try #require(workspace.focusedPanelID),
                title: nil,
                cwd: repository.project
            ))
            launcher.sessions = sessions
            coordinator = makeCoordinator(records: TaskRecordStore(fileURL: recordsFile))
        }

        func makeCoordinator(records: TaskRecordStore) -> TaskCoordinator {
            let coordinator = TaskCoordinator(
                records: records,
                store: store,
                launcher: launcher,
                configLoader: { [unowned self] in config },
                attachmentsDirectoryURL: repository.root.appendingPathComponent("task-attachments"),
                hasActiveSession: { _ in false },
                grantScope: { _, _ in },
                worktreeCreator: TaskGitTestRepository.creator(),
                terminalReadinessTimeout: .seconds(1),
                timing: .init(
                    sourceTurnTimeout: .seconds(3),
                    forkConfirmationTimeout: .milliseconds(600),
                    pollInterval: .milliseconds(20)
                )
            )
            coordinator.sessions = sessions
            return coordinator
        }

        func replaceCoordinator(_ coordinator: TaskCoordinator) { self.coordinator = coordinator }

        func record(_ id: UUID) -> TaskRecord? { coordinator.records.record(id: id) }

        func waitUntil(_ description: String, timeout: Duration = .seconds(20), _ condition: () -> Bool) async {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while condition() == false {
                guard ContinuousClock.now < deadline else {
                    Issue.record("Timed out waiting until \(description)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }

        func waitForMove(_ id: UUID) async {
            await waitUntil("the move ends") { record(id)?.startWork?.state != .running }
        }

        /// A task that task.create started, whose agent is in a turn.
        func startedTask(agent: String = "claude") async throws -> TaskRecord {
            let created = try await coordinator.create(TaskCreateRequest(
                text: "Composer keeps a blank line after send",
                workspaceID: workspaceID,
                agent: agent
            ))
            await waitUntil("setup ends") { record(created.id)?.setup != .settingUp }
            return try #require(record(created.id))
        }

        func caller(of task: TaskRecord) throws -> TaskCaller {
            TaskCaller(sessionID: try #require(task.operation.agentLaunch?.sessionID), workspaceID: task.taskSpaceWorkspaceID)
        }

        func terminalCWD(workspaceID: UUID, panelID: UUID) -> String? {
            guard case .terminal(let terminal)? = store.state.workspacesByID[workspaceID]?.panelState(for: panelID) else {
                return nil
            }
            return terminal.cwd
        }

        func worktreePaths() throws -> [String] {
            try TaskGitTestRepository.git(["worktree", "list", "--porcelain"], in: repository.project)
                .split(separator: "\n")
                .filter { $0.hasPrefix("worktree ") }
                .map { String($0.dropFirst("worktree ".count)) }
        }
    }

    @Test func moveWaitsForTheTurnForksIntoTheWorktreeAndClosesTheSourceOnceConfirmed() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask()
        let source = try #require(task.operation.agentLaunch?.sessionID)
        let sourcePanel = try #require(task.operation.taskSpace?.panelID)
        let taskSpace = try #require(task.taskSpaceWorkspaceID)
        let remoteTip = try fixture.repository.pushToRemote("upstream")

        let moving = try fixture.coordinator.startWork(TaskStartWorkRequest(branchPrefix: "fix"), caller: fixture.caller(of: task))
        #expect(moving.startWork?.state == .running)

        // The worktree is made while the agent finishes its turn; the fork
        // waits for the turn so it copies the whole conversation.
        await fixture.waitUntil("the worktree exists") { fixture.record(task.id)?.worktree != nil }
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.launcher.calls.count == 1)
        fixture.sessions.endTurn(source)

        await fixture.waitUntil("the fork launches") { fixture.launcher.calls.count == 2 }
        let worktree = try #require(fixture.record(task.id)?.worktree)
        let fork = fixture.launcher.calls[1]
        #expect(fork.profileID == "claude")
        #expect(fork.forkFromSessionID == source)
        #expect(fork.cwd == worktree.path)
        #expect(fork.workspaceID == taskSpace)
        #expect(fork.panelID != sourcePanel)
        #expect(fork.prompt.contains("You are in the git worktree \(worktree.path), on branch fix/composer-keeps-a-blank-line-after-send"))
        #expect(fixture.terminalCWD(workspaceID: taskSpace, panelID: fork.panelID) == worktree.path)
        #expect(fixture.store.state.workspacesByID[taskSpace]?.tabIDs.count == 2)

        // Until the fork reports its own conversation, the source stays.
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.sessions.closedPanels.isEmpty)
        fixture.sessions.confirm("launched-2")
        await fixture.waitForMove(task.id)

        let moved = try #require(fixture.record(task.id))
        #expect(moved.startWork?.state == .finished)
        #expect(moved.operation.sourceOutcome == .closed)
        #expect(moved.currentSessionID == "launched-2")
        #expect(fixture.sessions.closedPanels == [sourcePanel])
        #expect(moved.operation.base == TaskOperation.Base(sha: remoteTip, ref: "origin/main", fetched: true))
        #expect(worktree.path == fixture.repository.root.appendingPathComponent("project-composer-keeps-a-blank-line-after-send").path)
        #expect(try TaskGitTestRepository.git(["rev-parse", "--abbrev-ref", "HEAD"], in: worktree.path) == "fix/composer-keeps-a-blank-line-after-send")
        #expect(try TaskGitTestRepository.git(["rev-parse", "HEAD"], in: worktree.path) == remoteTip)
        // The project directory and config key stay.
        #expect(moved.projectRoot == task.projectRoot)
    }

    @Test func unconfirmedForkKeepsTheSourceAndRetryWaitsForTheSameFork() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask(agent: "codex")
        let source = try #require(task.operation.agentLaunch?.sessionID)
        fixture.sessions.endTurn(source)

        _ = try fixture.coordinator.startWork(TaskStartWorkRequest(), caller: fixture.caller(of: task))
        await fixture.waitForMove(task.id)

        let failed = try #require(fixture.record(task.id))
        guard case .failed(let reason)? = failed.startWork?.state else {
            Issue.record("The move must fail without a confirmed fork")
            return
        }
        #expect(reason.hasPrefix("Toastty did not see the forked conversation start"))
        #expect(fixture.sessions.closedPanels.isEmpty)
        #expect(failed.operation.worktreeSession?.sessionID == "launched-2")

        // The fork was only slow: Retry launches nothing new and finishes
        // once its conversation appears.
        try fixture.coordinator.retry(taskID: task.id)
        fixture.sessions.confirm("launched-2")
        await fixture.waitForMove(task.id)

        #expect(fixture.record(task.id)?.startWork?.state == .finished)
        #expect(fixture.launcher.calls.count == 2)
        #expect(fixture.sessions.closedPanels == [try #require(task.operation.taskSpace?.panelID)])
        #expect(try fixture.worktreePaths().count == 2)
    }

    @Test func forkWaitsUntilTheSourcesConversationIsKnown() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask(agent: "codex")
        let source = try #require(task.operation.agentLaunch?.sessionID)
        // A move asked for in the session's first seconds: its turn ends
        // before Toastty has matched it to its Codex conversation.
        fixture.sessions.sessions[source]?.nativeConversationID = nil
        fixture.sessions.endTurn(source)

        _ = try fixture.coordinator.startWork(TaskStartWorkRequest(), caller: fixture.caller(of: task))
        await fixture.waitUntil("the worktree exists") { fixture.record(task.id)?.worktree != nil }
        try await Task.sleep(for: .milliseconds(250))
        #expect(fixture.launcher.calls.count == 1)
        #expect(fixture.record(task.id)?.startWork?.state == .running)

        fixture.sessions.sessions[source]?.nativeConversationID = "conversation-source"
        await fixture.waitUntil("the fork launches") { fixture.launcher.calls.count == 2 }
        #expect(fixture.record(task.id)?.startWork?.source?.conversationID == "conversation-source")
        fixture.sessions.confirm("launched-2")
        await fixture.waitForMove(task.id)
        #expect(fixture.record(task.id)?.startWork?.state == .finished)
    }

    @Test func replacementForkWaitsForTheSourcesTurnAgain() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask()
        let source = try #require(task.operation.agentLaunch?.sessionID)
        fixture.sessions.endTurn(source)
        _ = try fixture.coordinator.startWork(TaskStartWorkRequest(), caller: fixture.caller(of: task))
        await fixture.waitForMove(task.id)
        #expect(fixture.launcher.calls.count == 2)

        // The first fork exited, and the source is working again: a retry
        // must not copy the conversation in the middle of that turn.
        fixture.sessions.stop("launched-2")
        fixture.sessions.sessions[source]?.isInTurn = true
        try fixture.coordinator.retry(taskID: task.id)
        try await Task.sleep(for: .milliseconds(250))
        #expect(fixture.launcher.calls.count == 2)

        fixture.sessions.endTurn(source)
        await fixture.waitUntil("the second fork launches") { fixture.launcher.calls.count == 3 }
        #expect(fixture.launcher.calls[2].forkFromSessionID == source)
        #expect(fixture.launcher.calls[2].panelID == fixture.launcher.calls[1].panelID)
        fixture.sessions.confirm("launched-3")
        await fixture.waitForMove(task.id)
        #expect(fixture.record(task.id)?.startWork?.state == .finished)
    }

    @Test func retryAfterARelaunchFollowsTheSessionsRestoredInTheirPanes() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask()
        let source = try #require(task.operation.agentLaunch?.sessionID)
        let sourcePanel = try #require(task.operation.taskSpace?.panelID)
        fixture.sessions.endTurn(source)
        _ = try fixture.coordinator.startWork(TaskStartWorkRequest(), caller: fixture.caller(of: task))
        await fixture.waitForMove(task.id)
        let forkPanel = try #require(fixture.launcher.calls.last?.panelID)

        // A relaunch restores both conversations under new session IDs, in
        // the same panes; the fork reports its own conversation by then.
        var restoredSource = try #require(fixture.sessions.sessions[source])
        restoredSource.sessionID = "restored-source"
        restoredSource.isInTurn = false
        var restoredFork = try #require(fixture.sessions.sessions["launched-2"])
        restoredFork.sessionID = "restored-fork"
        restoredFork.nativeConversationID = "conversation-fork"
        fixture.sessions.stop(source)
        fixture.sessions.stop("launched-2")
        fixture.sessions.sessions["restored-source"] = restoredSource
        fixture.sessions.sessions["restored-fork"] = restoredFork

        try fixture.coordinator.retry(taskID: task.id)
        await fixture.waitForMove(task.id)

        let moved = try #require(fixture.record(task.id))
        #expect(moved.startWork?.state == .finished)
        #expect(fixture.launcher.calls.count == 2)
        #expect(moved.startWork?.source?.sessionID == "restored-source")
        #expect(moved.operation.worktreeSession?.sessionID == "restored-fork")
        #expect(moved.operation.worktreeSession?.panelID == forkPanel)
        #expect(fixture.sessions.closedPanels == [sourcePanel])
    }

    @Test func failedHookKeepsTheWorktreeAndRetryRunsOnlyTheHookAgain() async throws {
        let fixture = try Fixture()
        fixture.config = TasksConfig(workspaces: [TasksConfig.Workspace(
            path: fixture.repository.project,
            createHook: "test -f ready || { echo 'bootstrap: run setup first' >&2; exit 4; }; touch hook-ran"
        )])
        let task = try await fixture.startedTask()
        let source = try #require(task.operation.agentLaunch?.sessionID)
        fixture.sessions.endTurn(source)

        _ = try fixture.coordinator.startWork(TaskStartWorkRequest(), caller: fixture.caller(of: task))
        await fixture.waitForMove(task.id)

        let failed = try #require(fixture.record(task.id))
        #expect(failed.startWork?.state == .failed(reason: "create_hook exited with status 4.\nbootstrap: run setup first"))
        let worktree = try #require(failed.worktree)
        #expect(fixture.launcher.calls.count == 1)

        FileManager.default.createFile(atPath: "\(worktree.path)/ready", contents: Data())
        try fixture.coordinator.retry(taskID: task.id)
        await fixture.waitUntil("the fork launches") { fixture.launcher.calls.count == 2 }
        fixture.sessions.confirm("launched-2")
        await fixture.waitForMove(task.id)

        let moved = try #require(fixture.record(task.id))
        #expect(moved.startWork?.state == .finished)
        #expect(moved.worktree == worktree)
        #expect(FileManager.default.fileExists(atPath: "\(worktree.path)/hook-ran"))
        #expect(try fixture.worktreePaths().count == 2)
    }

    @Test func sourceThatSomeoneTypedIntoStaysOpen() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask()
        let source = try #require(task.operation.agentLaunch?.sessionID)
        let sourcePanel = try #require(task.operation.taskSpace?.panelID)

        _ = try fixture.coordinator.startWork(TaskStartWorkRequest(), caller: fixture.caller(of: task))
        fixture.sessions.inputAt[sourcePanel] = Date().addingTimeInterval(1)
        fixture.sessions.endTurn(source)
        await fixture.waitUntil("the fork launches") { fixture.launcher.calls.count == 2 }
        fixture.sessions.confirm("launched-2")
        await fixture.waitForMove(task.id)

        let moved = try #require(fixture.record(task.id))
        #expect(moved.startWork?.state == .finished)
        #expect(moved.operation.sourceOutcome == .kept(reason: "Someone typed into this session after the move began."))
        #expect(fixture.sessions.closedPanels.isEmpty)
    }

    @Test func agentThatCannotBeForkedStartsFreshWithTheTaskAndTheSourceStays() async throws {
        let fixture = try Fixture()
        let task = try await fixture.startedTask(agent: "cursor")
        let source = try #require(task.operation.agentLaunch?.sessionID)
        fixture.sessions.endTurn(source)

        _ = try fixture.coordinator.startWork(TaskStartWorkRequest(), caller: fixture.caller(of: task))
        await fixture.waitForMove(task.id)

        let moved = try #require(fixture.record(task.id))
        let fresh = try #require(fixture.launcher.calls.last)
        #expect(fixture.launcher.calls.count == 2)
        #expect(fresh.forkFromSessionID == nil)
        #expect(fresh.profileID == "cursor")
        #expect(fresh.prompt.contains("Composer keeps a blank line after send"))
        #expect(moved.startWork?.state == .finished)
        #expect(moved.operation.worktreeSession?.forked == false)
        guard case .kept(let reason)? = moved.operation.sourceOutcome else {
            Issue.record("The source must stay")
            return
        }
        #expect(reason.hasSuffix("sessions cannot be forked, so the conversation stays in this session."))
        #expect(fixture.sessions.closedPanels.isEmpty)
    }

    @Test func sessionInATopLevelWorkspaceGetsANewTaskAndTaskSpace() async throws {
        let fixture = try Fixture()
        let workspace = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let sourcePanel = try #require(workspace.focusedPanelID)
        fixture.sessions.sessions["shaping"] = TaskSessionInfo(
            sessionID: "shaping",
            agent: .claude,
            panelID: sourcePanel,
            workspaceID: fixture.workspaceID,
            cwd: fixture.repository.project,
            isActive: true,
            isInTurn: false,
            nativeConversationID: "conversation-shaping",
            title: "Split the parser"
        )
        fixture.sessions.closeOutcome = .exited

        let created = try fixture.coordinator.startWork(
            TaskStartWorkRequest(),
            caller: TaskCaller(sessionID: "shaping", workspaceID: fixture.workspaceID)
        )
        #expect(created.title == "Split the parser")
        #expect(created.workspaceID == fixture.workspaceID)
        #expect(created.taskSpaceWorkspaceID == nil)
        await fixture.waitUntil("the fork launches") { fixture.launcher.calls.count == 1 }
        fixture.sessions.confirm("launched-1")
        await fixture.waitForMove(created.id)

        let moved = try #require(fixture.record(created.id))
        let taskSpace = try #require(moved.taskSpaceWorkspaceID)
        let fork = try #require(fixture.launcher.calls.first)
        #expect(fixture.store.state.workspacesByID[taskSpace]?.parentWorkspaceID == fixture.workspaceID)
        #expect(fixture.store.state.workspacesByID[taskSpace]?.taskID == created.id)
        #expect(fork.workspaceID == taskSpace)
        #expect(fork.forkFromSessionID == "shaping")
        #expect(fixture.terminalCWD(workspaceID: taskSpace, panelID: fork.panelID) == moved.worktree?.path)
        #expect(moved.operation.sourceOutcome == .exited)
        #expect(fixture.sessions.closedPanels == [sourcePanel])
    }

    @Test func refusesCallersThatCannotMove() async throws {
        let fixture = try Fixture()
        #expect(throws: TaskError.self) {
            try fixture.coordinator.startWork(TaskStartWorkRequest(), caller: .unmanaged)
        }

        // A session that already works in a linked worktree of the project.
        let linked = fixture.repository.root.appendingPathComponent("project-old").path
        try TaskGitTestRepository.git(["worktree", "add", "--quiet", "-b", "old", linked], in: fixture.repository.project)
        let workspace = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        fixture.sessions.sessions["old"] = TaskSessionInfo(
            sessionID: "old",
            agent: .codex,
            panelID: try #require(workspace.focusedPanelID),
            workspaceID: fixture.workspaceID,
            cwd: "\(linked)/Sources",
            isActive: true,
            isInTurn: false
        )
        do {
            try fixture.coordinator.startWork(TaskStartWorkRequest(), caller: TaskCaller(sessionID: "old", workspaceID: fixture.workspaceID))
            Issue.record("A session in another worktree must not get a second one")
        } catch let error as TaskError {
            #expect(error.message == "This session already works in the git worktree \(linked).")
        }

        // A second request from the same top-level session.
        let top = try #require(fixture.store.state.workspacesByID[fixture.workspaceID]?.focusedPanelID)
        fixture.sessions.sessions["shaping"] = TaskSessionInfo(
            sessionID: "shaping", agent: .claude, panelID: top, workspaceID: fixture.workspaceID,
            cwd: fixture.repository.project, isActive: true, isInTurn: true
        )
        let shaping = TaskCaller(sessionID: "shaping", workspaceID: fixture.workspaceID)
        let first = try fixture.coordinator.startWork(TaskStartWorkRequest(title: "Split the parser"), caller: shaping)
        do {
            try fixture.coordinator.startWork(TaskStartWorkRequest(title: "Split the parser"), caller: shaping)
            Issue.record("A second move from one session must be refused")
        } catch let error as TaskError {
            #expect(error.message == "This session is already moving into a worktree for task \(first.id.uuidString).")
        }
        try fixture.coordinator.delete(taskID: first.id)

        // A base that git would read as an option, then a second request
        // while the first move runs.
        let task = try await fixture.startedTask()
        #expect(throws: TaskError.self) {
            try fixture.coordinator.startWork(TaskStartWorkRequest(base: "--upload-pack=x"), caller: fixture.caller(of: task))
        }
        _ = try fixture.coordinator.startWork(TaskStartWorkRequest(), caller: fixture.caller(of: task))
        do {
            try fixture.coordinator.startWork(TaskStartWorkRequest(), caller: fixture.caller(of: task))
            Issue.record("A second move must be refused")
        } catch let error as TaskError {
            #expect(error.message == "This task is already moving into a worktree.")
        }
        try fixture.coordinator.delete(taskID: task.id)
    }

    @Test func createWithStartWorkStartsTheAgentInItsOwnWorktreeFromItsOwnBase() async throws {
        let fixture = try Fixture()
        let mainTip = try fixture.repository.pushToRemote("upstream")
        let stackTip = try fixture.repository.pushToRemote("stack", branch: "feat/stack")

        // Two creates from the same checkout at once, with different bases,
        // share FETCH_HEAD; each must still start from its own base.
        async let onMain = fixture.coordinator.create(TaskCreateRequest(
            text: "Fix the composer", workspaceID: fixture.workspaceID, agent: "codex", startWork: true
        ))
        async let onStack = fixture.coordinator.create(TaskCreateRequest(
            text: "Stack the parser", workspaceID: fixture.workspaceID, agent: "codex", startWork: true, base: "feat/stack", branchPrefix: "feat"
        ))
        let tasks = try await [onMain, onStack]
        for task in tasks {
            await fixture.waitUntil("setup ends") { fixture.record(task.id)?.setup != .settingUp }
        }

        let first = try #require(fixture.record(tasks[0].id))
        let second = try #require(fixture.record(tasks[1].id))
        #expect(first.setup == .started)
        #expect(second.setup == .started)
        #expect(first.startWork?.state == .finished)
        let firstWorktree = try #require(first.worktree)
        let secondWorktree = try #require(second.worktree)
        #expect(try TaskGitTestRepository.git(["rev-parse", "HEAD"], in: firstWorktree.path) == mainTip)
        #expect(try TaskGitTestRepository.git(["rev-parse", "HEAD"], in: secondWorktree.path) == stackTip)
        #expect(firstWorktree.branch == "task/fix-the-composer")
        #expect(secondWorktree.branch == "feat/stack-the-parser")

        for (task, worktree) in [(first, firstWorktree), (second, secondWorktree)] {
            let launch = try #require(fixture.launcher.calls.first { $0.workspaceID == task.taskSpaceWorkspaceID })
            #expect(launch.cwd == worktree.path)
            #expect(launch.forkFromSessionID == nil)
            #expect(launch.prompt.hasPrefix("You are in the git worktree \(worktree.path), on branch \(worktree.branch)"))
            let taskSpace = try #require(task.operation.taskSpace)
            #expect(fixture.terminalCWD(workspaceID: taskSpace.workspaceID, panelID: taskSpace.panelID) == worktree.path)
        }

        await #expect(throws: TaskError.self) {
            try await fixture.coordinator.create(TaskCreateRequest(text: "x", workspaceID: fixture.workspaceID, agent: "codex", base: "main"))
        }
    }

    @Test func relaunchFailsAnUnfinishedMoveUnlessTheForkWasConfirmed() async throws {
        let fixture = try Fixture()
        let records = TaskRecordStore(fileURL: fixture.recordsFile)
        var unconfirmed = TaskRecord(
            createdAt: Date(), text: "a", title: "a", slug: "a", source: .cli, setup: .started,
            startWork: TaskStartWork(branchPrefix: "task", requestedAt: Date())
        )
        unconfirmed.operation.worktreeSession = .init(workspaceID: UUID(), panelID: UUID(), sessionID: "s", forked: true)
        var confirmed = TaskRecord(
            createdAt: Date(), text: "b", title: "b", slug: "b", source: .cli, setup: .started,
            startWork: TaskStartWork(branchPrefix: "task", requestedAt: Date())
        )
        confirmed.operation.worktreeSession = .init(workspaceID: UUID(), panelID: UUID(), sessionID: "t", forked: true, nativeConversationID: "c")
        try records.insert(unconfirmed)
        try records.insert(confirmed)

        let relaunched = fixture.makeCoordinator(records: TaskRecordStore(fileURL: fixture.recordsFile))
        relaunched.reconcileAfterLaunch()

        #expect(relaunched.records.record(id: unconfirmed.id)?.startWork?.state ==
            .failed(reason: "Toastty quit before the move into the worktree finished. Retry to continue."))
        #expect(relaunched.records.record(id: confirmed.id)?.startWork?.state == .finished)
        #expect(relaunched.records.record(id: confirmed.id)?.operation.sourceOutcome ==
            .kept(reason: "Toastty quit before it closed this session."))
    }
}
