import Foundation
import RemoteProtocol
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
            35,
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

    func testEveryCanonicalHostFixtureDecodesThroughItsStrictSharedModel() throws {
        let decoders: [String: (Data) throws -> Void] = [
            "error-response": decode(RemoteGatewayErrorResponse.self),
            "events-request-backward-before": decode(RemoteGatewayEventsRequest.self),
            "events-request-backward-latest": decode(RemoteGatewayEventsRequest.self),
            "events-request": decode(RemoteGatewayEventsRequest.self),
            "events-response-not-found": decode(RemoteGatewayEventsResponse.self),
            "events-response-page": decode(RemoteGatewayEventsResponse.self),
            "events-response-resnapshot-required": decode(RemoteGatewayEventsResponse.self),
            "hello-response": decode(RemoteGatewayHelloResponse.self),
            "current-device-response": decode(RemoteGatewayCurrentDeviceResponse.self),
            "native-pairing-exchange-fallback-request": decode(RemoteGatewayNativePairingExchangeRequest.self),
            "native-pairing-exchange-qr-request": decode(RemoteGatewayNativePairingExchangeRequest.self),
            "native-pairing-exchange-response": decode(RemoteGatewayNativePairingExchangeResponse.self),
            "native-pairing-qr-payload": decode(RemoteNativePairingQRPayload.self),
            "pair-request": decode(RemoteGatewayPairRequest.self),
            "pair-response": decode(RemoteGatewayPairResponse.self),
            "pending-interaction-preview": decode(RemotePendingInteractionPreview.self),
            "revoke-current-device-request": decode(RemoteGatewayRevokeCurrentDeviceRequest.self),
            "revoke-current-device-response": decode(RemoteGatewayRevokeCurrentDeviceResponse.self),
            "send-request": decode(RemoteMessageSendRequest.self),
            "send-result-accepted": decode(RemoteMessageSendResult.self),
            "send-result-duplicate": decode(RemoteMessageSendResult.self),
            "send-result-rejected-empty_text": decode(RemoteMessageSendResult.self),
            "send-result-rejected-epoch_mismatch": decode(RemoteMessageSendResult.self),
            "send-result-rejected-local_draft_present": decode(RemoteMessageSendResult.self),
            "send-result-rejected-not_bound": decode(RemoteMessageSendResult.self),
            "send-result-rejected-pending_interaction": decode(RemoteMessageSendResult.self),
            "send-result-rejected-prompt_not_open": decode(RemoteMessageSendResult.self),
            "send-result-rejected-send_scope_denied": decode(RemoteMessageSendResult.self),
            "send-result-rejected-session_writes_disabled": decode(RemoteMessageSendResult.self),
            "send-result-rejected-surface_unavailable": decode(RemoteMessageSendResult.self),
            "send-result-uncertain": decode(RemoteMessageSendResult.self),
            "session-list-response": decode(RemoteGatewaySessionListResponse.self),
            "stream-conversation-events": decode(RemoteGatewayStreamMessage.self),
            "stream-resnapshot-required": decode(RemoteGatewayStreamMessage.self),
            "stream-session-list": decode(RemoteGatewayStreamMessage.self),
        ]

        XCTAssertEqual(decoders.count, 35)
        for (name, decoder) in decoders {
            try decoder(fixtureData(named: name))
        }
    }

    func testSharedProtocolSourceBoundaryRemainsFoundationOnly() throws {
        let sourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RemoteProtocol", isDirectory: true)
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey]
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sourceDirectory,
                includingPropertiesForKeys: resourceKeys
            )
        )
        let sourceFiles = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }

        XCTAssertFalse(sourceFiles.isEmpty)
        for sourceFile in sourceFiles {
            let source = try String(contentsOf: sourceFile, encoding: .utf8)
            let importedModules = source.split(separator: "\n").compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("import ") {
                    return String(trimmed.dropFirst("import ".count))
                }
                if trimmed.hasPrefix("@_exported import ") {
                    return String(trimmed.dropFirst("@_exported import ".count))
                }
                return nil
            }
            XCTAssertEqual(
                importedModules,
                ["Foundation"],
                "\(sourceFile.lastPathComponent) must remain Foundation-only and exclude AppKit, SwiftUI, and CryptoKit."
            )
        }
    }

    private func fixtureObject(named name: String) throws -> [String: Any] {
        let data = try fixtureData(named: name)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func fixtureData(named name: String) throws -> Data {
        let directory = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "v1", withExtension: nil))
        return try Data(contentsOf: directory.appending(path: name, directoryHint: .notDirectory).appendingPathExtension("json"))
    }

    private func decode<Value: Decodable>(_ type: Value.Type) -> (Data) throws -> Void {
        { data in
            _ = try ConversationEventCoding.makeDecoder().decode(type, from: data)
        }
    }
}
