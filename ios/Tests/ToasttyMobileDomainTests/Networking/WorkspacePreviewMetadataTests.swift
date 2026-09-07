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
        XCTAssertNil(presentation.rankedWorkspaces.first?.panels.first?.updatedAt)
        XCTAssertNil(presentation.rankedWorkspaces.first?.panels.first?.associatedConversationID)
    }

    func testPanelUpdateTimestampSurvivesCompatibilityDecoding() throws {
        let workspace: [String: Any] = ["id": UUID().uuidString, "title": "Documents", "panels": [
            ["panelID": UUID().uuidString, "auxiliaryTabID": UUID().uuidString,
             "workspaceTabID": UUID().uuidString, "workspaceTabTitle": "Research", "kind": "localDocument",
             "title": "Notes", "updatedAt": "2026-09-06T12:00:00.000Z"]
        ]]
        let result = try GatewayCompatibilityDecoder().decodeSessionListResponse(snapshotData(workspaces: [workspace]))
        XCTAssertEqual(result.presentation().rankedWorkspaces.first?.panels.first?.updatedAt,
                       ISO8601DateFormatter().date(from: "2026-09-06T12:00:00Z"))
    }

    func testHostEncodedPanelTimestampRoundTripsThroughCompatibilityDecoder() throws {
        let timestamp = Date(timeIntervalSince1970: 1_788_696_000.125)
        let panel = RemoteWorkspacePanel(
            panelID: UUID(), auxiliaryTabID: UUID(), workspaceTabID: UUID(),
            workspaceTabTitle: "Research", kind: "scratchpad", title: "Notes", updatedAt: timestamp,
            associatedConversationID: RemoteConversationID(rawValue: UUID())
        )
        let response = RemoteGatewaySessionListResponse(snapshot: RemoteSessionListSnapshot(
            projectionRunID: RemoteProjectionRunID(rawValue: UUID()), conversations: [], generatedAt: timestamp,
            workspaces: [RemoteWorkspaceSummary(id: UUID(), title: "Documents", panels: [panel])]
        ))
        // This is the encoder used by RemoteGatewayRequestHandler for session lists.
        let data = try ConversationEventCoding.makeEncoder().encode(response)
        let decoded = try GatewayCompatibilityDecoder().decodeSessionListResponse(data)
        let decodedPanel = try XCTUnwrap(decoded.presentation().rankedWorkspaces.first?.panels.first)
        XCTAssertEqual(decodedPanel.updatedAt, timestamp)
        XCTAssertEqual(decodedPanel.panelID, panel.panelID)
        XCTAssertEqual(decodedPanel.associatedConversationID, panel.associatedConversationID)
    }

    private func snapshotData(workspaces: [[String: Any]]?) throws -> Data {
        var snapshot: [String: Any] = ["projectionRunID": UUID().uuidString, "conversations": [],
                                        "generatedAt": "2026-09-06T12:00:00.000Z"]
        if let workspaces { snapshot["workspaces"] = workspaces }
        return try JSONSerialization.data(withJSONObject: ["protocolVersion": "1.0", "snapshot": snapshot])
    }
}
