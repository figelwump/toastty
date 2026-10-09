import XCTest

@MainActor
final class ToasttyMobileBadgeUITests: XCTestCase {
    func testHomeScreenBadgeShowsAttentionAndUnpairClearsIt() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_APP_BADGE"] = "1"
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-home"].waitForExistence(timeout: 10))

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // A clean simulator may show the OS permission sheet. The test uses
        // the real badge API; only the session snapshot comes from a fixture.
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }

        let iconLabel = app.label
        XCTAssertFalse(iconLabel.isEmpty)
        XCUIDevice.shared.press(.home)
        let icon = springboard.icons[iconLabel]
        XCTAssertTrue(icon.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForBadge("7", on: icon), "Expected seven attention sessions. Icon: \(icon.debugDescription)")
        attachHomeScreen(springboard, name: "ios-app-badge-seven")

        // A new process has no known badge count until its first live snapshot.
        // The reconnecting fixture must preserve the badge stored by iOS.
        app.terminate()
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_SCENARIO"] = "reconnecting"
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-home"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(waitForBadge("7", on: springboard.icons[iconLabel]))

        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        let settingsButton = app.buttons["toastty-mobile-settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-settings"].waitForExistence(timeout: 5))
        app.buttons["toastty-mobile-unpair"].tap()
        XCTAssertTrue(app.buttons["toastty-mobile-confirm-unpair"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["toastty-mobile-confirm-unpair"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-session-unpaired"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        let cleared = NSPredicate { _, _ in
            let value = springboard.icons[iconLabel].value as? String ?? ""
            return value.isEmpty || value == "0"
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: cleared, object: nil)], timeout: 5), .completed)
        attachHomeScreen(springboard, name: "ios-app-badge-cleared")
    }

    private func waitForBadge(_ count: String, on icon: XCUIElement) -> Bool {
        let predicate = NSPredicate { _, _ in
            (icon.value as? String)?.contains(count) == true
        }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 5) == .completed
    }

    private func attachHomeScreen(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
