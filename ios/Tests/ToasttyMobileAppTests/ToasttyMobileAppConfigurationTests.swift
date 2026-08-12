import Foundation
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

final class ToasttyMobileAppConfigurationTests: XCTestCase {
    func testFixtureConfigurationSeedsDeterministicHome() {
        let configuration = ToasttyMobileAppConfiguration(
            environment: ["TOASTTY_MOBILE_USE_FIXTURE": "1"],
            infoDictionary: [:]
        )

        XCTAssertEqual(configuration.runtimeMode, .fixture)
        XCTAssertEqual(configuration.initialConnectionState, .live)
        XCTAssertEqual(configuration.initialSnapshot, ToasttyMobileFixture.home)
    }

    func testLiveConfigurationDoesNotExposeFixtureWorkspaceData() throws {
        let gateway = try XCTUnwrap(URL(string: "https://toastty-mac.example.ts.net"))
        let configuration = ToasttyMobileAppConfiguration(
            environment: ["TOASTTY_MOBILE_GATEWAY_URL": gateway.absoluteString],
            infoDictionary: [:]
        )

        XCTAssertEqual(configuration.runtimeMode, .live(gatewayURL: gateway))
        XCTAssertEqual(configuration.initialConnectionState, .offline)
        XCTAssertEqual(configuration.initialSnapshot.hostName, "toastty-mac.example.ts.net")
        XCTAssertTrue(configuration.initialSnapshot.workspaces.isEmpty)
    }
}
