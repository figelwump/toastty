import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// `task.*` through the app-control executor, as the socket and the CLI
/// reach it.
@MainActor
struct TaskAppControlTests {
    private func makeExecutor(_ fixture: TaskCoordinatorTests.Fixture, coordinator: TaskCoordinator?) -> AppControlExecutor {
        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        let webPanelRuntimeRegistry = WebPanelRuntimeRegistry()
        webPanelRuntimeRegistry.bind(store: fixture.store)
        return AppControlExecutor(
            store: fixture.store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            webPanelRuntimeRegistry: webPanelRuntimeRegistry,
            sessionRuntimeStore: fixture.sessionRuntimeStore,
            focusedPanelCommandController: FocusedPanelCommandController(
                store: fixture.store,
                runtimeRegistry: terminalRuntimeRegistry,
                slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
            ),
            agentLaunchService: fixture.launcher,
            taskCoordinator: coordinator,
            reloadConfigurationAction: nil
        )
    }

    private func context(_ callerSessionID: String? = nil) -> AutomationRequestContext {
        AutomationRequestContext(callerSessionID: callerSessionID, commandName: "app_control.run_action")
    }

    private func taskID(_ result: [String: AutomationJSONValue]?) throws -> UUID {
        guard case .string(let raw)? = result?["taskID"], let id = UUID(uuidString: raw) else {
            throw TaskError("no taskID in \(String(describing: result))")
        }
        return id
    }

    private func expectInvalidPayload(_ message: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("expected invalidPayload(\(message))")
        } catch AutomationSocketError.invalidPayload(let actual) {
            #expect(actual == message)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    private func setupState(_ result: [String: AutomationJSONValue]) -> String? {
        guard case .object(let setup)? = result["setup"], case .string(let state)? = setup["state"] else { return nil }
        return state
    }

    @Test func createReturnsAtOnceAndGetReportsTheStartedTask() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)

        let outcome = try await executor.runActionAsync(
            id: "task.create",
            args: [
                "text": .string("The unread dot stays on"),
                "workspace": .string(fixture.workspaceID.uuidString),
                "agent": .string("codex"),
                "effort": .string("high"),
                "clientRequestID": .string("phone-1"),
            ],
            context: context()
        )
        let id = try taskID(outcome.result)
        #expect(outcome.result.map(setupState) == "settingUp")
        #expect(outcome.result?["effort"] == .string("high"))

        await fixture.waitForSetup(id)
        let got = try executor.runQuery(id: "task.get", args: ["taskID": .string(id.uuidString)])
        #expect(setupState(got) == "started")
        guard case .object(let setup)? = got["setup"] else {
            Issue.record("no setup object")
            return
        }
        #expect(setup["taskSpaceWorkspaceID"] == .string(try #require(fixture.taskSpaceIDs.first).uuidString))

        let repeated = try await executor.runActionAsync(
            id: "task.create",
            args: ["text": .string("ignored"), "agent": .string("codex"), "clientRequestID": .string("phone-1")],
            context: context()
        )
        #expect(try taskID(repeated.result) == id)
    }

    @Test func errorsComeBackAsInvalidPayload() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        await expectInvalidPayload("Name a workspace for the task with --workspace <id>, or create it from an agent session in that workspace.") {
            _ = try await executor.runActionAsync(id: "task.create", args: ["text": .string("x"), "agent": .string("codex")], context: context())
        }
        await expectInvalidPayload("workspace must be a workspace ID") {
            _ = try await executor.runActionAsync(id: "task.create", args: ["text": .string("x"), "workspace": .string("toastty")], context: context())
        }
        let missing = UUID()
        await expectInvalidPayload("No task has ID \(missing.uuidString).") {
            _ = try executor.runQuery(id: "task.get", args: ["taskID": .string(missing.uuidString)])
        }
    }

    @Test func aScopedAgentSeesOnlyItsOwnTasksAndCannotReachOtherWorkspaces() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        let unrelated = try await fixture.coordinator.create(TaskCreateRequest(text: "unrelated", workspaceID: fixture.workspaceID, agent: "codex"))
        let parent = try await fixture.coordinator.create(TaskCreateRequest(text: "parent", workspaceID: fixture.workspaceID, agent: "codex"))
        await fixture.waitForSetup(unrelated.id)
        await fixture.waitForSetup(parent.id)
        // The parent's agent is scoped to its own task space.
        let agentSessionID = try #require(fixture.record(parent.id)?.operation.agentLaunch?.sessionID)
        #expect(fixture.sessionRuntimeStore.isWorkspaceScoped(sessionID: agentSessionID))

        // It may add a task to its own project without naming a workspace.
        let child = try await executor.runActionAsync(
            id: "task.create",
            args: ["text": .string("child"), "agent": .string("claude")],
            context: context(agentSessionID)
        )
        let childID = try taskID(child.result)
        #expect(fixture.record(childID)?.workspaceID == fixture.workspaceID)

        // It sees its own task space's task and the one it created, not the
        // unrelated one.
        let list = try executor.runQuery(
            id: "task.list",
            args: [:],
            context: AutomationRequestContext(callerSessionID: agentSessionID, commandName: "app_control.run_query")
        )
        guard case .array(let tasks)? = list["tasks"] else {
            Issue.record("task.list returned no tasks array")
            return
        }
        let visible = Set(tasks.compactMap { task -> UUID? in
            guard case .object(let object) = task else { return nil }
            return try? taskID(object)
        })
        #expect(visible == [parent.id, childID])
        await expectInvalidPayload("No task has ID \(unrelated.id.uuidString).") {
            _ = try executor.runAction(id: "task.delete", args: ["taskID": .string(unrelated.id.uuidString)], context: context(agentSessionID))
        }

        // Another project's workspace is out of its scope.
        let windowID = try #require(fixture.store.state.selectedWindowID)
        _ = fixture.store.send(.createWorkspace(windowID: windowID, title: "website", activate: false))
        let otherWorkspaceID = try #require(fixture.store.state.windows.first?.workspaceIDs.last)
        do {
            _ = try await executor.runActionAsync(
                id: "task.create",
                args: ["text": .string("x"), "agent": .string("codex"), "workspace": .string(otherWorkspaceID.uuidString)],
                context: context(agentSessionID)
            )
            Issue.record("expected scopeDenied")
        } catch AutomationSocketError.scopeDenied(let workspaceID) {
            #expect(workspaceID == otherWorkspaceID)
        }

        // Scope over one subspace of that project does not cover its root,
        // where the new task space would go.
        let foreignChild = UUID()
        #expect(fixture.store.send(.createTaskSpace(
            windowID: windowID,
            workspaceID: foreignChild,
            panelID: UUID(),
            parentWorkspaceID: otherWorkspaceID,
            spawningSessionID: nil,
            taskID: UUID(),
            title: "foreign",
            terminalCWD: fixture.projectRoot
        )))
        #expect(fixture.sessionRuntimeStore.addScope(sessionID: agentSessionID, workspaceIDs: [foreignChild]))
        do {
            _ = try await executor.runActionAsync(
                id: "task.create",
                args: ["text": .string("x"), "agent": .string("codex"), "workspace": .string(foreignChild.uuidString)],
                context: context(agentSessionID)
            )
            Issue.record("expected scopeDenied for the root")
        } catch AutomationSocketError.scopeDenied(let workspaceID) {
            #expect(workspaceID == otherWorkspaceID)
        }
    }

    @Test func taskCommandsAreHiddenWithoutACoordinator() throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let executor = makeExecutor(fixture, coordinator: nil)
        #expect(executor.listActionDescriptors().contains { $0.id.hasPrefix("task.") } == false)
        #expect(executor.listQueryDescriptors().contains { $0.id.hasPrefix("task.") } == false)
        let withTasks = makeExecutor(fixture, coordinator: fixture.coordinator)
        #expect(Set(withTasks.listActionDescriptors().map(\.id)).isSuperset(of: ["task.create", "task.retry", "task.delete"]))
        #expect(Set(withTasks.listQueryDescriptors().map(\.id)).isSuperset(of: ["task.get", "task.list"]))
    }
}
