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

    // MARK: - What the Mac sends while the user types

    /// The coordinator's chat, the Coordinator tab's own screen: a response
    /// and the turn's end leave the keyboard, the draft and the insertion
    /// point where the user had them.
    func testTheKeyboardStaysWhileAResponseArrivesInTheCoordinatorsChat() {
        let app = launchIncomingFixture(taskSession: false)
        app.tabBars.buttons["Coordinator"].tap()
        assertTheKeyboardStaysWhileTheMacAnswers(in: app, name: "coordinator")
    }

    /// The same in a task's session, under its task bar.
    func testTheKeyboardStaysWhileAResponseArrivesInATaskSession() {
        let app = launchIncomingFixture(taskSession: true)
        app.tabBars.buttons["Tasks"].tap()
        let row = app.buttons["toastty-subspace-row-A1000000-0000-0000-0000-000000000012"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["toastty-task-bar"].waitForExistence(timeout: 5))
        assertTheKeyboardStaysWhileTheMacAnswers(in: app, name: "task-session")
    }

    /// The agent works while the user types. A response arrives, then the
    /// last one with the turn's end, and the prompt stays closed until the
    /// Mac opens it, as the Mac holds a Claude prompt closed for a moment
    /// after a turn. Send waits for the prompt; typing does not.
    private func assertTheKeyboardStaysWhileTheMacAnswers(in app: XCUIApplication, name: String) {
        let input = app.descendants(matching: .any)["toastty-mobile-composer-input"]
        let keyboard = app.keyboards.firstMatch
        let send = app.buttons["toastty-mobile-composer-send"]
        let log = app.descendants(matching: .any)["toastty-mobile-fixture-keyboard-log"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        input.typeText("draft.")
        // Put the insertion point at the start, where a field that was made
        // again or lost its place would not type. A tap right after typing
        // can be lost, so let the keyboard settle first.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()
        input.typeText("One ")
        XCTAssertEqual(input.value as? String, "One draft.")

        deliver("response", in: app)
        XCTAssertTrue(waitForTranscriptText("Incoming response 1", in: app))
        XCTAssertTrue(keyboard.exists, "A response took the keyboard")
        input.typeText("two ")
        XCTAssertEqual(input.value as? String, "One two draft.")

        deliver("turn-end", in: app)
        XCTAssertTrue(waitForTranscriptText("Incoming response 2", in: app))
        let status = app.descendants(matching: .any)["toastty-mobile-composer-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("Input is not available"), status.label)
        XCTAssertFalse(send.isEnabled)
        XCTAssertTrue(keyboard.exists, "The turn's end took the keyboard")
        input.typeText("three ")
        XCTAssertEqual(input.value as? String, "One two three draft.")
        attachScreenshot(named: "\(name)-typing-while-the-prompt-is-closed", of: app)

        deliver("prompt-opens", in: app)
        XCTAssertTrue(status.waitForNonExistence(timeout: 5))
        XCTAssertTrue(send.isEnabled)
        XCTAssertTrue(keyboard.exists, "The prompt's opening took the keyboard")
        input.typeText("four ")
        XCTAssertEqual(input.value as? String, "One two three four draft.")
        XCTAssertEqual(log.value as? String, "0", "The keyboard went down: \(log.label)")
        attachScreenshot(named: "\(name)-after-the-prompt-opens", of: app)
    }

    private func launchIncomingFixture(taskSession: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_TASKS"] = "1"
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_COORDINATOR"] = "working"
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_INCOMING"] = "1"
        if taskSession { app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_TASK_SESSION_SEND"] = "1" }
        app.launchArguments += ["-toastty-mobile-collapsed-project-cards", ""]
        app.launch()
        XCTAssertTrue(app.buttons["toastty-mobile-home-segment-all"].waitForExistence(timeout: 10))
        return app
    }

    /// Taps the fixture Mac's step and leaves time for a keyboard that
    /// would go down to do so.
    private func deliver(_ step: String, in app: XCUIApplication) {
        let button = app.buttons["toastty-mobile-fixture-incoming-\(step)"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), step)
        button.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    /// A message shows as selectable text, whose value is the text, or as
    /// a label.
    private func waitForTranscriptText(_ text: String, in app: XCUIApplication) -> Bool {
        let asValue = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch
        let asLabel = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if asValue.exists || asLabel.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return false
    }

    private func attachScreenshot(named name: String, of app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
