import UIKit
import XCTest

@MainActor
final class ToasttyMobileNotificationsUITests: XCTestCase {
    func testContinueReturnsToHomeAndSettingsShowsPendingWithoutAnotherScreen() {
        let app = launch(mode: "intro")
        let intro = app.descendants(matching: .any)["toastty-mobile-notifications-introduction"].firstMatch
        XCTAssertTrue(intro.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Alerts include the session title. Titles pass through Toastty’s notification service and Apple."].exists)
        let preview = app.descendants(matching: .any)["toastty-mobile-notifications-preview"].firstMatch
        XCTAssertTrue(preview.exists)
        XCTAssertEqual(preview.label, "Example notification: Fix checkout bug, Ready")
        XCTAssertTrue(app.buttons["toastty-mobile-notifications-continue"].isHittable)
        XCTAssertTrue(app.buttons["toastty-mobile-notifications-not-now"].isHittable)
        XCTAssertTrue(app.staticTexts["You can change this later in Settings."].exists)
        capture(app, name: "Notification introduction")
        app.buttons["toastty-mobile-notifications-continue"].tap()
        XCTAssertTrue(app.buttons["toastty-mobile-settings-button"].waitForExistence(timeout: 5))
        XCTAssertFalse(intro.exists)
        app.buttons["toastty-mobile-settings-button"].tap()
        XCTAssertTrue(app.switches["toastty-mobile-notifications-toggle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Enabling alerts. Keep Toastty open and connected to your Mac."].exists)
        capture(app, name: "Home after Allow and pending Settings")
    }

    func testNotNowIsRememberedAndSettingsStillOffersOneToggle() {
        let app = launch(mode: "intro")
        let notNowButton = app.buttons["toastty-mobile-notifications-not-now"]
        XCTAssertTrue(notNowButton.waitForExistence(timeout: 8))
        notNowButton.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        XCTAssertFalse(app.descendants(matching: .any)["toastty-mobile-notifications-introduction"].firstMatch.exists)
        app.buttons["toastty-mobile-settings-button"].tap()
        let toggle = app.switches["toastty-mobile-notifications-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        app.buttons["toastty-mobile-settings-done"].tap()
        XCTAssertFalse(app.buttons["toastty-mobile-notifications-continue"].exists)
    }

    func testIntroductionPreviewAndActionsRemainReachableAtAccessibilityXXXL() {
        let app = launch(mode: "intro", preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let intro = app.descendants(matching: .any)["toastty-mobile-notifications-introduction"].firstMatch
        XCTAssertTrue(intro.waitForExistence(timeout: 8))
        capture(app, name: "Notification introduction accessibility XXXL top")

        let preview = app.descendants(matching: .any)["toastty-mobile-notifications-preview"].firstMatch
        scrollTo(preview, in: app)
        XCTAssertEqual(preview.label, "Example notification: Fix checkout bug, Ready")
        capture(app, name: "Notification introduction accessibility XXXL preview")

        let continueButton = app.buttons["toastty-mobile-notifications-continue"]
        scrollTo(continueButton, in: app)
        XCTAssertTrue(continueButton.isHittable)
        let notNowButton = app.buttons["toastty-mobile-notifications-not-now"]
        scrollTo(notNowButton, in: app)
        XCTAssertTrue(notNowButton.isHittable)
        capture(app, name: "Notification introduction accessibility XXXL actions")
        notNowButton.tap()
        XCTAssertTrue(app.buttons["toastty-mobile-settings-button"].waitForExistence(timeout: 5))
        XCTAssertFalse(intro.exists)
    }

    func testIntroductionActionsRemainReachableAtXXXL() {
        let app = launch(mode: "intro", preferredContentSizeCategory: .extraExtraExtraLarge)
        let intro = app.descendants(matching: .any)["toastty-mobile-notifications-introduction"].firstMatch
        XCTAssertTrue(intro.waitForExistence(timeout: 8))
        capture(app, name: "Notification introduction XXXL top")

        let continueButton = app.buttons["toastty-mobile-notifications-continue"]
        scrollTo(continueButton, in: app)
        XCTAssertTrue(continueButton.isHittable)
        let notNowButton = app.buttons["toastty-mobile-notifications-not-now"]
        scrollTo(notNowButton, in: app)
        XCTAssertTrue(notNowButton.isHittable)
        capture(app, name: "Notification introduction XXXL actions")
        notNowButton.tap()
        XCTAssertTrue(app.buttons["toastty-mobile-settings-button"].waitForExistence(timeout: 5))
        XCTAssertFalse(intro.exists)
    }

    func testSetupErrorIsSmallAndProvidesRetryInHomeAndSettings() {
        let app = launch(mode: "error")
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-notifications-error"].firstMatch.waitForExistence(timeout: 8))
        capture(app, name: "Small setup error on Home")
        app.buttons["toastty-mobile-settings-button"].tap()
        XCTAssertTrue(app.switches["toastty-mobile-notifications-toggle"].waitForExistence(timeout: 5))
        for _ in 0..<4 {
            if app.buttons["toastty-mobile-notifications-retry"].exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["toastty-mobile-notifications-retry"].waitForExistence(timeout: 5))
    }

    func testDisabledAlertsBeforeOptInShowAnOffBlockedToggleAndLinkToIOSSettings() {
        let app = launch(mode: "denied")
        XCTAssertTrue(app.buttons["toastty-mobile-settings-button"].waitForExistence(timeout: 8))
        app.buttons["toastty-mobile-settings-button"].tap()
        let toggle = app.switches["toastty-mobile-notifications-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertFalse(toggle.isEnabled)
        XCTAssertTrue(app.staticTexts["Alerts are off in iOS Settings."].exists)
        XCTAssertTrue(app.buttons["toastty-mobile-notifications-open-settings"].exists)
        capture(app, name: "Permission denied in Settings")
    }

    private func launch(mode: String, preferredContentSizeCategory: UIContentSizeCategory? = nil) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["TOASTTY_MOBILE_USE_FIXTURE": "1", "TOASTTY_MOBILE_FIXTURE_NOTIFICATIONS": mode]
        if let preferredContentSizeCategory {
            app.launchArguments = ["-UIPreferredContentSizeCategoryName", preferredContentSizeCategory.rawValue]
        }
        app.launch()
        return app
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
