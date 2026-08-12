import Foundation
import XCTest
@testable import ToasttyMobileDomain

final class ToasttyMobileRuntimeModeTests: XCTestCase {
    func testMissingGatewayIsUnconfiguredRatherThanFixture() {
        let mode = ToasttyMobileRuntimeMode(environment: [:])

        XCTAssertEqual(mode, .unconfigured)
        XCTAssertEqual(mode.displayName, "unconfigured")
    }

    func testFixtureFlagHonorsBuildConfiguration() throws {
        let gateway = try XCTUnwrap(URL(string: "https://mac.tailnet.ts.net"))
        let mode = ToasttyMobileRuntimeMode(environment: [
            "TOASTTY_MOBILE_USE_FIXTURE": "1",
            "TOASTTY_MOBILE_GATEWAY_URL": gateway.absoluteString,
        ])

#if DEBUG
        XCTAssertEqual(mode, .fixture)
#else
        XCTAssertEqual(mode, .live(gatewayURL: gateway))
#endif
    }

    func testFixtureScenarioWithoutFixtureFlagDoesNotSelectFixtureMode() {
        let mode = ToasttyMobileRuntimeMode(environment: [
            "TOASTTY_MOBILE_FIXTURE_SCENARIO": "home",
        ])

        XCTAssertEqual(mode, .unconfigured)
    }

    func testSupportedLoopbackHTTPHostsSelectLocalMode() throws {
        for value in [
            "http://127.0.0.1:42871",
            "http://localhost:42871",
            "http://gateway.localhost:42871",
            "http://[::1]:42871",
        ] {
            let expectedURL = try XCTUnwrap(URL(string: value))
            let mode = ToasttyMobileRuntimeMode(environment: [
                "TOASTTY_MOBILE_GATEWAY_URL": expectedURL.absoluteString,
            ])

            XCTAssertEqual(mode, .local(gatewayURL: expectedURL), value)
        }
    }

    func testTailnetHTTPSSelectsLiveMode() throws {
        let expectedURL = try XCTUnwrap(URL(string: "https://toastty-mac.example.ts.net"))
        let mode = ToasttyMobileRuntimeMode(environment: [
            "TOASTTY_MOBILE_GATEWAY_URL": expectedURL.absoluteString,
        ])

        XCTAssertEqual(mode, .live(gatewayURL: expectedURL))
    }

    func testBundledGatewayProvidesFallback() throws {
        let expectedURL = try XCTUnwrap(URL(string: "https://toastty-mac.example.ts.net"))
        let mode = ToasttyMobileRuntimeMode(
            environment: [:],
            bundledGatewayURL: expectedURL
        )

        XCTAssertEqual(mode, .live(gatewayURL: expectedURL))
    }

    func testEnvironmentGatewayOverridesBundledGateway() throws {
        let environmentURL = try XCTUnwrap(URL(string: "https://environment-mac.example.ts.net"))
        let bundledURL = try XCTUnwrap(URL(string: "https://bundled-mac.example.ts.net"))
        let mode = ToasttyMobileRuntimeMode(
            environment: ["TOASTTY_MOBILE_GATEWAY_URL": environmentURL.absoluteString],
            bundledGatewayURL: bundledURL
        )

        XCTAssertEqual(mode, .live(gatewayURL: environmentURL))
    }

    func testBlankEnvironmentGatewayFallsBackToBundledGateway() throws {
        let bundledURL = try XCTUnwrap(URL(string: "https://bundled-mac.example.ts.net"))

        for blankValue in ["", "   ", "\n\t"] {
            let mode = ToasttyMobileRuntimeMode(
                environment: ["TOASTTY_MOBILE_GATEWAY_URL": blankValue],
                bundledGatewayURL: bundledURL
            )

            XCTAssertEqual(mode, .live(gatewayURL: bundledURL))
        }
    }

    func testInvalidNonblankEnvironmentGatewayDoesNotFallBackToBundledGateway() throws {
        let bundledURL = try XCTUnwrap(URL(string: "https://bundled-mac.example.ts.net"))

        for invalidValue in [
            "toastty-mac",
            "ftp://toastty-mac.example.ts.net",
        ] {
            let mode = ToasttyMobileRuntimeMode(
                environment: ["TOASTTY_MOBILE_GATEWAY_URL": invalidValue],
                bundledGatewayURL: bundledURL
            )

            XCTAssertEqual(mode, .unconfigured, "Expected \(invalidValue.debugDescription) to be rejected")
        }
    }

    func testInvalidBundledGatewayIsUnconfigured() throws {
        for invalidValue in [
            "toastty-mac",
            "ftp://toastty-mac.example.ts.net",
        ] {
            let bundledURL = try XCTUnwrap(URL(string: invalidValue))
            let mode = ToasttyMobileRuntimeMode(environment: [:], bundledGatewayURL: bundledURL)

            XCTAssertEqual(mode, .unconfigured, "Expected \(invalidValue) to be rejected")
        }
    }
}
