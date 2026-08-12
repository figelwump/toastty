import Foundation
import XCTest

final class RemoteProtocolBaselineFixtureTests: XCTestCase {
    func testCanonicalHostBaselineIsBundledAndValidJSON() throws {
        let fixturesDirectory = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "v1", withExtension: nil),
            "The iOS test target must consume the canonical host baseline without copying it."
        )
        let fixtureURLs = try FileManager.default.contentsOfDirectory(
            at: fixturesDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertEqual(
            fixtureURLs.count,
            25,
            "Adding or removing canonical v1 fixtures requires an intentional iOS harness update."
        )

        for fixtureURL in fixtureURLs {
            let data = try Data(contentsOf: fixtureURL)
            let object = try JSONSerialization.jsonObject(with: data)
            XCTAssertTrue(
                object is [String: Any],
                "\(fixtureURL.lastPathComponent) must remain a top-level JSON object."
            )
        }
    }

    func testHelloAndSessionBaselineExposeAdmissionAndSnapshotEnvelopes() throws {
        let hello = try fixtureObject(named: "hello-response")
        XCTAssertEqual(hello["protocolVersion"] as? String, "1.0")
        XCTAssertEqual(hello["minimumSupportedProtocolVersion"] as? String, "1.0")
        XCTAssertNotNil(hello["capabilities"] as? [String])

        let sessionList = try fixtureObject(named: "session-list-response")
        XCTAssertEqual(sessionList["protocolVersion"] as? String, "1.0")
        let snapshot = try XCTUnwrap(sessionList["snapshot"] as? [String: Any])
        XCTAssertNotNil(snapshot["projectionRunID"] as? String)
        XCTAssertFalse(try XCTUnwrap(snapshot["conversations"] as? [[String: Any]]).isEmpty)
    }

    private func fixtureObject(named name: String) throws -> [String: Any] {
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "v1", withExtension: nil))
        let data = try Data(contentsOf: directory.appending(path: name, directoryHint: .notDirectory).appendingPathExtension("json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
