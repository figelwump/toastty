import Foundation
import RemoteProtocol
@testable import ToasttyMobileDomain
import XCTest

final class PairingInputParserTests: XCTestCase {
    func testQRCodeParsesOfflineIntoConfirmableCandidate() throws {
        let expiry = Self.now.addingTimeInterval(120)
        let payload = RemoteNativePairingQRPayload(
            gatewayURL: try XCTUnwrap(URL(string: "https://mac.example-tailnet.ts.net")),
            offerID: Self.offerID,
            secret: Self.secret,
            expiresAt: expiry
        )

        let candidate = try PairingInputParser().parseQRCode(
            try payload.encodedString(),
            now: Self.now
        )

        XCTAssertEqual(candidate.gatewayURL.absoluteString, "https://mac.example-tailnet.ts.net")
        XCTAssertEqual(candidate.proof, .qr(offerID: Self.offerID, secret: Self.secret, expiresAt: expiry))
    }

    func testExpiredQRCodeIsRejectedBeforeNetworkExchange() throws {
        let payload = RemoteNativePairingQRPayload(
            gatewayURL: try XCTUnwrap(URL(string: "https://mac.tail.ts.net")),
            offerID: Self.offerID,
            secret: Self.secret,
            expiresAt: Self.now
        )
        XCTAssertThrowsError(try PairingInputParser().parseQRCode(try payload.encodedString(), now: Self.now)) {
            XCTAssertEqual($0 as? PairingInputError, .expired)
        }
    }

    func testQRCodeBoundsAndVersionsAreStrict() throws {
        XCTAssertThrowsError(
            try PairingInputParser().parseQRCode(String(repeating: "x", count: 301), now: Self.now)
        ) {
            XCTAssertEqual($0 as? PairingInputError, .inputTooLarge)
        }
        let unsupported = try Self.encodedPayload(fields: [
            "2", "https://mac.tail.ts.net", Self.offerID.uuidString.lowercased(),
            Self.secret, "1786200120.0", "2.0",
        ])
        XCTAssertThrowsError(try PairingInputParser().parseQRCode(unsupported, now: Self.now)) {
            XCTAssertEqual($0 as? PairingInputError, .unsupportedVersion)
        }
    }

    func testManualInputCanonicalizesHostnameAndFallbackCode() throws {
        let candidate = try PairingInputParser().parseManual(
            gateway: " MAC.EXAMPLE-TAILNET.TS.NET ",
            code: "23456789abcd"
        )
        XCTAssertEqual(candidate.gatewayURL.absoluteString, "https://mac.example-tailnet.ts.net")
        XCTAssertEqual(candidate.proof, .manual(fallbackCode: "2345-6789-ABCD"))
    }

    func testHostileOrNonRootGatewaysAreRejected() {
        let values = [
            "http://mac.tail.ts.net",
            "https://mac.tail.ts.net:443",
            "https://user@mac.tail.ts.net",
            "https://mac.tail.ts.net/path",
            "https://mac.tail.ts.net?secret=x",
            "https://mac.tail.ts.net#fragment",
            "https://mac.tail.ts.net.evil.example",
            "https://ts.net",
            "https://.ts.net",
            "https://mac..tail.ts.net",
            "https://-mac.tail.ts.net",
            "https://mac-.tail.ts.net",
            "https://mác.tail.ts.net",
            "https://127.0.0.1",
            "https://[::1]",
            "javascript:alert(1)",
        ]
        for value in values {
            XCTAssertThrowsError(
                try PairingInputParser().parseManual(gateway: value, code: "2345-6789-ABCD"),
                "Expected hostile gateway rejection for \(value)"
            )
        }
    }

    func testAmbiguousOrMalformedFallbackCodesAreRejected() {
        for code in [
            "", "2345-6789-ABC", "2345-6789-ABCDE", "1234-5678-ABCD",
            "2345_6789_ABCD", "2345-6789-ABCI", "2345-6789-ABCO",
        ] {
            XCTAssertThrowsError(
                try PairingInputParser().parseManual(gateway: "mac.tail.ts.net", code: code),
                "Expected fallback rejection for \(code)"
            )
        }
    }

    func testPairingProofDescriptionsAreRedacted() throws {
        let candidate = try PairingInputParser().parseManual(
            gateway: "mac.tail.ts.net",
            code: "2345-6789-ABCD"
        )
        XCTAssertFalse(String(describing: candidate).contains("2345"))
        XCTAssertEqual(String(describing: candidate.proof), "<redacted pairing proof>")
    }

    private static func encodedPayload(fields: [String]) throws -> String {
        let data = try JSONEncoder().encode(fields)
        return RemoteNativePairingQRPayload.encodedPrefix + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static let now = Date(timeIntervalSince1970: 1_786_200_000)
    private static let offerID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
    private static let secret = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
}
