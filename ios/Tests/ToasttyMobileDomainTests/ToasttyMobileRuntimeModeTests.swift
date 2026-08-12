import Foundation
import XCTest
@testable import ToasttyMobileDomain

final class ToasttyMobileRuntimeModeTests: XCTestCase {
    func testFixtureFlagTakesPrecedenceOverGateway() {
        let mode = ToasttyMobileRuntimeMode(environment: [
            "TOASTTY_MOBILE_USE_FIXTURE": "1",
            "TOASTTY_MOBILE_GATEWAY_URL": "https://mac.tailnet.ts.net",
        ])

        XCTAssertEqual(mode, .fixture)
    }

    func testLoopbackHTTPSelectsLocalMode() throws {
        let expectedURL = try XCTUnwrap(URL(string: "http://127.0.0.1:42871"))
        let mode = ToasttyMobileRuntimeMode(environment: [
            "TOASTTY_MOBILE_GATEWAY_URL": expectedURL.absoluteString,
        ])

        XCTAssertEqual(mode, .local(gatewayURL: expectedURL))
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
}
