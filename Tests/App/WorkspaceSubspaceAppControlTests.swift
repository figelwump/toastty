import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
private final class WorkspaceSubspaceAppControlFixture {
    let store: AppStore
    let executor: AppControlExecutor
    let sessionRuntimeStore: SessionRuntimeStore
    let windowID: UUID
    let workspaceID: UUID
    let panelID: UUID

    init() throws {
        store = AppStore(persistTerminalFontPreference: false)
        let selection = try #require(store.state.selectedWorkspaceSelection())
        windowID = selection.windowID
        workspaceID = selection.workspaceID
        panelID = try #require(selection.workspace.focusedPanelID)

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
                socketPathProvider: { "/tmp/toastty-subspace-test.sock" }
            ),
            annotationStyleStore: nil,
            inactiveAnnotationUsageCountsProvider: { [:] },
            reloadConfigurationAction: nil
        )
    }

    func startCaller(sessionID: String, scopedWorkspaceIDs: Set<UUID>? = nil) {
        sessionRuntimeStore.startSession(
            sessionID: sessionID,
            agent: .codex,
            panelID: panelID,
            windowID: windowID,
            workspaceID: workspaceID,
            cwd: nil,
            repoRoot: nil,
            scopedWorkspaceIDs: scopedWorkspaceIDs,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func createWorkspace(
        callerSessionID: String? = nil,
        parent: String? = nil
    ) throws -> (workspaceID: UUID, parentWorkspaceID: UUID?) {
        var args: [String: AutomationJSONValue] = [
            "windowID": .string(windowID.uuidString),
            "activate": .bool(false),
        ]
        if let parent {
            args["parent"] = .string(parent)
        }
        let outcome = try executor.runAction(
            id: AppControlActionID.workspaceCreate.rawValue,
            args: args,
            context: AutomationRequestContext(
                callerSessionID: callerSessionID,
                commandName: "app_control.run_action"
            )
        )
        let createdID = try #require(outcome.result?.string("workspaceID").flatMap(UUID.init(uuidString:)))
        let parentID = outcome.result?.string("parentWorkspaceID").flatMap(UUID.init(uuidString:))
        return (createdID, parentID)
    }

    func setParent(
        of workspaceID: UUID,
        parent: String,
        callerSessionID: String? = nil
    ) throws -> AppControlActionOutcome {
        try executor.runAction(
            id: AppControlActionID.workspaceSetParent.rawValue,
            args: [
                "workspaceID": .string(workspaceID.uuidString),
                "parent": .string(parent),
            ],
            context: AutomationRequestContext(
                callerSessionID: callerSessionID,
                commandName: "app_control.run_action"
            )
        )
    }

    func workspace(_ id: UUID) -> WorkspaceState? {
        store.state.workspacesByID[id]
    }
}

@MainActor
struct WorkspaceSubspaceAppControlTests {
    @Test
    func managedCallerNestsCreatedWorkspaceUnderItsOwnWorkspace() throws {
        let fixture = try WorkspaceSubspaceAppControlFixture()
        fixture.startCaller(sessionID: "spawner")

        let created = try fixture.createWorkspace(callerSessionID: "spawner")

        #expect(created.parentWorkspaceID == fixture.workspaceID)
        #expect(fixture.workspace(created.workspaceID)?.parentWorkspaceID == fixture.workspaceID)
        #expect(fixture.workspace(created.workspaceID)?.spawningSessionID == "spawner")
        #expect(fixture.store.state.topLevelWorkspaceIDs(in: fixture.windowID) == [fixture.workspaceID])
        #expect(fixture.store.state.subspaceWorkspaceIDs(of: fixture.workspaceID) == [created.workspaceID])
    }

    @Test
    func parentNoneAndUnmanagedCallersCreateTopLevelWorkspaces() throws {
        let fixture = try WorkspaceSubspaceAppControlFixture()
        fixture.startCaller(sessionID: "spawner")

        let optedOut = try fixture.createWorkspace(callerSessionID: "spawner", parent: "none")
        #expect(optedOut.parentWorkspaceID == nil)
        #expect(fixture.workspace(optedOut.workspaceID)?.parentWorkspaceID == nil)

        let unmanaged = try fixture.createWorkspace()
        #expect(unmanaged.parentWorkspaceID == nil)
        #expect(fixture.workspace(unmanaged.workspaceID)?.spawningSessionID == nil)
    }

    @Test
    func explicitParentNestsUnderThatWorkspaceAndFlattensToItsRoot() throws {
        let fixture = try WorkspaceSubspaceAppControlFixture()
        fixture.startCaller(sessionID: "spawner")
        let sibling = try fixture.createWorkspace(parent: "none")
        let child = try fixture.createWorkspace(callerSessionID: "spawner", parent: sibling.workspaceID.uuidString)
        #expect(child.parentWorkspaceID == sibling.workspaceID)
        #expect(fixture.workspace(child.workspaceID)?.spawningSessionID == "spawner")

        // Nesting under a subspace lands on its root.
        let grandchild = try fixture.createWorkspace(parent: child.workspaceID.uuidString)
        #expect(grandchild.parentWorkspaceID == sibling.workspaceID)
    }

    @Test
    func invalidOrUnknownParentIsRejectedBeforeAnythingIsCreated() throws {
        let fixture = try WorkspaceSubspaceAppControlFixture()
        let countBefore = fixture.store.state.workspacesByID.count
        #expect(throws: AutomationSocketError.self) {
            try fixture.createWorkspace(parent: "not-a-workspace")
        }
        #expect(throws: AutomationSocketError.self) {
            try fixture.createWorkspace(parent: UUID().uuidString)
        }
        #expect(fixture.store.state.workspacesByID.count == countBefore)
    }

    @Test
    func setParentRequiresAnExplicitParentArgument() throws {
        let fixture = try WorkspaceSubspaceAppControlFixture()
        let created = try fixture.createWorkspace()
        _ = try fixture.setParent(of: created.workspaceID, parent: fixture.workspaceID.uuidString)
        #expect(throws: AutomationSocketError.self) {
            try fixture.executor.runAction(
                id: AppControlActionID.workspaceSetParent.rawValue,
                args: ["workspaceID": .string(created.workspaceID.uuidString), "parent": .string("   ")]
            )
        }
        #expect(throws: AutomationSocketError.self) {
            try fixture.executor.runAction(
                id: AppControlActionID.workspaceSetParent.rawValue,
                args: ["workspaceID": .string(created.workspaceID.uuidString)]
            )
        }
        #expect(fixture.workspace(created.workspaceID)?.parentWorkspaceID == fixture.workspaceID)
    }

    @Test
    func reparentingKeepsTheOriginalSpawner() throws {
        let fixture = try WorkspaceSubspaceAppControlFixture()
        fixture.startCaller(sessionID: "spawner")
        let child = try fixture.createWorkspace(callerSessionID: "spawner")
        let otherParent = try fixture.createWorkspace(parent: "none")

        let moved = try fixture.setParent(
            of: child.workspaceID,
            parent: otherParent.workspaceID.uuidString,
            callerSessionID: "spawner"
        )
        #expect(moved.didMutateState)
        #expect(fixture.workspace(child.workspaceID)?.parentWorkspaceID == otherParent.workspaceID)
        #expect(fixture.workspace(child.workspaceID)?.spawningSessionID == "spawner")

        // A workspace with no spawner takes the caller as one when nested.
        let orphan = try fixture.createWorkspace(parent: "none")
        _ = try fixture.setParent(of: orphan.workspaceID, parent: fixture.workspaceID.uuidString, callerSessionID: "spawner")
        #expect(fixture.workspace(orphan.workspaceID)?.spawningSessionID == "spawner")
    }

    @Test
    func setParentNestsDetachesAndRejectsCycles() throws {
        let fixture = try WorkspaceSubspaceAppControlFixture()
        let created = try fixture.createWorkspace()
        #expect(created.parentWorkspaceID == nil)

        let nested = try fixture.setParent(of: created.workspaceID, parent: fixture.workspaceID.uuidString)
        #expect(nested.didMutateState)
        #expect(nested.result?.string("parentWorkspaceID") == fixture.workspaceID.uuidString)
        #expect(fixture.workspace(created.workspaceID)?.parentWorkspaceID == fixture.workspaceID)

        // The parent cannot move under its own subspace.
        #expect(throws: AutomationSocketError.self) {
            try fixture.setParent(of: fixture.workspaceID, parent: created.workspaceID.uuidString)
        }
        #expect(throws: AutomationSocketError.self) {
            try fixture.setParent(of: created.workspaceID, parent: created.workspaceID.uuidString)
        }

        let detached = try fixture.setParent(of: created.workspaceID, parent: "none")
        #expect(detached.didMutateState)
        #expect(detached.result?["parentWorkspaceID"] == .null)
        #expect(fixture.workspace(created.workspaceID)?.parentWorkspaceID == nil)

        let unchanged = try fixture.setParent(of: created.workspaceID, parent: "NONE")
        #expect(unchanged.didMutateState == false)
    }

    @Test
    func scopedCallerNeedsAccessToTheParentWorkspace() throws {
        let fixture = try WorkspaceSubspaceAppControlFixture()
        let outside = try fixture.createWorkspace()
        // The caller may automate only the workspace it was created in, so the
        // outside workspace is neither a valid target nor a valid parent.
        fixture.startCaller(sessionID: "scoped", scopedWorkspaceIDs: [fixture.workspaceID])
        let own = try fixture.createWorkspace(callerSessionID: "scoped", parent: "none")

        #expect(throws: AutomationSocketError.self) {
            try fixture.setParent(of: own.workspaceID, parent: outside.workspaceID.uuidString, callerSessionID: "scoped")
        }
        #expect(fixture.workspace(own.workspaceID)?.parentWorkspaceID == nil)

        let allowed = try fixture.setParent(
            of: own.workspaceID,
            parent: fixture.workspaceID.uuidString,
            callerSessionID: "scoped"
        )
        #expect(allowed.didMutateState)
        #expect(fixture.workspace(own.workspaceID)?.spawningSessionID == "scoped")

        // Naming an in-scope subspace as the parent still resolves to its
        // root, so the root must be in scope too.
        let outsideChild = try fixture.createWorkspace(parent: outside.workspaceID.uuidString)
        _ = fixture.sessionRuntimeStore.addScope(sessionID: "scoped", workspaceIDs: [outsideChild.workspaceID])
        #expect(throws: AutomationSocketError.self) {
            try fixture.setParent(of: own.workspaceID, parent: outsideChild.workspaceID.uuidString, callerSessionID: "scoped")
        }
        #expect(fixture.workspace(own.workspaceID)?.parentWorkspaceID == fixture.workspaceID)

        // Snapshot hides related workspaces the caller cannot automate.
        let snapshot = try fixture.executor.runQuery(
            id: AppControlQueryID.workspaceSnapshot.rawValue,
            args: ["workspaceID": .string(outsideChild.workspaceID.uuidString)],
            context: AutomationRequestContext(callerSessionID: "scoped", commandName: "app_control.run_query")
        )
        #expect(snapshot["parentWorkspaceID"] == .null)
    }

    @Test
    func workspaceSnapshotReportsParentAndSubspaces() throws {
        let fixture = try WorkspaceSubspaceAppControlFixture()
        fixture.startCaller(sessionID: "spawner")
        let child = try fixture.createWorkspace(callerSessionID: "spawner")

        let parentSnapshot = try fixture.executor.runQuery(
            id: AppControlQueryID.workspaceSnapshot.rawValue,
            args: ["workspaceID": .string(fixture.workspaceID.uuidString)]
        )
        #expect(parentSnapshot["parentWorkspaceID"] == .null)
        #expect(parentSnapshot["subspaceWorkspaceIDs"] == .array([.string(child.workspaceID.uuidString)]))

        let childSnapshot = try fixture.executor.runQuery(
            id: AppControlQueryID.workspaceSnapshot.rawValue,
            args: ["workspaceID": .string(child.workspaceID.uuidString)]
        )
        #expect(childSnapshot["parentWorkspaceID"] == .string(fixture.workspaceID.uuidString))
        #expect(childSnapshot["spawningSessionID"] == .string("spawner"))
        #expect(childSnapshot["subspaceWorkspaceIDs"] == .array([]))
    }

    @Test
    func createDescriptorAdvertisesParentParameter() throws {
        let fixture = try WorkspaceSubspaceAppControlFixture()
        let descriptors = fixture.executor.listActionDescriptors()
        let create = try #require(descriptors.first { $0.id == AppControlActionID.workspaceCreate.rawValue })
        #expect(create.parameters.contains { $0.name == "parent" && $0.required == false })
        let setParent = try #require(descriptors.first { $0.id == AppControlActionID.workspaceSetParent.rawValue })
        #expect(setParent.parameters.contains { $0.name == "parent" && $0.required })
    }
}
