import XCTest

@MainActor
final class ToasttyMobileBadgeUITests: XCTestCase {
    func testPermissionWaitsForIntroductionThenBadgeTracksAttentionAndUnpair() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_APP_BADGE"] = "1"
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-home"].waitForExistence(timeout: 10))

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // This test runs on a clean simulator. Start without push configuration
        // and with real badge writes: attention must not prompt on its own.
        let allow = springboard.buttons["Allow"]
        XCTAssertFalse(allow.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["toastty-mobile-notifications-continue"].exists)

        // The Mac and relay remain fixtures; permission uses the system client.
        app.terminate()
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_NOTIFICATIONS"] = "system-intro"
        app.launch()
        let introduction = app.descendants(matching: .any)["toastty-mobile-notifications-introduction"].firstMatch
        XCTAssertTrue(introduction.waitForExistence(timeout: 8))
        XCTAssertFalse(allow.exists)
        attachHomeScreen(app, name: "ios-notification-introduction-before-permission")
        app.buttons["toastty-mobile-notifications-not-now"].tap()
        XCTAssertTrue(introduction.waitForNonExistence(timeout: 5))
        XCTAssertFalse(allow.waitForExistence(timeout: 2))

        // Relaunch resets only fixture intent, so Continue can exercise the
        // real permission prompt after the earlier Not now path stayed quiet.
        app.terminate()
        app.launch()
        XCTAssertTrue(introduction.waitForExistence(timeout: 8))
        app.buttons["toastty-mobile-notifications-continue"].tap()
        XCTAssertTrue(allow.waitForExistence(timeout: 5),
            "This permission test requires a clean simulator with no previous notification choice.")
        attachHomeScreen(springboard, name: "ios-notification-permission-after-continue")
        allow.tap()
        XCTAssertTrue(introduction.waitForNonExistence(timeout: 5))

        let iconLabel = app.label
        XCTAssertFalse(iconLabel.isEmpty)
        XCUIDevice.shared.press(.home)
        let icon = springboard.icons[iconLabel]
        XCTAssertTrue(icon.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForBadge("7", on: icon), "Expected seven attention sessions. Icon: \(icon.debugDescription)")
        attachHomeScreen(springboard, name: "ios-app-badge-seven")

        // With the Mac's task system on, the badge is the yellow number on
        // Home's Needs you switcher, not its Ready to review count.
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "TOASTTY_MOBILE_FIXTURE_NOTIFICATIONS")
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_TASKS"] = "1"
        app.launch()
        let needsYouSegment = app.buttons["toastty-mobile-home-segment-needsYou"]
        XCTAssertTrue(needsYouSegment.waitForExistence(timeout: 10))
        XCTAssertEqual(needsYouSegment.label, "Only what needs you, 9, 1 ready for review")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(waitForBadge("9", on: springboard.icons[iconLabel]), "Expected the nine Needs you rows.")
        attachHomeScreen(springboard, name: "ios-app-badge-task-board-nine")

        // A new process has no known badge count until its first live snapshot.
        // The reconnecting fixture must preserve the badge stored by iOS.
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "TOASTTY_MOBILE_FIXTURE_TASKS")
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_SCENARIO"] = "reconnecting"
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-home"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(waitForBadge("9", on: springboard.icons[iconLabel]))

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
