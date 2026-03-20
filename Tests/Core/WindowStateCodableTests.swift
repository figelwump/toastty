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
            sidebarVisible: false
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WindowState.self, from: data)

        #expect(decoded == original)
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
