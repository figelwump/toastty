import CoreState
import Foundation
import Testing

struct WindowStateCodableTests {
    @Test
    func windowStateRoundTripsThroughCodable() throws {
        let workspaceID = UUID()
        let original = WindowState(
            id: UUID(),
            frame: CGRectCodable(x: 12, y: 24, width: 1280, height: 800),
            workspaceIDs: [workspaceID],
            selectedWorkspaceID: workspaceID,
            sidebarVisible: false,
            sidebarWidthPointsOverride: 320,
            terminalFontSizePointsOverride: 17.5,
            markdownTextScaleOverride: 1.2
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WindowState.self, from: data)

        #expect(decoded == original)
    }

    @Test
    func emptyWindowStateRoundTripsThroughCodable() throws {
        let original = WindowState(
            id: UUID(),
            frame: CGRectCodable(x: 32, y: 64, width: 1024, height: 768),
            workspaceIDs: [],
            selectedWorkspaceID: nil,
            terminalFontSizePointsOverride: 16,
            markdownTextScaleOverride: 0.9
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WindowState.self, from: data)

        #expect(decoded == original)
    }

    @Test
    func windowStateNormalizesSidebarWidthOverride() {
        let low = WindowState(
            id: UUID(),
            frame: CGRectCodable(x: 32, y: 64, width: 1024, height: 768),
            workspaceIDs: [],
            selectedWorkspaceID: nil,
            sidebarWidthPointsOverride: 12
        )
        let high = WindowState(
            id: UUID(),
            frame: CGRectCodable(x: 32, y: 64, width: 1024, height: 768),
            workspaceIDs: [],
            selectedWorkspaceID: nil,
            sidebarWidthPointsOverride: 900
        )
        let nonFinite = WindowState(
            id: UUID(),
            frame: CGRectCodable(x: 32, y: 64, width: 1024, height: 768),
            workspaceIDs: [],
            selectedWorkspaceID: nil,
            sidebarWidthPointsOverride: .infinity
        )

        #expect(low.sidebarWidthPointsOverride == WindowState.minSidebarWidth)
        #expect(high.sidebarWidthPointsOverride == WindowState.maxSidebarWidth)
        #expect(nonFinite.sidebarWidthPointsOverride == nil)
    }

    @Test
    func decodingLegacyWindowStateIgnoresRemovedSidebarWidthOverride() throws {
        let windowID = UUID()
        let workspaceID = UUID()
        let legacy = LegacyWindowState(
            id: windowID,
            frame: CGRectCodable(x: 0, y: 0, width: 1200, height: 800),
            workspaceIDs: [workspaceID],
            selectedWorkspaceID: workspaceID,
            sidebarVisible: true,
            sidebarWidthOverride: 320
        )

        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(WindowState.self, from: data)

        #expect(decoded.id == windowID)
        #expect(decoded.frame == legacy.frame)
        #expect(decoded.workspaceIDs == [workspaceID])
        #expect(decoded.selectedWorkspaceID == workspaceID)
        #expect(decoded.sidebarVisible)
        #expect(decoded.sidebarWidthPointsOverride == nil)
        #expect(decoded.terminalFontSizePointsOverride == nil)
        #expect(decoded.markdownTextScaleOverride == nil)
        // Saved before the coordinator's dock: the dock is hidden, at its
        // default width.
        #expect(decoded.coordinatorDockVisible == false)
        #expect(decoded.coordinatorDockWidthPointsOverride == nil)
        #expect(decoded.coordinatorDockWidth == WindowState.defaultCoordinatorDockWidth)
    }

    @Test
    func coordinatorDockSurvivesARelaunchAndKeepsItsWidthInItsLimits() throws {
        var state = AppState.bootstrap()
        let reducer = AppReducer()
        let windowID = try #require(state.windows.first?.id)

        #expect(reducer.send(.setCoordinatorDockVisible(windowID: windowID, visible: true), state: &state))
        #expect(reducer.send(.setCoordinatorDockVisible(windowID: windowID, visible: true), state: &state) == false)
        #expect(reducer.send(.setCoordinatorDockWidth(windowID: windowID, width: 420), state: &state))
        #expect(reducer.send(.setCoordinatorDockWidth(windowID: windowID, width: 420), state: &state) == false)

        // Saved and read back, as a relaunch does.
        let saved = try JSONEncoder().encode(WorkspaceLayoutSnapshot(state: state))
        let restored = try JSONDecoder().decode(WorkspaceLayoutSnapshot.self, from: saved).makeAppState()
        let window = try #require(restored.windows.first)
        #expect(window.coordinatorDockVisible)
        #expect(window.coordinatorDockWidth == 420)

        // A drag past either limit stops at it, and the default width is
        // saved as no width.
        #expect(reducer.send(.setCoordinatorDockWidth(windowID: windowID, width: 90), state: &state))
        #expect(state.windows.first?.coordinatorDockWidth == WindowState.minCoordinatorDockWidth)
        #expect(reducer.send(.setCoordinatorDockWidth(windowID: windowID, width: 9_000), state: &state))
        #expect(state.windows.first?.coordinatorDockWidth == WindowState.maxCoordinatorDockWidth)
        #expect(reducer.send(.setCoordinatorDockWidth(windowID: windowID, width: .nan), state: &state) == false)
        #expect(reducer.send(
            .setCoordinatorDockWidth(windowID: windowID, width: WindowState.defaultCoordinatorDockWidth),
            state: &state
        ))
        #expect(state.windows.first?.coordinatorDockWidthPointsOverride == nil)
        #expect(reducer.send(.setCoordinatorDockVisible(windowID: UUID(), visible: false), state: &state) == false)

        // A width from a newer or edited file is kept in the limits too.
        var json = try #require(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(window)) as? [String: Any]
        )
        json["coordinatorDockWidthPointsOverride"] = 9_000
        let edited = try JSONDecoder().decode(WindowState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(edited.coordinatorDockWidth == WindowState.maxCoordinatorDockWidth)
        try StateValidator.validate(state)
    }

    @Test
    func coordinatorDockIsAtMostFortyPercentOfTheWindow() {
        var window = WindowState(
            id: UUID(),
            frame: CGRectCodable(x: 0, y: 0, width: 1_600, height: 900),
            workspaceIDs: [],
            selectedWorkspaceID: nil,
            coordinatorDockWidthPointsOverride: 900
        )
        // A wide window shows a wide dock, up to 40% of the window.
        #expect(WindowState.maxCoordinatorDockWidth(windowWidth: 2_000) == 800)
        #expect(window.coordinatorDockWidth(windowWidth: 2_000) == 800)
        #expect(window.coordinatorDockWidth(windowWidth: 3_000) == 900)
        // A narrow window shows it narrower and keeps the saved width.
        #expect(window.coordinatorDockWidth(windowWidth: 1_000) == 400)
        #expect(window.coordinatorDockWidthPointsOverride == 900)
        // The dock never goes under its minimum, and an unknown window
        // width does not limit it.
        #expect(window.coordinatorDockWidth(windowWidth: 500) == WindowState.minCoordinatorDockWidth)
        #expect(window.coordinatorDockWidth(windowWidth: 0) == 900)
        window.coordinatorDockWidthPointsOverride = nil
        #expect(window.coordinatorDockWidth(windowWidth: 1_000) == WindowState.defaultCoordinatorDockWidth)
    }
}

private struct LegacyWindowState: Codable {
    let id: UUID
    let frame: CGRectCodable
    let workspaceIDs: [UUID]
    let selectedWorkspaceID: UUID?
    let sidebarVisible: Bool
    let sidebarWidthOverride: Double
}
