import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

/// A command runner that answers from a script: triage gets a canned
/// answer, the create script makes a real directory.
final class ScriptedTaskCommandRunner: TaskCommandRunning, @unchecked Sendable {
    typealias Handler = @Sendable (TaskCommand) async -> TaskCommandResult
    private let lock = NSLock()
    private var handler: Handler
    private var recorded: [TaskCommand] = []

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    var commands: [TaskCommand] { lock.withLock { recorded } }

    func setHandler(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    func run(_ command: TaskCommand) async -> TaskCommandResult {
        let handler = lock.withLock {
            recorded.append(command)
            return self.handler
        }
        return await handler(command)
    }
}

/// Runs the quick-task flow against the real agent launcher, with a fake
/// terminal in place of Ghostty and scripted triage and create commands.
struct TaskInboxCoordinatorTests {
    @MainActor
    final class Fixture {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        let router = TestTerminalCommandRouter()
        let root: URL
        let projectDirectory: String
        let createScript: String
        let launcher: AgentLaunchService
        let workspaceID: UUID
        let inbox: TaskInboxStore
        let configStore: TasksConfigStore
        let runner: ScriptedTaskCommandRunner
        let coordinator: TaskInboxCoordinator
        let runtimePaths: ToasttyRuntimePaths

        init(
            config: (String) -> TasksConfig = { script in
                TasksConfig(
                    triage: .init(profileID: "claude"),
                    create: .init(script: script),
                    start: .init(skill: "task-start")
                )
            },
            items: [TaskInboxItem] = [],
            readinessTimeout: Duration = .seconds(3)
        ) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("toastty-task-inbox-\(UUID().uuidString)", isDirectory: true)
            let project = root.appendingPathComponent("project", isDirectory: true)
            let bin = root.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            projectDirectory = project.resolvingSymlinksInPath().path
            var executables: [String: String] = [:]
            for name in ["claude", "codex", "task-create.sh"] {
                let path = bin.appendingPathComponent(name).path
                FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8))
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
                executables[name] = path
            }
            createScript = executables["task-create.sh"]!

            sessionRuntimeStore.bind(store: store)
            router.defaultPromptState = .idleAtPrompt
            let workspace = store.selectedWorkspace!
            workspaceID = workspace.id
            _ = store.send(.renameWorkspace(workspaceID: workspaceID, title: "toastty"))
            _ = store.send(.updateTerminalPanelMetadata(panelID: workspace.focusedPanelID!, title: nil, cwd: projectDirectory))

            launcher = AgentLaunchService(
                store: store,
                terminalCommandRouter: router,
                sessionRuntimeStore: sessionRuntimeStore,
                agentCatalogProvider: TestAgentCatalogProvider(profiles: [
                    AgentProfile(id: "claude", displayName: "Claude Code", argv: [executables["claude"]!]),
                    AgentProfile(id: "codex", displayName: "Codex", argv: [executables["codex"]!]),
                ]),
                cliExecutablePathProvider: { "/bin/sh" },
                socketPathProvider: { "/tmp/toastty-tests.sock" }
            )
            runtimePaths = ToasttyRuntimePaths.resolve(environment: [
                "TOASTTY_RUNTIME_HOME": root.appendingPathComponent("runtime-home").path,
            ])
            inbox = TaskInboxStore.inMemory(items)
            configStore = TasksConfigStore(config: config(createScript))
            runner = ScriptedTaskCommandRunner { _ in
                TaskCommandResult(termination: .exited(1), stdout: Data(), stderr: Data("unscripted\n".utf8))
            }
            coordinator = TaskInboxCoordinator(
                store: store,
                inbox: inbox,
                configStore: configStore,
                sessionRuntimeStore: sessionRuntimeStore,
                launcher: launcher,
                runner: runner,
                runtimePaths: runtimePaths,
                acceptedUserSkillNames: { ["task-start"] },
                commandPath: { "/usr/bin:/bin" },
                terminalReadinessTimeout: readinessTimeout
            )
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// Triage answers with `workspaceID` (this fixture's workspace by
        /// default); the create script makes `<root>/worktrees/<slug>`.
        func scriptHappyPath(confident: Bool = true, workspaceID: UUID? = nil, scriptFailures: Int = 0) {
            let workspaceID = workspaceID ?? self.workspaceID
            let root = self.root
            let createScript = self.createScript
            let failures = Counter(scriptFailures)
            runner.setHandler { command in
                if command.executablePath.hasSuffix("/claude") {
                    let answer = #"{"type":"result","is_error":false,"structured_output":{"workspaceID":"\#(workspaceID.uuidString)","title":"Fix the unread dot","slug":"ios-unread-dot","branchPrefix":"fix","profileID":"codex","model":"gpt-6.1-sol","effort":"high","confident":\#(confident),"reason":"The sidebar lives in toastty."}}"#
                    return TaskCommandResult(termination: .exited(0), stdout: Data(answer.utf8), stderr: Data())
                }
                if command.executablePath == createScript {
                    if failures.take() {
                        return TaskCommandResult(termination: .exited(1), stdout: Data(), stderr: Data("fatal: branch exists\n".utf8))
                    }
                    let slug = command.environment["TOASTTY_TASK_SLUG"] ?? "x"
                    let directory = root.appendingPathComponent("worktrees/\(slug)", isDirectory: true)
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let line = #"{"directory":"\#(directory.resolvingSymlinksInPath().path)","branch":"fix/\#(slug)","baseRef":"d18c9655"}"#
                    return TaskCommandResult(termination: .exited(0), stdout: Data("Preparing\n\(line)\n".utf8), stderr: Data())
                }
                return TaskCommandResult(termination: .exited(127), stdout: Data(), stderr: Data())
            }
        }

        var taskSpaceIDs: [UUID] { store.state.subspaceWorkspaceIDs(of: workspaceID) }

        func createCalls() -> [TaskCommand] { runner.commands.filter { $0.executablePath == createScript } }
        func triageCalls() -> [TaskCommand] { runner.commands.filter { $0.executablePath.hasSuffix("/claude") } }

        func waitUntil(_ description: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while condition() == false {
                guard ContinuousClock.now < deadline else {
                    Issue.record("Timed out waiting until \(description)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        init(_ value: Int) { remaining = value }
        func take() -> Bool {
            lock.withLock {
                guard remaining > 0 else { return false }
                remaining -= 1
                return true
            }
        }
    }

    @MainActor
    @Test func triagedTaskGetsATaskSpaceAndAScopedAgentWithItsFirstPrompt() async throws {
        let fixture = try Fixture()
        fixture.scriptHappyPath()

        let item = try await fixture.coordinator.add(text: "The unread dot stays on.", source: .cli)
        await fixture.waitUntil("the task leaves the Inbox") { fixture.inbox.items.isEmpty }

        // Triage ran headless with the task on stdin and no session saved.
        let triage = try #require(fixture.triageCalls().first)
        #expect(triage.arguments.contains("--no-session-persistence"))
        #expect(triage.arguments.contains(#"{"disableAllHooks":true}"#))
        #expect(String(decoding: triage.standardInput ?? Data(), as: UTF8.self).contains(fixture.workspaceID.uuidString))
        #expect(triage.environment.keys.contains { $0.hasPrefix("TOASTTY_") } == false)

        // The create script ran in the workspace with the task's names.
        let create = try #require(fixture.createCalls().first)
        #expect(create.directory == fixture.projectDirectory)
        #expect(create.environment["TOASTTY_TASK_ID"] == item.id.uuidString)
        #expect(create.environment["TOASTTY_TASK_SLUG"] == "ios-unread-dot")
        #expect(create.environment["TOASTTY_TASK_BRANCH_PREFIX"] == "fix")
        #expect(create.environment["TOASTTY_TASK_STATE_DIR"]?.hasSuffix("/tasks/state/\(item.id.uuidString)") == true)

        // One unvisited task space, its terminal in the new directory.
        let taskSpaceID = try #require(fixture.taskSpaceIDs.first)
        #expect(fixture.taskSpaceIDs.count == 1)
        let taskSpace = try #require(fixture.store.state.workspacesByID[taskSpaceID])
        #expect(taskSpace.title == "ios-unread-dot")
        #expect(taskSpace.hasBeenVisited == false)
        #expect(fixture.store.selectedWorkspace?.id == fixture.workspaceID)
        let panelID = try #require(taskSpace.orderedTabs.first?.panels.keys.first)

        // The agent got the start skill in Codex syntax, the task, and context,
        // and its session is scoped to the task space.
        let sent = try #require(fixture.router.sentTextByPanelID[panelID])
        #expect(sent.contains("$toastty-user:task-start"))
        #expect(sent.contains("The unread dot stays on."))
        #expect(sent.contains("Branch: fix/ios-unread-dot, from d18c9655"))
        #expect(sent.contains("gpt-6.1-sol"))
        let session = try #require(fixture.sessionRuntimeStore.sessionRegistry.activeSession(for: panelID))
        #expect(session.workspaceID == taskSpaceID)
        #expect(fixture.sessionRuntimeStore.effectiveWorkspaceScope(sessionID: session.sessionID) == [taskSpaceID])
        #expect(fixture.router.focusPolicyByPanelID[panelID] == .preserveFirstResponder)
    }

    @MainActor
    @Test func unsureTriageWaitsForTheUserWhoPicksTheWorkspace() async throws {
        let fixture = try Fixture()
        fixture.scriptHappyPath(confident: false)

        let item = try await fixture.coordinator.add(text: "Pricing says per user", source: .cli)
        await fixture.waitUntil("triage finishes") { fixture.inbox.item(id: item.id)?.phase == .needsWorkspace }
        let waiting = try #require(fixture.inbox.item(id: item.id))
        #expect(waiting.suggestion?.workspaceID == fixture.workspaceID)
        #expect(waiting.problem?.contains("not sure") == true)
        #expect(fixture.createCalls().isEmpty)

        try fixture.coordinator.place(taskID: item.id, workspaceID: fixture.workspaceID)
        await fixture.waitUntil("the task starts") { fixture.inbox.items.isEmpty }
        #expect(fixture.taskSpaceIDs.count == 1)
    }

    @MainActor
    @Test func failedScriptCanBeRetriedAndAFailedStartReusesTheDirectory() async throws {
        let fixture = try Fixture(readinessTimeout: .milliseconds(300))
        fixture.scriptHappyPath(scriptFailures: 1)

        let item = try await fixture.coordinator.add(text: "Fix the dot", source: .cli)
        await fixture.waitUntil("setup fails") { fixture.inbox.item(id: item.id)?.phase == .setupFailed }
        #expect(fixture.inbox.item(id: item.id)?.problem == "The create script failed (exit 1): fatal: branch exists")
        #expect(fixture.taskSpaceIDs.isEmpty)

        // The terminal never gets ready: the start fails before any text is
        // sent, and the untouched task space is removed again.
        fixture.router.sendSucceeds = false
        try fixture.coordinator.retry(taskID: item.id)
        await fixture.waitUntil("the start fails") { fixture.inbox.item(id: item.id)?.phase == .setupFailed }
        #expect(fixture.createCalls().count == 2)
        #expect(fixture.taskSpaceIDs.isEmpty)
        #expect(fixture.inbox.item(id: item.id)?.createdDirectory != nil)
        #expect(fixture.inbox.item(id: item.id)?.taskSpace == nil)

        // Retry skips the script and keeps the slug.
        fixture.router.sendSucceeds = true
        try fixture.coordinator.retry(taskID: item.id)
        await fixture.waitUntil("the task starts") { fixture.inbox.items.isEmpty }
        #expect(fixture.createCalls().count == 2)
        #expect(fixture.taskSpaceIDs.compactMap { fixture.store.state.workspacesByID[$0]?.title } == ["ios-unread-dot"])
    }

    @MainActor
    @Test func uncertainDeliveryKeepsTheTaskSpaceAndRetryReusesIt() async throws {
        let fixture = try Fixture()
        fixture.scriptHappyPath()
        fixture.router.sendFailure = .uncertain
        fixture.router.failingSendCount = 1

        let item = try await fixture.coordinator.add(text: "Fix the dot", source: .cli)
        await fixture.waitUntil("setup fails") { fixture.inbox.item(id: item.id)?.phase == .setupFailed }
        let failed = try #require(fixture.inbox.item(id: item.id))
        #expect(failed.problem?.contains("may not have arrived") == true)
        let taskSpace = try #require(failed.taskSpace)
        #expect(fixture.taskSpaceIDs == [taskSpace.workspaceID])

        try fixture.coordinator.retry(taskID: item.id)
        await fixture.waitUntil("the task starts") { fixture.inbox.items.isEmpty }
        #expect(fixture.taskSpaceIDs == [taskSpace.workspaceID])
        #expect(fixture.router.sentTextByPanelID[taskSpace.panelID] != nil)
    }

    @MainActor
    @Test func deleteDuringSetupStopsTheScriptAndStartsNothing() async throws {
        let fixture = try Fixture(config: { script in
            TasksConfig(create: .init(script: script))
        })
        fixture.runner.setHandler { _ in
            // A slow script that only a cancel ends.
            while Task.isCancelled == false {
                try? await Task.sleep(for: .milliseconds(20))
            }
            return TaskCommandResult(termination: .cancelled, stdout: Data(), stderr: Data())
        }

        let item = try await fixture.coordinator.add(
            text: "Fix the dot",
            pins: .init(workspaceID: fixture.workspaceID),
            source: .cli
        )
        await fixture.waitUntil("the script runs") { fixture.createCalls().count == 1 }
        fixture.coordinator.delete(taskID: item.id)
        try? await Task.sleep(for: .milliseconds(200))

        #expect(fixture.inbox.items.isEmpty)
        #expect(fixture.taskSpaceIDs.isEmpty)
        #expect(fixture.router.sentTextByPanelID.isEmpty)
    }

    @MainActor
    @Test func withoutTriageAPinnedWorkspaceStartsAtOnceAndOthersWait() async throws {
        let fixture = try Fixture(config: { _ in TasksConfig() })
        let unpinned = try await fixture.coordinator.add(text: "No workspace yet", source: .cli)
        #expect(fixture.inbox.item(id: unpinned.id)?.phase == .needsWorkspace)

        _ = try await fixture.coordinator.add(
            text: "Fix the dot", pins: .init(workspaceID: fixture.workspaceID, profileID: "claude"), source: .cli
        )
        await fixture.waitUntil("the pinned task starts") { fixture.inbox.items.count == 1 }
        // No create script: the task space opens in the workspace's directory,
        // and the prompt is the task alone.
        let taskSpaceID = try #require(fixture.taskSpaceIDs.first)
        let tab = try #require(fixture.store.state.workspacesByID[taskSpaceID]?.orderedTabs.first)
        let panelID = try #require(tab.panels.keys.first)
        guard case .terminal(let terminal)? = tab.panels[panelID] else {
            Issue.record("Expected a terminal")
            return
        }
        #expect(terminal.cwd == fixture.projectDirectory)
        let sent = try #require(fixture.router.sentTextByPanelID[panelID])
        #expect(sent.contains("task-start") == false)
        #expect(fixture.runner.commands.isEmpty)
    }

    @MainActor
    @Test func twoTasksForOneWorkspaceGetDifferentSlugs() async throws {
        let fixture = try Fixture()
        fixture.scriptHappyPath(confident: false)
        let first = try await fixture.coordinator.add(text: "one", source: .cli)
        let second = try await fixture.coordinator.add(text: "two", source: .cli)
        await fixture.waitUntil("both wait") {
            fixture.inbox.items.allSatisfy { $0.phase == .needsWorkspace }
        }
        fixture.router.sendSucceeds = false
        try fixture.coordinator.place(taskID: first.id, workspaceID: fixture.workspaceID)
        try fixture.coordinator.place(taskID: second.id, workspaceID: fixture.workspaceID)
        #expect(fixture.inbox.item(id: first.id)?.plan?.slug == "ios-unread-dot")
        #expect(fixture.inbox.item(id: second.id)?.plan?.slug == "ios-unread-dot-2")
    }

    @MainActor
    @Test func resumeRequeuesTriageAndMarksInterruptedSetupFailed() async throws {
        let routing = TaskInboxItem(text: "route me", source: .cli, createdAt: Date(), phase: .routing)
        let interrupted = TaskInboxItem(text: "was setting up", source: .cli, createdAt: Date(), phase: .settingUp)
        let fixture = try Fixture(items: [routing, interrupted])
        fixture.scriptHappyPath(confident: false)

        fixture.coordinator.resume()
        #expect(fixture.inbox.item(id: interrupted.id)?.phase == .setupFailed)
        #expect(fixture.inbox.item(id: interrupted.id)?.problem == "Toastty quit during setup. Retry to continue.")
        await fixture.waitUntil("triage runs again") { fixture.inbox.item(id: routing.id)?.phase == .needsWorkspace }
        #expect(fixture.triageCalls().count == 1)
    }

    @MainActor
    @Test func addRejectsBadPinsAndEmptyTasks() async throws {
        let fixture = try Fixture()
        await #expect(throws: TaskInboxError.emptyTask) {
            try await fixture.coordinator.add(text: "  ", source: .cli)
        }
        await #expect(throws: TaskInboxError.invalidPin("That workspace is not open.")) {
            try await fixture.coordinator.add(text: "x", pins: .init(workspaceID: UUID()), source: .cli)
        }
        await #expect(throws: TaskInboxError.invalidPin("Codex does not take effort \"max\".")) {
            try await fixture.coordinator.add(text: "x", pins: .init(profileID: "codex", effort: "max"), source: .cli)
        }
        #expect(fixture.inbox.items.isEmpty)
    }
}
