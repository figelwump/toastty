import Foundation
import RemoteProtocol
import XCTest

final class PushPayloadFixtureTests: XCTestCase {
    func testSharedGoldenAlertsDecodeWithDifferentStrictPayloadShapes() throws {
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "v1", withExtension: nil))
        for (name, kind) in [
            ("push-session", RemotePushPayloadKind.session), ("push-task", .task), ("push-verification", .verification),
        ] {
            let data = try Data(contentsOf: directory.appendingPathComponent(name + ".json"))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let payload = try JSONDecoder().decode(RemotePushPayload.self,
                from: JSONSerialization.data(withJSONObject: XCTUnwrap(object["toastty"])))
            XCTAssertEqual(payload.kind, kind)
            XCTAssertEqual(payload.version, 1)
            XCTAssertTrue(payload.isValid)
            XCTAssertEqual(payload.pairingID.uuidString.lowercased(), "c0d6d62e-dd0b-4b90-81cd-45083da827ce")
            switch kind {
            case .session: XCTAssertNotNil(payload.conversationID); XCTAssertNil(payload.nonce); XCTAssertNil(payload.taskID)
            case .task: XCTAssertNotNil(payload.taskID); XCTAssertNotNil(payload.conversationID); XCTAssertNil(payload.nonce)
            case .verification: XCTAssertNotNil(payload.nonce); XCTAssertNil(payload.conversationID); XCTAssertNil(payload.taskID)
            }
        }
    }

    /// A task alert for a task with no open session has no conversation;
    /// a session alert must still name one, and only a task alert a task.
    func testTaskAlertsNeedATaskAndMayOmitTheirSession() throws {
        let ids = (registration: UUID(), pairing: UUID(), task: UUID(), event: UUID())
        func decode(_ toastty: [String: Any]) throws -> RemotePushPayload {
            try JSONDecoder().decode(RemotePushPayload.self, from: JSONSerialization.data(withJSONObject: toastty))
        }
        var task: [String: Any] = ["version": 1, "kind": "task", "registrationID": ids.registration.uuidString,
                                   "pairingID": ids.pairing.uuidString, "taskID": ids.task.uuidString,
                                   "eventID": ids.event.uuidString]
        let withoutSession = try decode(task)
        XCTAssertEqual(withoutSession.taskID, ids.task)
        XCTAssertNil(withoutSession.conversationID)
        task["taskID"] = nil
        XCTAssertThrowsError(try decode(task))
        var session = task
        session["kind"] = "session"
        session["conversationID"] = UUID().uuidString
        session["taskID"] = ids.task.uuidString
        XCTAssertThrowsError(try decode(session))
    }
}
