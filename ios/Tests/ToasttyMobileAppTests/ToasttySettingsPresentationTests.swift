import Foundation
import RemoteProtocol
import XCTest
@testable import ToasttyMobileApp

final class ToasttySettingsPresentationTests: XCTestCase {
    func testGatewayPresentationRedactsEverythingExceptHost() throws {
        let url = try XCTUnwrap(URL(string: "https://user:secret@toastty.test.ts.net/private?token=secret#fragment"))

        let presentation = ToasttySettingsPresentation(
            gatewayURL: url,
            reachability: .live
        )

        XCTAssertEqual(presentation.host, "toastty.test.ts.net")
        XCTAssertFalse(presentation.host.contains("secret"))
        XCTAssertFalse(presentation.host.contains("private"))
    }

    func testDeviceMetadataRemainsFieldBasedAndCredentialFree() throws {
        let url = try XCTUnwrap(URL(string: "https://toastty.test.ts.net"))
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let device = RemoteGatewayDeviceSummary(
            id: UUID(uuidString: "D1000000-0000-0000-0000-000000000001")!,
            name: "Vishal’s iPhone",
            scopes: [.send, .read]
        )

        let presentation = ToasttySettingsPresentation(
            gatewayURL: url,
            reachability: .reconnecting,
            projectionRunID: "run-id",
            projectionGeneration: 42,
            activeConversationCursor: 19,
            device: device,
            credentialCreatedAt: createdAt
        )

        XCTAssertEqual(presentation.device, device)
        XCTAssertEqual(presentation.device?.scopes, [.read, .send])
        XCTAssertEqual(presentation.credentialCreatedAt, createdAt)
        XCTAssertEqual(presentation.activeConversationCursor, 19)
    }
}
