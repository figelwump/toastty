import CoreState
import Foundation
import Testing

struct TaskSpaceReducerTests {
    private final class Fixture {
        var state: AppState
        let windowID: UUID
        let workspaceIDs: [UUID]

        init() {
            let windowID = UUID()
            let workspaces = (0..<2).map { WorkspaceState.bootstrap(title: "Workspace \($0 + 1)") }
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
            workspaceIDs = workspaces.map(\.id)
        }

        func createTaskSpace(
            workspaceID: UUID = UUID(),
            panelID: UUID = UUID(),
            parent: UUID,
            taskID: UUID = UUID()
        ) -> Bool {
            AppReducer.reduce(
                action: .createTaskSpace(
                    windowID: windowID,
                    workspaceID: workspaceID,
                    panelID: panelID,
                    parentWorkspaceID: parent,
                    spawningSessionID: " session-1 ",
                    taskID: taskID,
                    title: "fix-dot",
                    terminalCWD: "/repo"
                ),
                state: &state
            )
        }
    }

    @Test
    func createsANestedUnselectedTaskSpaceWithTheChosenIDs() {
        let fixture = Fixture()
        let workspaceID = UUID()
        let panelID = UUID()
        let taskID = UUID()
        #expect(fixture.createTaskSpace(workspaceID: workspaceID, panelID: panelID, parent: fixture.workspaceIDs[0], taskID: taskID))

        let taskSpace = fixture.state.workspacesByID[workspaceID]
        #expect(taskSpace?.title == "fix-dot")
        #expect(taskSpace?.parentWorkspaceID == fixture.workspaceIDs[0])
        #expect(taskSpace?.spawningSessionID == "session-1")
        #expect(taskSpace?.taskID == taskID)
        #expect(taskSpace?.hasBeenVisited == false)
        guard case .terminal(let terminal)? = taskSpace?.panelState(for: panelID) else {
            Issue.record("task space has no terminal with the chosen panel ID")
            return
        }
        #expect(terminal.cwd == "/repo")
        #expect(fixture.state.windows[0].selectedWorkspaceID == fixture.workspaceIDs[0])
        #expect(fixture.state.subspaceWorkspaceIDs(of: fixture.workspaceIDs[0]) == [workspaceID])
    }

    @Test
    func nestsUnderTheRootWhenAskedForASubspace() {
        let fixture = Fixture()
        let first = UUID()
        #expect(fixture.createTaskSpace(workspaceID: first, parent: fixture.workspaceIDs[0]))
        let second = UUID()
        #expect(fixture.createTaskSpace(workspaceID: second, parent: first))
        #expect(fixture.state.workspacesByID[second]?.parentWorkspaceID == fixture.workspaceIDs[0])
    }

    @Test
    func refusesReusedIDsAndUnknownParents() {
        let fixture = Fixture()
        let workspaceID = UUID()
        let panelID = UUID()
        #expect(fixture.createTaskSpace(workspaceID: workspaceID, panelID: panelID, parent: fixture.workspaceIDs[0]))
        // A retry with the same IDs must not make a second workspace.
        #expect(fixture.createTaskSpace(workspaceID: workspaceID, parent: fixture.workspaceIDs[0]) == false)
        #expect(fixture.createTaskSpace(panelID: panelID, parent: fixture.workspaceIDs[0]) == false)
        #expect(fixture.createTaskSpace(parent: UUID()) == false)
        #expect(fixture.state.windows[0].workspaceIDs.count == 3)
    }

    @Test
    func rootDirectoryIsOnlyForTopLevelWorkspaces() {
        let fixture = Fixture()
        let top = fixture.workspaceIDs[0]
        #expect(AppReducer.reduce(action: .setWorkspaceRootDirectory(workspaceID: top, rootDirectory: " /repo "), state: &fixture.state))
        #expect(fixture.state.workspacesByID[top]?.rootDirectory == "/repo")
        #expect(AppReducer.reduce(action: .setWorkspaceRootDirectory(workspaceID: top, rootDirectory: "relative"), state: &fixture.state) == false)

        let taskSpace = UUID()
        #expect(fixture.createTaskSpace(workspaceID: taskSpace, parent: top))
        #expect(AppReducer.reduce(action: .setWorkspaceRootDirectory(workspaceID: taskSpace, rootDirectory: "/repo"), state: &fixture.state) == false)

        #expect(AppReducer.reduce(action: .setWorkspaceRootDirectory(workspaceID: top, rootDirectory: nil), state: &fixture.state))
        #expect(fixture.state.workspacesByID[top]?.rootDirectory == nil)
    }

    @Test
    func rootDirectoryAndTaskLinkSurviveALayoutRoundTrip() throws {
        let fixture = Fixture()
        let top = fixture.workspaceIDs[0]
        let taskSpace = UUID()
        let taskID = UUID()
        _ = AppReducer.reduce(action: .setWorkspaceRootDirectory(workspaceID: top, rootDirectory: "/repo"), state: &fixture.state)
        #expect(fixture.createTaskSpace(workspaceID: taskSpace, parent: top, taskID: taskID))

        let encoded = try JSONEncoder().encode(WorkspaceLayoutSnapshot(state: fixture.state))
        let restored = try JSONDecoder().decode(WorkspaceLayoutSnapshot.self, from: encoded).makeAppState()
        #expect(restored.workspacesByID[top]?.rootDirectory == "/repo")
        #expect(restored.workspacesByID[taskSpace]?.taskID == taskID)
        #expect(restored.workspacesByID[taskSpace]?.parentWorkspaceID == top)

        let stateData = try JSONEncoder().encode(fixture.state.workspacesByID[taskSpace])
        #expect(try JSONDecoder().decode(WorkspaceState.self, from: stateData).taskID == taskID)
    }

    @Test
    func taskLinkCanBeCleared() {
        let fixture = Fixture()
        let taskSpace = UUID()
        #expect(fixture.createTaskSpace(workspaceID: taskSpace, parent: fixture.workspaceIDs[0]))
        #expect(AppReducer.reduce(action: .setWorkspaceTaskID(workspaceID: taskSpace, taskID: nil), state: &fixture.state))
        #expect(fixture.state.workspacesByID[taskSpace]?.taskID == nil)
        #expect(AppReducer.reduce(action: .setWorkspaceTaskID(workspaceID: taskSpace, taskID: nil), state: &fixture.state) == false)
    }
}

struct TaskWindowStateTests {
    private func state() -> (AppState, UUID, [UUID]) {
        let windowID = UUID()
        let workspaces = (0..<2).map { WorkspaceState.bootstrap(title: "Workspace \($0 + 1)") }
        let state = AppState(
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
        return (state, windowID, workspaces.map(\.id))
    }

    @Test
    func selectingAWorkspaceLeavesTheTasksView() {
        var (state, windowID, workspaceIDs) = state()
        #expect(AppReducer.reduce(action: .setTasksViewShown(windowID: windowID, shown: true), state: &state))
        #expect(state.windows[0].showsTasksView)
        #expect(AppReducer.reduce(action: .setTasksViewShown(windowID: windowID, shown: true), state: &state) == false)

        #expect(AppReducer.reduce(action: .selectWorkspace(windowID: windowID, workspaceID: workspaceIDs[1]), state: &state))
        #expect(state.windows[0].showsTasksView == false)
    }

    @Test
    func theSidebarSegmentIsSavedButTheTasksViewIsNot() throws {
        var (state, windowID, _) = state()
        #expect(state.windows[0].sidebarSegment == .all)
        #expect(AppReducer.reduce(action: .setSidebarSegment(windowID: windowID, segment: .needsYou), state: &state))
        #expect(AppReducer.reduce(action: .setSidebarSegment(windowID: windowID, segment: .needsYou), state: &state) == false)
        _ = AppReducer.reduce(action: .setTasksViewShown(windowID: windowID, shown: true), state: &state)

        let encoded = try JSONEncoder().encode(state.windows[0])
        let decoded = try JSONDecoder().decode(WindowState.self, from: encoded)
        #expect(decoded.sidebarSegment == .needsYou)
        #expect(decoded.showsTasksView == false)

        // Windows saved before segments existed open on All; windows saved
        // with the earlier segment names open on the segment that replaced them.
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "sidebarSegment")
        let older = try JSONDecoder().decode(WindowState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.sidebarSegment == .all)
        for (savedName, segment) in [("projects", SidebarSegment.all), ("status", .needsYou), ("stages", .all)] {
            object["sidebarSegment"] = savedName
            let saved = try JSONDecoder().decode(WindowState.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(saved.sidebarSegment == segment, "\(savedName)")
        }
    }

    @Test
    func aCollapsedProjectCardIsSavedWithItsWindow() throws {
        var (state, windowID, workspaceIDs) = state()
        #expect(state.windows[0].collapsedSidebarWorkspaceIDs.isEmpty)
        let collapse = AppAction.setSidebarWorkspaceCollapsed(windowID: windowID, workspaceID: workspaceIDs[1], collapsed: true)
        #expect(AppReducer.reduce(action: collapse, state: &state))
        #expect(AppReducer.reduce(action: collapse, state: &state) == false)
        // A workspace that is not in the window cannot collapse there.
        #expect(AppReducer.reduce(
            action: .setSidebarWorkspaceCollapsed(windowID: windowID, workspaceID: UUID(), collapsed: true),
            state: &state
        ) == false)

        var decoded = try JSONDecoder().decode(WindowState.self, from: JSONEncoder().encode(state.windows[0]))
        #expect(decoded.collapsedSidebarWorkspaceIDs == [workspaceIDs[1]])

        // A workspace that left the window drops out when the window is saved.
        var window = state.windows[0]
        window.workspaceIDs.removeAll { $0 == workspaceIDs[1] }
        decoded = try JSONDecoder().decode(WindowState.self, from: JSONEncoder().encode(window))
        #expect(decoded.collapsedSidebarWorkspaceIDs.isEmpty)

        #expect(AppReducer.reduce(
            action: .setSidebarWorkspaceCollapsed(windowID: windowID, workspaceID: workspaceIDs[1], collapsed: false),
            state: &state
        ))
        #expect(state.windows[0].collapsedSidebarWorkspaceIDs.isEmpty)
    }
}
