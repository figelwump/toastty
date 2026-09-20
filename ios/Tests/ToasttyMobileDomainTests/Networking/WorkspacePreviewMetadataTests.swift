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

    func testCanonicalHostAnnotationsReachWorkspacesAndOlderWorkspacesHaveNone() throws {
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "v1", withExtension: nil))
        let rest = try GatewayCompatibilityDecoder().decodeSessionListResponse(Data(
            contentsOf: directory.appending(path: "session-list-response.json", directoryHint: .notDirectory)))
        guard case .sessionList(let streamed) = try GatewayCompatibilityDecoder().decodeStreamMessage(Data(
            contentsOf: directory.appending(path: "stream-session-list.json", directoryHint: .notDirectory)))
        else { return XCTFail("Expected a session_list stream message") }

        for snapshot in [rest, streamed] {
            let workspaces = snapshot.presentation().workspaces
            let annotated = try XCTUnwrap(workspaces.first { $0.title == "Mobile Remote Access" })
            XCTAssertEqual(annotated.annotations, [
                RemoteWorkspaceAnnotation(key: "github-pr", text: "PR #12",
                                          url: URL(string: "https://github.com/example/toastty/pull/12"),
                                          color: "#5BA08A"),
                RemoteWorkspaceAnnotation(key: "task-status", text: "Working", color: "#A78BFA"),
            ])
            XCTAssertEqual(workspaces.first { $0.title == "No annotations" }?.annotations, [])
        }
    }

    func testMalformedAnnotationsAreDroppedWithoutLosingTheWorkspace() throws {
        let valid: [String: Any] = ["id": UUID().uuidString, "title": "Chips", "panels": [], "annotations": [
            ["key": "ok", "text": "Kept", "color": "#5ba08a", "url": "https://example.com/a"],
            ["key": "bad-color", "text": "Neutral", "color": "green"],
            ["key": "bad-url", "text": "Text only", "color": "#E55C5C", "url": 42],
            ["key": "no-text", "color": "#E55C5C"],
            ["text": "No key", "color": "#E55C5C"],
        ]]
        let invalidField: [String: Any] = ["id": UUID().uuidString, "title": "Broken", "panels": [],
                                           "annotations": "not an array"]
        let result = try GatewayCompatibilityDecoder().decodeSessionListResponse(
            snapshotData(workspaces: [valid, invalidField]))
        let workspaces = result.presentation().workspaces

        let chips = try XCTUnwrap(workspaces.first { $0.title == "Chips" }?.annotations)
        XCTAssertEqual(chips.map(\.key), ["ok", "bad-color", "bad-url"])
        XCTAssertEqual(chips.map(\.color), ["#5BA08A", "#B7AEA5", "#E55C5C"])
        XCTAssertEqual(chips.map(\.url), [URL(string: "https://example.com/a"), nil, nil])
        XCTAssertEqual(workspaces.first { $0.title == "Broken" }?.annotations, [])
    }

    private func snapshotData(workspaces: [[String: Any]]?) throws -> Data {
        var snapshot: [String: Any] = ["projectionRunID": UUID().uuidString, "conversations": [],
                                        "generatedAt": "2026-09-06T12:00:00.000Z"]
        if let workspaces { snapshot["workspaces"] = workspaces }
        return try JSONSerialization.data(withJSONObject: ["protocolVersion": "1.0", "snapshot": snapshot])
    }
}
