import RemoteProtocol
import XCTest
@testable import ToasttyMobileDomain

final class WorkspacePreviewMetadataTests: XCTestCase {
    func testOlderHostWithoutWorkspaceMetadataStillDecodes() throws {
        let result = try GatewayCompatibilityDecoder().decodeSessionListResponse(snapshotData(workspaces: nil))
        XCTAssertTrue(result.workspaces.isEmpty)
    }

    func testPanelOnlyWorkspaceAndUnknownPanelKindSurviveSnapshotPresentation() throws {
        let id = UUID()
        let panelID = UUID()
        let workspace: [String: Any] = ["id": id.uuidString, "title": "Documents", "panels": [
            ["panelID": panelID.uuidString, "auxiliaryTabID": UUID().uuidString,
             "workspaceTabID": UUID().uuidString, "workspaceTabTitle": "Research", "kind": "future_kind", "title": "Future panel"],
            ["malformed": true]
        ]]
        let result = try GatewayCompatibilityDecoder().decodeSessionListResponse(snapshotData(workspaces: [workspace]))
        let presentation = result.presentation()
        XCTAssertTrue(presentation.activitySessions.isEmpty)
        XCTAssertEqual(presentation.rankedWorkspaces.first?.id, id)
        XCTAssertEqual(presentation.rankedWorkspaces.first?.panels.map(\.panelID), [panelID])
        XCTAssertEqual(presentation.rankedWorkspaces.first?.panels.first?.kind, "future_kind")
    }

    private func snapshotData(workspaces: [[String: Any]]?) throws -> Data {
        var snapshot: [String: Any] = ["projectionRunID": UUID().uuidString, "conversations": [],
                                        "generatedAt": "2026-09-06T12:00:00.000Z"]
        if let workspaces { snapshot["workspaces"] = workspaces }
        return try JSONSerialization.data(withJSONObject: ["protocolVersion": "1.0", "snapshot": snapshot])
    }
}
