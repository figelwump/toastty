import CoreState
import Darwin
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
struct TaskAppControlTests {
    private func makeExecutor(_ fixture: TaskInboxCoordinatorTests.Fixture, coordinator: TaskInboxCoordinator?) -> AppControlExecutor {
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
            taskInboxCoordinator: coordinator,
            reloadConfigurationAction: nil
        )
    }

    private func context(_ callerSessionID: String? = nil) -> AutomationRequestContext {
        AutomationRequestContext(callerSessionID: callerSessionID, commandName: "app_control.run_action")
    }

    @Test func createCopiesFilesAndListShowsTheTask() async throws {
        let fixture = try TaskInboxCoordinatorTests.Fixture()
        fixture.scriptHappyPath(confident: false)
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        let notes = fixture.root.appendingPathComponent("repro notes.md")
        try "1. Open a session on the phone".write(to: notes, atomically: true, encoding: .utf8)

        let outcome = try await executor.runActionAsync(
            id: "task.create",
            args: [
                "text": .string("The unread dot stays on"),
                "files": .array([.string("repro notes.md")]),
                "cwd": .string(fixture.root.path),
            ],
            context: context()
        )
        let taskID = try #require(outcome.result?["taskID"].flatMap { if case .string(let id) = $0 { UUID(uuidString: id) } else { nil } })
        #expect(outcome.result?["phase"] == .string("routing"))
        let stored = try #require(fixture.inbox.item(id: taskID)?.attachments.first)
        #expect(stored.displayName == "repro notes.md")
        #expect(stored.path.hasPrefix(fixture.runtimePaths.taskAttachmentsDirectoryURL.path))
        #expect(try String(contentsOfFile: stored.path, encoding: .utf8) == "1. Open a session on the phone")

        let list = try executor.runQuery(id: "task.list", args: [:])
        guard case .array(let tasks)? = list["tasks"], case .object(let task)? = tasks.first else {
            Issue.record("task.list returned no tasks")
            return
        }
        #expect(task["taskID"] == .string(taskID.uuidString))
        #expect(task["files"] == .array([.string("repro notes.md")]))

        _ = try await executor.runActionAsync(id: "task.delete", args: ["taskID": .string(taskID.uuidString)], context: context())
        #expect(fixture.inbox.items.isEmpty)
    }

    @Test func createRefusesFilesItCannotSafelyRead() async throws {
        let fixture = try TaskInboxCoordinatorTests.Fixture()
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        let fifo = fixture.root.appendingPathComponent("pipe.txt").path
        #expect(mkfifo(fifo, 0o600) == 0)
        let large = fixture.root.appendingPathComponent("large.txt")
        try Data(repeating: 65, count: 4 * 1024 * 1024 + 1).write(to: large)
        let binary = fixture.root.appendingPathComponent("tool.exe")
        try Data("MZ".utf8).write(to: binary)

        for path in [fifo, large.path, binary.path, fixture.root.appendingPathComponent("missing.txt").path, "relative.txt"] {
            await #expect(throws: AutomationSocketError.self) {
                try await executor.runActionAsync(
                    id: "task.create",
                    args: ["text": .string("x"), "files": .array([.string(path)])],
                    context: context()
                )
            }
        }
        #expect(fixture.inbox.items.isEmpty)
    }

    @Test func scopedSessionsCannotUseTasksAndTheyAreHiddenWithoutACoordinator() async throws {
        let fixture = try TaskInboxCoordinatorTests.Fixture()
        let executor = makeExecutor(fixture, coordinator: fixture.coordinator)
        let workspace = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        fixture.sessionRuntimeStore.startSession(
            sessionID: "scoped-caller",
            agent: .codex,
            panelID: try #require(workspace.focusedPanelID),
            windowID: try #require(fixture.store.state.windows.first?.id),
            workspaceID: fixture.workspaceID,
            codexStatusTrackingSource: .externallyReported,
            cwd: nil,
            repoRoot: nil,
            scopedWorkspaceIDs: [],
            at: Date()
        )
        await #expect(throws: AutomationSocketError.self) {
            try await executor.runActionAsync(id: "task.create", args: ["text": .string("x")], context: context("scoped-caller"))
        }
        #expect(throws: AutomationSocketError.self) {
            try executor.runQuery(id: "task.list", args: [:], context: AutomationRequestContext(callerSessionID: "scoped-caller", commandName: "q"))
        }

        let withoutTasks = makeExecutor(fixture, coordinator: nil)
        #expect(withoutTasks.listActionDescriptors().contains { $0.id.hasPrefix("task.") } == false)
        #expect(withoutTasks.listQueryDescriptors().contains { $0.id == "task.list" } == false)
        #expect(executor.listActionDescriptors().filter { $0.id.hasPrefix("task.") }.count == 4)
    }
}
