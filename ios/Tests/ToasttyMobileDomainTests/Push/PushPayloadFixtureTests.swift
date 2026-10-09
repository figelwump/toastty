import Foundation
import RemoteProtocol
import XCTest

final class PushPayloadFixtureTests: XCTestCase {
    func testSharedGoldenAlertsDecodeWithDifferentStrictPayloadShapes() throws {
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "v1", withExtension: nil))
        for (name, kind) in [("push-session", RemotePushPayloadKind.session), ("push-verification", .verification)] {
            let data = try Data(contentsOf: directory.appendingPathComponent(name + ".json"))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let payload = try JSONDecoder().decode(RemotePushPayload.self,
                from: JSONSerialization.data(withJSONObject: XCTUnwrap(object["toastty"])))
            XCTAssertEqual(payload.kind, kind)
            XCTAssertEqual(payload.version, 1)
            XCTAssertTrue(payload.isValid)
            XCTAssertEqual(payload.pairingID.uuidString.lowercased(), "c0d6d62e-dd0b-4b90-81cd-45083da827ce")
            if kind == .session { XCTAssertNotNil(payload.conversationID); XCTAssertNil(payload.nonce) }
            else { XCTAssertNotNil(payload.nonce); XCTAssertNil(payload.conversationID) }
        }
    }
}
