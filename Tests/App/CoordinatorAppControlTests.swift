import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// `coordinator.*` through the app-control executor, as the socket and the
/// CLI reach it, and the checks that the coordinator is not a task.
@MainActor
struct CoordinatorAppControlTests {
    typealias Fixture = CoordinatorControllerTests.Fixture

    private func executor(_ fixture: Fixture) -> AppControlExecutor {
        TaskAppControlTests().makeExecutor(fixture.tasks, coordinator: fixture.tasks.coordinator)
    }

    private func context(_ callerSessionID: String? = nil) -> AutomationRequestContext {
        AutomationRequestContext(callerSessionID: callerSessionID, commandName: "app_control.run_action")
    }

    private func string(_ result: [String: AutomationJSONValue]?, _ key: String) -> String? {
        guard case .string(let value)? = result?[key] else { return nil }
        return value
    }

    private func expectInvalidPayload(
        containing mention: String,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            Issue.record("expected invalidPayload containing \(mention)", sourceLocation: sourceLocation)
        } catch AutomationSocketError.invalidPayload(let actual) {
            #expect(actual.contains(mention), "\(actual)", sourceLocation: sourceLocation)
        } catch {
            Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
        }
    }

    private func attachBoard(_ fixture: Fixture) -> TaskBoardStore {
        let board = TaskBoardStore(
            coordinator: fixture.tasks.coordinator,
            store: fixture.store,
            sessionRuntimeStore: fixture.sessions,
            pullRequests: PullRequestStateCache(runner: TaskAppControlTests.OfflineGitHub()),
            refreshInterval: nil,
            releaseCheckInterval: nil
        )
        fixture.tasks.coordinator.board = board
        fixture.sessions.taskCoordinator = fixture.tasks.coordinator
        return board
    }

    // MARK: - Actions

    @Test func openGetSendAndRestartThroughAppControl() async throws {
        let fixture = try Fixture()
        let executor = executor(fixture)
        let actionIDs = Set(executor.listActionDescriptors().map(\.id))
        #expect(actionIDs.isSuperset(of: ["coordinator.open", "coordinator.restart", "coordinator.send"]))
        #expect(executor.listQueryDescriptors().map(\.id).contains("coordinator.get"))
        #expect(try executor.runQuery(id: "coordinator.get", args: [:]) == ["exists": .bool(false), "queuedCount": .int(0)])

        // Open creates the coordinator and starts its agent, here without
        // taking the selection.
        let opened = try await executor.runActionAsync(id: "coordinator.open", args: ["select": .bool(false)], context: context())
        #expect(opened.didMutateState)
        let location = try #require(fixture.store.state.coordinator)
        let firstSessionID = try fixture.session().sessionID
        #expect(opened.result?["exists"] == .bool(true))
        #expect(opened.result?["createdWorkspace"] == .bool(true))
        #expect(opened.result?["startedAgent"] == .bool(true))
        #expect(string(opened.result, "workspaceID") == location.workspaceID.uuidString)
        #expect(string(opened.result, "windowID") == location.windowID.uuidString)
        #expect(string(opened.result, "panelID") == location.panelID?.uuidString)
        #expect(string(opened.result, "agentState") == "running")
        #expect(string(opened.result, "sessionID") == firstSessionID)
        #expect(string(opened.result, "agent") == "claude")
        #expect(fixture.store.selectedWorkspaceID(in: location.windowID) == fixture.tasks.workspaceID)

        // A second open selects it and starts nothing.
        let again = try await executor.runActionAsync(id: "coordinator.open", args: [:], context: context())
        #expect(again.result?["createdWorkspace"] == .bool(false))
        #expect(again.result?["startedAgent"] == .bool(false))
        #expect(string(again.result, "sessionID") == firstSessionID)
        #expect(fixture.store.selectedWorkspaceID(in: location.windowID) == location.workspaceID)
        #expect(fixture.store.state.workspacesByID.values.filter(\.isCoordinator).count == 1)

        // Send: typed at the open prompt, queued while the agent works.
        try fixture.reportAgentStarted()
        let sent = try executor.runAction(id: "coordinator.send", args: ["text": .string("One task needs you.")], context: context())
        #expect(sent.didMutateState == false)
        #expect(sent.result == ["delivery": .string("sent"), "queuedCount": .int(0)])
        #expect(fixture.typedTexts == ["One task needs you."])
        try fixture.setStatus(.working)
        let queued = try executor.runAction(id: "coordinator.send", args: ["text": .string("Another.")], context: context())
        #expect(queued.result == [
            "delivery": .string("queued"), "position": .int(1), "hold": .string("busy"), "queuedCount": .int(1),
        ])
        let status = try executor.runQuery(id: "coordinator.get", args: [:])
        #expect(status["queuedCount"] == .int(1))
        #expect(status["hold"] == .string("busy"))
        #expect(status["status"] == .string("working"))

        // Restart: a fresh session in the same workspace; the queue stays.
        let restarted = try await executor.runActionAsync(id: "coordinator.restart", args: [:], context: context())
        #expect(string(restarted.result, "workspaceID") == location.workspaceID.uuidString)
        #expect(string(restarted.result, "sessionID") != firstSessionID)
        #expect(restarted.result?["startedAgent"] == .bool(true))
        #expect(restarted.result?["queuedCount"] == .int(1))

        await expectInvalidPayload(containing: "text is required") {
            _ = try executor.runAction(id: "coordinator.send", args: [:], context: context())
        }
        await expectInvalidPayload(containing: "empty") {
            _ = try executor.runAction(id: "coordinator.send", args: ["text": .string("  ")], context: context())
        }
        // Open and restart wait for the agent, so they have no synchronous form.
        await expectInvalidPayload(containing: "app_control.run_action") {
            _ = try executor.runAction(id: "coordinator.open", args: [:], context: context())
        }
    }

    @Test func aFailedStartComesBackAsAnErrorAndGetReportsIt() async throws {
        let fixture = try Fixture()
        let executor = executor(fixture)
        fixture.tasks.config.coordinator = TasksConfig.Coordinator(agent: "nobody")
        await expectInvalidPayload(containing: "nobody") {
            _ = try await executor.runActionAsync(id: "coordinator.open", args: [:], context: context())
        }
        let status = try executor.runQuery(id: "coordinator.get", args: [:])
        #expect(status["exists"] == .bool(true))
        #expect(status["agentState"] == .string("notRunning"))
        #expect(string(status, "startFailure")?.contains("nobody") == true)
        await expectInvalidPayload(containing: "windowID does not exist") {
            _ = try await executor.runActionAsync(
                id: "coordinator.restart", args: ["windowID": .string(UUID().uuidString)], context: context()
            )
        }
    }

    @Test func withoutACoordinatorControllerTheCommandsAreHiddenAndRefused() async throws {
        let tasks = try TaskCoordinatorTests.Fixture()
        let executor = TaskAppControlTests().makeExecutor(tasks, coordinator: tasks.coordinator)
        #expect(executor.listActionDescriptors().contains { $0.id.hasPrefix("coordinator.") } == false)
        #expect(executor.listQueryDescriptors().contains { $0.id.hasPrefix("coordinator.") } == false)
        for action in ["coordinator.open", "coordinator.restart", "coordinator.send"] {
            await expectInvalidPayload(containing: "not available") {
                _ = try await executor.runActionAsync(id: action, args: ["text": .string("x")], context: context())
            }
        }
        await expectInvalidPayload(containing: "not available") {
            _ = try executor.runQuery(id: "coordinator.get", args: [:])
        }
    }

    @Test func aWorkspaceScopedSessionCannotCreateOrReachTheCoordinator() async throws {
        let fixture = try Fixture()
        let executor = executor(fixture)
        // A task agent that the user scoped to its own task space.
        let task = try await fixture.tasks.coordinator.create(
            TaskCreateRequest(text: "scoped", workspaceID: fixture.tasks.workspaceID, agent: "codex")
        )
        await fixture.tasks.waitForSetup(task.id)
        let scoped = try #require(fixture.tasks.record(task.id)?.operation.agentLaunch?.sessionID)
        #expect(fixture.sessions.setScope(sessionID: scoped, workspaceIDs: []))

        await expectInvalidPayload(containing: "cannot create the coordinator") {
            _ = try await executor.runActionAsync(id: "coordinator.open", args: [:], context: context(scoped))
        }
        #expect(fixture.store.state.coordinator == nil)

        try await fixture.openAtPrompt()
        let coordinatorID = try #require(fixture.store.state.coordinatorWorkspaceID)
        for run in [
            { _ = try executor.runAction(id: "coordinator.send", args: ["text": .string("Merge everything.")], context: context(scoped)) },
            { _ = try executor.runQuery(
                id: "coordinator.get", args: [:],
                context: AutomationRequestContext(callerSessionID: scoped, commandName: "app_control.run_query")
            ) },
        ] as [() throws -> Void] {
            do {
                try run()
                Issue.record("expected scopeDenied")
            } catch AutomationSocketError.scopeDenied(let workspaceID) {
                #expect(workspaceID == coordinatorID)
            }
        }
        do {
            _ = try await executor.runActionAsync(id: "coordinator.restart", args: [:], context: context(scoped))
            Issue.record("expected scopeDenied")
        } catch AutomationSocketError.scopeDenied(let workspaceID) {
            #expect(workspaceID == coordinatorID)
        }
        #expect(fixture.typedTexts.isEmpty)
    }

    // MARK: - Not a task

    @Test func theCoordinatorIsInNoTaskListBoardOrWebhookEvent() async throws {
        let fixture = try Fixture()
        let executor = executor(fixture)
        let board = attachBoard(fixture)
        try await fixture.openAtPrompt()
        try fixture.setStatus(.working)
        let coordinatorID = try #require(fixture.store.state.coordinatorWorkspaceID)

        // Its busy agent session makes no task anywhere.
        #expect(try executor.runQuery(id: "task.list", args: [:])["tasks"] == .array([]))
        #expect(fixture.tasks.coordinator.records.records.isEmpty)
        #expect(board.items().isEmpty)
        #expect(TaskBoard.items(board.items(), in: try #require(fixture.store.state.selectedWindowID), state: fixture.store.state).isEmpty)
        #expect(TaskWebhookService.taskStates(board.items()).isEmpty)

        // It is not a place for a task.
        let choices = fixture.tasks.coordinator.workspaceChoices()
        #expect(choices.open.map(\.id) == [fixture.tasks.workspaceID])
        #expect(QuickEntryController.taskWorkspaces(in: fixture.store.state).map(\.id) == [fixture.tasks.workspaceID])
        await expectInvalidPayload(containing: "not a project") {
            _ = try await executor.runActionAsync(
                id: "task.create",
                args: ["text": .string("x"), "agent": .string("codex"), "workspace": .string(coordinatorID.uuidString)],
                context: context()
            )
        }
        await expectInvalidPayload(containing: "Only a task space can become a task") {
            _ = try executor.runAction(id: "task.adopt", args: ["workspaceID": .string(coordinatorID.uuidString)], context: context())
        }

        // Closing it is not a closed project to reopen for a task.
        #expect(fixture.store.send(.closeWorkspace(workspaceID: coordinatorID)))
        #expect(fixture.tasks.recentWorkspaces.items.isEmpty)
    }

    @Test func tasksTheCoordinatorCreatesHaveNoParentTaskAndNeverLandInItsWorkspace() async throws {
        let fixture = try Fixture()
        let executor = executor(fixture)
        try await fixture.openAtPrompt()
        let coordinatorID = try #require(fixture.store.state.coordinatorWorkspaceID)
        let coordinatorSession = try fixture.session().sessionID
        let windowID = try #require(fixture.store.state.selectedWindowID)

        // With a project named: a task space under that project.
        let placed = try await executor.runActionAsync(
            id: "task.create",
            args: ["text": .string("Fix the unread dot"), "agent": .string("codex"), "workspace": .string(fixture.tasks.workspaceID.uuidString)],
            context: context(coordinatorSession)
        )
        let placedID = try #require(string(placed.result, "taskID").flatMap(UUID.init(uuidString:)))
        await fixture.tasks.waitForSetup(placedID)
        let placedRecord = try #require(fixture.tasks.record(placedID))
        #expect(placedRecord.parentTaskID == nil)
        #expect(placedRecord.workspaceID == fixture.tasks.workspaceID)
        #expect(placedRecord.setup == .started)
        let taskSpaceID = try #require(placedRecord.operation.taskSpace?.workspaceID)
        #expect(fixture.store.state.workspacesByID[taskSpaceID]?.parentWorkspaceID == fixture.tasks.workspaceID)

        // With no project named: the task waits for one. The caller's own
        // workspace, the coordinator's, is not used.
        let unplaced = try await executor.runActionAsync(
            id: "task.create",
            args: ["text": .string("Tidy the changelog"), "agent": .string("codex")],
            context: context(coordinatorSession)
        )
        let unplacedID = try #require(string(unplaced.result, "taskID").flatMap(UUID.init(uuidString:)))
        let unplacedRecord = try #require(fixture.tasks.record(unplacedID))
        #expect(unplacedRecord.parentTaskID == nil)
        #expect(unplacedRecord.workspaceID == nil)
        if case .needsWorkspace = unplacedRecord.setup {} else {
            Issue.record("expected needsWorkspace, got \(unplacedRecord.setup)")
        }

        // The picker's action cannot place it there either.
        await expectInvalidPayload(containing: "not a project") {
            _ = try executor.runAction(
                id: "task.set-workspace",
                args: ["taskID": .string(unplacedID.uuidString), "workspace": .string(coordinatorID.uuidString)],
                context: context()
            )
        }
        #expect(fixture.tasks.record(unplacedID)?.workspaceID == nil)

        // Nothing nests under the coordinator, whoever asks.
        #expect(fixture.store.state.subspaceWorkspaceIDs(of: coordinatorID).isEmpty)
        let created = try executor.runAction(
            id: "workspace.create", args: ["title": .string("scratch"), "activate": .bool(false)], context: context(coordinatorSession)
        )
        #expect(created.didMutateState)
        let scratchID = try #require(fixture.store.state.workspacesByID.values.first { $0.title == "scratch" }?.id)
        #expect(fixture.store.state.workspacesByID[scratchID]?.parentWorkspaceID == nil)
        #expect(fixture.store.state.topLevelWorkspaceIDs(in: windowID).contains(scratchID))

        // The coordinator's own session is not a task and cannot become one.
        await expectInvalidPayload(containing: "coordinator is not a task") {
            _ = try executor.runAction(id: "task.start-work", args: [:], context: context(coordinatorSession))
        }
        do {
            _ = try executor.runQuery(
                id: "task.get", args: [:],
                context: AutomationRequestContext(callerSessionID: coordinatorSession, commandName: "app_control.run_query")
            )
            Issue.record("the coordinator's session has no task of its own")
        } catch AutomationSocketError.invalidPayload {}
        #expect(fixture.store.state.workspacesByID[coordinatorID]?.taskID == nil)
    }

    // MARK: - Command palette

    @Test func thePaletteOpensAndRestartsTheCoordinator() async throws {
        let fixture = try Fixture()
        // The task coordinator holds its board weakly.
        let board = attachBoard(fixture)
        defer { withExtendedLifetime(board) {} }
        var failures: [String] = []
        let palette = CommandPaletteTaskActions(
            store: fixture.store,
            sessionRuntimeStore: fixture.sessions,
            presentFailure: { title, message in failures.append("\(title): \(message)") },
            afterPaletteCloses: { $0() }
        )
        let windowID = try #require(fixture.store.state.selectedWindowID)
        func titles() -> [String] {
            CommandPaletteTaskCatalog.descriptors(current: nil, releases: [], coordinator: palette.coordinatorOption()).map(\.title)
        }

        #expect(titles() == ["Open Coordinator"])
        #expect(palette.execute(.openCoordinator, originWindowID: windowID))
        await fixture.waitUntil("the palette's Open starts the agent") { fixture.controller.session != nil }
        let location = try #require(fixture.store.state.coordinator)
        #expect(location.windowID == windowID)
        #expect(fixture.store.selectedWorkspaceID(in: windowID) == location.workspaceID)
        let firstSessionID = try fixture.session().sessionID

        #expect(titles() == ["Open Coordinator", "Restart Coordinator"])
        #expect(palette.execute(.restartCoordinator, originWindowID: windowID))
        await fixture.waitUntil("the palette's Restart starts a fresh session") {
            fixture.controller.isStarting == false && fixture.controller.session.map { $0.sessionID != firstSessionID } == true
        }
        #expect(fixture.store.state.coordinator?.workspaceID == location.workspaceID)
        #expect(failures.isEmpty)

        // A start that fails says why.
        fixture.tasks.config.coordinator = TasksConfig.Coordinator(agent: "nobody")
        #expect(palette.execute(.restartCoordinator, originWindowID: windowID))
        await fixture.waitUntil("the failure is shown") { failures.isEmpty == false }
        #expect(failures.first?.hasPrefix("Unable to Restart the Coordinator: ") == true)
        #expect(failures.first?.contains("nobody") == true)
        // The agent that ran keeps running.
        #expect(fixture.controller.session != nil)
    }

    @Test func withoutACoordinatorControllerThePaletteOffersNothing() throws {
        let tasks = try TaskCoordinatorTests.Fixture()
        let palette = CommandPaletteTaskActions(store: tasks.store, sessionRuntimeStore: tasks.sessionRuntimeStore)
        #expect(palette.coordinatorOption() == nil)
        #expect(CommandPaletteTaskCatalog.descriptors(current: nil, releases: [], coordinator: nil).isEmpty)
    }
}
