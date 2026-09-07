import XCTest

@MainActor
final class ToasttyMobileComposerTypingUITests: XCTestCase {
    func testTypingThroughFirstWrapAndContinuedLinesPreservesTextOrder() {
        let app = XCUIApplication()
        app.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_SCENARIO"] = "gated-send"
        app.launch()
        let home = app.descendants(matching: .any)["toastty-mobile-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        let session = app.buttons["toastty-mobile-grouped-card-B1000000-0000-0000-0000-000000000007"]
        for _ in 0..<12 where !session.isHittable { home.swipeUp() }
        XCTAssertTrue(session.isHittable)
        session.tap()
        let input = app.descendants(matching: .any)["toastty-mobile-composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        var expected = ""
        for part in ["This is a message that grows", " past the first line and keeps", " each new word in its original order.",
                     " The second sentence continues across several more lines without moving the insertion point."] {
            app.typeText(part)
            expected += part
            XCTAssertEqual(input.value as? String, expected)
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "composer-sustained-wrapped-typing"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
