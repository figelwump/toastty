import CoreState
import Foundation
import Testing

struct WindowStateCodableTests {
    @Test
    func decodingLegacyWindowStateDefaultsSidebarWidthOverrideToNil() throws {
        let windowID = UUID()
        let workspaceID = UUID()
        let legacy = LegacyWindowState(
            id: windowID,
            frame: CGRectCodable(x: 12, y: 24, width: 1200, height: 800),
            workspaceIDs: [workspaceID],
            selectedWorkspaceID: workspaceID,
            sidebarVisible: true
        )

        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(WindowState.self, from: data)

        #expect(decoded.id == windowID)
        #expect(decoded.sidebarVisible)
        #expect(decoded.sidebarWidthOverride == nil)
    }

    @Test
    func windowStateInitializerClampsSidebarWidthOverride() {
        let window = WindowState(
            id: UUID(),
            frame: CGRectCodable(x: 0, y: 0, width: 1200, height: 800),
            workspaceIDs: [UUID()],
            selectedWorkspaceID: nil,
            sidebarWidthOverride: 999
        )

        #expect(window.sidebarWidthOverride == WindowState.maximumSidebarWidthOverride)
    }

    @Test
    func decodingSidebarWidthOverrideClampsOutOfRangeValues() throws {
        let windowID = UUID()
        let workspaceID = UUID()
        let overMax = DecodableWindowState(
            id: windowID,
            frame: CGRectCodable(x: 12, y: 24, width: 1200, height: 800),
            workspaceIDs: [workspaceID],
            selectedWorkspaceID: workspaceID,
            sidebarVisible: true,
            sidebarWidthOverride: 999
        )
        let underMin = DecodableWindowState(
            id: windowID,
            frame: CGRectCodable(x: 12, y: 24, width: 1200, height: 800),
            workspaceIDs: [workspaceID],
            selectedWorkspaceID: workspaceID,
            sidebarVisible: true,
            sidebarWidthOverride: 12
        )

        let decodedOverMax = try JSONDecoder().decode(WindowState.self, from: JSONEncoder().encode(overMax))
        let decodedUnderMin = try JSONDecoder().decode(WindowState.self, from: JSONEncoder().encode(underMin))

        #expect(decodedOverMax.sidebarWidthOverride == WindowState.maximumSidebarWidthOverride)
        #expect(decodedUnderMin.sidebarWidthOverride == WindowState.minimumSidebarWidthOverride)
    }
}

private struct LegacyWindowState: Codable {
    let id: UUID
    let frame: CGRectCodable
    let workspaceIDs: [UUID]
    let selectedWorkspaceID: UUID?
    let sidebarVisible: Bool
}

private struct DecodableWindowState: Codable {
    let id: UUID
    let frame: CGRectCodable
    let workspaceIDs: [UUID]
    let selectedWorkspaceID: UUID?
    let sidebarVisible: Bool
    let sidebarWidthOverride: Double?
}
