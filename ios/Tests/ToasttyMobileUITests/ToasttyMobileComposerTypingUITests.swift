import XCTest

@MainActor
final class ToasttyMobileComposerTypingUITests: XCTestCase {
    func testOnscreenKeyboardTapsPreserveWordOrderAcrossFirstWrap() {
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
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let initialHeight = input.frame.height
        var expected = ""
        for word in "this is a normal message with several words on the second line".split(separator: " ") {
            for character in word {
                let lowercaseKey = keyboard.keys[String(character)]
                let key = lowercaseKey.exists ? lowercaseKey : keyboard.keys[String(character).uppercased()]
                XCTAssertTrue(key.exists, "Expected the standard keyboard key for \(character)")
                key.tap()
            }
            keyboard.keys["space"].tap()
            expected += word + " "
            XCTAssertEqual((input.value as? String)?.lowercased(), expected,
                           "Onscreen key taps must keep each completed word in order")
        }
        XCTAssertGreaterThan(input.frame.height, initialHeight, "The draft must cross a soft-wrap boundary")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "composer-onscreen-key-taps-after-wrap"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

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
