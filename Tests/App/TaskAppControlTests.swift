import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// `task.*` through the app-control executor, as the socket and the CLI
/// reach it.
@MainActor
struct TaskAppControlTests {
    func makeExecutor(_ fixture: TaskCoordinatorTests.Fixture, coordinator: TaskCoordinator?) -> AppControlExecutor {
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
            annotationStyleStore: AnnotationStyleStore(
                runtimePaths: ToasttyRuntimePaths.resolve(
                    homeDirectoryPath: fixture.root.path,
                    environment: [ToasttyRuntimePaths.environmentKey: fixture.root.path]
                )
            ),
            taskCoordinator: coordinator,
            reloadConfigurationAction: nil
        )
    }

    func context(_ callerSessionID: String? = nil) -> AutomationRequestContext {
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

    @Test func pullRequestAnnotationRequiresAnExplicitWorkspaceAndTheReleaseAgentOwnsItsLink() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let board = TaskBoardStore(
            coordinator: fixture.coordinator, store: fixture.store, sessionRuntimeStore: fixture.sessionRuntimeStore,
            pullRequests: PullRequestStateCache(runner: TaskBoardTests.FakeGitHub()),
            refreshInterval: nil, releaseCheckInterval: nil
        )
        fixture.coordinator.board = board
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        let request = TaskCreateRequest(text: "Task for PR", workspaceID: fixture.workspaceID, agent: "codex")
        let task = try await fixture.coordinator.create(request)
        await fixture.waitForSetup(task.id)
        let release = try await fixture.coordinator.create(TaskCreateRequest(
            text: "Release", workspaceID: fixture.workspaceID, agent: "codex"
        ))
        await fixture.waitForSetup(release.id)
        try fixture.coordinator.records.save(id: release.id) { $0.release = TaskRelease(childTaskIDs: []) }
        let releaseSpace = try #require(fixture.record(release.id)?.taskSpaceWorkspaceID)
        let taskSpace = try #require(fixture.record(task.id)?.taskSpaceWorkspaceID)
        let windowID = try #require(fixture.store.state.windows.first?.id)
        _ = fixture.store.send(.selectWorkspace(windowID: windowID, workspaceID: releaseSpace))
        #expect(fixture.store.state.selectedWorkspaceSelection()?.workspaceID == releaseSpace)

        let url = "https://github.com/example/toastty/pull/124"
        var args: [String: AutomationJSONValue] = [
            "key": .string("GitHub-PR"), "text": .string("PR #124"), "url": .string(url)
        ]
        let caller = context(try #require(fixture.record(task.id)?.currentSessionID))
        await expectInvalidPayload("workspaceID is required for a github-pr annotation") {
            _ = try executor.runAction(id: "workspace.set-annotation", args: args, context: caller)
        }
        args["windowID"] = .string(windowID.uuidString)
        await expectInvalidPayload("workspaceID is required for a github-pr annotation") {
            _ = try executor.runAction(id: "workspace.clear-annotation", args: args, context: caller)
        }
        args["workspaceID"] = .string(releaseSpace.uuidString)
        let releaseCaller = context(try #require(fixture.record(release.id)?.currentSessionID))
        for foreignCaller in [caller, context()] {
            await expectInvalidPayload("Only a managed session in the release task space can link its preparation pull request") {
                _ = try executor.runAction(id: "workspace.set-annotation", args: args, context: foreignCaller)
            }
        }

        args["workspaceID"] = .string(taskSpace.uuidString)
        let result = try executor.runAction(id: "workspace.set-annotation", args: args, context: caller)
        #expect(result.result?["workspaceID"] == .string(taskSpace.uuidString))
        #expect(fixture.record(task.id)?.pullRequestURL == url)
        #expect(fixture.record(release.id)?.pullRequestURL == nil)
        #expect(fixture.store.state.workspacesByID[releaseSpace]?.annotations["github-pr"] == nil)
        #expect(fixture.store.state.selectedWorkspaceSelection()?.workspaceID == releaseSpace)
        #expect(try executor.runAction(id: "workspace.clear-annotation", args: args, context: caller).didMutateState)
        #expect(fixture.record(task.id)?.pullRequestURL == url)

        let preparationURL = "https://github.com/example/toastty/pull/125"
        args["workspaceID"] = .string(releaseSpace.uuidString)
        args["url"] = .string(preparationURL)
        #expect(try executor.runAction(id: "workspace.set-annotation", args: args, context: releaseCaller).didMutateState)
        #expect(fixture.savedRecord(release.id)?.release?.preparationPullRequestURL == preparationURL)
        #expect(try fixture.coordinator.mergeTarget(try #require(fixture.record(release.id))).pullRequest.url == preparationURL)
        await expectInvalidPayload("Only a managed session in the release task space can link its preparation pull request") {
            _ = try executor.runAction(id: "workspace.set-annotation", args: args, context: caller)
        }
        #expect(fixture.record(release.id)?.pullRequestURL == preparationURL)
        #expect(try executor.runAction(id: "workspace.clear-annotation", args: args, context: releaseCaller).didMutateState)
        #expect(fixture.record(release.id)?.pullRequestURL == nil)
        #expect(fixture.savedRecord(release.id)?.release?.preparationPullRequestURL == nil)
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

    /// A coordinator passes the agent, model and effort its policy names
    /// for releases.
    @Test func releaseTakesTheCallersAgentModelAndEffort() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        fixture.config.workspaces = [TasksConfig.Workspace(path: fixture.projectRoot, releasePrompt: "Release it.")]
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)

        await expectInvalidPayload("Agent gemini is not a profile in agents.toml (available: claude, codex).") {
            _ = try executor.runAction(
                id: "task.release",
                args: ["workspaceID": .string(fixture.workspaceID.uuidString), "agent": .string("gemini")],
                context: context()
            )
        }
        let outcome = try executor.runAction(
            id: "task.release",
            args: [
                "workspaceID": .string(fixture.workspaceID.uuidString),
                "agent": .string("codex"),
                "model": .string("gpt-6.2-sol"),
                "effort": .string("high"),
            ],
            context: context()
        )
        #expect(outcome.result?["agent"] == .string("codex"))
        #expect(outcome.result?["model"] == .string("gpt-6.2-sol"))
        #expect(outcome.result?["effort"] == .string("high"))
    }

    @Test func releaseCompletionRejectsInvalidReportsAndUnmanagedCallers() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        await expectInvalidPayload("Expected a JSON report with tags, each with a tag name and a list of taskIDs.") {
            _ = try await executor.runActionAsync(
                id: "task.release-complete", args: ["report": .string("{}")], context: context()
            )
        }
        await expectInvalidPayload("Only the release task's own agent can report its completion.") {
            _ = try await executor.runActionAsync(
                id: "task.release-complete", args: ["report": .string(#"{"tags":[{"tag":"v1","taskIDs":[]}]}"#)], context: context()
            )
        }
        #expect(fixture.coordinator.records.records.isEmpty)
    }

    /// The bug this guards: an agent's `workspace.set-done` finished its own
    /// task while the task's pull request was open, so the task skipped the
    /// merge and To ship. The done checkbox, on the Mac and on a phone,
    /// already refused that.
    @Test func setDoneRefusesATaskWithAnOpenPullRequest() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let gitHub = TaskBoardTests.FakeGitHub()
        let board = TaskBoardStore(
            coordinator: fixture.coordinator,
            store: fixture.store,
            sessionRuntimeStore: fixture.sessionRuntimeStore,
            pullRequests: PullRequestStateCache(runner: gitHub),
            refreshInterval: nil,
            releaseCheckInterval: nil
        )
        fixture.coordinator.board = board
        fixture.sessionRuntimeStore.taskCoordinator = fixture.coordinator
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        let created = try await fixture.coordinator.create(TaskCreateRequest(
            text: "Fix the unread dot", workspaceID: fixture.workspaceID, agent: "codex", prompt: "Fix it."))
        await fixture.waitForSetup(created.id)
        let taskSpace = try #require(fixture.record(created.id)?.taskSpaceWorkspaceID)
        let session = try #require(fixture.record(created.id)?.operation.agentLaunch?.sessionID)
        let url = "https://github.com/example/toastty/pull/124"
        #expect(fixture.store.send(.setWorkspaceAnnotation(
            workspaceID: taskSpace, key: "github-pr", annotation: WorkspaceAnnotation(text: "PR #124", url: url))))
        let link = try #require(WorkspacePullRequestLink(annotationURL: url))
        gitHub.answer(url, state: "OPEN")
        await board.pullRequests?.refresh(link).value
        func group() throws -> AutomationJSONValue? {
            let got = try executor.runQuery(id: "task.get", args: ["taskID": .string(created.id.uuidString)])
            guard case .object(let stage)? = got["stage"] else { return nil }
            return stage["group"]
        }

        // The task's agent marks its own task space, naming no workspace.
        await expectInvalidPayload(
            "workspace.set-done does not finish a task with an open pull request or a merge under way; the task finishes when the user merges or archives it"
        ) {
            _ = try executor.runAction(id: "workspace.set-done", args: [:], context: context(session))
        }
        #expect(fixture.store.state.workspacesByID[taskSpace]?.doneAt == nil)
        #expect(try group() != .string("done"))

        // Once the pull request is closed without a merge, the mark
        // finishes the task.
        gitHub.answer(url, state: "CLOSED")
        await board.pullRequests?.refresh(link).value
        let marked = try executor.runAction(id: "workspace.set-done", args: [:], context: context(session))
        #expect(marked.didMutateState)
        #expect(try group() == .string("done"))
    }

    @Test func errorsComeBackAsInvalidPayload() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        await expectInvalidPayload("Agent gemini is not a profile in agents.toml (available: claude, codex).") {
            _ = try await executor.runActionAsync(id: "task.create", args: ["text": .string("x"), "agent": .string("gemini")], context: context())
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
        await expectInvalidPayload("a workspace-scoped session cannot create a task by rootDirectory; pass its workspace") {
            _ = try await executor.runActionAsync(
                id: "task.create",
                args: ["text": .string("third"), "agent": .string("codex"), "rootDirectory": .string(fixture.root.path)],
                context: context(scopedSessionID)
            )
        }

        // A name looks up project directories: the open one by its title,
        // and a git repository next to it that Toastty never opened. A
        // scoped session gets neither: one is outside its scope, the other
        // is not open.
        let sibling = fixture.root.appendingPathComponent("billing-service", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let open = try executor.runQuery(id: "task.workspace-choices", args: ["name": .string("Toastty")])
        #expect(open["matches"] == .array([.object([
            "title": .string("toastty"),
            "rootDirectory": .string(fixture.projectRoot),
            "source": .string("open"),
            "workspaceID": .string(fixture.workspaceID.uuidString),
        ])]))
        let guessed = try executor.runQuery(id: "task.workspace-choices", args: ["name": .string("billing service")])
        #expect(guessed["matches"] == .array([.object([
            "title": .string("billing-service"),
            "rootDirectory": .string(sibling.path),
            "source": .string("sibling"),
        ])]))
        for name in ["toastty", "billing service"] {
            let scoped = try executor.runQuery(
                id: "task.workspace-choices",
                args: ["name": .string(name)],
                context: context(scopedSessionID)
            )
            #expect(scoped["matches"] == .array([]))
        }
        #expect(try executor.runQuery(id: "task.workspace-choices", args: [:])["matches"] == nil)
    }

    /// An outside coordinator names the project by its directory and the
    /// issue the task came from; task.get and task.list return the issue.
    @Test func createByRootDirectoryWithAnExternalReference() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        let reference: AutomationJSONValue = .object([
            "id": .string("github:acme/toastty#123"),
            "url": .string("https://github.com/acme/toastty/issues/123"),
        ])

        let outcome = try await executor.runActionAsync(
            id: "task.create",
            args: [
                "text": .string("Composer keeps a blank line"),
                "rootDirectory": .string(fixture.projectRoot),
                "agent": .string("claude"),
                "externalRef": .string("github:acme/toastty#123"),
                "externalURL": .string("https://github.com/acme/toastty/issues/123"),
                "clientRequestID": .string("grok:github:acme/toastty#123"),
            ],
            context: context()
        )
        let id = try taskID(outcome.result)
        #expect(outcome.result?["workspaceID"] == .string(fixture.workspaceID.uuidString))
        #expect(outcome.result?["externalRef"] == reference)
        await fixture.waitForSetup(id)
        let got = try executor.runQuery(id: "task.get", args: ["taskID": .string(id.uuidString)])
        #expect(got["externalRef"] == reference)
        let listed = try executor.runQuery(id: "task.list", args: [:])
        guard case .array(let tasks)? = listed["tasks"], case .object(let first)? = tasks.first else {
            Issue.record("no tasks in \(listed)")
            return
        }
        #expect(first["externalRef"] == reference)

        await expectInvalidPayload("pass workspace or rootDirectory, not both") {
            _ = try await executor.runActionAsync(id: "task.create", args: [
                "text": .string("x"), "agent": .string("claude"),
                "workspace": .string(fixture.workspaceID.uuidString), "rootDirectory": .string(fixture.projectRoot),
            ], context: context())
        }
        await expectInvalidPayload("rootDirectory must be an absolute path or start with ~") {
            _ = try await executor.runActionAsync(id: "task.create", args: [
                "text": .string("x"), "agent": .string("claude"), "rootDirectory": .string("project"),
            ], context: context())
        }
        await expectInvalidPayload("An external URL needs an external reference.") {
            _ = try await executor.runActionAsync(id: "task.create", args: [
                "text": .string("x"), "agent": .string("claude"), "workspace": .string(fixture.workspaceID.uuidString),
                "externalURL": .string("https://github.com/acme/toastty/issues/1"),
            ], context: context())
        }
        for badReference in ["github: acme#1", String(repeating: "x", count: 129), "github:acme#1é"] {
            await expectInvalidPayload("An external reference must be printable ASCII with no spaces, at most 128 characters.") {
                _ = try await executor.runActionAsync(id: "task.create", args: [
                    "text": .string("x"), "agent": .string("claude"), "workspace": .string(fixture.workspaceID.uuidString),
                    "externalRef": .string(badReference),
                ], context: context())
            }
        }
        for badURL in ["javascript:alert(1)", "file:///etc/hosts", "https://"] {
            await expectInvalidPayload("An external URL must be an http or https address.") {
                _ = try await executor.runActionAsync(id: "task.create", args: [
                    "text": .string("x"), "agent": .string("claude"), "workspace": .string(fixture.workspaceID.uuidString),
                    "externalRef": .string("linear:acme:ENG-42"), "externalURL": .string(badURL),
                ], context: context())
            }
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

    /// `coordinator` defaults to the fixture's; pass one made for a relaunch.
    @discardableResult
    func useLiveSessions(_ fixture: TaskCoordinatorTests.Fixture, coordinator: TaskCoordinator? = nil) -> TypedText {
        let typed = TypedText()
        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        (coordinator ?? fixture.coordinator).sessions = LiveTaskSessions(
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
        // Both agents finish the turn their launch started.
        for session in [producerSession, consumerSession] {
            for kind in [SessionStatusKind.working, .idle] {
                fixture.sessionRuntimeStore.updateStatus(sessionID: session, status: SessionStatus(kind: kind, summary: "\(kind)"), at: Date())
            }
        }

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
        // The task as an agent names it in text.
        let producerTitle = try #require(fixture.record(producer.id)?.title)
        #expect(busy["markdownLink"] == .string("[\(producerTitle)](toastty://task/\(producer.id.uuidString))"))

        // A follow-up by task ID reaches the producer's terminal, after a
        // first line that names the sending task as a link.
        let sent = try executor.runAction(
            id: "task.send",
            args: ["taskID": .string(producer.id.uuidString), "text": .string("Also document the errors")],
            context: context(consumerSession)
        )
        #expect(sent.result?["sessionID"] == .string(producerSession))
        #expect(typed.entries.map(\.panelID) == [producerPanel])
        let consumerTitle = try #require(fixture.record(consumer.id)?.title)
        #expect(typed.entries.last?.text == """
            [Toastty] From task [\(consumerTitle)](toastty://task/\(consumer.id.uuidString)): not from the user.
            Also document the errors
            """)
        // A message with no text is refused, sender line or not.
        for steer in [false, true] {
            await expectInvalidPayload("The message is empty.") {
                _ = try await executor.runActionAsync(
                    id: "task.send",
                    args: ["taskID": .string(producer.id.uuidString), "text": .string(" \n "), "steer": .bool(steer)],
                    context: context(consumerSession)
                )
            }
        }
        #expect(typed.entries.count == 1)
        // A program outside Toastty, with no session, names itself; a
        // session that gives a name is still named by its task.
        _ = try executor.runAction(
            id: "task.send",
            args: ["taskID": .string(producer.id.uuidString), "text": .string("Yes, go ahead"), "from": .string("Grok Bot")],
            context: context()
        )
        #expect(typed.entries.last?.text == """
            [Toastty] From "Grok Bot" (named by the caller): Toastty cannot tell who ran it.
            Yes, go ahead
            """)
        _ = try executor.runAction(
            id: "task.send",
            args: ["taskID": .string(producer.id.uuidString), "text": .string("Done"), "from": .string("the user")],
            context: context(consumerSession)
        )
        #expect(typed.entries.last?.text == """
            [Toastty] From task [\(consumerTitle)](toastty://task/\(consumer.id.uuidString)): not from the user.
            Done
            """)

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
            sessionID: consumerSession, status: SessionStatus(kind: .needsApproval, summary: "Waiting for approval"), at: Date()
        )
        fixture.sessionRuntimeStore.updateStatus(
            sessionID: producerSession, status: SessionStatus(kind: .ready, summary: "Ready"), at: Date().addingTimeInterval(1)
        )
        let previousDeliveryCount = typed.entries.count
        fixture.coordinator.evaluateWatches()
        #expect(typed.entries.count == previousDeliveryCount)
        fixture.sessionRuntimeStore.updateStatus(
            sessionID: consumerSession, status: SessionStatus(kind: .ready, summary: "Ready"), at: Date().addingTimeInterval(1)
        )
        fixture.coordinator.evaluateWatches()
        #expect(typed.entries.last?.panelID == consumerPanel)
        #expect(typed.entries.last?.text.contains(
            "Task [\(producerTitle)](toastty://task/\(producer.id.uuidString)) is idle. Read it with: toastty task get \(producer.id.uuidString)"
        ) == true)

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
        // The checked send has the same limit.
        await expectInvalidPayload("No task has ID \(other.id.uuidString).") {
            _ = try await executor.runActionAsync(
                id: "task.send",
                args: ["taskID": .string(other.id.uuidString), "text": .string("hi"), "steer": .bool(true)],
                context: context(scoped)
            )
        }
    }

    @Test func aSteerSendTypesNothingWhenToasttyCannotTellWhatTheAgentDoes() async throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        // These sessions have no conversation that Toastty follows.
        let typed = useLiveSessions(fixture)
        let task = try await fixture.coordinator.create(TaskCreateRequest(text: "mine", workspaceID: fixture.workspaceID, agent: "codex"))
        await fixture.waitForSetup(task.id)
        let title = try #require(fixture.record(task.id)).title
        let typedBefore = typed.entries.count
        let args: [String: AutomationJSONValue] = [
            "taskID": .string(task.id.uuidString), "text": .string("Use the new name"), "steer": .bool(true),
        ]

        await expectInvalidPayload(
            "Toastty cannot tell what task \(title)'s agent does now, so it typed nothing. Send the message again when the agent is idle."
        ) {
            _ = try await executor.runActionAsync(id: "task.send", args: args, context: context())
        }
        // The call that cannot wait refuses a steer send. It does not fall
        // back to typing without the check.
        await expectInvalidPayload("task.send with steer waits for the agent's state; send it through app_control.run_action") {
            _ = try executor.runAction(id: "task.send", args: args, context: context())
        }
        #expect(typed.entries.count == typedBefore)
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

        _ = try executor.runAction(id: "window.sidebar.set-segment", args: args.merging(["segment": .string("needsYou")]) { $1 })
        #expect(fixture.store.window(id: windowID)?.sidebarSegment == .needsYou)
        _ = try executor.runAction(id: "window.sidebar.set-segment", args: args.merging(["segment": .string("all")]) { $1 })
        #expect(fixture.store.window(id: windowID)?.sidebarSegment == .all)
        // Scripts written for the earlier segment names keep working.
        _ = try executor.runAction(id: "window.sidebar.set-segment", args: args.merging(["segment": .string("status")]) { $1 })
        #expect(fixture.store.window(id: windowID)?.sidebarSegment == .needsYou)
        do {
            _ = try executor.runAction(id: "window.sidebar.set-segment", args: args.merging(["segment": .string("stages")]) { $1 })
            Issue.record("an unknown segment should fail")
        } catch AutomationSocketError.invalidPayload(let message) {
            #expect(message == "segment must be all or needsYou")
        }
    }

    struct OfflineGitHub: WorkspaceMergeCommandRunning {
        func run(arguments: [String], directory: String, timeout: TimeInterval) async -> WorkspaceMergeCommandResult {
            WorkspaceMergeCommandResult(exitCode: 1, stdout: "", stderr: "offline", failure: nil)
        }
    }

    /// A task that finished through its child tasks reports it in `stage`,
    /// and a poll lists it as changed when only a child's record changed.
    @Test func aParentsStageFollowsItsChildrenInGetAndList() throws {
        let fixture = try TaskCoordinatorTests.Fixture()
        // The coordinator holds its board weakly.
        let board = TaskBoardStore(
            coordinator: fixture.coordinator,
            store: fixture.store,
            sessionRuntimeStore: fixture.sessionRuntimeStore,
            pullRequests: PullRequestStateCache(runner: OfflineGitHub()),
            refreshInterval: nil,
            releaseCheckInterval: nil
        )
        fixture.coordinator.board = board
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        func insert(_ title: String, parent: UUID? = nil) throws -> TaskRecord {
            let record = TaskRecord(
                createdAt: Date(), text: title, title: title, slug: title, source: .cli,
                workspaceID: fixture.workspaceID, projectRoot: fixture.projectRoot, setup: .started, parentTaskID: parent
            )
            try fixture.coordinator.records.insert(record)
            return record
        }
        let parent = try insert("coordinate-signup")
        let child = try insert("fix-signup", parent: parent.id)
        // The stage without its time, which other tests cover.
        func withoutTime(_ stage: AutomationJSONValue?) -> AutomationJSONValue? {
            guard case .object(var object)? = stage else { return stage }
            object["changedAt"] = nil
            return .object(object)
        }
        func parentStage() throws -> AutomationJSONValue? {
            withoutTime(try executor.runQuery(id: "task.get", args: ["taskID": .string(parent.id.uuidString)])["stage"])
        }
        #expect(try parentStage() == .object(["group": .string("idle"), "needsUser": .bool(false)]))
        let first = try executor.runQuery(id: "task.list", args: [:])
        guard case .string(let cursor)? = first["cursor"] else {
            Issue.record("task.list has no cursor: \(first)")
            return
        }

        _ = fixture.coordinator.records.update(id: child.id) {
            $0.mergedAt = Date()
            $0.mergeCommit = "abc123"
        }
        let finished = AutomationJSONValue.object([
            "group": .string("done"), "needsUser": .bool(false), "finishedThroughChildren": .bool(true),
        ])
        #expect(try parentStage() == finished)
        #expect(fixture.record(parent.id)?.doneAt == nil)
        let changed = try executor.runQuery(id: "task.list", args: ["changedSince": .string(cursor)])
        guard case .array(let tasks)? = changed["tasks"] else {
            Issue.record("task.list has no tasks: \(changed)")
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: tasks.compactMap { task -> (String, AutomationJSONValue?)? in
            guard case .object(let object) = task, case .string(let id)? = object["taskID"] else { return nil }
            return (id, withoutTime(object["stage"]))
        })
        #expect(Set(byID.keys) == [parent.id.uuidString, child.id.uuidString])
        #expect(byID[parent.id.uuidString] == finished)
    }
}
