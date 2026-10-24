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
        await expectInvalidPayload("Name an agent with --agent <profile>, or set agent in the [defaults] table of ~/.toastty/tasks.toml.") {
            _ = try await executor.runActionAsync(id: "task.create", args: ["text": .string("x")], context: context())
        }
        await expectInvalidPayload("workspace must be a workspace ID") {
            _ = try await executor.runActionAsync(id: "task.create", args: ["text": .string("x"), "workspace": .string("toastty")], context: context())
        }
        await expectInvalidPayload("startWork must be true or false") {
            _ = try await executor.runActionAsync(
                id: "task.create",
                args: ["text": .string("x"), "workspace": .string(fixture.workspaceID.uuidString), "startWork": .string("yes")],
                context: context()
            )
        }
        await expectInvalidPayload("--fork copies the conversation of the agent session that runs it, so it runs only from a Toastty-managed Claude Code or Codex session.") {
            _ = try await executor.runActionAsync(
                id: "task.create",
                args: ["text": .string("x"), "workspace": .string(fixture.workspaceID.uuidString), "fork": .bool(true)],
                context: context()
            )
        }
        await expectInvalidPayload("task start-work runs from the agent session whose work moves into the worktree.") {
            _ = try executor.runAction(id: "task.start-work", args: [:], context: context())
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
        // Task sessions start unscoped; the user scopes the parent's agent to
        // its own task space.
        let agentSessionID = try #require(fixture.record(parent.id)?.operation.agentLaunch?.sessionID)
        #expect(fixture.sessionRuntimeStore.isWorkspaceScoped(sessionID: agentSessionID) == false)
        #expect(fixture.sessionRuntimeStore.setScope(sessionID: agentSessionID, workspaceIDs: []))
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
        #expect(Set(withTasks.listActionDescriptors().map(\.id)).isSuperset(of: ["task.create", "task.retry", "task.delete", "task.set-workspace", "task.start-work"]))
        #expect(Set(withTasks.listQueryDescriptors().map(\.id)).isSuperset(of: ["task.get", "task.list", "task.workspace-choices"]))
    }

    @Test func aTaskWithNoWorkspaceWaitsUntilSetWorkspacePlacesIt() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        let outcome = try await executor.runActionAsync(
            id: "task.create",
            args: ["text": .string("Fix the unread dot"), "agent": .string("codex")],
            context: context()
        )
        let id = try taskID(outcome.result)
        let created = try #require(outcome.result)
        #expect(setupState(created) == "needsWorkspace")
        #expect(created["workspaceID"] == .null)

        let choices = try executor.runQuery(id: "task.workspace-choices", args: [:])
        #expect(choices["open"] == .array([.object([
            "workspaceID": .string(fixture.workspaceID.uuidString),
            "title": .string("toastty"),
            "rootDirectory": .string(fixture.projectRoot),
        ])]))
        #expect(choices["recent"] == .array([]))
        #expect(choices["suggested"] == nil)

        await expectInvalidPayload("pass one of workspace, recentWorkspace or rootDirectory") {
            _ = try executor.runAction(id: "task.set-workspace", args: ["taskID": .string(id.uuidString)], context: context())
        }
        let placed = try executor.runAction(
            id: "task.set-workspace",
            args: ["taskID": .string(id.uuidString), "workspace": .string(fixture.workspaceID.uuidString)],
            context: context()
        )
        #expect(placed.result.map(setupState) == "routing")
        await fixture.waitUntil("the task starts") { fixture.record(id)?.setup == .started }
        let got = try executor.runQuery(id: "task.get", args: ["taskID": .string(id.uuidString)])
        #expect(got["workspaceID"] == .string(fixture.workspaceID.uuidString))

        // A scoped session cannot reopen a closed workspace: that makes a
        // top-level workspace no scope covers.
        let scopedSessionID = try #require(fixture.record(id)?.operation.agentLaunch?.sessionID)
        #expect(fixture.sessionRuntimeStore.setScope(sessionID: scopedSessionID, workspaceIDs: []))
        #expect(fixture.sessionRuntimeStore.isWorkspaceScoped(sessionID: scopedSessionID))
        let second = try await executor.runActionAsync(
            id: "task.create",
            args: ["text": .string("second"), "agent": .string("codex")],
            context: context()
        )
        await expectInvalidPayload("a workspace-scoped session cannot reopen a closed workspace") {
            _ = try executor.runAction(
                id: "task.set-workspace",
                args: ["taskID": .string(try taskID(second.result).uuidString), "recentWorkspace": .string(UUID().uuidString)],
                context: context(scopedSessionID)
            )
        }
        await expectInvalidPayload("a workspace-scoped session cannot open a workspace") {
            _ = try executor.runAction(
                id: "task.set-workspace",
                args: ["taskID": .string(try taskID(second.result).uuidString), "rootDirectory": .string(fixture.root.path)],
                context: context(scopedSessionID)
            )
        }
    }

    @Test func triagesSuggestionIsInTheChoicesAndRootDirectoryOpensIt() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        fixture.config.triage = TasksConfig.Triage(command: "fake-triage")
        let website = fixture.root.appendingPathComponent("website", isDirectory: true)
        try FileManager.default.createDirectory(at: website.appendingPathComponent(".git"), withIntermediateDirectories: true)
        fixture.config.workspaces = [TasksConfig.Workspace(path: website.path)]
        let websiteRoot = TasksConfigFile.normalizedPath(website.path)
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        fixture.triage.answer(.success(TaskTriage.Answer(workspace: website.path, reason: "The website is not open.")))
        let outcome = try await executor.runActionAsync(
            id: "task.create",
            args: ["text": .string("pricing typo"), "agent": .string("codex"), "model": .string("gpt-6.1-sol"), "effort": .string("high"), "prompt": .string("Fix it.")],
            context: context()
        )
        let id = try taskID(outcome.result)
        await fixture.waitUntil("triage ends") { fixture.record(id)?.setup != .routing }

        let got = try executor.runQuery(id: "task.get", args: ["taskID": .string(id.uuidString)])
        #expect(got["suggestedWorkspace"] == .object(["title": .string("website"), "rootDirectory": .string(websiteRoot)]))
        let choices = try executor.runQuery(id: "task.workspace-choices", args: ["taskID": .string(id.uuidString)])
        // For a directory, rootDirectory is also the task.set-workspace argument.
        #expect(choices["suggested"] == .object([
            "title": .string("website"),
            "rootDirectory": .string(websiteRoot),
        ]))

        await expectInvalidPayload("rootDirectory must be an absolute path or start with ~") {
            _ = try executor.runAction(
                id: "task.set-workspace",
                args: ["taskID": .string(id.uuidString), "rootDirectory": .string("website")],
                context: context()
            )
        }
        _ = try executor.runAction(
            id: "task.set-workspace",
            args: ["taskID": .string(id.uuidString), "rootDirectory": .string(websiteRoot)],
            context: context()
        )
        await fixture.waitUntil("the task starts") { fixture.record(id)?.setup == .started }
        let openedID = try #require(fixture.record(id)?.workspaceID)
        #expect(fixture.store.state.workspacesByID[openedID]?.rootDirectory == websiteRoot)
        #expect(fixture.store.state.workspacesByID[openedID]?.title == "website")
    }

    /// Text typed through `LiveTaskSessions`, in order.
    @MainActor
    final class TypedText {
        var entries: [(text: String, panelID: UUID)] = []
    }

    private func useLiveSessions(_ fixture: TaskCoordinatorTests.Fixture) -> TypedText {
        let typed = TypedText()
        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        fixture.coordinator.sessions = LiveTaskSessions(
            sessionRuntimeStore: fixture.sessionRuntimeStore,
            closeController: SessionCloseController(
                store: fixture.store,
                sessionRuntimeStore: fixture.sessionRuntimeStore,
                focusedPanelCommandController: FocusedPanelCommandController(
                    store: fixture.store,
                    runtimeRegistry: terminalRuntimeRegistry,
                    slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
                ),
                terminalCloseAssessment: { _ in nil },
                localDocumentCloseConfirmationState: { _ in nil },
                shouldBypassConfirmation: true
            ),
            exitController: nil,
            sendText: { text, panelID in
                typed.entries.append((text, panelID))
                return true
            }
        )
        return typed
    }

    private func agentState(_ task: [String: AutomationJSONValue]) -> String? {
        guard case .object(let state)? = task["agentState"], case .string(let value)? = state["state"] else { return nil }
        return value
    }

    @Test func aCoordinatorOutsideToasttyPollsSendsAndWakesATaskWithAWatch() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        let typed = useLiveSessions(fixture)
        func create(_ text: String) async throws -> TaskRecord {
            let outcome = try await executor.runActionAsync(
                id: "task.create",
                args: ["text": .string(text), "workspace": .string(fixture.workspaceID.uuidString), "agent": .string("claude")],
                context: context()
            )
            let id = try taskID(outcome.result)
            await fixture.waitForSetup(id)
            return try #require(fixture.record(id))
        }
        let producer = try await create("Define the API")
        let consumer = try await create("Build the client on the API")
        let producerSession = try #require(producer.operation.agentLaunch?.sessionID)
        let consumerSession = try #require(consumer.operation.agentLaunch?.sessionID)
        let producerPanel = try #require(producer.operation.taskSpace?.panelID)
        let consumerPanel = try #require(consumer.operation.taskSpace?.panelID)

        // A first poll lists every task with its agent's state and a cursor.
        let first = try executor.runQuery(id: "task.list", args: [:])
        guard case .array(let all)? = first["tasks"], case .string(let cursor)? = first["cursor"] else {
            Issue.record("task.list has no tasks or cursor: \(first)")
            return
        }
        #expect(all.count == 2)
        #expect(all.compactMap { task -> String? in
            guard case .object(let object) = task else { return nil }
            return agentState(object)
        } == ["idle", "idle"])
        let quiet = try executor.runQuery(id: "task.list", args: ["changedSince": .string(cursor)])
        #expect(quiet["tasks"] == .array([]))

        // The producer starts a turn: only it is listed as changed.
        fixture.sessionRuntimeStore.updateStatus(
            sessionID: producerSession, status: SessionStatus(kind: .working, summary: "Working"), at: Date()
        )
        let changed = try executor.runQuery(id: "task.list", args: ["changedSince": .string(cursor)])
        guard case .array(let changedTasks)? = changed["tasks"], case .object(let busy)? = changedTasks.first else {
            Issue.record("expected one changed task: \(changed)")
            return
        }
        #expect(changedTasks.count == 1)
        #expect(busy["taskID"] == .string(producer.id.uuidString))
        #expect(agentState(busy) == "busy")

        // A follow-up by task ID reaches the producer's terminal.
        let sent = try executor.runAction(
            id: "task.send",
            args: ["taskID": .string(producer.id.uuidString), "text": .string("Also document the errors")],
            context: context()
        )
        #expect(sent.result?["sessionID"] == .string(producerSession))
        #expect(typed.entries.map(\.panelID) == [producerPanel])

        // The consumer's agent waits for the producer instead of polling;
        // the watch notifies the caller's own task by default.
        let watch = try executor.runAction(
            id: "task.watch",
            args: ["taskID": .string(producer.id.uuidString), "until": .string("idle")],
            context: context(consumerSession)
        )
        #expect(watch.result?["notifyTaskID"] == .string(consumer.id.uuidString))
        #expect(watch.result?["state"] == .string("pending"))
        fixture.sessionRuntimeStore.updateStatus(
            sessionID: producerSession, status: SessionStatus(kind: .ready, summary: "Ready"), at: Date().addingTimeInterval(1)
        )
        fixture.coordinator.evaluateWatches()
        #expect(typed.entries.last?.panelID == consumerPanel)
        #expect(typed.entries.last?.text.contains("is idle. Read it with: toastty task get \(producer.id.uuidString)") == true)

        let watches = try executor.runQuery(id: "task.watches", args: ["notifyTaskID": .string(consumer.id.uuidString)])
        guard case .array(let listed)? = watches["watches"], case .object(let fired)? = listed.first else {
            Issue.record("no watches listed: \(watches)")
            return
        }
        #expect(fired["state"] == .string("fired"))
        #expect(fired["delivered"] == .bool(true))

        // task.get reports the agent and its reply, which is null until a
        // transcript is confirmed.
        let got = try executor.runQuery(id: "task.get", args: ["taskID": .string(producer.id.uuidString)])
        #expect(agentState(got) == "idle")
        #expect(got["lastReply"] == .null)

        // A caller that is not a task's agent must say whom to notify.
        await expectInvalidPayload("the caller is not a task's agent; name the task to notify with notifyTaskID, or pass wait=true and poll task.watches") {
            _ = try executor.runAction(
                id: "task.watch",
                args: ["taskID": .string(producer.id.uuidString), "until": .string("idle")],
                context: context()
            )
        }
        await expectInvalidPayload("until must be one of: idle, waiting, ready-for-review, merged, to-ship, done, archived") {
            _ = try executor.runAction(
                id: "task.watch",
                args: ["taskID": .string(producer.id.uuidString), "until": .string("soon"), "wait": .bool(true)],
                context: context()
            )
        }
    }

    @Test func aScopedSessionCanSendOnlyToTasksItMaySee() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        _ = useLiveSessions(fixture)
        let mine = try await fixture.coordinator.create(TaskCreateRequest(text: "mine", workspaceID: fixture.workspaceID, agent: "codex"))
        let other = try await fixture.coordinator.create(TaskCreateRequest(text: "other", workspaceID: fixture.workspaceID, agent: "codex"))
        await fixture.waitForSetup(mine.id)
        await fixture.waitForSetup(other.id)
        let scoped = try #require(fixture.record(mine.id)?.operation.agentLaunch?.sessionID)
        #expect(fixture.sessionRuntimeStore.setScope(sessionID: scoped, workspaceIDs: []))

        _ = try executor.runAction(
            id: "task.send", args: ["taskID": .string(mine.id.uuidString), "text": .string("hi")], context: context(scoped)
        )
        await expectInvalidPayload("No task has ID \(other.id.uuidString).") {
            _ = try executor.runAction(
                id: "task.send", args: ["taskID": .string(other.id.uuidString), "text": .string("hi")], context: context(scoped)
            )
        }
    }
}

extension TaskAppControlTests {
    @Test func adoptGivesAnUntrackedTaskSpaceARecordOnce() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        let windowID = try #require(fixture.store.state.windows.first?.id)
        let before = Set(fixture.store.state.workspacesByID.keys)
        _ = fixture.store.send(.createWorkspace(windowID: windowID, title: "qa-mobile-navigation", activate: false))
        let taskSpace = try #require(Set(fixture.store.state.workspacesByID.keys).subtracting(before).first)
        _ = fixture.store.send(.setWorkspaceParent(workspaceID: taskSpace, parentWorkspaceID: fixture.workspaceID, spawningSessionID: nil))
        _ = fixture.store.send(.setWorkspaceAnnotation(
            workspaceID: taskSpace,
            key: "github-pr",
            annotation: WorkspaceAnnotation(text: "PR #130", url: "https://github.com/example/toastty/pull/130")
        ))

        let adopted = try executor.runAction(id: "task.adopt", args: ["workspaceID": .string(taskSpace.uuidString)])
        guard case .string(let rawID)? = adopted.result?["taskID"], let taskID = UUID(uuidString: rawID) else {
            Issue.record("no taskID in \(String(describing: adopted.result))")
            return
        }
        let record = try #require(fixture.record(taskID))
        #expect(record.source == .adopted)
        #expect(record.title == "qa-mobile-navigation")
        #expect(record.workspaceID == fixture.workspaceID)
        #expect(record.taskSpaceWorkspaceID == taskSpace)
        #expect(record.pullRequestURL == "https://github.com/example/toastty/pull/130")
        #expect(fixture.store.state.workspacesByID[taskSpace]?.taskID == taskID)

        // A second adopt returns the same task.
        let again = try executor.runAction(id: "task.adopt", args: ["workspaceID": .string(taskSpace.uuidString)])
        #expect(again.result?["taskID"] == .string(taskID.uuidString))
        #expect(fixture.coordinator.records.records.count == 1)

        // Only task spaces can become tasks.
        do {
            _ = try executor.runAction(id: "task.adopt", args: ["workspaceID": .string(fixture.workspaceID.uuidString)])
            Issue.record("adopting a top-level workspace should fail")
        } catch AutomationSocketError.invalidPayload(let message) {
            #expect(message.contains("top-level workspace"))
        }
    }

    @Test func windowActionsShowTheTasksViewAndSwitchTheSidebar() throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        let windowID = try #require(fixture.store.state.windows.first?.id)
        let args: [String: AutomationJSONValue] = ["windowID": .string(windowID.uuidString)]

        _ = try executor.runAction(id: "window.tasks.show", args: args)
        #expect(fixture.store.window(id: windowID)?.showsTasksView == true)
        _ = try executor.runAction(id: "window.tasks.hide", args: args)
        #expect(fixture.store.window(id: windowID)?.showsTasksView == false)

        _ = try executor.runAction(id: "window.sidebar.set-segment", args: args.merging(["segment": .string("status")]) { $1 })
        #expect(fixture.store.window(id: windowID)?.sidebarSegment == .status)
        do {
            _ = try executor.runAction(id: "window.sidebar.set-segment", args: args.merging(["segment": .string("stages")]) { $1 })
            Issue.record("an unknown segment should fail")
        } catch AutomationSocketError.invalidPayload(let message) {
            #expect(message == "segment must be projects or status")
        }
    }

    @Test func coordinatorPostAppendsACardThatOnlyTheCoordinatorMayPost() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let files = CoordinatorFiles(directoryURL: fixture.root.appendingPathComponent("coordinator", isDirectory: true))
        let session = CoordinatorSessionController(
            store: fixture.store,
            launcher: fixture.launcher,
            sessions: TaskStartWorkTests.FakeSessions(),
            configLoader: { TasksConfig() },
            files: files
        )
        fixture.coordinator.coordinatorSession = session
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        let created = try await executor.runActionAsync(
            id: "task.create",
            args: ["text": .string("Fix the dot"), "workspace": .string(fixture.workspaceID.uuidString), "agent": .string("claude")],
            context: context()
        )
        let id = try taskID(created.result)
        await fixture.waitForSetup(id)

        let posted = try executor.runAction(
            id: "coordinator.post",
            args: ["kind": .string("question"), "taskID": .string(id.uuidString), "text": .string("Which base branch?")],
            context: context()
        )
        #expect(posted.result?["kind"] == .string("question"))
        let events = files.events()
        #expect(events.map(\.kind) == [.question])
        #expect(events.first?.taskID == id)
        #expect(events.first?.text == "Which base branch?")
        #expect(FileManager.default.fileExists(atPath: files.routingFileURL.path))

        // A task's own agent reports through its task, not by posting cards.
        let agentSessionID = try #require(fixture.record(id)?.operation.agentLaunch?.sessionID)
        await expectInvalidPayload("only the coordinator's session posts to its chat") {
            _ = try executor.runAction(
                id: "coordinator.post",
                args: ["kind": .string("note"), "text": .string("hi")],
                context: context(agentSessionID)
            )
        }
        // So does a session Toastty does not know, or no longer runs.
        await expectInvalidPayload("only the coordinator's session posts to its chat") {
            _ = try executor.runAction(
                id: "coordinator.post",
                args: ["kind": .string("note"), "text": .string("hi")],
                context: context("stopped-session")
            )
        }
        await expectInvalidPayload("A packet card names its task with --task <task-id>.") {
            _ = try executor.runAction(id: "coordinator.post", args: ["kind": .string("packet")], context: context())
        }
        let missing = UUID()
        await expectInvalidPayload("No task has ID \(missing.uuidString).") {
            _ = try executor.runAction(
                id: "coordinator.post",
                args: ["kind": .string("packet"), "taskID": .string(missing.uuidString)],
                context: context()
            )
        }
        #expect(files.events().count == 1)

        let status = try executor.runQuery(id: "coordinator.status", args: [:])
        #expect(status["state"] == .string("off"))
        #expect(status["eventsFile"] == .string(files.eventsFileURL.path))
    }

    @Test func aTaskTheCoordinatorCreatesWithoutAWorkspaceIsNotPutInItsWorkspace() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let windowID = try #require(fixture.store.state.selectedWindowID)
        let coordinatorWorkspaceID = UUID()
        #expect(fixture.store.send(.createCoordinatorWorkspace(
            windowID: windowID,
            workspaceID: coordinatorWorkspaceID,
            panelID: UUID(),
            terminalCWD: fixture.root.path
        )))
        let record = try await fixture.coordinator.create(
            TaskCreateRequest(text: "Route me", agent: "claude"),
            caller: TaskCaller(sessionID: "coordinator-session", workspaceID: coordinatorWorkspaceID)
        )
        #expect(record.workspaceID == nil)
        #expect(fixture.coordinator.workspaceChoices().open.contains { $0.id == coordinatorWorkspaceID } == false)

        // Workspace indexes skip it: a workspace made after it is number 2.
        _ = fixture.store.send(.createWorkspace(windowID: windowID, title: "website", activate: false))
        let website = try #require(fixture.store.state.windows.first?.workspaceIDs.last)
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        let listed = try executor.runQuery(id: "workspace.list", args: [:])
        guard case .array(let entries)? = listed["workspaces"] else {
            Issue.record("workspace.list returned no workspaces")
            return
        }
        let indexes = entries.compactMap { entry -> (String, AutomationJSONValue)? in
            guard case .object(let object) = entry, case .string(let id)? = object["workspaceID"] else { return nil }
            return (id, object["index"] ?? .null)
        }
        #expect(indexes.first { $0.0 == coordinatorWorkspaceID.uuidString }?.1 == .null)
        #expect(indexes.first { $0.0 == website.uuidString }?.1 == .int(2))
        _ = try executor.runAction(id: "workspace.select", args: ["windowID": .string(windowID.uuidString), "index": .int(2)], context: context())
        #expect(fixture.store.state.windows.first?.selectedWorkspaceID == website)
    }
}
