import CoreState
import Foundation
import Testing

struct WorkspaceSubspacesTests {
    private struct Fixture {
        var state: AppState
        let windowID: UUID
        let workspaceIDs: [UUID]

        init(workspaceCount: Int = 4) {
            let windowID = UUID()
            let workspaces = (0..<workspaceCount).map { index in
                WorkspaceState.bootstrap(title: "Workspace \(index + 1)")
            }
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

        @discardableResult
        mutating func nest(_ index: Int, under parentIndex: Int, spawner: String? = "session-\(UUID().uuidString)") -> Bool {
            AppReducer.reduce(
                action: .setWorkspaceParent(
                    workspaceID: workspaceIDs[index],
                    parentWorkspaceID: workspaceIDs[parentIndex],
                    spawningSessionID: spawner
                ),
                state: &state
            )
        }

        func parent(of index: Int) -> UUID? {
            state.workspacesByID[workspaceIDs[index]]?.parentWorkspaceID
        }
    }

    @Test
    func nestingRecordsParentAndSpawnerAndHidesSubspaceFromTopLevel() {
        var fixture = Fixture()
        let didNest1 = fixture.nest(1, under: 0, spawner: "  session-a  ")
        #expect(didNest1)

        #expect(fixture.parent(of: 1) == fixture.workspaceIDs[0])
        #expect(fixture.state.workspacesByID[fixture.workspaceIDs[1]]?.spawningSessionID == "session-a")
        #expect(fixture.state.topLevelWorkspaceIDs(in: fixture.windowID) == [
            fixture.workspaceIDs[0], fixture.workspaceIDs[2], fixture.workspaceIDs[3],
        ])
        #expect(fixture.state.subspaceWorkspaceIDs(of: fixture.workspaceIDs[0]) == [fixture.workspaceIDs[1]])

        // Repeating the same link is not a state change.
        let didNest2 = fixture.nest(1, under: 0, spawner: "session-a")
        #expect(didNest2 == false)
    }

    @Test
    func nestingUnderASubspaceResolvesToItsRootAndFlattensExistingChildren() {
        var fixture = Fixture()
        let didNest3 = fixture.nest(1, under: 0)
        #expect(didNest3)
        // Requested parent is itself nested: the link lands on the root.
        let didNest4 = fixture.nest(2, under: 1)
        #expect(didNest4)
        #expect(fixture.parent(of: 2) == fixture.workspaceIDs[0])

        // A top-level workspace with its own subspace becomes a subspace:
        // its child moves to the shared root rather than nesting two deep.
        var second = Fixture()
        let didNest5 = second.nest(2, under: 1)
        #expect(didNest5)
        let didNest6 = second.nest(1, under: 0)
        #expect(didNest6)
        #expect(second.parent(of: 1) == second.workspaceIDs[0])
        #expect(second.parent(of: 2) == second.workspaceIDs[0])
        #expect(second.state.subspaceWorkspaceIDs(of: second.workspaceIDs[0]) == [
            second.workspaceIDs[1], second.workspaceIDs[2],
        ])
    }

    @Test
    func nestingRejectsSelfCyclesMissingAndCrossWindowParents() {
        var fixture = Fixture()
        let didNest7 = fixture.nest(0, under: 0)
        #expect(didNest7 == false)
        let didNest8 = fixture.nest(1, under: 0)
        #expect(didNest8)
        // The parent cannot be nested under something already under it.
        let didNest9 = fixture.nest(0, under: 1)
        #expect(didNest9 == false)
        #expect(fixture.parent(of: 0) == nil)

        let missingParent = AppReducer.reduce(
            action: .setWorkspaceParent(
                workspaceID: fixture.workspaceIDs[2],
                parentWorkspaceID: UUID(),
                spawningSessionID: nil
            ),
            state: &fixture.state
        )
        #expect(missingParent == false)

        let otherWindowWorkspace = WorkspaceState.bootstrap(title: "Elsewhere")
        fixture.state.workspacesByID[otherWindowWorkspace.id] = otherWindowWorkspace
        fixture.state.windows.append(
            WindowState(
                id: UUID(),
                frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                workspaceIDs: [otherWindowWorkspace.id],
                selectedWorkspaceID: otherWindowWorkspace.id
            )
        )
        let crossWindow = AppReducer.reduce(
            action: .setWorkspaceParent(
                workspaceID: fixture.workspaceIDs[2],
                parentWorkspaceID: otherWindowWorkspace.id,
                spawningSessionID: nil
            ),
            state: &fixture.state
        )
        #expect(crossWindow == false)
    }

    @Test
    func detachingClearsSpawnerAndClosingParentPromotesSubspaces() {
        var fixture = Fixture()
        let didNest10 = fixture.nest(1, under: 0, spawner: "session-a")
        #expect(didNest10)
        let didNest11 = fixture.nest(2, under: 0, spawner: "session-a")
        #expect(didNest11)

        let detached = AppReducer.reduce(
            action: .setWorkspaceParent(
                workspaceID: fixture.workspaceIDs[1],
                parentWorkspaceID: nil,
                spawningSessionID: "ignored"
            ),
            state: &fixture.state
        )
        #expect(detached)
        #expect(fixture.parent(of: 1) == nil)
        #expect(fixture.state.workspacesByID[fixture.workspaceIDs[1]]?.spawningSessionID == nil)

        let didClose = AppReducer.reduce(action: .closeWorkspace(workspaceID: fixture.workspaceIDs[0]), state: &fixture.state)
        #expect(didClose)
        #expect(fixture.parent(of: 2) == nil)
        #expect(fixture.state.workspacesByID[fixture.workspaceIDs[2]]?.spawningSessionID == nil)
        #expect(fixture.state.topLevelWorkspaceIDs(in: fixture.windowID) == Array(fixture.workspaceIDs[1...]))
    }

    @Test
    func layoutSnapshotRoundTripsLinksAndDropsDanglingOnes() throws {
        var fixture = Fixture()
        let didNest12 = fixture.nest(1, under: 0, spawner: "session-a")
        #expect(didNest12)
        // A link written by hand into the layout file to a workspace that
        // does not exist must not survive a restore.
        let danglingWorkspaceID = fixture.workspaceIDs[2]
        fixture.state.workspacesByID[danglingWorkspaceID]?.parentWorkspaceID = UUID()
        fixture.state.workspacesByID[danglingWorkspaceID]?.spawningSessionID = "session-b"
        // Two-deep nesting written by hand flattens to the root.
        let nestedParentID = fixture.workspaceIDs[1]
        let deepWorkspaceID = fixture.workspaceIDs[3]
        fixture.state.workspacesByID[deepWorkspaceID]?.parentWorkspaceID = nestedParentID

        let encoded = try JSONEncoder().encode(WorkspaceLayoutSnapshot(state: fixture.state))
        let decoded = try JSONDecoder().decode(WorkspaceLayoutSnapshot.self, from: encoded)
        let restored = decoded.makeAppState()

        let ids = fixture.workspaceIDs
        #expect(restored.workspacesByID[ids[1]]?.parentWorkspaceID == ids[0])
        #expect(restored.workspacesByID[ids[1]]?.spawningSessionID == "session-a")
        #expect(restored.workspacesByID[ids[2]]?.parentWorkspaceID == nil)
        #expect(restored.workspacesByID[ids[2]]?.spawningSessionID == nil)
        #expect(restored.workspacesByID[ids[3]]?.parentWorkspaceID == ids[0])
        #expect(restored.topLevelWorkspaceIDs(in: fixture.windowID) == [ids[0], ids[2]])
    }

    @Test
    func workspaceStateCodableRoundTripKeepsLinksAndDropsMalformedOnes() throws {
        var fixture = Fixture(workspaceCount: 2)
        let didNest = fixture.nest(1, under: 0, spawner: "session-a")
        #expect(didNest)
        let subspace = try #require(fixture.state.workspacesByID[fixture.workspaceIDs[1]])

        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(subspace))
        #expect(decoded.parentWorkspaceID == fixture.workspaceIDs[0])
        #expect(decoded.spawningSessionID == "session-a")

        // A hand-edited file with a malformed link keeps the workspace and
        // drops only the link.
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(subspace)) as? [String: Any])
        object["parentWorkspaceID"] = "not-a-uuid"
        let malformed = try JSONDecoder().decode(WorkspaceState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(malformed.id == subspace.id)
        #expect(malformed.parentWorkspaceID == nil)
    }

    @Test
    func normalizationClearsSpawnerOnTopLevelWorkspaces() {
        var fixture = Fixture(workspaceCount: 1)
        fixture.state.workspacesByID[fixture.workspaceIDs[0]]?.spawningSessionID = "stale"
        fixture.state.normalizeWorkspaceParentLinks()
        #expect(fixture.state.workspacesByID[fixture.workspaceIDs[0]]?.spawningSessionID == nil)
    }

    @Test
    func topLevelWorkspacesEncodeWithoutParentFieldsAndDecodeAsTopLevel() throws {
        let fixture = Fixture(workspaceCount: 1)
        let encoded = try JSONEncoder().encode(WorkspaceLayoutSnapshot(state: fixture.state))
        let json = try #require(String(data: encoded, encoding: .utf8))
        // Layout files written before subspaces existed carry neither key, so
        // a top-level workspace must not depend on them being present.
        #expect(json.contains("parentWorkspaceID") == false)
        #expect(json.contains("spawningSessionID") == false)

        let restored = try JSONDecoder().decode(WorkspaceLayoutSnapshot.self, from: encoded).makeAppState()
        #expect(restored.workspacesByID[fixture.workspaceIDs[0]]?.parentWorkspaceID == nil)
        #expect(restored.topLevelWorkspaceIDs(in: fixture.windowID) == fixture.workspaceIDs)
    }
}
