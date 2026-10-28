import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// The command palette's task commands through the real palette handler,
/// store, reducer, task coordinator and board, with the start-work
/// fixture's git repository and fake agents.
@MainActor
struct CommandPaletteTaskCommandsTests {
    typealias Fixture = TaskStartWorkTests.Fixture

    /// `gh` that never answers, so stages come from links and the record.
    private struct OfflineGitHub: WorkspaceMergeCommandRunning {
        func run(arguments: [String], directory: String, timeout: TimeInterval) async -> WorkspaceMergeCommandResult {
            WorkspaceMergeCommandResult(exitCode: 1, stdout: "", stderr: "offline", failure: nil)
        }
    }

    @MainActor
    final class Harness {
        let fixture: Fixture
        let sessionRuntimeStore = SessionRuntimeStore()
        let board: TaskBoardStore
        private(set) var actions: CommandPaletteActionHandler!
        var failures: [String] = []
        var openedURLs: [URL] = []

        init() throws {
            fixture = try Fixture()
            board = TaskBoardStore(
                coordinator: fixture.coordinator,
                store: fixture.store,
                sessionRuntimeStore: sessionRuntimeStore,
                pullRequests: PullRequestStateCache(runner: OfflineGitHub()),
                refreshInterval: nil,
                releaseCheckInterval: nil
            )
            fixture.coordinator.board = board
            sessionRuntimeStore.taskCoordinator = fixture.coordinator

            let store = fixture.store
            let runtimeRegistry = TerminalRuntimeRegistry()
            runtimeRegistry.bind(store: store)
            let profiles = TerminalProfileStore(
                fileManager: .default,
                homeDirectoryPath: fixture.repository.root.path,
                environment: [:]
            )
            let taskActions = CommandPaletteTaskActions(
                store: store,
                sessionRuntimeStore: sessionRuntimeStore,
                openURL: { [unowned self] in openedURLs.append($0) },
                presentFailure: { [unowned self] title, message in failures.append("\(title): \(message)") },
                // Runs at once instead of after the palette closes.
                afterPaletteCloses: { $0() }
            )
            actions = CommandPaletteActionHandler(
                store: store,
                splitLayoutCommandController: SplitLayoutCommandController(store: store),
                focusedPanelCommandController: FocusedPanelCommandController(
                    store: store,
                    runtimeRegistry: runtimeRegistry,
                    slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
                ),
                terminalRuntimeRegistry: runtimeRegistry,
                sessionRuntimeStore: sessionRuntimeStore,
                agentLaunchService: AgentLaunchService(
                    store: store,
                    terminalCommandRouter: runtimeRegistry,
                    sessionRuntimeStore: sessionRuntimeStore,
                    agentCatalogProvider: AgentCatalogStore(fileManager: .default, homeDirectoryPath: fixture.repository.root.path)
                ),
                terminalProfilesMenuController: TerminalProfilesMenuController(
                    store: store,
                    terminalRuntimeRegistry: runtimeRegistry,
                    terminalProfileProvider: profiles,
                    installShellIntegrationAction: {},
                    openProfilesConfigurationAction: {}
                ),
                supportsConfigurationReload: { true },
                reloadConfigurationAction: {},
                openLocalDocumentAction: { _, _ in false },
                taskActions: taskActions
            )
        }

        var windowID: UUID { fixture.store.state.windows[0].id }
        var window: WindowState { fixture.store.state.windows[0] }

        func commands() -> [PaletteCommandDescriptor] {
            CommandPaletteCatalog.commands(
                originWindowID: windowID,
                actions: actions,
                agentCatalog: .empty,
                terminalProfileCatalog: .empty,
                profileShortcutRegistry: makeProfileShortcutRegistry()
            )
        }

        /// The "Task: …" and "Release …" rows, as title and subtitle.
        func taskRows() -> [String] {
            commands()
                .filter { if case .task = $0.invocation { true } else { false } }
                .map { [$0.title, $0.subtitle].compactMap { $0 }.joined(separator: " — ") }
        }

        func run(_ title: String) throws -> Bool {
            let command = try #require(commands().first { $0.title == title })
            return actions.execute(command.invocation, originWindowID: windowID)
        }

        func select(_ workspaceID: UUID) {
            _ = fixture.store.send(.selectWorkspace(windowID: windowID, workspaceID: workspaceID))
        }

        /// A task that started in its own worktree.
        func startedTask(_ text: String) async throws -> TaskRecord {
            let created = try await fixture.coordinator.create(TaskCreateRequest(
                text: text,
                workspaceID: fixture.workspaceID,
                agent: "claude",
                startWork: true
            ))
            await fixture.waitUntil("setup ends") { fixture.record(created.id)?.setup != .settingUp }
            let task = try #require(fixture.record(created.id))
            #expect(task.setup == .started)
            return task
        }
    }

    @Test func taskCommandsFollowTheSelectedTaskSpace() async throws {
        let harness = try Harness()
        let first = try await harness.startedTask("Fix the composer")
        _ = try await harness.startedTask("Keep the sidebar order")
        let firstSpace = try #require(first.taskSpaceWorkspaceID)

        // A project workspace has no current task.
        harness.select(harness.fixture.workspaceID)
        #expect(harness.taskRows().isEmpty)

        harness.select(firstSpace)
        #expect(harness.taskRows() == [
            "Task: Mark Done — Fix the composer · Idle",
            "Task: Archive… — Fix the composer · Idle",
        ])

        #expect(harness.failures.isEmpty)
    }

    @Test func markDoneFromThePaletteFinishesTheTask() async throws {
        let harness = try Harness()
        let task = try await harness.startedTask("Fix the composer")
        let taskSpace = try #require(task.taskSpaceWorkspaceID)
        harness.select(taskSpace)
        let markDone = try #require(harness.commands().first { $0.title == "Task: Mark Done" })

        #expect(harness.actions.execute(markDone.invocation, originWindowID: harness.windowID))

        #expect(harness.fixture.record(task.id)?.doneAt != nil)
        #expect(harness.fixture.store.state.workspacesByID[taskSpace]?.doneAt != nil)
        #expect(harness.failures.isEmpty)
        // A done task has no actions left, and the stale row does nothing.
        #expect(harness.taskRows().isEmpty)
        #expect(harness.actions.execute(markDone.invocation, originWindowID: harness.windowID) == false)
    }

    @Test func releaseIsListedWithNothingToShipAndHiddenWhileItRuns() async throws {
        let harness = try Harness()
        let fixture = harness.fixture
        _ = try fixture.repository.pushToRemote("released")
        fixture.config.defaults = TasksConfig.Defaults(agent: "claude")
        let project = try #require(fixture.store.state.workspacesByID[fixture.workspaceID]?.title)
        // The project has no saved root, and its terminal is below the
        // repository root: the configured project still matches.
        let workspace = try #require(fixture.store.state.workspacesByID[fixture.workspaceID])
        let sources = URL(filePath: fixture.repository.project).appending(path: "Sources").path
        try FileManager.default.createDirectory(atPath: sources, withIntermediateDirectories: true)
        #expect(workspace.rootDirectory == nil)
        _ = fixture.store.send(.updateTerminalPanelMetadata(
            panelID: try #require(workspace.focusedPanelID),
            title: nil,
            cwd: sources
        ))
        // Without release_skill or release_prompt there is nothing to release.
        harness.board.reloadConfig()
        #expect(harness.taskRows().isEmpty)

        // A release skill alone is enough.
        fixture.config.workspaces = [TasksConfig.Workspace(path: fixture.repository.project, releaseSkill: "toastty-release")]
        harness.board.reloadConfig()
        #expect(harness.taskRows() == ["Release \(project)… — Nothing to ship yet"])

        #expect(try harness.run("Release \(project)…"))
        #expect(harness.failures.isEmpty)
        let release = try #require(fixture.coordinator.records.records.first { $0.release != nil })
        #expect(release.release?.childTaskIDs == [])
        #expect(release.projectRoot == fixture.repository.project)
        await fixture.waitUntil("setup ends") { fixture.record(release.id)?.setup != .settingUp }
        #expect(fixture.record(release.id)?.setup == .started)
        // One release of a project at a time.
        #expect(harness.taskRows().contains { $0.hasPrefix("Release") } == false)
    }

    @Test func aDefaultReleaseSkillListsAProjectWithNoTableOfItsOwn() throws {
        let harness = try Harness()
        let fixture = harness.fixture
        let project = try #require(fixture.store.state.workspacesByID[fixture.workspaceID]?.title)
        fixture.config.defaults = TasksConfig.Defaults(agent: "claude", releaseSkill: "toastty-release")
        harness.board.reloadConfig()
        // The palette cannot ask git for the root, so it needs a saved one.
        #expect(harness.taskRows().isEmpty)

        _ = fixture.store.send(.setWorkspaceRootDirectory(workspaceID: fixture.workspaceID, rootDirectory: fixture.repository.project))
        #expect(harness.taskRows() == ["Release \(project)… — Nothing to ship yet"])
    }
}
