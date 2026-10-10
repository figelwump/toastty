import CoreState
import Foundation
import RemoteProtocol
import Testing
@testable import ToasttyApp

/// A cleanup runner that records what it was asked to run and answers with
/// a scripted result.
private final class FakeCleanupRunner: WorkspaceTaskCleanupCommandRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
        let directory: String?
        let workspaceID: String?
        let cliPath: String?
        let sessionID: String?
    }

    private let lock = NSLock()
    private var _invocations: [Invocation] = []
    var result: WorkspaceTaskCleanupCommandResult

    init(result: WorkspaceTaskCleanupCommandResult) {
        self.result = result
    }

    var invocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return _invocations
    }

    func run(
        executable: String,
        arguments: [String],
        directory: String?,
        environment: [String: String],
        timeout: TimeInterval
    ) async -> WorkspaceTaskCleanupCommandResult {
        lock.withLock {
            _invocations.append(Invocation(
                executable: executable,
                arguments: arguments,
                directory: directory,
                workspaceID: environment["TOASTTY_WORKSPACE_ID"],
                cliPath: environment["TOASTTY_CLI_PATH"],
                sessionID: environment["TOASTTY_SESSION_ID"]
            ))
        }
        return result
    }
}

@MainActor
private final class TaskHooksFixture {
    let store: AppStore
    let executor: AppControlExecutor
    let sessionRuntimeStore: SessionRuntimeStore
    let runner: WorkspaceTaskHookRunner
    let cleanupRunner: FakeCleanupRunner
    let skillsRoot: URL
    let windowID: UUID
    let parentWorkspaceID: UUID
    let parentPanelID: UUID
    var sentTexts: [(text: String, panelID: UUID)] = []
    var launches: [(profileID: String, workspaceID: UUID, cwd: String?, prompt: String)] = []
    var launchResult: Result<(sessionID: String, panelID: UUID), Error> = .success(("launched", UUID()))
    var notifications: [String] = []

    init(
        cleanupResult: WorkspaceTaskCleanupCommandResult = WorkspaceTaskCleanupCommandResult(exitCode: 0, output: "removed worktree\n", failure: nil)
    ) throws {
        store = AppStore(persistTerminalFontPreference: false)
        let selection = try #require(store.state.selectedWorkspaceSelection())
        windowID = selection.windowID
        parentWorkspaceID = selection.workspaceID
        parentPanelID = try #require(selection.workspace.focusedPanelID)

        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        let webPanelRuntimeRegistry = WebPanelRuntimeRegistry()
        sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        webPanelRuntimeRegistry.bind(store: store)
        executor = AppControlExecutor(
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            webPanelRuntimeRegistry: webPanelRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            focusedPanelCommandController: FocusedPanelCommandController(
                store: store,
                runtimeRegistry: terminalRuntimeRegistry,
                slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
            ),
            agentLaunchService: AgentLaunchService(
                store: store,
                terminalCommandRouter: terminalRuntimeRegistry,
                sessionRuntimeStore: sessionRuntimeStore,
                agentCatalogProvider: TestAgentCatalogProvider(),
                cliExecutablePathProvider: { "/bin/sh" },
                socketPathProvider: { "/tmp/toastty-task-hooks-test.sock" }
            ),
            annotationStyleStore: nil,
            inactiveAnnotationUsageCountsProvider: { [:] },
            reloadConfigurationAction: nil
        )

        skillsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-task-hooks-\(UUID().uuidString)", isDirectory: true)
        let scriptURL = skillsRoot
            .appendingPathComponent("worktree-cleanup/scripts", isDirectory: true)
            .appendingPathComponent("worktree-status.py")
        try FileManager.default.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/usr/bin/env python3\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        // Both skills are accepted packages, so the runner's validator scan
        // finds them the way it finds real installed skills.
        for skill in ["worktree-cleanup", "worktree-done"] {
            let skillURL = skillsRoot.appendingPathComponent(skill, isDirectory: true)
            try FileManager.default.createDirectory(at: skillURL, withIntermediateDirectories: true)
            try "---\nname: \(skill)\ndescription: test skill\n---\n# \(skill)\n"
                .write(to: skillURL.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }

        cleanupRunner = FakeCleanupRunner(result: cleanupResult)
        var sendTextSink: (@MainActor (String, UUID) -> Bool)?
        var launchSink: (@MainActor (String, UUID, String?, String) throws -> (sessionID: String, panelID: UUID))?
        var notifySink: (@MainActor (String, String) -> Void)?
        runner = WorkspaceTaskHookRunner(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            runner: cleanupRunner,
            userSkillsDirectoryURL: skillsRoot,
            baseEnvironment: {
                ["TOASTTY_CLI_PATH": "/tmp/toastty-cli", "TOASTTY_SESSION_ID": "leaked", "TOASTTY_PANEL_ID": "leaked"]
            },
            sendText: { text, panelID in sendTextSink?(text, panelID) ?? false },
            launchAgent: { profileID, workspaceID, cwd, prompt in
                try launchSink!(profileID, workspaceID, cwd, prompt)
            },
            notify: { title, body in notifySink?(title, body) }
        )
        notifySink = { [unowned self] title, body in notifications.append("\(title): \(body)") }
        sendTextSink = { [unowned self] text, panelID in
            sentTexts.append((text, panelID))
            return true
        }
        launchSink = { [unowned self] profileID, workspaceID, cwd, prompt in
            launches.append((profileID, workspaceID, cwd, prompt))
            return try launchResult.get()
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: skillsRoot)
    }

    func run(_ action: AppControlActionID, _ args: [String: AutomationJSONValue], caller: String? = nil) throws -> AppControlActionOutcome {
        try executor.runAction(
            id: action.rawValue,
            args: args,
            context: AutomationRequestContext(callerSessionID: caller, commandName: "app_control.run_action")
        )
    }

    func runAsync(_ action: AppControlActionID, _ args: [String: AutomationJSONValue], caller: String? = nil) async throws -> AppControlActionOutcome {
        try await executor.runActionAsync(
            id: action.rawValue,
            args: args,
            context: AutomationRequestContext(callerSessionID: caller, commandName: "app_control.run_action")
        )
    }

    /// A subspace under the selected workspace with the worktree hooks set.
    func makeTask(title: String = "task", hooks: Bool = true) throws -> UUID {
        let outcome = try run(.workspaceCreate, [
            "windowID": .string(windowID.uuidString),
            "title": .string(title),
            "activate": .bool(false),
            "parent": .string(parentWorkspaceID.uuidString),
        ])
        let workspaceID = try #require(outcome.result?.string("workspaceID").flatMap(UUID.init(uuidString:)))
        if hooks {
            _ = try run(.workspaceTaskSetHooks, [
                "workspaceID": .string(workspaceID.uuidString),
                "finishSkill": .string("worktree-done"),
                "cleanupSkill": .string("worktree-cleanup"),
                "cleanupScript": .string("scripts/worktree-status.py"),
                "cleanupArgs": .string("--cleanup-workspace"),
            ])
        }
        return workspaceID
    }

    /// Starts a session in the workspace's focused panel, or in a new split
    /// so two sessions can be live at once.
    func startSession(_ sessionID: String, agent: AgentKind, in workspaceID: UUID, cwd: String? = "/work/task", inNewPanel: Bool = false, at seconds: TimeInterval) throws {
        let panelID: UUID
        if inNewPanel {
            let before = Set(store.state.workspacesByID[workspaceID]?.allPanelsByID.keys ?? [:].keys)
            #expect(store.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal)))
            let after = Set(store.state.workspacesByID[workspaceID]?.allPanelsByID.keys ?? [:].keys)
            panelID = try #require(after.subtracting(before).first)
        } else {
            panelID = try #require(store.state.workspacesByID[workspaceID]?.focusedPanelID)
        }
        sessionRuntimeStore.startSession(
            sessionID: sessionID,
            agent: agent,
            panelID: panelID,
            windowID: windowID,
            workspaceID: workspaceID,
            cwd: cwd,
            repoRoot: cwd,
            at: Date(timeIntervalSince1970: seconds)
        )
    }

    func hooks(_ workspaceID: UUID) -> WorkspaceTaskHooks? {
        store.state.workspacesByID[workspaceID]?.taskHooks
    }
}

@MainActor
struct WorkspaceTaskHooksAppControlTests {
    @Test
    func setHooksValidatesAndRejectsTopLevelWorkspaces() throws {
        let fixture = try TaskHooksFixture()
        let task = try fixture.makeTask(hooks: false)

        let set = try fixture.run(.workspaceTaskSetHooks, [
            "workspaceID": .string(task.uuidString),
            "finishSkill": .string("worktree-done"),
            "cleanupSkill": .string("worktree-cleanup"),
            "cleanupScript": .string("scripts/worktree-status.py"),
            "cleanupArgs": .array([.string("--cleanup-workspace"), .string("--quiet")]),
        ])
        #expect(set.didMutateState)
        #expect(fixture.hooks(task)?.finishSkill == "worktree-done")
        #expect(fixture.hooks(task)?.cleanup?.arguments == ["--cleanup-workspace", "--quiet"])
        #expect(set.result?["cleanup"] != nil)

        // Only one hook, and the snapshot reports it.
        _ = try fixture.run(.workspaceTaskSetHooks, ["workspaceID": .string(task.uuidString), "finishSkill": .string("worktree-done")])
        #expect(fixture.hooks(task)?.cleanup == nil)
        let snapshot = try fixture.executor.runQuery(id: AppControlQueryID.workspaceSnapshot.rawValue, args: ["workspaceID": .string(task.uuidString)])
        #expect(snapshot["taskHooks"] == .object(["finishSkill": .string("worktree-done"), "cleanup": .null, "close": .null]))

        // No parameters clears.
        let cleared = try fixture.run(.workspaceTaskSetHooks, ["workspaceID": .string(task.uuidString)])
        #expect(cleared.didMutateState)
        #expect(fixture.hooks(task)?.isEmpty == true)

        for badArgs: [String: AutomationJSONValue] in [
            ["cleanupSkill": .string("worktree-cleanup")],
            ["cleanupScript": .string("scripts/x.py")],
            ["cleanupArgs": .string("--x")],
            ["finishSkill": .string("../escape")],
            ["cleanupSkill": .string("ok"), "cleanupScript": .string("../../bin/rm")],
            ["cleanupSkill": .string("ok"), "cleanupScript": .string("/abs/path")],
        ] {
            var args = badArgs
            args["workspaceID"] = .string(task.uuidString)
            #expect(throws: AutomationSocketError.self, "\(badArgs)") { try fixture.run(.workspaceTaskSetHooks, args) }
        }
        #expect(fixture.hooks(task)?.isEmpty == true)

        #expect(throws: AutomationSocketError.self) {
            try fixture.run(.workspaceTaskSetHooks, [
                "workspaceID": .string(fixture.parentWorkspaceID.uuidString),
                "finishSkill": .string("worktree-done"),
            ])
        }
    }

    @Test
    func setTaskStageMovesASubspaceAndTheListReportsIt() throws {
        let fixture = try TaskHooksFixture()
        let task = try fixture.makeTask()

        let review = try fixture.run(.workspaceSetTaskStage, ["workspaceID": .string(task.uuidString), "stage": .string("review")])
        #expect(review.didMutateState)
        #expect(review.result?["taskStage"] == .string("review"))
        #expect(fixture.store.state.workspacesByID[task]?.taskStage == .review)
        let snapshot = try fixture.executor.runQuery(id: AppControlQueryID.workspaceSnapshot.rawValue, args: ["workspaceID": .string(task.uuidString)])
        #expect(snapshot["taskStage"] == .string("review"))

        _ = try fixture.run(.workspaceSetTaskStage, ["workspaceID": .string(task.uuidString), "stage": .string("done")])
        #expect(fixture.store.state.workspacesByID[task]?.taskStage == .done)
        let list = try fixture.executor.runQuery(id: AppControlQueryID.workspaceList.rawValue, args: [:])
        guard case .array(let rows)? = list["workspaces"] else {
            Issue.record("workspace.list has no workspaces array: \(list)")
            return
        }
        let row = try #require(rows.lazy.compactMap { value -> [String: AutomationJSONValue]? in
            guard case .object(let object) = value, object.string("workspaceID") == task.uuidString else { return nil }
            return object
        }.first)
        #expect(row.string("taskStage") == "done")
        #expect(row.bool("done") == true)

        let reopened = try fixture.run(.workspaceSetTaskStage, ["workspaceID": .string(task.uuidString), "stage": .string("open")])
        #expect(reopened.didMutateState)
        #expect(fixture.store.state.workspacesByID[task]?.taskStage == .open)
        #expect(fixture.store.state.workspacesByID[task]?.reviewReadyAt == nil)

        // The caller's own workspace is the default target.
        try fixture.startSession("agent", agent: .claude, in: task, at: 100)
        _ = try fixture.run(.workspaceSetTaskStage, ["stage": .string("review")], caller: "agent")
        #expect(fixture.store.state.workspacesByID[task]?.taskStage == .review)

        #expect(throws: AutomationSocketError.self) {
            try fixture.run(.workspaceSetTaskStage, ["workspaceID": .string(task.uuidString), "stage": .string("shipped")])
        }
        #expect(throws: AutomationSocketError.self) {
            try fixture.run(.workspaceSetTaskStage, ["workspaceID": .string(fixture.parentWorkspaceID.uuidString), "stage": .string("review")])
        }
        // open is harmless on a top-level workspace.
        let topLevelOpen = try fixture.run(.workspaceSetTaskStage, ["workspaceID": .string(fixture.parentWorkspaceID.uuidString), "stage": .string("open")])
        #expect(topLevelOpen.didMutateState == false)
    }

    @Test
    func closeRunsTheCloseHookAndKeepsItsResultApartFromCleanup() async throws {
        let fixture = try TaskHooksFixture(cleanupResult: WorkspaceTaskCleanupCommandResult(
            exitCode: 3, output: "the worktree has uncommitted changes\n", failure: nil
        ))
        let task = try fixture.makeTask()
        try fixture.startSession("agent", agent: .claude, in: task, cwd: "/work/task", at: 100)

        // No close hook yet.
        await #expect(throws: AutomationSocketError.self) {
            try await fixture.runAsync(.workspaceTaskClose, ["workspaceID": .string(task.uuidString)])
        }
        let set = try fixture.run(.workspaceTaskSetHooks, [
            "workspaceID": .string(task.uuidString),
            "finishSkill": .string("worktree-done"),
            "cleanupSkill": .string("worktree-cleanup"),
            "cleanupScript": .string("scripts/worktree-status.py"),
            "cleanupArgs": .string("--cleanup-workspace"),
            "closeSkill": .string("worktree-cleanup"),
            "closeScript": .string("scripts/worktree-status.py"),
            "closeArgs": .array([.string("--close-workspace")]),
        ])
        #expect(set.result?["close"] != nil)
        #expect(fixture.hooks(task)?.close?.arguments == ["--close-workspace"])
        #expect(throws: AutomationSocketError.self) {
            try fixture.run(.workspaceTaskSetHooks, ["workspaceID": .string(task.uuidString), "closeScript": .string("scripts/x.py")])
        }

        let outcome = try await fixture.runAsync(.workspaceTaskClose, ["workspaceID": .string(task.uuidString)])
        #expect(outcome.result?["outcome"] == .string("skipped"))
        #expect(outcome.result?["detail"] == .string("the worktree has uncommitted changes"))
        let invocation = try #require(fixture.cleanupRunner.invocations.first)
        #expect(invocation.arguments.last == "--close-workspace")
        #expect(invocation.directory == "/work/task")
        #expect(invocation.workspaceID == task.uuidString)
        #expect(invocation.sessionID == nil)
        let run = try #require(fixture.sessionRuntimeStore.workspaceTaskScriptRuns[task])
        #expect(run.kind == .close)
        #expect(run.phase == .skipped(detail: "the worktree has uncommitted changes"))

        // Close works at any stage, so the result survives a stage move;
        // a successful close that leaves the workspace in place clears it.
        _ = try fixture.run(.workspaceSetTaskStage, ["workspaceID": .string(task.uuidString), "stage": .string("review")])
        #expect(fixture.sessionRuntimeStore.workspaceTaskScriptRuns[task]?.kind == .close)
        fixture.cleanupRunner.result = WorkspaceTaskCleanupCommandResult(exitCode: 0, output: "closed PR #7\n", failure: nil)
        let closed = try await fixture.runAsync(.workspaceTaskClose, ["workspaceID": .string(task.uuidString)])
        #expect(closed.result?["outcome"] == .string("closed"))
        #expect(fixture.sessionRuntimeStore.workspaceTaskScriptRuns[task] == nil)
    }

    @Test
    func finishSendsTheSkillToTheLatestAgentSessionInItsOwnSyntax() async throws {
        let fixture = try TaskHooksFixture()
        let task = try fixture.makeTask()
        try fixture.startSession("older-codex", agent: .codex, in: task, at: 100)
        try fixture.startSession("newer-claude", agent: .claude, in: task, inNewPanel: true, at: 200)

        let outcome = try await fixture.runAsync(.workspaceTaskFinish, ["workspaceID": .string(task.uuidString)])
        #expect(outcome.result?["delivery"] == .string("sent"))
        #expect(outcome.result?["sessionID"] == .string("newer-claude"))
        #expect(fixture.sentTexts.count == 1)
        // An accepted user skill is named through the plugin that delivers it.
        #expect(fixture.sentTexts.first?.text.hasPrefix("/toastty-user:worktree-done ") == true)
        #expect(fixture.sentTexts.first?.text.contains("clicked Finish Task") == true)
        #expect(fixture.launches.isEmpty)

        // The Codex session becomes the latest and gets the `$` form.
        fixture.sessionRuntimeStore.updateStatus(
            sessionID: "older-codex",
            status: SessionStatus(kind: .ready, summary: "Ready", detail: nil),
            at: Date(timeIntervalSince1970: 300)
        )
        _ = try await fixture.runAsync(.workspaceTaskFinish, ["workspaceID": .string(task.uuidString)])
        #expect(fixture.sentTexts.last?.text.hasPrefix("$toastty-user:worktree-done ") == true)

        // The synchronous path cannot wait for a launch, so it refuses.
        #expect(throws: AutomationSocketError.self) {
            try fixture.run(.workspaceTaskFinish, ["workspaceID": .string(task.uuidString)])
        }
    }

    @Test
    func finishLaunchesAnAgentWhenNoneIsRunningAndRefusesWithoutAHook() async throws {
        let fixture = try TaskHooksFixture()
        let task = try fixture.makeTask()
        try fixture.startSession("gone", agent: .claude, in: task, cwd: "/work/task", at: 100)
        fixture.sessionRuntimeStore.stopSession(sessionID: "gone", at: Date(timeIntervalSince1970: 150))

        let outcome = try await fixture.runAsync(.workspaceTaskFinish, ["workspaceID": .string(task.uuidString)])
        #expect(outcome.result?["delivery"] == .string("launched"))
        #expect(outcome.result?["sessionID"] == .string("launched"))
        #expect(fixture.sentTexts.isEmpty)
        #expect(fixture.launches.count == 1)
        // The last session's profile and directory, with the prompt in that
        // agent's syntax.
        #expect(fixture.launches.first?.profileID == "claude")
        #expect(fixture.launches.first?.cwd == "/work/task")
        #expect(fixture.launches.first?.prompt.hasPrefix("/toastty-user:worktree-done ") == true)

        // A finish skill that is not an installed user skill is sent as given.
        _ = try fixture.run(.workspaceTaskSetHooks, ["workspaceID": .string(task.uuidString), "finishSkill": .string("ship-it")])
        _ = try await fixture.runAsync(.workspaceTaskFinish, ["workspaceID": .string(task.uuidString)])
        #expect(fixture.launches.last?.prompt.hasPrefix("/ship-it ") == true)

        let bare = try fixture.makeTask(title: "bare", hooks: false)
        await #expect(throws: AutomationSocketError.self) {
            try await fixture.runAsync(.workspaceTaskFinish, ["workspaceID": .string(bare.uuidString)])
        }
        await #expect(throws: AutomationSocketError.self) {
            try await fixture.runAsync(.workspaceTaskFinish, ["workspaceID": .string(fixture.parentWorkspaceID.uuidString)])
        }
    }

    @Test
    func cleanupRunsTheScriptFromTheInstalledSkillWithoutASessionIdentity() async throws {
        let fixture = try TaskHooksFixture()
        let task = try fixture.makeTask()
        try fixture.startSession("agent", agent: .claude, in: task, cwd: "/work/task", at: 100)

        let outcome = try await fixture.runAsync(.workspaceTaskCleanup, ["workspaceID": .string(task.uuidString)])
        #expect(outcome.result?["outcome"] == .string("cleaned"))
        #expect(outcome.result?["detail"] == .string("removed worktree"))
        let invocation = try #require(fixture.cleanupRunner.invocations.first)
        #expect(invocation.executable == "/usr/bin/env")
        #expect(invocation.arguments == [
            "python3",
            fixture.skillsRoot.appendingPathComponent("worktree-cleanup/scripts/worktree-status.py").path,
            "--cleanup-workspace",
        ])
        #expect(invocation.directory == "/work/task")
        #expect(invocation.workspaceID == task.uuidString)
        #expect(invocation.cliPath == "/tmp/toastty-cli")
        #expect(invocation.sessionID == nil, "a cleanup script acts for the user, not for a session")
        // A cleaned result leaves nothing on the row.
        #expect(fixture.sessionRuntimeStore.workspaceTaskScriptRuns[task] == nil)
    }

    @Test
    func cleanupReportsSkipsAndFailuresOnTheRowUntilDismissed() async throws {
        let fixture = try TaskHooksFixture(cleanupResult: WorkspaceTaskCleanupCommandResult(
            exitCode: 3, output: "checking\nPR #7 is open: still running: CI gate\n", failure: nil
        ))
        let task = try fixture.makeTask()
        // A cleanup result belongs to a done task; on an open one it would
        // cover Finish Task, so the runner drops it (the CLI still returns it).
        _ = try fixture.run(.workspaceSetDone, ["workspaceID": .string(task.uuidString)])

        let skipped = try await fixture.runAsync(.workspaceTaskCleanup, ["workspaceID": .string(task.uuidString)])
        #expect(skipped.result?["outcome"] == .string("skipped"))
        #expect(skipped.result?["detail"] == .string("PR #7 is open: still running: CI gate"))
        #expect(fixture.sessionRuntimeStore.workspaceTaskScriptRuns[task]?.phase == .skipped(detail: "PR #7 is open: still running: CI gate"))

        fixture.cleanupRunner.result = WorkspaceTaskCleanupCommandResult(exitCode: 1, output: "progress\ngit worktree remove failed\n", failure: nil)
        let failed = try await fixture.runAsync(.workspaceTaskCleanup, ["workspaceID": .string(task.uuidString)])
        #expect(failed.result?["outcome"] == .string("failed"))
        #expect(fixture.sessionRuntimeStore.workspaceTaskScriptRuns[task]?.phase == .failed(detail: "git worktree remove failed"))

        fixture.runner.dismissScriptResult(workspaceID: task)
        #expect(fixture.sessionRuntimeStore.workspaceTaskScriptRuns[task] == nil)

        fixture.cleanupRunner.result = WorkspaceTaskCleanupCommandResult(exitCode: nil, output: "", failure: "The cleanup script did not finish within 300 seconds")
        let timedOut = try await fixture.runAsync(.workspaceTaskCleanup, ["workspaceID": .string(task.uuidString)])
        #expect(timedOut.result?["detail"] == .string("The cleanup script did not finish within 300 seconds"))
        #expect(fixture.sessionRuntimeStore.workspaceTaskScriptRuns[task]?.phase == .failed(detail: "The cleanup script did not finish within 300 seconds"))

        // New work in the task clears its done mark; the old result goes
        // with it, so the row offers Finish Task again, not a stale retry.
        _ = try fixture.run(.workspaceSetDone, ["workspaceID": .string(task.uuidString)])
        _ = try fixture.run(.workspaceClearDone, ["workspaceID": .string(task.uuidString)])
        #expect(fixture.sessionRuntimeStore.workspaceTaskScriptRuns[task] == nil)
        #expect(fixture.notifications.isEmpty, "the row was there to show every result")
    }

    /// A script that closes the workspace and then stops leaves no row to
    /// report on, so the user hears about it another way.
    @Test
    func cleanupFailureAfterTheWorkspaceClosedIsNotified() async throws {
        let fixture = try TaskHooksFixture(cleanupResult: WorkspaceTaskCleanupCommandResult(
            exitCode: 1, output: "closed task; worktree kept: uncommitted changes\n", failure: nil
        ))
        let task = try fixture.makeTask(title: "closing")
        let closing = CloseDuringCleanupRunner(store: fixture.store, workspaceID: task, result: fixture.cleanupRunner.result)
        let runner = WorkspaceTaskHookRunner(
            store: fixture.store,
            sessionRuntimeStore: fixture.sessionRuntimeStore,
            runner: closing,
            userSkillsDirectoryURL: fixture.skillsRoot,
            baseEnvironment: { [:] },
            sendText: { _, _ in false },
            launchAgent: { _, _, _, _ in throw WorkspaceTaskHookRunner.FinishProblem.launchFailed("unused") },
            notify: { [fixture] title, body in fixture.notifications.append("\(title): \(body)") }
        )
        let outcome = try await fixture.runAsync(.workspaceTaskCleanup, ["workspaceID": .string(task.uuidString)])
        _ = runner
        #expect(outcome.result?["outcome"] == .string("failed"))
        #expect(fixture.store.state.workspacesByID[task] == nil)
        #expect(fixture.sessionRuntimeStore.workspaceTaskScriptRuns[task] == nil)
        #expect(fixture.notifications == ["closing: cleanup did not finish: closed task; worktree kept: uncommitted changes"])
    }

    @Test
    func cleanupRefusesAMissingScriptAMissingHookAndTheCallersOwnWorkspace() async throws {
        let fixture = try TaskHooksFixture()
        let task = try fixture.makeTask()
        _ = try fixture.run(.workspaceTaskSetHooks, [
            "workspaceID": .string(task.uuidString),
            "cleanupSkill": .string("not-installed"),
            "cleanupScript": .string("scripts/run.py"),
        ])
        await #expect(throws: AutomationSocketError.self) {
            try await fixture.runAsync(.workspaceTaskCleanup, ["workspaceID": .string(task.uuidString)])
        }
        #expect(fixture.cleanupRunner.invocations.isEmpty)

        // A skill directory, or a script, that is a symbolic link could
        // point anywhere, so neither counts as installed.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("toastty-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: outside.appendingPathComponent("scripts/run.sh"), atomically: true, encoding: .utf8)
        try "---\nname: linked\ndescription: x\n---\n".write(to: outside.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: fixture.skillsRoot.appendingPathComponent("linked"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.skillsRoot.appendingPathComponent("worktree-cleanup/scripts/escape.sh"),
            withDestinationURL: outside.appendingPathComponent("scripts/run.sh")
        )
        for (skill, script) in [("linked", "scripts/run.sh"), ("worktree-cleanup", "scripts/escape.sh")] {
            _ = try fixture.run(.workspaceTaskSetHooks, [
                "workspaceID": .string(task.uuidString),
                "cleanupSkill": .string(skill),
                "cleanupScript": .string(script),
            ])
            await #expect(throws: AutomationSocketError.self, "\(skill)/\(script)") {
                try await fixture.runAsync(.workspaceTaskCleanup, ["workspaceID": .string(task.uuidString)])
            }
        }
        #expect(fixture.cleanupRunner.invocations.isEmpty)

        let bare = try fixture.makeTask(title: "bare", hooks: false)
        await #expect(throws: AutomationSocketError.self) {
            try await fixture.runAsync(.workspaceTaskCleanup, ["workspaceID": .string(bare.uuidString)])
        }

        // The script would close the terminal that asked for it.
        let hooked = try fixture.makeTask(title: "hooked")
        try fixture.startSession("inside", agent: .codex, in: hooked, at: 100)
        await #expect(throws: AutomationSocketError.self) {
            try await fixture.runAsync(.workspaceTaskCleanup, ["workspaceID": .string(hooked.uuidString)], caller: "inside")
        }
        #expect(fixture.cleanupRunner.invocations.isEmpty)
    }

    @Test
    func cleanupFinishedRunsOnlyDoneSubspacesWithAHookOneAtATime() async throws {
        let fixture = try TaskHooksFixture()
        let done = try fixture.makeTask(title: "done")
        let doneWithoutHook = try fixture.makeTask(title: "done-no-hook", hooks: false)
        let open = try fixture.makeTask(title: "open")
        for workspaceID in [done, doneWithoutHook] {
            _ = try fixture.run(.workspaceSetDone, ["workspaceID": .string(workspaceID.uuidString)])
        }

        let outcome = try await fixture.runAsync(.workspaceTaskCleanupFinished, ["workspaceID": .string(fixture.parentWorkspaceID.uuidString)])
        let results = try #require(outcome.result?["results"])
        #expect(results == .array([.object([
            "workspaceID": .string(done.uuidString),
            "outcome": .string("cleaned"),
            "detail": .string("removed worktree"),
        ])]))
        #expect(fixture.cleanupRunner.invocations.map(\.workspaceID) == [done.uuidString])
        _ = open

        // Naming a subspace means its parent's group.
        let fromChild = try await fixture.runAsync(.workspaceTaskCleanupFinished, ["workspaceID": .string(open.uuidString)])
        #expect(fromChild.result?["workspaceID"] == .string(fixture.parentWorkspaceID.uuidString))
    }

    /// A task that reopens while an earlier script in the batch is still
    /// running is left alone, and a second request joins the running batch.
    @Test
    func cleanupFinishedRechecksEachTaskBeforeItsScriptStarts() async throws {
        let fixture = try TaskHooksFixture()
        let first = try fixture.makeTask(title: "first")
        let second = try fixture.makeTask(title: "second")
        for workspaceID in [first, second] {
            _ = try fixture.run(.workspaceSetDone, ["workspaceID": .string(workspaceID.uuidString)])
        }
        let gate = GatedCleanupRunner(result: fixture.cleanupRunner.result)
        let runner = WorkspaceTaskHookRunner(
            store: fixture.store,
            sessionRuntimeStore: fixture.sessionRuntimeStore,
            runner: gate,
            userSkillsDirectoryURL: fixture.skillsRoot,
            baseEnvironment: { [:] },
            sendText: { _, _ in false },
            launchAgent: { _, _, _, _ in throw WorkspaceTaskHookRunner.FinishProblem.launchFailed("unused") }
        )
        let batch = runner.cleanUpFinished(parentWorkspaceID: fixture.parentWorkspaceID)
        #expect(runner.cleanUpFinished(parentWorkspaceID: fixture.parentWorkspaceID) == batch)
        await gate.waitForStart()
        // The first script is running; the second task picks up new work.
        _ = try fixture.run(.workspaceClearDone, ["workspaceID": .string(second.uuidString)])
        gate.release()
        let results = await batch.value
        #expect(results.map(\.workspaceID) == [first])
        #expect(gate.startedWorkspaceIDs == [first.uuidString])
    }

    @Test
    func outcomeReadsTheExitStatusAndLastLine() {
        typealias Outcome = WorkspaceTaskHookRunner.ScriptOutcome
        func outcome(_ code: Int32?, _ output: String = "", failure: String? = nil) -> Outcome {
            WorkspaceTaskHookRunner.outcome(from: WorkspaceTaskCleanupCommandResult(exitCode: code, output: output, failure: failure))
        }
        #expect(outcome(0, "a\nb\n") == .cleaned(detail: "b"))
        #expect(outcome(0) == .cleaned(detail: "cleaned"))
        #expect(outcome(3, "why\n") == .skipped(detail: "why"))
        #expect(outcome(2) == .failed(detail: "the cleanup script exited with status 2"))
        #expect(outcome(nil, failure: "boom") == .failed(detail: "boom"))
        #expect(WorkspaceTaskHookRunner.finishPrompt(skill: "worktree-done", agent: .codex, isUserSkill: true).hasPrefix("$toastty-user:worktree-done "))
        #expect(WorkspaceTaskHookRunner.finishPrompt(skill: "worktree-done", agent: .claude, isUserSkill: true).hasPrefix("/toastty-user:worktree-done "))
        #expect(WorkspaceTaskHookRunner.finishPrompt(skill: "worktree-done", agent: .cursor, isUserSkill: false).hasPrefix("/worktree-done "))
    }
}


/// Closes the workspace while its script "runs", as the real cleanup
/// script does, then reports the scripted result.
private final class CloseDuringCleanupRunner: WorkspaceTaskCleanupCommandRunning, @unchecked Sendable {
    private let store: AppStore
    private let workspaceID: UUID
    private let result: WorkspaceTaskCleanupCommandResult

    @MainActor
    init(store: AppStore, workspaceID: UUID, result: WorkspaceTaskCleanupCommandResult) {
        self.store = store
        self.workspaceID = workspaceID
        self.result = result
    }

    func run(executable: String, arguments: [String], directory: String?, environment: [String: String], timeout: TimeInterval) async -> WorkspaceTaskCleanupCommandResult {
        await MainActor.run { _ = store.send(.closeWorkspace(workspaceID: workspaceID)) }
        return result
    }
}

/// Holds each script until released, so a test can change state while a
/// batch is between tasks.
private final class GatedCleanupRunner: WorkspaceTaskCleanupCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _started: [String] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private let result: WorkspaceTaskCleanupCommandResult

    init(result: WorkspaceTaskCleanupCommandResult) {
        self.result = result
    }

    var startedWorkspaceIDs: [String] {
        lock.withLock { _started }
    }

    func waitForStart() async {
        await withCheckedContinuation { continuation in
            let startedAlready = lock.withLock { () -> Bool in
                if _started.isEmpty {
                    startContinuations.append(continuation)
                    return false
                }
                return true
            }
            if startedAlready { continuation.resume() }
        }
    }

    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            defer { releaseContinuations = [] }
            return releaseContinuations
        }
        waiting.forEach { $0.resume() }
    }

    func run(executable: String, arguments: [String], directory: String?, environment: [String: String], timeout: TimeInterval) async -> WorkspaceTaskCleanupCommandResult {
        let starters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            _started.append(environment["TOASTTY_WORKSPACE_ID"] ?? "?")
            defer { startContinuations = [] }
            return startContinuations
        }
        starters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            let proceed = lock.withLock { () -> Bool in
                if released { return true }
                releaseContinuations.append(continuation)
                return false
            }
            if proceed { continuation.resume() }
        }
        return result
    }
}
