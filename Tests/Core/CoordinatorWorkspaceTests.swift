import CoreState
import Foundation
import Testing

/// The hidden coordinator workspace: made by the reducer, kept out of the
/// sidebar's list, never nested, and kept across a layout save.
struct CoordinatorWorkspaceTests {
    private final class Fixture {
        var state: AppState
        let windowID: UUID
        let workspaceIDs: [UUID]

        init(workspaceCount: Int = 2) {
            let windowID = UUID()
            let workspaces = (0..<workspaceCount).map { WorkspaceState.bootstrap(title: "Workspace \($0 + 1)") }
            state = AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 0, y: 0, width: 1200, height: 800),
                        workspaceIDs: workspaces.map(\.id),
                        selectedWorkspaceID: workspaces.first?.id
                    ),
                ],
                workspacesByID: Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) }),
                selectedWindowID: windowID,
                configuredTerminalFontPoints: nil
            )
            self.windowID = windowID
            workspaceIDs = workspaces.map(\.id)
        }

        @discardableResult
        func createCoordinator(workspaceID: UUID = UUID(), panelID: UUID = UUID()) -> Bool {
            AppReducer.reduce(
                action: .createCoordinatorWorkspace(
                    windowID: windowID,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    terminalCWD: "/Users/tester"
                ),
                state: &state
            )
        }

        func send(_ action: AppAction) -> Bool {
            AppReducer.reduce(action: action, state: &state)
        }
    }

    @Test
    func createsOneUnselectedCoordinatorWorkspaceThatTheSidebarLeavesOut() throws {
        let fixture = Fixture()
        let workspaceID = UUID()
        let panelID = UUID()
        #expect(fixture.createCoordinator(workspaceID: workspaceID, panelID: panelID))

        let workspace = try #require(fixture.state.workspacesByID[workspaceID])
        #expect(workspace.isCoordinator)
        #expect(workspace.title == "Coordinator")
        guard case .terminal(let terminal)? = workspace.panelState(for: panelID) else {
            Issue.record("the coordinator workspace has no terminal with the chosen panel ID")
            return
        }
        #expect(terminal.cwd == "/Users/tester")
        #expect(terminal.profileBinding == nil)
        #expect(fixture.state.coordinatorWorkspaceID == workspaceID)
        #expect(fixture.state.windows[0].workspaceIDs.last == workspaceID)
        #expect(fixture.state.windows[0].selectedWorkspaceID == fixture.workspaceIDs[0])
        #expect(fixture.state.topLevelWorkspaceIDs(in: fixture.windowID) == fixture.workspaceIDs)
        #expect(fixture.state.sidebarOrderedWorkspaceIDs(in: fixture.windowID) == fixture.workspaceIDs)
        try StateValidator.validate(fixture.state)

        // A second coordinator workspace is refused, even with new IDs.
        #expect(fixture.createCoordinator() == false)
    }

    @Test
    func closingTheSelectedWorkspaceSelectsAVisibleOneBeforeTheCoordinator() {
        let fixture = Fixture()
        let coordinatorID = UUID()
        fixture.createCoordinator(workspaceID: coordinatorID)
        // The coordinator sits after the second workspace; closing that one
        // falls back to the first, not to the coordinator next to it.
        #expect(fixture.send(.selectWorkspace(windowID: fixture.windowID, workspaceID: fixture.workspaceIDs[1])))
        #expect(fixture.send(.closeWorkspace(workspaceID: fixture.workspaceIDs[1])))
        #expect(fixture.state.windows[0].selectedWorkspaceID == fixture.workspaceIDs[0])

        // With nothing else left, the window shows the coordinator.
        #expect(fixture.send(.closeWorkspace(workspaceID: fixture.workspaceIDs[0])))
        #expect(fixture.state.windows[0].selectedWorkspaceID == coordinatorID)
    }

    @Test
    func theCoordinatorWorkspaceNeitherNestsNorHoldsSubspaces() {
        let fixture = Fixture()
        let coordinatorID = UUID()
        fixture.createCoordinator(workspaceID: coordinatorID)

        #expect(fixture.state.resolvedParentWorkspaceID(forNesting: coordinatorID, under: fixture.workspaceIDs[0]) == nil)
        #expect(fixture.state.resolvedParentWorkspaceID(forNesting: fixture.workspaceIDs[1], under: coordinatorID) == nil)
        #expect(fixture.state.resolvedParentWorkspaceID(forNewWorkspaceIn: fixture.windowID, under: coordinatorID) == nil)
        #expect(fixture.send(.createTaskSpace(
            windowID: fixture.windowID,
            workspaceID: UUID(),
            panelID: UUID(),
            parentWorkspaceID: coordinatorID,
            spawningSessionID: nil,
            taskID: UUID(),
            title: "task",
            terminalCWD: "/repo"
        )) == false)
    }

    @Test
    func theCoordinatorMarkSurvivesALayoutRoundTrip() throws {
        let fixture = Fixture()
        let coordinatorID = UUID()
        fixture.createCoordinator(workspaceID: coordinatorID)

        let snapshot = WorkspaceLayoutSnapshot(state: fixture.state)
        let data = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(WorkspaceLayoutSnapshot.self, from: data).makeAppState()
        #expect(restored.coordinatorWorkspaceID == coordinatorID)
        #expect(restored.workspacesByID[fixture.workspaceIDs[0]]?.isCoordinator == false)

        // Only the coordinator workspace writes the key, so other layouts
        // stay byte for byte as before.
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.components(separatedBy: "isCoordinator").count == 2)
    }
}
