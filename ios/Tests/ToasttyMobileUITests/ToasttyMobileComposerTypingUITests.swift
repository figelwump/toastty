import XCTest

@MainActor
final class ToasttyMobileComposerTypingUITests: XCTestCase {
    func testOnscreenTypingPreservesRecordedDraftAcrossLineGrowth() {
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
        var expected = "Here’s another thought taking a step back here what if we used open claw for the coordinator. And the idea is "
        app.typeText(expected)
        let initialHeight = input.frame.height
        for character in "that this would keep the words in order " {
            let label = character == " " ? "space" : String(character)
            let lowercaseKey = keyboard.keys[label]
            let key = lowercaseKey.exists ? lowercaseKey : keyboard.keys[label.uppercased()]
            XCTAssertTrue(key.exists)
            key.tap()
            expected.append(character)
            // UIKit includes inline predictions in the accessibility value;
            // compare the typed prefix until a space commits the whole word.
            XCTAssertTrue((input.value as? String)?.lowercased().hasPrefix(expected.lowercased()) == true,
                           "Typing \(character) must retain the insertion point across a wrap")
            if character == " " {
                XCTAssertEqual((input.value as? String)?.lowercased(), expected.lowercased())
            }
        }
        XCTAssertGreaterThan(input.frame.height, initialHeight)
    }

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

    /// A keystroke updates the composer only. Each key used to run the
    /// app's root view, the conversation screen and the transcript again,
    /// and in a long chat that made typing slow. The app counts the
    /// transcript's body runs (`TOASTTY_MOBILE_FIXTURE_RENDER_COUNTS`).
    func testTypingDoesNotRunTheTranscriptAgainForEachKey() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_TASKS"] = "1"
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_COORDINATOR"] = "working"
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_RENDER_COUNTS"] = "1"
        app.launchArguments += ["-toastty-mobile-collapsed-project-cards", ""]
        app.launch()
        XCTAssertTrue(app.buttons["toastty-mobile-home-segment-all"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Coordinator"].tap()
        let input = app.descendants(matching: .any)["toastty-mobile-composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // The first key turns Stop into Send; count from the second.
        app.typeText("S")
        Thread.sleep(forTimeInterval: 1)
        let count = app.descendants(matching: .any)["toastty-mobile-fixture-transcript-body-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        let before = try XCTUnwrap(Int(count.value as? String ?? ""))
        // One key at a time, so that each key gets its own update, and short
        // enough that the field does not grow a line.
        let keys = "hip it today"
        for key in keys {
            app.typeText(String(key))
            Thread.sleep(forTimeInterval: 0.1)
        }
        Thread.sleep(forTimeInterval: 1)
        let after = try XCTUnwrap(Int(count.value as? String ?? ""))
        // UIKit can add an inline prediction to the value after the last word.
        XCTAssertTrue((input.value as? String)?.lowercased().hasPrefix("ship it today") == true)
        XCTAssertLessThanOrEqual(after - before, 2, "\(keys.count) keys ran the transcript's body \(after - before) times")

        // The app keeps the draft, not the composer: it is still there after
        // another tab shows. A slow drag down the transcript drops the
        // keyboard, which covers the tab bar.
        let transcript = app.scrollViews["toastty-mobile-transcript"]
        transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).press(
            forDuration: 0.1,
            thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)),
            withVelocity: .slow,
            thenHoldForDuration: 0.1
        )
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.buttons["toastty-mobile-home-segment-all"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Coordinator"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue((input.value as? String)?.lowercased().hasPrefix("ship it today") == true)
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
