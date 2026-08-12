import Foundation
import XCTest
@testable import ToasttyMobileApp

final class DeepLinkParserTests: XCTestCase {
    private let conversationID = UUID(
        uuidString: "B1000000-0000-0000-0000-000000000007"
    )!
    private let workspaceID = UUID(
        uuidString: "A1000000-0000-0000-0000-000000000003"
    )!

    func testParsesStableConversationAndWorkspaceRoutesForConfiguredScheme() throws {
        let parser = try XCTUnwrap(DeepLinkParser(scheme: "toastty-mobile-dev"))

        XCTAssertEqual(
            parser.parse(try url("toastty-mobile-dev://conversation/\(conversationID.uuidString)")),
            .conversation(conversationID)
        )
        XCTAssertEqual(
            parser.parse(try url("TOASTTY-MOBILE-DEV://workspace/\(workspaceID.uuidString.lowercased())")),
            .workspace(workspaceID)
        )
    }

    func testRejectsOtherBuildSchemesAndHostileOrMalformedRoutes() throws {
        let parser = try XCTUnwrap(DeepLinkParser(scheme: "toastty-mobile-dev"))
        let rejected = [
            "toastty-mobile://conversation/\(conversationID.uuidString)",
            "toastty-mobile-prodtest://conversation/\(conversationID.uuidString)",
            "toastty-mobile-dev://conversa%74ion/\(conversationID.uuidString)",
            "toastty-mobile-dev://attacker@conversation/\(conversationID.uuidString)",
            "toastty-mobile-dev://conversation/\(conversationID.uuidString)?redirect=https://attacker.invalid",
            "toastty-mobile-dev://conversation/\(conversationID.uuidString)#fragment",
            "toastty-mobile-dev://conversation/../\(conversationID.uuidString)",
            "toastty-mobile-dev://conversation/\(conversationID.uuidString)/extra",
            "toastty-mobile-dev://unknown/\(conversationID.uuidString)",
            "toastty-mobile-dev://workspace/not-a-uuid",
        ]

        for rawURL in rejected {
            XCTAssertNil(parser.parse(try url(rawURL)), rawURL)
        }
    }

    func testRejectsInvalidConfiguredScheme() {
        XCTAssertNil(DeepLinkParser(scheme: ""))
        XCTAssertNil(DeepLinkParser(scheme: "1toastty"))
        XCTAssertNil(DeepLinkParser(scheme: "toastty mobile"))
    }

    private func url(_ value: String) throws -> URL {
        try XCTUnwrap(URL(string: value))
    }
}
