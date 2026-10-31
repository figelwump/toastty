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
            var scopedWorkspaceIDs: Set<UUID>? = nil
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
            scopedWorkspaceIDs: Set<UUID>?,
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
                forkFromSessionID: forkFromSessionID,
                scopedWorkspaceIDs: scopedWorkspaceIDs
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

        /// Text typed into each panel, in order.
        private(set) var delivered: [(panelID: UUID, text: String)] = []
        var replies: [String: TaskAgentReply] = [:]
        var scopes: [String: Set<UUID>] = [:]

        func activeSessions(workspaceID: UUID) -> [TaskSessionInfo] {
            sessions.values.filter { $0.workspaceID == workspaceID && $0.isActive }
        }

        /// What the next deliveries report; a typed text counts as delivered
        /// for `.delivered` and `.uncertain`.
        var deliveryResult: TerminalInputDeliveryResult = .delivered

        func deliver(_ text: String, panelID: UUID) -> TerminalInputDeliveryResult {
            guard activeSession(panelID: panelID) != nil, deliveryResult != .unavailable else { return .unavailable }
            delivered.append((panelID, text))
            return deliveryResult
        }

        func lastReply(sessionID: String) -> TaskAgentReply? { replies[sessionID] }

        func scope(sessionID: String) -> Set<UUID>? { scopes[sessionID] }

        /// Reports a status, as the agent's hooks do.
        /// A turn that was running ends at `.idle`, `.ready` or `.error`.
        func report(_ sessionID: String, _ kind: SessionStatusKind, at date: Date = Date()) {
            let wasInTurn = sessions[sessionID]?.isInTurn == true
            sessions[sessionID]?.status = SessionStatus(kind: kind, summary: kind.rawValue)
            sessions[sessionID]?.statusUpdatedAt = date
            sessions[sessionID]?.isInTurn = [.working, .needsApproval].contains(kind)
            if wasInTurn, [.idle, .ready, .error].contains(kind) {
                sessions[sessionID]?.lastTurnEndedAt = date
            }
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
        let triage = FakeTriageRunner()
        let recentWorkspaces = RecentWorkspacesStore.inMemory()
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
                ),
                triageRunner: triage,
                recentWorkspaces: recentWorkspaces
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
        fixture.config.defaults.startSkill = "task-start"
        let task = try await fixture.startedTask()
        #expect(fixture.launcher.calls.first?.prompt
            == "Use the task-start skill.\n\nComposer keeps a blank line after send\n\n\(TaskPrompt.replyLine)")
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
        // The fork has the first message already.
        #expect(fork.prompt.contains("Use the task-start skill.") == false)
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
        fixture.config.workspaces = [TasksConfig.Workspace(path: fixture.repository.project, startSkill: "repo-start")]
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
        #expect(fresh.prompt.hasPrefix("Use the repo-start skill.\n\nYou are in the git worktree"))
        #expect(fresh.prompt.hasSuffix("Composer keeps a blank line after send\n\n\(TaskPrompt.replyLine)"))
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

    // MARK: - Forked tasks

    @Test func forkedTasksWaitForTheCallersTurnAndForkItsConversationIntoTheirTaskSpaces() async throws {
        let fixture = try Fixture()
        fixture.config.defaults.startSkill = "task-start"
        let remoteTip = try fixture.repository.pushToRemote("upstream")
        let coordinatorTask = try await fixture.coordinator.create(TaskCreateRequest(
            text: "Plan the parser work", workspaceID: fixture.workspaceID, agent: "claude", model: "opus", effort: "xhigh"
        ))
        await fixture.waitUntil("setup ends") { fixture.record(coordinatorTask.id)?.setup == .started }
        let parent = try #require(fixture.record(coordinatorTask.id))
        let source = try #require(parent.operation.agentLaunch?.sessionID)
        let sourcePanel = try #require(parent.operation.taskSpace?.panelID)
        let caller = try fixture.caller(of: parent)

        // Two forks asked for in one turn: one in its own worktree, one in
        // the project directory with its own model.
        let inWorktree = try await fixture.coordinator.create(
            TaskCreateRequest(text: "Split the parser", prompt: "Brief for the parser.", startWork: true, branchPrefix: "feat", fork: true),
            caller: caller
        )
        let inProject = try await fixture.coordinator.create(
            TaskCreateRequest(text: "Split the lexer", agent: "claude", model: "sonnet", fork: true),
            caller: caller
        )
        #expect(inWorktree.setup == .settingUp)
        #expect(inWorktree.parentTaskID == parent.id)
        #expect(inWorktree.forkSource == TaskStartWork.Source(
            sessionID: source, panelID: sourcePanel, agent: "claude", conversationID: "conversation-\(source)"
        ))
        // The fork keeps the caller's task's model and effort unless the
        // request sets them.
        #expect(inWorktree.resolved?.agent == "claude")
        #expect(inWorktree.resolved?.model == "opus")
        #expect(inWorktree.resolved?.effort == "xhigh")
        #expect(inProject.resolved?.model == "sonnet")
        #expect(inProject.resolved?.effort == "xhigh")

        // Both wait for the caller's turn to end before they copy it.
        await fixture.waitUntil("both task spaces exist") {
            fixture.record(inWorktree.id)?.taskSpaceWorkspaceID != nil && fixture.record(inProject.id)?.taskSpaceWorkspaceID != nil
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.launcher.calls.count == 1)
        fixture.sessions.endTurn(source)
        await fixture.waitUntil("both forks launch") { fixture.launcher.calls.count == 3 }

        let worktreeTask = try #require(fixture.record(inWorktree.id))
        let projectTask = try #require(fixture.record(inProject.id))
        let worktree = try #require(worktreeTask.worktree)
        let worktreeSpace = try #require(worktreeTask.operation.taskSpace)
        let projectSpace = try #require(projectTask.operation.taskSpace)
        let worktreeFork = try #require(fixture.launcher.calls.first { $0.workspaceID == worktreeSpace.workspaceID })
        let projectFork = try #require(fixture.launcher.calls.first { $0.workspaceID == projectSpace.workspaceID })
        for fork in [worktreeFork, projectFork] {
            #expect(fork.profileID == "claude")
            #expect(fork.forkFromSessionID == source)
            #expect(fork.panelID != sourcePanel)
        }
        #expect(worktreeFork.panelID == worktreeSpace.panelID)
        #expect(worktreeFork.cwd == worktree.path)
        #expect(worktreeFork.model == "opus")
        #expect(projectFork.cwd == fixture.repository.project)
        #expect(projectFork.model == "sonnet")
        #expect(worktreeFork.prompt == """
            Use the task-start skill.

            You are now the agent of the task "Split the parser" (task ID \(inWorktree.id.uuidString)), in its task space \
            split-the-parser (workspace \(worktreeSpace.workspaceID.uuidString)). Toastty started you as a fork of the \
            conversation above. The session that had that conversation keeps running and keeps its other work.

            You are in the git worktree \(worktree.path), on branch feat/split-the-parser, which starts at origin/main \
            (\(remoteTip.prefix(12))).

            You own only this task. The conversation above can plan other tasks and other work: do not do them, and do \
            not act for the session that created this task. Report progress, questions and results to the task that \
            created this one with `toastty task send \(parent.id.uuidString) "<message>"`.

            Brief for the parser.

            The task, as written:

            Split the parser

            \(TaskPrompt.replyLine)
            """)
        #expect(projectFork.prompt.contains("You are in the git worktree") == false)
        #expect(projectFork.prompt.hasSuffix(
            "`toastty task send \(parent.id.uuidString) \"<message>\"`.\n\nSplit the lexer\n\n\(TaskPrompt.replyLine)"
        ))

        // Setup ends only once each fork reports its own conversation.
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.record(inWorktree.id)?.setup == .settingUp)
        #expect(AppControlExecutor.taskSnapshot(worktreeTask)["fork"] == .object([
            "sourceSessionID": .string(source),
            "sourceConversationID": .string("conversation-\(source)"),
            "conversationConfirmed": .bool(false),
        ]))
        for task in [worktreeTask, projectTask] {
            fixture.sessions.confirm(try #require(task.operation.agentLaunch?.sessionID))
        }
        await fixture.waitUntil("both tasks start") {
            fixture.record(inWorktree.id)?.setup == .started && fixture.record(inProject.id)?.setup == .started
        }
        let started = try #require(fixture.record(inWorktree.id))
        #expect(started.startWork?.state == .finished)
        let launched = try #require(started.operation.agentLaunch)
        #expect(launched.forkConversationID == "conversation-\(launched.sessionID)")
        #expect(started.currentSessionID == launched.sessionID)

        // The caller keeps running, untouched.
        #expect(fixture.sessions.sessions[source]?.isActive == true)
        #expect(fixture.sessions.closedPanels.isEmpty)
        #expect(fixture.sessions.delivered.isEmpty)
        #expect(fixture.launcher.calls.count == 3)
    }

    @Test func aForkFromATopLevelSessionReportsToThatSessionAndSkipsDefaults() async throws {
        let fixture = try Fixture()
        fixture.config.defaults = TasksConfig.Defaults(agent: "codex", model: "default-model", effort: "low")
        let workspace = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let sourcePanel = try #require(workspace.focusedPanelID)
        fixture.sessions.sessions["shaping"] = TaskSessionInfo(
            sessionID: "shaping", agent: .codex, panelID: sourcePanel, workspaceID: fixture.workspaceID,
            cwd: fixture.repository.project, isActive: true, isInTurn: false, nativeConversationID: "conversation-shaping"
        )

        let created = try await fixture.coordinator.create(
            TaskCreateRequest(text: "Fix the composer", fork: true),
            caller: TaskCaller(sessionID: "shaping", workspaceID: fixture.workspaceID)
        )
        #expect(created.parentTaskID == nil)
        #expect(created.workspaceID == fixture.workspaceID)
        #expect(created.resolved == TaskFields(workspaceID: fixture.workspaceID, agent: "codex"))

        // The caller is idle, so the fork launches at once.
        await fixture.waitUntil("the fork launches") { fixture.launcher.calls.count == 1 }
        let fork = try #require(fixture.launcher.calls.first)
        #expect(fork.forkFromSessionID == "shaping")
        #expect(fork.cwd == fixture.repository.project)
        #expect(fork.model == nil)
        #expect(fork.prompt.contains(
            "`toastty action run terminal.send-text --panel \(sourcePanel.uuidString) expectedSessionID=shaping submit=true text=\"<message>\"`. "
                + "If that session's ID changed, find the panel's current session with "
                + "`toastty query run workspace.snapshot --workspace \(fixture.workspaceID.uuidString)`."
        ))
        fixture.sessions.confirm("launched-1")
        await fixture.waitUntil("the task starts") { fixture.record(created.id)?.setup == .started }
        #expect(fixture.sessions.closedPanels.isEmpty)
    }

    @Test func forkRefusesCallersAndAgentsItCannotUse() async throws {
        let fixture = try Fixture()
        func refusal(_ request: TaskCreateRequest, caller: TaskCaller) async -> String? {
            do {
                _ = try await fixture.coordinator.create(request, caller: caller)
                return nil
            } catch {
                return (error as? TaskError)?.message
            }
        }
        let fork = TaskCreateRequest(text: "Split it", workspaceID: fixture.workspaceID, fork: true)
        #expect(await refusal(fork, caller: .unmanaged)
            == "--fork copies the conversation of the agent session that runs it, so it runs only from a Toastty-managed Claude Code or Codex session.")

        let cursorTask = try await fixture.startedTask(agent: "cursor")
        let cursorRefusal = await refusal(fork, caller: try fixture.caller(of: cursorTask))
        #expect(cursorRefusal?.hasSuffix("sessions cannot be forked. --fork runs only from Claude Code and Codex sessions.") == true)

        let claudeTask = try await fixture.startedTask()
        var otherAgent = fork
        otherAgent.agent = "codex"
        #expect(await refusal(otherAgent, caller: try fixture.caller(of: claudeTask))
            == "A fork uses the calling session's agent, claude. Leave out --agent, or name claude.")
        #expect(fixture.coordinator.records.records.count == 2)
    }

    @Test func anUnconfirmedForkFailsSetupAndRetryContinuesFromTheLaunchedFork() async throws {
        let fixture = try Fixture()
        let parent = try await fixture.startedTask(agent: "codex")
        let source = try #require(parent.operation.agentLaunch?.sessionID)
        fixture.sessions.endTurn(source)
        let caller = try fixture.caller(of: parent)
        func waitForSetup(_ id: UUID) async {
            await fixture.waitUntil("setup ends") { fixture.record(id)?.setup != .settingUp }
        }

        // A fork that never reports its conversation fails setup, and the
        // caller stays as it was.
        let slow = try await fixture.coordinator.create(TaskCreateRequest(text: "Slow fork", fork: true), caller: caller)
        await waitForSetup(slow.id)
        guard case .setupFailed(let reason)? = fixture.record(slow.id)?.setup else {
            Issue.record("Setup must fail without a confirmed fork")
            return
        }
        #expect(reason.hasPrefix("Toastty did not see the forked conversation start within"))
        #expect(reason.hasSuffix("The session that created the task is unchanged; check the task space's terminal, then retry."))
        #expect(fixture.record(slow.id)?.operation.agentLaunch?.sessionID == "launched-2")
        #expect(fixture.sessions.closedPanels.isEmpty)

        // It was only slow: Retry launches nothing new and finishes once its
        // conversation appears.
        try fixture.coordinator.retry(taskID: slow.id)
        fixture.sessions.confirm("launched-2")
        await waitForSetup(slow.id)
        #expect(fixture.record(slow.id)?.setup == .started)
        #expect(fixture.launcher.calls.count == 2)

        // A fork that exited is launched again in the same task space.
        let exited = try await fixture.coordinator.create(TaskCreateRequest(text: "Exited fork", fork: true), caller: caller)
        await fixture.waitUntil("the fork launches") { fixture.launcher.calls.count == 3 }
        fixture.sessions.stop("launched-3")
        await waitForSetup(exited.id)
        #expect(fixture.record(exited.id)?.setup == .setupFailed(
            reason: "The forked agent exited before its conversation started. The session that created the task is unchanged; retry to try again."
        ))
        let taskSpace = try #require(fixture.record(exited.id)?.operation.taskSpace)
        try fixture.coordinator.retry(taskID: exited.id)
        await fixture.waitUntil("the fork launches again") { fixture.launcher.calls.count == 4 }
        let relaunch = try #require(fixture.launcher.calls.last)
        #expect(relaunch.forkFromSessionID == source)
        #expect(relaunch.workspaceID == taskSpace.workspaceID)
        #expect(relaunch.panelID == taskSpace.panelID)
        fixture.sessions.confirm("launched-4")
        await waitForSetup(exited.id)
        #expect(fixture.record(exited.id)?.setup == .started)
        #expect(fixture.record(exited.id)?.operation.taskSpace == taskSpace)

        // After a relaunch, a fork can run restored under a new ID before
        // Toastty saved its launch: Retry waits for it instead of launching
        // a second fork into its terminal.
        let restored = try await fixture.coordinator.create(TaskCreateRequest(text: "Restored fork", fork: true), caller: caller)
        await fixture.waitUntil("the fork launches") { fixture.launcher.calls.count == 5 }
        await waitForSetup(restored.id)
        let restoredSpace = try #require(fixture.record(restored.id)?.operation.taskSpace)
        var restoredSession = try #require(fixture.sessions.sessions["launched-5"])
        restoredSession.sessionID = "restored-fork"
        fixture.sessions.stop("launched-5")
        fixture.sessions.sessions["restored-fork"] = restoredSession
        try fixture.coordinator.records.save(id: restored.id) { $0.operation.agentLaunch = nil }
        try fixture.coordinator.retry(taskID: restored.id)
        fixture.sessions.confirm("restored-fork")
        await waitForSetup(restored.id)
        #expect(fixture.record(restored.id)?.setup == .started)
        #expect(fixture.record(restored.id)?.operation.agentLaunch?.sessionID == "restored-fork")
        #expect(fixture.record(restored.id)?.operation.taskSpace == restoredSpace)
        #expect(fixture.launcher.calls.count == 5)
        #expect(fixture.sessions.closedPanels.isEmpty)
    }

    // MARK: - With triage

    @Test func aTaskWhoseWorktreeWasMadeCannotMoveToAnotherProject() async throws {
        let fixture = try Fixture()
        try fixture.repository.pushToRemote("upstream")
        fixture.config = TasksConfig(
            triage: .init(command: "fake-triage"),
            workspaces: [TasksConfig.Workspace(
                path: fixture.repository.project,
                createHook: "test -f ready || { echo 'bootstrap: run setup first' >&2; exit 4; }"
            )]
        )
        // Another project, open in its own workspace.
        let other = try TaskGitTestRepository()
        let windowID = try #require(fixture.store.state.windows.first?.id)
        _ = fixture.store.send(.createWorkspace(windowID: windowID, title: "other", activate: false))
        let otherWorkspace = try #require(fixture.store.state.workspacesByID.values.first { $0.title == "other" })
        _ = fixture.store.send(.setWorkspaceRootDirectory(workspaceID: otherWorkspace.id, rootDirectory: other.project))

        fixture.triage.answer(.success(TaskTriage.Answer(agent: "codex", firstPrompt: "Start with the composer.")))
        let created = try await fixture.coordinator.create(TaskCreateRequest(
            text: "Fix the composer", workspaceID: fixture.workspaceID, startWork: true
        ))
        #expect(created.setup == .routing)
        await fixture.waitUntil("setup fails on the hook") {
            if case .setupFailed? = fixture.record(created.id)?.setup { return true }
            return false
        }
        let failed = try #require(fixture.record(created.id))
        let worktree = try #require(failed.worktree)
        #expect(failed.operation.base != nil)
        // The worktree comes before the task space, so only the new check
        // stands between this task and another project.
        #expect(failed.operation.taskSpace == nil)

        // Another project cannot take over the first one's worktree.
        do {
            try fixture.coordinator.setWorkspace(taskID: created.id, choice: .open(otherWorkspace.id))
            Issue.record("the task moved to another project")
        } catch {
            #expect(error.localizedDescription.contains("already has a worktree in \(fixture.repository.project)"))
        }
        #expect(fixture.record(created.id)?.workspaceID == fixture.workspaceID)
        let recent = RecentWorkspace(id: UUID(), title: "other-closed", rootDirectory: other.project, closedAt: Date())
        fixture.recentWorkspaces.record(recent)
        #expect(throws: TaskError.self) {
            try fixture.coordinator.setWorkspace(taskID: created.id, choice: .recent(recent.id))
        }

        // The same project is fine: setup continues in the same worktree.
        FileManager.default.createFile(atPath: "\(worktree.path)/ready", contents: Data())
        fixture.triage.answer(.success(TaskTriage.Answer(agent: "codex")))
        try fixture.coordinator.setWorkspace(taskID: created.id, choice: .open(fixture.workspaceID))
        await fixture.waitUntil("the task starts") { fixture.record(created.id)?.setup == .started }
        let started = try #require(fixture.record(created.id))
        #expect(started.worktree == worktree)
        #expect(fixture.launcher.calls.last?.cwd == worktree.path)
    }

    @Test func triagesPromptIsLeftOutWhenTheWorktreeLineMakesTheMessageTooLong() async throws {
        let fixture = try Fixture()
        try fixture.repository.pushToRemote("upstream")
        fixture.config = TasksConfig(triage: .init(command: "fake-triage"))
        // Longer than the worktree line, so leaving it out makes room.
        let triagePrompt = String(repeating: "Start with the composer views. ", count: 33)
        // Just under the limit with triage's prompt, so routing accepts it;
        // the worktree line added at launch pushes it over.
        let limit = AgentLaunchService.maximumInitialPromptUTF8Count
        let wrapper = "\n\nThe task, as written:\n\n"
        let text = String(repeating: "x", count: limit - 10 - triagePrompt.utf8.count - wrapper.utf8.count)
        fixture.triage.answer(.success(TaskTriage.Answer(agent: "codex", firstPrompt: triagePrompt)))

        let created = try await fixture.coordinator.create(TaskCreateRequest(
            text: text, workspaceID: fixture.workspaceID, startWork: true
        ))
        await fixture.waitUntil("setup ends") {
            let setup = fixture.record(created.id)?.setup
            return setup != .routing && setup != .settingUp
        }
        let record = try #require(fixture.record(created.id))
        #expect(record.setup == .started)
        #expect(record.resolved?.prompt == nil)
        #expect(record.triageNote == "Toastty left out triage's first prompt, which made the agent's first message longer than 64 KB.")
        let launch = try #require(fixture.launcher.calls.last)
        let worktree = try #require(record.worktree)
        #expect(launch.prompt.hasPrefix("You are in the git worktree \(worktree.path)"))
        #expect(launch.prompt.contains("Start with the composer views.") == false)
        #expect(launch.prompt.utf8.count <= limit)
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
        // A forked task's setup counts as started only once its fork
        // reported a conversation of its own.
        let forkSource = TaskStartWork.Source(sessionID: "creator", panelID: UUID(), agent: "claude")
        var unconfirmedFork = TaskRecord(createdAt: Date(), text: "c", title: "c", slug: "c", source: .agent(sessionID: "creator"))
        unconfirmedFork.forkSource = forkSource
        unconfirmedFork.operation.agentLaunch = .init(sessionID: "u", at: Date())
        var confirmedFork = TaskRecord(createdAt: Date(), text: "d", title: "d", slug: "d", source: .agent(sessionID: "creator"))
        confirmedFork.forkSource = forkSource
        confirmedFork.operation.agentLaunch = .init(sessionID: "v", at: Date(), forkConversationID: "fork")
        try records.insert(unconfirmedFork)
        try records.insert(confirmedFork)

        let relaunched = fixture.makeCoordinator(records: TaskRecordStore(fileURL: fixture.recordsFile))
        relaunched.reconcileAfterLaunch()

        #expect(relaunched.records.record(id: unconfirmedFork.id)?.setup ==
            .setupFailed(reason: "Toastty quit before setup finished. Retry to continue."))
        #expect(relaunched.records.record(id: confirmedFork.id)?.setup == .started)

        #expect(relaunched.records.record(id: unconfirmed.id)?.startWork?.state ==
            .failed(reason: "Toastty quit before the move into the worktree finished. Retry to continue."))
        #expect(relaunched.records.record(id: confirmed.id)?.startWork?.state == .finished)
        #expect(relaunched.records.record(id: confirmed.id)?.operation.sourceOutcome ==
            .kept(reason: "Toastty quit before it closed this session."))
    }
}
