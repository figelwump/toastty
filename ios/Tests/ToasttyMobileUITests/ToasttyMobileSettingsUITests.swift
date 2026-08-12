import UIKit
import XCTest

@MainActor
final class ToasttyMobileSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFixtureSettingsShowsRedactedConnectionAndUnpairs() {
        let app = launchFixtureApp()
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-home"].waitForExistence(timeout: 10))

        let settingsButton = app.buttons["toastty-mobile-settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()

        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-settings"].waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.descendants(matching: .any)["toastty-mobile-settings-host"].label,
            "Host, fixture-mac.example.ts.net"
        )
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-settings-device-name"].exists)
        XCTAssertTrue(app.staticTexts["Device scopes and per-session remote input are managed on your Mac."].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "AAAAAAAAAAAA")).firstMatch.exists)
        attachScreenshot(named: "fixture-settings", of: app)

        app.buttons["toastty-mobile-unpair"].tap()
        XCTAssertTrue(app.alerts["Unpair this iPhone?"].waitForExistence(timeout: 5))
        app.buttons["toastty-mobile-confirm-unpair"].firstMatch.tap()

        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-session-unpaired"].waitForExistence(timeout: 5))
    }

    func testFixtureSettingsReflowsAtAccessibilityXXXL() {
        let app = launchFixtureApp(launchArguments: [
            "-UIPreferredContentSizeCategoryName",
            UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue,
        ])
        XCTAssertTrue(app.buttons["toastty-mobile-settings-button"].waitForExistence(timeout: 10))
        app.buttons["toastty-mobile-settings-button"].tap()

        let settings = app.descendants(matching: .any)["toastty-mobile-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-settings-host"].exists)
        let unpairButton = app.buttons["toastty-mobile-unpair"]
        for _ in 0..<5 where !unpairButton.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(unpairButton.isHittable)
        attachScreenshot(named: "fixture-settings-accessibility-xxxl", of: app)
    }

    private func launchFixtureApp(launchArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_SCENARIO"] = "home"
        app.launchArguments += launchArguments
        app.launch()
        return app
    }

    private func attachScreenshot(named name: String, of app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
