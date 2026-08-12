import Foundation
import XCTest
@testable import ToasttyMobileApp
@testable import ToasttyMobileDomain

final class ToasttyMobileAppConfigurationTests: XCTestCase {
    func testUnconfiguredAppStartsEmptyForPairing() {
        let configuration = ToasttyMobileAppConfiguration(
            environment: [:],
            infoDictionary: [:]
        )

        XCTAssertEqual(configuration.runtimeMode, .unconfigured)
        XCTAssertNil(configuration.fixtureScenario)
        XCTAssertEqual(configuration.initialConnectionState, .offline)
        XCTAssertEqual(configuration.initialSnapshot.hostName, "Toastty Mac")
        XCTAssertTrue(configuration.initialSnapshot.workspaces.isEmpty)
    }

    func testFixtureConfigurationHonorsBuildConfiguration() {
        let configuration = ToasttyMobileAppConfiguration(
            environment: ["TOASTTY_MOBILE_USE_FIXTURE": "1"],
            infoDictionary: [:]
        )

#if DEBUG
        XCTAssertEqual(configuration.runtimeMode, .fixture)
        XCTAssertEqual(configuration.fixtureScenario, .home)
        XCTAssertEqual(configuration.initialConnectionState, .live)
        XCTAssertEqual(configuration.initialSnapshot, ToasttyMobileFixture.home)
#else
        XCTAssertEqual(configuration.runtimeMode, .unconfigured)
        XCTAssertNil(configuration.fixtureScenario)
        XCTAssertEqual(configuration.initialConnectionState, .offline)
        XCTAssertEqual(configuration.initialSnapshot.hostName, "Toastty Mac")
        XCTAssertTrue(configuration.initialSnapshot.workspaces.isEmpty)
#endif
    }

    func testFixtureScenarioAloneDoesNotEnableFixtureHarness() {
        let configuration = ToasttyMobileAppConfiguration(
            environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "gated-send"],
            infoDictionary: [:]
        )

        XCTAssertEqual(configuration.runtimeMode, .unconfigured)
        XCTAssertNil(configuration.fixtureScenario)
        XCTAssertTrue(configuration.initialSnapshot.workspaces.isEmpty)
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

    func testBlankEnvironmentGatewayUsesBundledConfiguration() throws {
        let gateway = try XCTUnwrap(URL(string: "https://bundled-mac.example.ts.net"))
        let configuration = ToasttyMobileAppConfiguration(
            environment: ["TOASTTY_MOBILE_GATEWAY_URL": "  \n"],
            infoDictionary: ["ToasttyMobileGatewayURL": gateway.absoluteString]
        )

        XCTAssertEqual(configuration.runtimeMode, .live(gatewayURL: gateway))
        XCTAssertEqual(configuration.initialSnapshot.hostName, "bundled-mac.example.ts.net")
        XCTAssertTrue(configuration.initialSnapshot.workspaces.isEmpty)
    }

    func testInvalidNonblankEnvironmentGatewayDoesNotUseBundledConfiguration() throws {
        let gateway = try XCTUnwrap(URL(string: "https://bundled-mac.example.ts.net"))
        let configuration = ToasttyMobileAppConfiguration(
            environment: ["TOASTTY_MOBILE_GATEWAY_URL": "not-a-gateway"],
            infoDictionary: ["ToasttyMobileGatewayURL": gateway.absoluteString]
        )

        XCTAssertEqual(configuration.runtimeMode, .unconfigured)
        XCTAssertEqual(configuration.initialSnapshot.hostName, "Toastty Mac")
        XCTAssertTrue(configuration.initialSnapshot.workspaces.isEmpty)
    }

    func testConfigurationReadsOnlyNamedRoutingScheme() {
        let configuration = ToasttyMobileAppConfiguration(
            environment: ["TOASTTY_MOBILE_USE_FIXTURE": "1"],
            infoDictionary: [
                "CFBundleURLTypes": [
                    [
                        "CFBundleURLName": "attacker.invalid",
                        "CFBundleURLSchemes": ["hostile-scheme"],
                    ],
                    [
                        "CFBundleURLName": "com.giantthings.toastty.mobile.routing",
                        "CFBundleURLSchemes": ["toastty-mobile-dev"],
                    ],
                ],
            ]
        )

        XCTAssertEqual(configuration.urlScheme, "toastty-mobile-dev")
    }
}
