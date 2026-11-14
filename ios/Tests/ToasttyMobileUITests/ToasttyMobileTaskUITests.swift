import XCTest

/// Home from a fixture Mac that runs the task system: Projects | Status
/// segments, task marks and pills, project footers, and task detail.
final class ToasttyMobileTaskUITests: XCTestCase {
    private let toasttyWorkspaceID = "A1000000-0000-0000-0000-000000000001"
    private let needsApprovalSubspaceID = "A1000000-0000-0000-0000-000000000011"
    private let questionSubspaceID = "A1000000-0000-0000-0000-000000000012"
    private let workingSubspaceID = "A1000000-0000-0000-0000-000000000013"
    private let doneSubspaceID = "A1000000-0000-0000-0000-000000000014"
    private let setupFailedTaskID = "D1000000-0000-0000-0000-000000000003"
    private let startingTaskID = "D1000000-0000-0000-0000-000000000004"
    private let shippedTaskID = "D1000000-0000-0000-0000-000000000005"
    private let openPromptConversationID = "B1000000-0000-0000-0000-000000000007"

    override func setUp() {
        continueAfterFailure = false
    }

    func testProjectsShowTaskMarksAndFinishedCounts() {
        let app = launchTaskFixture()
        let segment = app.segmentedControls["toastty-mobile-home-segment"]
        XCTAssertTrue(segment.waitForExistence(timeout: 10))
        // The Mac's segments replace All | Active, and Status counts the
        // tasks that need the user.
        XCTAssertFalse(app.segmentedControls["toastty-mobile-workspace-session-filter"].exists)
        XCTAssertTrue(segment.buttons["Status 5"].exists)
        select("Projects", in: segment)

        let group = app.buttons["toastty-subspaces-group-\(toasttyWorkspaceID)"]
        XCTAssertTrue(scrollTo(group, in: app))
        // The done task left the list; the footer counts it.
        XCTAssertEqual(group.label, "Task Spaces, 3, 1 asks a question, 1 needs approval")
        XCTAssertFalse(app.buttons["toastty-subspace-row-\(doneSubspaceID)"].exists)

        let question = app.buttons["toastty-subspace-row-\(questionSubspaceID)"]
        XCTAssertTrue(scrollTo(question, in: app))
        // The agent's question replaces its last status line.
        XCTAssertTrue(question.label.hasPrefix(
            "early-session-titles, task space, asks a question, Asks: Should the badge count tasks or sessions?"
        ))
        // An approval wins over the task's own stage, as on the Mac.
        let approval = app.buttons["toastty-subspace-row-\(needsApprovalSubspaceID)"]
        XCTAssertTrue(approval.label.contains("task space, needs approval"))
        XCTAssertTrue(approval.label.hasSuffix("github-pr: PR #36"))
        attachScreenshot(named: "tasks-projects", of: app)

        let footer = app.buttons["toastty-project-finished-\(toasttyWorkspaceID)"]
        XCTAssertTrue(scrollTo(footer, in: app))
        XCTAssertTrue(footer.label.contains("To ship 3"))
        XCTAssertTrue(footer.label.contains("Done 12"))
        attachScreenshot(named: "tasks-projects-footer", of: app)
        // The footer shows the finished tasks in Status.
        footer.tap()
        XCTAssertTrue(segment.buttons["Status 5"].waitForSelection())
    }

    func testStatusGroupsTasksAndATaskWithoutATaskSpaceOpensItsDetail() {
        let app = launchTaskFixture()
        let segment = app.segmentedControls["toastty-mobile-home-segment"]
        XCTAssertTrue(segment.waitForExistence(timeout: 10))
        select("Status 5", in: segment)

        // Rows with an open task space are that task space's row.
        let question = app.buttons["toastty-subspace-row-\(questionSubspaceID)"]
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        // Rows from several projects share the list, so each names its own.
        XCTAssertTrue(question.label.contains("Should the badge count tasks or sessions?, toastty"))
        XCTAssertTrue(app.buttons["toastty-subspace-row-\(workingSubspaceID)"].exists)
        // A task Toastty is still setting up lists under the task that
        // started it.
        XCTAssertTrue(app.buttons["toastty-task-row-\(startingTaskID)"].exists)
        let failed = app.buttons["toastty-task-row-\(setupFailedTaskID)"]
        XCTAssertTrue(failed.exists)
        XCTAssertEqual(failed.label, "Composer blank line, ⚠ setup failed, toastty")
        // Only task spaces list here: the toastty workspace's own sessions do not.
        XCTAssertFalse(app.buttons["toastty-mobile-workspace-\(toasttyWorkspaceID)"].exists)
        attachScreenshot(named: "tasks-status", of: app)

        let toShip = app.buttons["toastty-status-to-ship"]
        XCTAssertTrue(scrollTo(toShip, in: app))
        XCTAssertEqual(toShip.value as? String, "Collapsed")
        XCTAssertFalse(app.buttons["toastty-task-row-\(shippedTaskID)"].exists)
        toShip.tap()
        let shipped = app.buttons["toastty-task-row-\(shippedTaskID)"]
        XCTAssertTrue(scrollTo(shipped, in: app))
        XCTAssertTrue(app.descendants(matching: .any)["toastty-status-done"].exists)
        attachScreenshot(named: "tasks-status-to-ship", of: app)
        toShip.tap()

        XCTAssertTrue(scrollTo(failed, in: app))
        failed.tap()
        let title = app.staticTexts["toastty-task-detail-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Composer blank line")
        XCTAssertTrue(app.descendants(matching: .any)["toastty-task-detail-stage"].label
            .contains("create_hook exited 1"))
        attachScreenshot(named: "tasks-detail-setup-failed", of: app)
        app.buttons["Done"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
    }

    func testTaskLinksDrawAsChipsThatOpenTheTaskSpace() {
        let app = launchTaskFixture(taskLinks: true)
        let segment = app.segmentedControls["toastty-mobile-home-segment"]
        XCTAssertTrue(segment.waitForExistence(timeout: 10))
        select("Projects", in: segment)
        let card = app.buttons["toastty-mobile-grouped-card-\(openPromptConversationID)"]
        XCTAssertTrue(scrollTo(card, in: app))
        card.tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-conversation-title"].waitForExistence(timeout: 5))

        let answer = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Removed task")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        // A chip shows the task's current title and pull request number,
        // not the link's text.
        let question = link(containing: "early-session-titles", in: app)
        XCTAssertTrue(question.exists)
        XCTAssertTrue(Self.words(question.label).contains("#45"), question.label)
        XCTAssertFalse(link(containing: "Should the badge", in: app).exists)
        XCTAssertTrue(Self.words(link(containing: "compact-session-rows", in: app).label).contains("#36"))
        XCTAssertTrue(link(containing: "#259", in: app).exists)
        // A task the Mac does not list, a task space with no task, and any
        // other Toastty link are text that a tap cannot open.
        for text in ["Removed task", "Watched space", "a settings link"] {
            XCTAssertTrue((answer.value as? String)?.contains(text) == true, text)
            XCTAssertFalse(link(containing: text, in: app).exists, text)
        }
        attachScreenshot(named: "task-link-chips", of: app)

        // A task with no task space to open shows its detail instead.
        link(containing: "#259", in: app).tap()
        let title = app.staticTexts["toastty-task-detail-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Parent task rollup")
        attachScreenshot(named: "task-link-chip-without-task-space-opens-detail", of: app)
        app.navigationBars["Task"].buttons["Done"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))

        // A tap opens the task's space in place of the conversation, so Back
        // returns to Home.
        question.tap()
        let taskSpace = app.navigationBars["early-session-titles"]
        XCTAssertTrue(taskSpace.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-workspace-detail"].exists)
        XCTAssertFalse(app.staticTexts["toastty-mobile-conversation-title"].exists)
        attachScreenshot(named: "task-link-chip-opens-task-space", of: app)
        taskSpace.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(segment.waitForExistence(timeout: 5))
    }

    /// A chip keeps its text on one line with no-break spaces and word
    /// joiners; compare its words without them.
    private func link(containing text: String, in app: XCUIApplication) -> XCUIElement {
        let matches = app.links.allElementsBoundByIndex.filter { Self.words($0.label).contains(text) }
        return matches.first ?? app.links["no link contains \(text)"]
    }

    private static func words(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2060}", with: "").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private func launchTaskFixture(taskLinks: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_TASKS"] = "1"
        if taskLinks { app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_TASK_LINKS"] = "1" }
        app.launch()
        return app
    }

    private func select(_ title: String, in segment: XCUIElement) {
        let button = segment.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        if button.isSelected == false { button.tap() }
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 10) -> Bool {
        let list = app.collectionViews["toastty-mobile-home"].exists
            ? app.collectionViews["toastty-mobile-home"]
            : app.collectionViews.firstMatch
        for _ in 0..<attempts {
            if element.exists, element.isHittable { return true }
            list.swipeUp(velocity: .slow)
        }
        for _ in 0..<attempts {
            if element.exists, element.isHittable { return true }
            list.swipeDown(velocity: .slow)
        }
        return element.exists && element.isHittable
    }

    private func attachScreenshot(named name: String, of app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension XCUIElement {
    func waitForSelection(timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
