import XCTest

@MainActor
final class ToasttyMobileComposerTraceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testTypingTraceExportOpensFilesOnlyInDiagnosticLaunch() {
        let app = launchFixture(traceEnabled: true)
        let home = app.descendants(matching: .any)["toastty-mobile-home"]
        let session = app.buttons["toastty-mobile-grouped-card-B1000000-0000-0000-0000-000000000007"]
        for _ in 0..<12 where !session.isHittable { home.swipeUp() }
        XCTAssertTrue(session.isHittable)
        session.tap()
        let input = app.descendants(matching: .any)["toastty-mobile-composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        app.typeText("This is filler text for a typing trace.")
        XCTAssertEqual(input.value as? String, "This is filler text for a typing trace.")
        let back = app.navigationBars.firstMatch.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        openSettings(app)
        let export = app.buttons["toastty-mobile-save-typing-trace"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.tap()
        // Save only this test's trace inside the disposable simulator.
        let save = app.buttons["Save"]
        let picker = XCTAttachment(screenshot: app.screenshot())
        picker.name = "typing-trace-files-picker"
        picker.lifetime = .keepAlways
        add(picker)
        XCTAssertTrue(save.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(save.isHittable)
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Could not save typing trace"].exists)
    }

    func testNormalLaunchDoesNotOfferTypingTraceExport() {
        let app = launchFixture(traceEnabled: false)
        openSettings(app)
        XCTAssertFalse(app.buttons["toastty-mobile-save-typing-trace"].exists)
    }

    private func launchFixture(traceEnabled: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_SCENARIO"] = "gated-send"
        app.launchEnvironment["TOASTTY_MOBILE_COMPOSER_TRACE"] = traceEnabled ? "1" : "0"
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-home"].waitForExistence(timeout: 10))
        return app
    }

    private func openSettings(_ app: XCUIApplication) {
        let settings = app.buttons["toastty-mobile-settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let export = app.buttons["toastty-mobile-save-typing-trace"]
        let list = app.descendants(matching: .any)["toastty-mobile-settings"]
        for _ in 0..<5 where !export.isHittable { list.swipeUp() }
    }
}
