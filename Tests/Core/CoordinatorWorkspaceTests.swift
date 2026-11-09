import CoreState
import Foundation
import Testing

/// The coordinator's workspace in the app state: made once, pinned outside
/// the project list, saved with the layout, and never a project or a task.
struct CoordinatorWorkspaceTests {
    private final class Fixture {
        var state: AppState
        let windowID: UUID
        let projectIDs: [UUID]

        init() {
            let windowID = UUID()
            let workspaces = (0..<2).map { WorkspaceState.bootstrap(title: "Project \($0 + 1)") }
            state = AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 0, y: 0, width: 1200, height: 800),
                        workspaceIDs: workspaces.map(\.id),
                        selectedWorkspaceID: workspaces[0].id
                    ),
                ],
                workspacesByID: Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) }),
                selectedWindowID: windowID,
                configuredTerminalFontPoints: nil
            )
            self.windowID = windowID
            projectIDs = workspaces.map(\.id)
        }

        @discardableResult
        func send(_ action: AppAction) -> Bool {
            AppReducer.reduce(action: action, state: &state)
        }

        @discardableResult
        func createCoordinator(workspaceID: UUID = UUID(), panelID: UUID = UUID()) -> Bool {
            send(.createCoordinatorWorkspace(
                windowID: windowID,
                workspaceID: workspaceID,
                panelID: panelID,
                terminalCWD: "/home/.toastty/coordinator"
            ))
        }

        func restored() throws -> AppState {
            let encoded = try JSONEncoder().encode(WorkspaceLayoutSnapshot(state: state))
            return try JSONDecoder().decode(WorkspaceLayoutSnapshot.self, from: encoded).makeAppState()
        }
    }

    @Test
    func createsOnePinnedWorkspaceThatIsNotAProjectCard() throws {
        let fixture = Fixture()
        let workspaceID = UUID()
        let panelID = UUID()
        #expect(fixture.state.coordinator == nil)
        #expect(fixture.createCoordinator(workspaceID: workspaceID, panelID: panelID))

        #expect(fixture.state.coordinator == CoordinatorLocation(windowID: fixture.windowID, workspaceID: workspaceID, panelID: panelID))
        let workspace = try #require(fixture.state.workspacesByID[workspaceID])
        #expect(workspace.title == "Coordinator")
        #expect(workspace.isCoordinator)
        #expect(workspace.parentWorkspaceID == nil)
        #expect(workspace.taskID == nil)
        guard case .terminal(let terminal)? = workspace.panelState(for: panelID) else {
            Issue.record("the coordinator's panel is not a terminal")
            return
        }
        #expect(terminal.cwd == "/home/.toastty/coordinator")
        // Created without taking the selection.
        #expect(fixture.state.windows[0].selectedWorkspaceID == fixture.projectIDs[0])
        // Last in window order, outside the cards, first in sidebar order.
        #expect(fixture.state.windows[0].workspaceIDs == fixture.projectIDs + [workspaceID])
        #expect(fixture.state.topLevelWorkspaceIDs(in: fixture.windowID) == fixture.projectIDs)
        #expect(fixture.state.sidebarOrderedWorkspaceIDs(in: fixture.windowID) == [workspaceID] + fixture.projectIDs)

        // At most one.
        #expect(fixture.createCoordinator() == false)
        #expect(fixture.state.workspacesByID.values.filter(\.isCoordinator).count == 1)
    }

    @Test
    func closingItRemovesTheCoordinatorAndANewOneCanBeMade() {
        let fixture = Fixture()
        let first = UUID()
        fixture.createCoordinator(workspaceID: first)
        #expect(fixture.send(.selectWorkspace(windowID: fixture.windowID, workspaceID: first)))
        #expect(fixture.send(.closeWorkspace(workspaceID: first)))
        #expect(fixture.state.coordinator == nil)
        // The selection moves to its neighbor in window order.
        #expect(fixture.state.windows[0].selectedWorkspaceID == fixture.projectIDs[1])

        let second = UUID()
        #expect(fixture.createCoordinator(workspaceID: second))
        #expect(fixture.state.coordinatorWorkspaceID == second)
    }

    @Test
    func closingItsLastPanelRemovesTheCoordinator() {
        let fixture = Fixture()
        let panelID = UUID()
        fixture.createCoordinator(panelID: panelID)
        #expect(fixture.send(.closePanel(panelID: panelID)))
        #expect(fixture.state.coordinator == nil)
        #expect(fixture.state.workspacesByID.values.contains(where: \.isCoordinator) == false)
    }

    @Test
    func takesNoPartInNestingTasksOrRenaming() {
        let fixture = Fixture()
        let coordinatorID = UUID()
        fixture.createCoordinator(workspaceID: coordinatorID)
        let project = fixture.projectIDs[0]

        // No task space under it, and it is never a task space.
        #expect(fixture.send(.createTaskSpace(
            windowID: fixture.windowID,
            workspaceID: UUID(),
            panelID: UUID(),
            parentWorkspaceID: coordinatorID,
            spawningSessionID: nil,
            taskID: UUID(),
            title: "fix-dot",
            terminalCWD: "/repo"
        )) == false)
        #expect(fixture.send(.setWorkspaceTaskID(workspaceID: coordinatorID, taskID: UUID())) == false)
        // Neither a parent nor a subspace.
        #expect(fixture.send(.setWorkspaceParent(workspaceID: project, parentWorkspaceID: coordinatorID, spawningSessionID: nil)) == false)
        #expect(fixture.send(.setWorkspaceParent(workspaceID: coordinatorID, parentWorkspaceID: project, spawningSessionID: nil)) == false)
        #expect(fixture.state.resolvedParentWorkspaceID(forNewWorkspaceIn: fixture.windowID, under: coordinatorID) == nil)
        #expect(fixture.state.subspaceParentIDsByWorkspaceID().isEmpty)
        // It keeps its name.
        #expect(fixture.send(.renameWorkspace(workspaceID: coordinatorID, title: "Mine")) == false)
        #expect(fixture.state.workspacesByID[coordinatorID]?.title == "Coordinator")
        // Nesting among projects still works.
        #expect(fixture.send(.setWorkspaceParent(workspaceID: fixture.projectIDs[1], parentWorkspaceID: project, spawningSessionID: nil)))
    }

    @Test
    func thePanelCanMoveToANewTerminalAndAClosedPanelReadsAsNone() throws {
        let fixture = Fixture()
        let coordinatorID = UUID()
        let firstPanel = UUID()
        fixture.createCoordinator(workspaceID: coordinatorID, panelID: firstPanel)

        // A panel in another workspace cannot be the coordinator's.
        let otherPanel = try #require(fixture.state.workspacesByID[fixture.projectIDs[0]]?.focusedPanelID)
        #expect(fixture.send(.setCoordinatorPanel(panelID: otherPanel)) == false)

        let secondPanel = UUID()
        #expect(fixture.send(.createBackgroundTerminalTab(
            workspaceID: coordinatorID,
            tabID: UUID(),
            panelID: secondPanel,
            terminalCWD: "/home/.toastty/coordinator"
        )))
        #expect(fixture.send(.setCoordinatorPanel(panelID: secondPanel)))
        #expect(fixture.state.coordinator?.panelID == secondPanel)
        #expect(fixture.send(.setCoordinatorPanel(panelID: secondPanel)) == false)

        // The workspace stays open on its other terminal; the coordinator
        // then has no panel until a restart names one.
        #expect(fixture.send(.closePanel(panelID: secondPanel)))
        #expect(fixture.state.coordinator == CoordinatorLocation(windowID: fixture.windowID, workspaceID: coordinatorID, panelID: nil))
    }

    @Test
    func theMarkAndThePanelSurviveALayoutRoundTrip() throws {
        let fixture = Fixture()
        let coordinatorID = UUID()
        let panelID = UUID()
        fixture.createCoordinator(workspaceID: coordinatorID, panelID: panelID)

        let restored = try fixture.restored()
        #expect(restored.coordinator == CoordinatorLocation(windowID: fixture.windowID, workspaceID: coordinatorID, panelID: panelID))
        #expect(restored.workspacesByID[coordinatorID]?.title == "Coordinator")
        #expect(restored.topLevelWorkspaceIDs(in: fixture.windowID) == fixture.projectIDs)
        #expect(restored.sidebarOrderedWorkspaceIDs(in: fixture.windowID).first == coordinatorID)
        try StateValidator.validate(restored)

        // The same through WorkspaceState's own coding.
        let stateData = try JSONEncoder().encode(fixture.state.workspacesByID[coordinatorID])
        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: stateData)
        #expect(decoded.isCoordinator)
        #expect(decoded.coordinatorPanelID == panelID)
    }

    @Test
    func otherWorkspacesSaveNoCoordinatorKeysAndOlderFilesDecodeWithoutThem() throws {
        let fixture = Fixture()
        let project = try #require(fixture.state.workspacesByID[fixture.projectIDs[0]])
        for data in [
            try JSONEncoder().encode(project),
            try JSONEncoder().encode(WorkspaceLayoutSnapshot(state: fixture.state)),
        ] {
            let text = try #require(String(data: data, encoding: .utf8))
            #expect(text.contains("isCoordinator") == false)
            #expect(text.contains("coordinatorPanelID") == false)
        }
        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: try JSONEncoder().encode(project))
        #expect(decoded.isCoordinator == false)
        #expect(decoded.coordinatorPanelID == nil)
    }

    @Test
    func aMalformedMarkOrPanelDropsThatValueOnly() throws {
        let fixture = Fixture()
        let coordinatorID = UUID()
        fixture.createCoordinator(workspaceID: coordinatorID)

        func decodingWorkspace(_ edit: (inout [String: Any]) -> Void) throws -> WorkspaceState {
            let data = try JSONEncoder().encode(fixture.state.workspacesByID[coordinatorID])
            var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            edit(&object)
            return try JSONDecoder().decode(WorkspaceState.self, from: try JSONSerialization.data(withJSONObject: object))
        }

        let badPanel = try decodingWorkspace { $0["coordinatorPanelID"] = "not-a-uuid" }
        #expect(badPanel.isCoordinator)
        #expect(badPanel.coordinatorPanelID == nil)

        let badMark = try decodingWorkspace { $0["isCoordinator"] = "yes" }
        #expect(badMark.isCoordinator == false)
        #expect(badMark.title == "Coordinator")
    }

    @Test
    func aRestoreKeepsOneValidCoordinatorAndDropsMarksThatCannotHold() throws {
        // Two marked workspaces: the first in window order stays, and the
        // other is an ordinary workspace again.
        let two = Fixture()
        let coordinatorID = UUID()
        two.createCoordinator(workspaceID: coordinatorID)
        two.state.workspacesByID[two.projectIDs[1]]?.isCoordinator = true
        var restored = try two.restored()
        #expect(restored.coordinatorWorkspaceID == two.projectIDs[1])
        #expect(restored.workspacesByID.values.filter(\.isCoordinator).count == 1)
        #expect(restored.workspacesByID[coordinatorID]?.isCoordinator == false)
        #expect(restored.workspacesByID[coordinatorID]?.coordinatorPanelID == nil)
        #expect(restored.topLevelWorkspaceIDs(in: two.windowID) == [two.projectIDs[0], coordinatorID])

        // A marked task space is a task space, not the coordinator.
        let task = Fixture()
        task.state.workspacesByID[task.projectIDs[1]]?.isCoordinator = true
        task.state.workspacesByID[task.projectIDs[1]]?.taskID = UUID()
        restored = try task.restored()
        #expect(restored.coordinator == nil)
        #expect(restored.topLevelWorkspaceIDs(in: task.windowID) == task.projectIDs)

        // A panel that is gone reads as none; a parent link on the
        // coordinator, or one that points at it, is dropped.
        let links = Fixture()
        let linkedCoordinator = UUID()
        links.createCoordinator(workspaceID: linkedCoordinator)
        links.state.workspacesByID[linkedCoordinator]?.coordinatorPanelID = UUID()
        links.state.workspacesByID[linkedCoordinator]?.parentWorkspaceID = links.projectIDs[0]
        links.state.workspacesByID[links.projectIDs[1]]?.parentWorkspaceID = linkedCoordinator
        restored = try links.restored()
        #expect(restored.coordinator == CoordinatorLocation(windowID: links.windowID, workspaceID: linkedCoordinator, panelID: nil))
        #expect(restored.workspacesByID[linkedCoordinator]?.parentWorkspaceID == nil)
        #expect(restored.workspacesByID[links.projectIDs[1]]?.parentWorkspaceID == nil)
        #expect(restored.topLevelWorkspaceIDs(in: links.windowID) == links.projectIDs)
        try StateValidator.validate(restored)
    }

    @Test
    func aSavedLayoutFileRestoresThePinnedCoordinatorAfterARelaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-coordinator-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("workspace-layout-profiles.json")

        let fixture = Fixture()
        let coordinatorID = UUID()
        let panelID = UUID()
        fixture.createCoordinator(workspaceID: coordinatorID, panelID: panelID)
        #expect(WorkspaceLayoutPersistenceStore(fileURL: fileURL)
            .persistLayout(WorkspaceLayoutSnapshot(state: fixture.state), for: "desktop"))

        // A new store, as the next launch makes one.
        let loaded = try #require(WorkspaceLayoutPersistenceStore(fileURL: fileURL).loadLayout(for: "desktop"))
        let restored = loaded.layout.makeAppState()
        #expect(restored.coordinator == CoordinatorLocation(windowID: fixture.windowID, workspaceID: coordinatorID, panelID: panelID))
        #expect(restored.sidebarOrderedWorkspaceIDs(in: fixture.windowID).first == coordinatorID)
        #expect(restored.topLevelWorkspaceIDs(in: fixture.windowID) == fixture.projectIDs)
    }
}
