import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
private final class WorkspaceListFixture {
    let store: AppStore
    let executor: AppControlExecutor
    let sessionRuntimeStore: SessionRuntimeStore
    let windowID: UUID
    let firstWorkspaceID: UUID

    init() throws {
        store = AppStore(persistTerminalFontPreference: false)
        let selection = try #require(store.state.selectedWorkspaceSelection())
        windowID = selection.windowID
        firstWorkspaceID = selection.workspaceID

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
                socketPathProvider: { "/tmp/toastty-workspace-list-test.sock" }
            ),
            reloadConfigurationAction: nil
        )
    }

    func createWorkspace(title: String) throws -> UUID {
        let existingWorkspaceIDs = Set(store.state.workspacesByID.keys)
        #expect(store.send(.createWorkspace(windowID: windowID, title: title, activate: false)))
        return try #require(store.state.workspacesByID.keys.first { existingWorkspaceIDs.contains($0) == false })
    }

    func setTerminalCwd(_ cwd: String, in workspaceID: UUID) throws {
        let panelID = try #require(store.state.workspacesByID[workspaceID]?.focusedPanelID)
        #expect(store.send(.updateTerminalPanelMetadata(panelID: panelID, title: nil, cwd: cwd)))
    }

    func list(
        args: [String: AutomationJSONValue] = [:],
        callerSessionID: String? = nil
    ) throws -> [[String: AutomationJSONValue]] {
        let result = try executor.runQuery(
            id: AppControlQueryID.workspaceList.rawValue,
            args: args,
            context: AutomationRequestContext(callerSessionID: callerSessionID, commandName: "app_control.run_query")
        )
        guard case .array(let entries) = result["workspaces"] else {
            Issue.record("workspace.list returned no workspaces array")
            return []
        }
        return entries.compactMap { entry in
            guard case .object(let object) = entry else { return nil }
            return object
        }
    }
}

@MainActor
struct WorkspaceListAppControlTests {
    /// Tooling maps worktrees to workspaces through this listing, so it must
    /// report every workspace with its identity, chips, and terminal directories.
    @Test
    func listsWorkspacesInWindowOrderWithoutChangingSelection() throws {
        let fixture = try WorkspaceListFixture()
        let taskWorkspaceID = try fixture.createWorkspace(title: "sidebar-subspaces")
        #expect(fixture.store.send(.setWorkspaceAnnotation(
            workspaceID: taskWorkspaceID,
            key: "github-pr",
            annotation: WorkspaceAnnotation(text: "PR #23", url: "https://github.com/figelwump/toastty/pull/23")
        )))
        try fixture.setTerminalCwd("/tmp/toastty-sidebar-subspaces", in: taskWorkspaceID)
        let selectionBefore = fixture.store.state.selectedWorkspaceSelection()?.workspaceID

        let entries = try fixture.list()

        #expect(entries.map { $0["workspaceID"] } == [
            .string(fixture.firstWorkspaceID.uuidString),
            .string(taskWorkspaceID.uuidString),
        ])
        let task = try #require(entries.last)
        #expect(task["windowID"] == .string(fixture.windowID.uuidString))
        #expect(task["index"] == .int(2))
        #expect(task["title"] == .string("sidebar-subspaces"))
        #expect(task["isSelected"] == .bool(false))
        #expect(task["terminalCwds"] == .array([.string("/tmp/toastty-sidebar-subspaces")]))
        guard case .array(let annotations) = task["annotations"],
              case .object(let annotation) = annotations.first else {
            Issue.record("expected one annotation")
            return
        }
        #expect(annotations.count == 1)
        #expect(annotation["key"] == .string("github-pr"))
        #expect(annotation["text"] == .string("PR #23"))
        #expect(annotation["url"] == .string("https://github.com/figelwump/toastty/pull/23"))
        #expect(entries.first?["isSelected"] == .bool(true))
        #expect(fixture.store.state.selectedWorkspaceSelection()?.workspaceID == selectionBefore)
    }

    /// Worktree matching relies on every tab's terminals, not just the selected one.
    @Test
    func reportsSortedUniqueTerminalDirectoriesAcrossTabs() throws {
        let fixture = try WorkspaceListFixture()
        let workspaceID = try fixture.createWorkspace(title: "tabs")
        #expect(fixture.store.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil)))
        #expect(fixture.store.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil)))
        let workspace = try #require(fixture.store.state.workspacesByID[workspaceID])
        let terminalPanelIDs = workspace.allPanelsByID.compactMap { panelID, panel -> UUID? in
            if case .terminal = panel { return panelID }
            return nil
        }
        #expect(terminalPanelIDs.count == 3)
        for (panelID, cwd) in zip(terminalPanelIDs, ["/tmp/wt/b", "/tmp/wt/a", "/tmp/wt/b"]) {
            #expect(fixture.store.send(.updateTerminalPanelMetadata(panelID: panelID, title: nil, cwd: cwd)))
        }

        let entry = try #require(try fixture.list().first { $0["workspaceID"] == .string(workspaceID.uuidString) })

        #expect(entry["terminalCwds"] == .array([.string("/tmp/wt/a"), .string("/tmp/wt/b")]))
    }

    /// A scoped session must not learn about workspaces it cannot automate.
    @Test
    func scopedCallerSeesOnlyWorkspacesInScope() throws {
        let fixture = try WorkspaceListFixture()
        let outsideWorkspaceID = try fixture.createWorkspace(title: "outside")
        let panelID = try #require(fixture.store.state.workspacesByID[fixture.firstWorkspaceID]?.focusedPanelID)
        fixture.sessionRuntimeStore.startSession(
            sessionID: "workspace-list-scoped-caller",
            agent: .codex,
            panelID: panelID,
            windowID: fixture.windowID,
            workspaceID: fixture.firstWorkspaceID,
            cwd: nil,
            repoRoot: nil,
            scopedWorkspaceIDs: [],
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let scoped = try fixture.list(callerSessionID: "workspace-list-scoped-caller")
        let unscoped = try fixture.list()

        #expect(scoped.map { $0["workspaceID"] } == [.string(fixture.firstWorkspaceID.uuidString)])
        #expect(unscoped.contains { $0["workspaceID"] == .string(outsideWorkspaceID.uuidString) })
    }

    @Test
    func windowSelectorLimitsListingAndRejectsUnknownWindow() throws {
        let fixture = try WorkspaceListFixture()

        let entries = try fixture.list(args: ["windowID": .string(fixture.windowID.uuidString)])
        #expect(entries.count == 1)

        #expect(throws: AutomationSocketError.self) {
            _ = try fixture.list(args: ["windowID": .string(UUID().uuidString)])
        }
        #expect(throws: AutomationSocketError.self) {
            _ = try fixture.list(args: ["windowID": .string("not-a-uuid")])
        }
    }
}
