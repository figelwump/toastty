import XCTest

/// @ mentions in the Coordinator tab's message field, through the fixture:
/// `@` opens the list of tasks above the composer, a tap puts the task in
/// the field as one highlighted word, one Delete removes it, and Send
/// delivers the task's link, which the chat shows as a chip. The field reads
/// a mention as "mention, <title>".
@MainActor
final class ToasttyMobileMentionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTypingAtListsTasksAndATapPutsInAHighlightedWordThatSends() {
        let app = openCoordinator("working")
        let input = composer(in: app)
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        input.typeText("Can you check @")
        let list = mentionList(in: app)
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCTAssertTrue(row("early-session-titles", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(row("Split the parser", in: app).exists)
        attachScreenshot(named: "mention-list-open", of: app)

        input.typeText("pars")
        XCTAssertTrue(waitUntil { self.row("early-session-titles", in: app).exists == false })
        let parser = row("Split the parser", in: app)
        XCTAssertTrue(parser.exists)
        XCTAssertTrue(parser.label.hasPrefix("Split the parser, Working, toastty"), parser.label)
        attachScreenshot(named: "mention-list-filtered", of: app)

        parser.tap()
        XCTAssertTrue(list.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForValue("Can you check mention, Split the parser ", of: input, allowsPrediction: true))
        attachScreenshot(named: "mention-in-field", of: app)

        // One Delete after the space removes the whole word.
        input.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(waitForValue("Can you check mention, Split the parser", of: input))
        input.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(waitForValue("Can you check ", of: input))

        input.typeText("@spl")
        XCTAssertTrue(waitUntilHittable(parser))
        parser.tap()
        XCTAssertTrue(waitForValue("Can you check mention, Split the parser ", of: input, allowsPrediction: true))
        input.typeText("before the release?")
        XCTAssertTrue(waitForValue("Can you check mention, Split the parser before the release?", of: input))
        attachScreenshot(named: "mention-sentence", of: app)

        let send = app.buttons["toastty-mobile-composer-send"]
        XCTAssertTrue(waitForLabel("Steer message", of: send))
        send.tap()
        let sent = app.descendants(matching: .any)["toastty-mobile-send-optimistic-fixture-queued-1"]
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
        // The message holds the task's link, as the Mac sends it (the
        // bubble's label is the message as sent), and the chat draws the
        // link as the task's chip.
        XCTAssertTrue(
            sent.label.hasPrefix("Can you check [Split the parser](toastty://task/D1000000-0000-0000-0000-000000000004) before the release?"),
            sent.label
        )
        XCTAssertTrue(waitUntil { self.chip(containing: "Split the parser", in: app).exists })
        attachScreenshot(named: "mention-sent-chip", of: app)
    }

    func testThePaperclipMentionsATask() {
        let app = openCoordinator("quiet")
        let input = composer(in: app)
        let paperclip = app.buttons["toastty-mobile-attachment-add"]
        XCTAssertTrue(paperclip.waitForExistence(timeout: 5))
        XCTAssertEqual(paperclip.label, "Attach or mention")
        paperclip.tap()
        // On iOS 26 the dialog is a popover, where the item's label matches
        // two elements.
        let mention = app.buttons["Mention a Task"].firstMatch
        XCTAssertTrue(mention.waitForExistence(timeout: 5))
        attachScreenshot(named: "mention-paperclip-menu", of: app)
        mention.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The field takes the keyboard")
        XCTAssertTrue(mentionList(in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue("@", of: input))
        attachScreenshot(named: "mention-paperclip-list", of: app)

        // After a word, it types a space first.
        input.typeText(XCUIKeyboardKey.delete.rawValue)
        input.typeText("Ask")
        XCTAssertTrue(mentionList(in: app).waitForNonExistence(timeout: 5))
        paperclip.tap()
        XCTAssertTrue(mention.waitForExistence(timeout: 5))
        mention.tap()
        XCTAssertTrue(waitForValue("Ask @", of: input))
        XCTAssertTrue(mentionList(in: app).waitForExistence(timeout: 5))
        input.typeText("compact")
        let compact = row("compact-session-rows", in: app)
        XCTAssertTrue(waitUntilHittable(compact))
        compact.tap()
        XCTAssertTrue(waitForValue("Ask mention, compact-session-rows ", of: input, allowsPrediction: true))
    }

    func testTheListCloses() {
        let app = openCoordinator("quiet")
        let input = composer(in: app)
        let list = mentionList(in: app)
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))

        // An email address opens no list.
        input.typeText("mail me@exa")
        XCTAssertFalse(list.waitForExistence(timeout: 1))

        // A space after a search that matches nothing.
        input.typeText(" @zzq")
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-mention-empty"].exists)
        input.typeText(" ")
        XCTAssertTrue(list.waitForNonExistence(timeout: 5))

        // The @ deleted.
        input.typeText("@")
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        input.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(list.waitForNonExistence(timeout: 5))

        // A tap on the chat above the list; typing on after the same @ keeps
        // it closed.
        input.typeText("@co")
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        attachScreenshot(named: "mention-list-before-tap-outside", of: app)
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -24)).tap()
        XCTAssertTrue(list.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.exists, "The tap closes the list, not the keyboard")
        input.typeText("m")
        XCTAssertFalse(list.waitForExistence(timeout: 1))

        // The field loses the keyboard when the app leaves the screen.
        input.typeText(" @")
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(list.waitForNonExistence(timeout: 5))
    }

    /// The coordinator's waiting messages sit at the end of the chat, just
    /// above the composer, where the list opens. The list draws over them,
    /// and a tap on one of its rows reaches the list, not a waiting
    /// message's buttons below it.
    func testTheListDrawsOverTheCoordinatorsWaitingMessages() {
        let app = openCoordinator("working", environment: ["TOASTTY_MOBILE_FIXTURE_COORDINATOR_QUEUE": "1"])
        let waitingIDs = ["fixture-chat-1", "fixture-chat-2", "fixture-own-1", "fixture-own-2", "fixture-own-3"]
        let waiting = waitingIDs.map { app.descendants(matching: .any)["toastty-mobile-send-queued-\($0)"] }
        XCTAssertTrue(waiting[waiting.count - 1].waitForExistence(timeout: 5))
        let input = composer(in: app)
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        attachScreenshot(named: "mention-waiting-messages-keyboard", of: app)

        input.typeText("@")
        let list = mentionList(in: app)
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilHittable(row("Composer blank line", in: app)))
        let covered = waiting.filter { $0.exists && $0.frame.intersects(list.frame) }
        XCTAssertFalse(covered.isEmpty, "The list opens over the waiting messages at the chat's end")
        attachScreenshot(named: "mention-list-over-waiting-messages", of: app)

        // The row is below the list's first four; the search brings it up.
        input.typeText("spl")
        let parser = row("Split the parser", in: app)
        XCTAssertTrue(waitUntilHittable(parser))
        parser.tap()
        XCTAssertTrue(list.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForValue("mention, Split the parser ", of: input, allowsPrediction: true))
        for (id, row) in zip(waitingIDs, waiting) {
            XCTAssertTrue(row.exists, "\(id) is still waiting")
        }
        attachScreenshot(named: "mention-in-field-waiting-messages", of: app)
    }

    /// A draft with a mention comes back with it, after another tab and
    /// after Edit on a waiting message.
    func testADraftWithAMentionComesBack() {
        let app = openCoordinator("working")
        let input = composer(in: app)
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        input.typeText("Then check @early")
        let early = row("early-session-titles", in: app)
        XCTAssertTrue(waitUntilHittable(early))
        early.tap()
        input.typeText("again.")
        XCTAssertTrue(waitForValue("Then check mention, early-session-titles again.", of: input))

        dropTheKeyboard(in: app)
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.buttons["toastty-mobile-home-segment-all"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Coordinator"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue("Then check mention, early-session-titles again.", of: input))
        attachScreenshot(named: "mention-draft-restored", of: app)

        // Queue it, then Edit brings it back with its mention.
        input.tap()
        let mode = app.buttons["toastty-mobile-composer-mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.tap()
        let queueChoice = app.buttons["toastty-mobile-composer-mode-queue"]
        XCTAssertTrue(queueChoice.waitForExistence(timeout: 5))
        queueChoice.tap()
        let send = app.buttons["toastty-mobile-composer-send"]
        XCTAssertTrue(waitForLabel("Queue message", of: send))
        send.tap()
        let edit = app.buttons["toastty-mobile-queued-edit-fixture-queued-1"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue("", of: input, orPlaceholder: true))
        XCTAssertTrue(waitUntilHittable(edit))
        edit.tap()
        XCTAssertTrue(waitForValue("Then check mention, early-session-titles again.", of: input))
        attachScreenshot(named: "mention-edit-restored", of: app)

        // Edit while the field has the keyboard and text: the waiting
        // message goes in after that text, with its mention.
        XCTAssertTrue(waitForLabel("Queue message", of: send))
        send.tap()
        let secondEdit = app.buttons["toastty-mobile-queued-edit-fixture-queued-2"]
        XCTAssertTrue(secondEdit.waitForExistence(timeout: 5))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        input.typeText("Also")
        XCTAssertTrue(scrollAboveTheComposer(secondEdit, input: input, in: app))
        secondEdit.tap()
        XCTAssertTrue(waitForValue("Also\n\nThen check mention, early-session-titles again.", of: input))
        XCTAssertTrue(app.keyboards.firstMatch.exists, "The field keeps the keyboard")
        attachScreenshot(named: "mention-edit-into-focused-field", of: app)
    }

    func testTheListAtALargeTextSize() {
        let app = openCoordinator("quiet", textSize: "UICTContentSizeCategoryAccessibilityL")
        let input = composer(in: app)
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        input.typeText("@")
        let list = mentionList(in: app)
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        attachScreenshot(named: "mention-list-large-text-all", of: app)
        input.typeText("early")
        let first = row("early-session-titles", in: app)
        XCTAssertTrue(waitUntilHittable(first))
        // The list stays between the navigation bar and the composer.
        let navigationBar = app.navigationBars.firstMatch
        XCTAssertGreaterThanOrEqual(list.frame.minY, navigationBar.frame.maxY - 1)
        XCTAssertLessThanOrEqual(list.frame.maxY, input.frame.minY)
        attachScreenshot(named: "mention-list-large-text", of: app)
        first.tap()
        XCTAssertTrue(waitForValue("mention, early-session-titles ", of: input, allowsPrediction: true))
        attachScreenshot(named: "mention-in-field-large-text", of: app)
    }

    // MARK: - Support

    private func openCoordinator(
        _ coordinator: String,
        textSize: String? = nil,
        environment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_TASKS"] = "1"
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_COORDINATOR"] = coordinator
        app.launchEnvironment.merge(environment) { _, new in new }
        app.launchArguments += ["-toastty-mobile-collapsed-project-cards", ""]
        if let textSize { app.launchArguments += ["-UIPreferredContentSizeCategoryName", textSize] }
        app.launch()
        XCTAssertTrue(app.buttons["toastty-mobile-home-segment-all"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Coordinator"].tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-coordinator-title"].waitForExistence(timeout: 5))
        return app
    }

    private func composer(in app: XCUIApplication) -> XCUIElement {
        let input = app.descendants(matching: .any)["toastty-mobile-composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        return input
    }

    private func mentionList(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["toastty-mobile-mention-list"]
    }

    /// A row of the list, by the title its label starts with.
    private func row(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'toastty-mobile-mention-' AND label BEGINSWITH %@", "\(title),"
        )).firstMatch
    }

    /// A task's chip in the chat. The fixture chat links other tasks, not
    /// the one the tests mention.
    private func chip(containing text: String, in element: XCUIElement) -> XCUIElement {
        let words = { (label: String) in
            label.replacingOccurrences(of: "\u{2060}", with: "").replacingOccurrences(of: "\u{00A0}", with: " ")
        }
        let matches = element.links.allElementsBoundByIndex.filter { words($0.label).contains(text) }
        return matches.first ?? element.links["no link contains \(text)"]
    }

    /// Scrolls the chat until `element` shows between the navigation bar
    /// and the composer, with the keyboard up.
    private func scrollAboveTheComposer(_ element: XCUIElement, input: XCUIElement, in app: XCUIApplication) -> Bool {
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22))
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
        for _ in 0..<12 {
            let top = app.navigationBars.firstMatch.frame.maxY
            let bottom = input.frame.minY - 60
            let frame = element.frame
            if element.exists, frame.minY >= top, frame.maxY <= bottom { return waitUntilHittable(element) }
            if element.exists, frame.maxY > bottom {
                lower.press(forDuration: 0.05, thenDragTo: upper, withVelocity: .slow, thenHoldForDuration: 0.3)
            } else {
                upper.press(forDuration: 0.05, thenDragTo: lower, withVelocity: .slow, thenHoldForDuration: 0.3)
            }
        }
        return false
    }

    /// A slow drag down the chat drops the keyboard.
    private func dropTheKeyboard(in app: XCUIApplication) {
        let transcript = app.scrollViews["toastty-mobile-transcript"]
        transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).press(
            forDuration: 0.1,
            thenDragTo: transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)),
            withVelocity: .slow,
            thenHoldForDuration: 0.1
        )
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    }

    /// The field's value; an empty field reads its placeholder. After a
    /// space, UIKit can show an inline prediction in the value, so
    /// `allowsPrediction` accepts more words after `value`.
    private func waitForValue(
        _ value: String,
        of element: XCUIElement,
        orPlaceholder: Bool = false,
        allowsPrediction: Bool = false
    ) -> Bool {
        let matched = waitUntil(timeout: 15) {
            let current = element.value as? String ?? ""
            if orPlaceholder, current.hasPrefix("Message ") { return true }
            return current == value || (allowsPrediction && current.hasPrefix(value) && current.contains("\n") == false)
        }
        if matched == false { XCTFail("The field reads \(String(describing: element.value)), not \(value)") }
        return matched
    }

    private func waitForLabel(_ label: String, of element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 15) == .completed
    }

    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return condition()
    }

    private func attachScreenshot(named name: String, of app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
