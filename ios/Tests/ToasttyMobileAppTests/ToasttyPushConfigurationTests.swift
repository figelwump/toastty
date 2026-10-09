import XCTest
@testable import ToasttyMobileApp

final class ToasttyPushConfigurationTests: XCTestCase {
    func testUnconfiguredArbitraryIdentityAndProdtestCannotEnableDevelopmentPush() {
        XCTAssertNil(ToasttyPushConfiguration(infoDictionary: [:]))
        var value = Self.developmentInfo
        XCTAssertNotNil(ToasttyPushConfiguration(infoDictionary: value))
        for bundleID in ["com.giantthings.toastty.mobile.dev.worktree", "com.giantthings.toastty.mobile.prodtest", "com.giantthings.toastty.mobile"] {
            value["CFBundleIdentifier"] = bundleID
            XCTAssertNil(ToasttyPushConfiguration(infoDictionary: value))
        }
    }
    func testRelayOriginAndAPNsEnvironmentMustAgreeWithFixedIdentity() {
        for url in ["http://push.example.com", "https://secret@push.example.com", "https://push.example.com/path", "https://push.example.com?key=value"] {
            var info = Self.developmentInfo
            info["ToasttyMobilePushRelayURL"] = url
            XCTAssertNil(ToasttyPushConfiguration(infoDictionary: info))
        }
        var info = Self.developmentInfo
        info["ToasttyMobilePushEnvironment"] = "production"
        XCTAssertNil(ToasttyPushConfiguration(infoDictionary: info))
        info["CFBundleIdentifier"] = "com.giantthings.toastty.mobile"
        XCTAssertNil(ToasttyPushConfiguration(infoDictionary: info))
        info["ToasttyMobilePushRelayID"] = "toastty-push-production-v1"
        XCTAssertNotNil(ToasttyPushConfiguration(infoDictionary: info))
    }
    private static let developmentInfo: [String: String] = [
        "CFBundleIdentifier": "com.giantthings.toastty.mobile.dev",
        "ToasttyMobilePushRelayURL": "https://push.example.com",
        "ToasttyMobilePushRelayID": "toastty-push-dev-v1",
        "ToasttyMobilePushEnvironment": "development",
    ]
}
