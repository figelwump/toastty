import XCTest

/// Home from a fixture Mac that runs the task system: All | Needs you, the
/// project cards and their buckets, the Home | Tasks tab bar, the Tasks
/// tab, and task detail.
final class ToasttyMobileTaskUITests: XCTestCase {
    private let toasttyWorkspaceID = "A1000000-0000-0000-0000-000000000001"
    private let emptyosWorkspaceID = "A1000000-0000-0000-0000-000000000005"
    private let needsApprovalSubspaceID = "A1000000-0000-0000-0000-000000000011"
    private let questionSubspaceID = "A1000000-0000-0000-0000-000000000012"
    private let workingSubspaceID = "A1000000-0000-0000-0000-000000000013"
    private let doneSubspaceID = "A1000000-0000-0000-0000-000000000014"
    private let reviewSubspaceID = "A1000000-0000-0000-0000-000000000022"
    private let archiveSubspaceID = "A1000000-0000-0000-0000-000000000026"
    private let setupFailedTaskID = "D1000000-0000-0000-0000-000000000003"
    private let startingTaskID = "D1000000-0000-0000-0000-000000000004"
    private let shippedTaskID = "D1000000-0000-0000-0000-000000000005"
    private let otherProjectTaskID = "D1000000-0000-0000-0000-000000000012"
    private let shareSheetTaskID = "D1000000-0000-0000-0000-000000000013"
    /// The release task the fixture starts.
    private let releaseTaskID = "D1000000-0000-0000-0000-000000000015"
    /// A working session in the toastty workspace.
    private let workingSessionID = "B1000000-0000-0000-0000-000000000002"

    override func setUp() {
        continueAfterFailure = false
    }

    func testAllListsEachProjectAsACardWithBuckets() {
        let app = launchTaskFixture()
        // The Mac's switcher replaces All | Active, and Needs you counts the
        // tasks that need the user.
        XCTAssertFalse(app.segmentedControls["toastty-mobile-workspace-session-filter"].exists)
        XCTAssertEqual(app.buttons["toastty-mobile-home-segment-needsYou"].label, "Needs you, 5")
        select(.all, in: app)

        let toastty = app.buttons["toastty-mobile-workspace-\(toasttyWorkspaceID)"]
        XCTAssertTrue(toastty.waitForExistence(timeout: 5))
        XCTAssertTrue(toastty.label.hasSuffix("6 need you, 3 running"), toastty.label)
        // Sessions, task spaces and tasks without a task space share the
        // buckets; the done task space left the card.
        let needsYou = app.descendants(matching: .any)["toastty-card-bucket-\(toasttyWorkspaceID)-needsYou"]
        XCTAssertTrue(needsYou.exists)
        XCTAssertEqual(needsYou.label, "Needs you, 6")
        XCTAssertTrue(app.buttons["toastty-mobile-grouped-card-B1000000-0000-0000-0000-000000000001"].exists)
        let approval = app.buttons["toastty-subspace-row-\(needsApprovalSubspaceID)"]
        XCTAssertTrue(scrollTo(approval, in: app))
        // An approval beats the task's own stage.
        XCTAssertTrue(approval.label.contains("task space, needs approval"))
        XCTAssertFalse(app.buttons["toastty-subspace-row-\(doneSubspaceID)"].exists)
        // A parent shows its child progress, and the task it started lists
        // under it in the parent's bucket although it is starting.
        let question = app.buttons["toastty-subspace-row-\(questionSubspaceID)"]
        XCTAssertTrue(scrollTo(question, in: app))
        XCTAssertTrue(question.label.hasSuffix("1/2 merged"), question.label)
        let child = app.buttons["toastty-task-row-\(startingTaskID)"]
        XCTAssertTrue(scrollTo(child, in: app))
        XCTAssertGreaterThan(child.frame.minY, question.frame.minY)
        XCTAssertLessThan(child.frame.minY, app.descendants(matching: .any)["toastty-card-bucket-\(toasttyWorkspaceID)-running"].frame.minY)
        attachScreenshot(named: "home-all", of: app)

        // The To ship line shows the project's latest To ship tasks in place.
        let toShip = app.buttons["toastty-card-to-ship-\(toasttyWorkspaceID)"]
        XCTAssertTrue(scrollTo(toShip, in: app))
        XCTAssertEqual(toShip.label, "To ship 3")
        XCTAssertEqual(app.buttons["toastty-card-done-\(toasttyWorkspaceID)"].label, "Done 12")
        XCTAssertFalse(app.buttons["toastty-task-row-\(shippedTaskID)"].exists)
        app.buttons["toastty-card-to-ship-toggle-\(toasttyWorkspaceID)"].tap()
        XCTAssertTrue(scrollTo(app.buttons["toastty-task-row-\(shippedTaskID)"], in: app))
        attachScreenshot(named: "home-all-to-ship", of: app)

        // Ready to review is apart from Needs you.
        let emptyos = app.buttons["toastty-mobile-workspace-\(emptyosWorkspaceID)"]
        XCTAssertTrue(scrollTo(emptyos, in: app))
        XCTAssertTrue(emptyos.label.hasSuffix("1 needs you, 1 ready for review, 3 running, 2 idle"), emptyos.label)
        XCTAssertTrue(scrollTo(app.buttons["toastty-subspace-row-\(reviewSubspaceID)"], in: app))
        XCTAssertEqual(
            app.descendants(matching: .any)["toastty-card-bucket-\(emptyosWorkspaceID)-readyToReview"].label,
            "Ready to review, 1"
        )
        // A task whose project is not open lists in Other tasks, last.
        let other = app.descendants(matching: .any)["toastty-card-other-tasks"]
        XCTAssertTrue(scrollTo(app.buttons["toastty-task-row-\(otherProjectTaskID)"], in: app))
        XCTAssertEqual(other.label, "Other tasks, 1 idle")
        attachScreenshot(named: "home-all-other-tasks", of: app)

        // Needs you lists the tasks that need the user.
        select(.needsYou, in: app)
        XCTAssertTrue(app.buttons["toastty-subspace-row-\(questionSubspaceID)"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["toastty-task-row-\(setupFailedTaskID)"].exists)
        XCTAssertFalse(app.buttons["toastty-subspace-row-\(workingSubspaceID)"].exists)
        attachScreenshot(named: "home-needs-you", of: app)
    }

    func testACollapsedCardStaysCollapsedAfterARelaunch() {
        var app = launchTaskFixture(keepsCollapsedCards: true)
        select(.all, in: app)
        let collapse = app.buttons["toastty-card-collapse-\(emptyosWorkspaceID)"]
        XCTAssertTrue(scrollTo(collapse, in: app))
        // Left over from a run that failed before it cleaned up.
        if collapse.value as? String == "Collapsed" { collapse.tap() }
        let row = app.buttons["toastty-subspace-row-\(archiveSubspaceID)"]
        XCTAssertTrue(scrollTo(row, in: app))
        XCTAssertTrue(scrollTo(collapse, in: app))
        collapse.tap()
        XCTAssertEqual(collapse.value as? String, "Collapsed")
        XCTAssertFalse(row.exists)
        // The name line keeps its counts.
        XCTAssertTrue(app.buttons["toastty-mobile-workspace-\(emptyosWorkspaceID)"].label.hasSuffix("2 idle"))
        attachScreenshot(named: "home-card-collapsed", of: app)

        app.terminate()
        app = launchTaskFixture(keepsCollapsedCards: true)
        select(.all, in: app)
        let relaunched = app.buttons["toastty-card-collapse-\(emptyosWorkspaceID)"]
        XCTAssertTrue(scrollTo(relaunched, in: app))
        XCTAssertEqual(relaunched.value as? String, "Collapsed")
        XCTAssertFalse(app.buttons["toastty-subspace-row-\(archiveSubspaceID)"].exists)
        relaunched.tap()
        XCTAssertEqual(relaunched.value as? String, "Expanded")
        XCTAssertTrue(scrollTo(app.buttons["toastty-subspace-row-\(archiveSubspaceID)"], in: app))
    }

    func testTheTabBarShowsOnlyWhileTheMacSendsATaskBoard() {
        let plain = XCUIApplication()
        plain.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        plain.launch()
        XCTAssertTrue(plain.segmentedControls["toastty-mobile-workspace-session-filter"].waitForExistence(timeout: 10))
        XCTAssertFalse(plain.tabBars.buttons["Tasks"].exists)
        XCTAssertFalse(plain.buttons["toastty-mobile-home-segment-all"].exists)
        plain.terminate()

        let app = launchTaskFixture()
        XCTAssertTrue(app.tabBars.buttons["Home"].exists)
        XCTAssertTrue(app.tabBars.buttons["Tasks"].exists)
        XCTAssertTrue(app.tabBars.buttons["Home"].isSelected)
    }

    func testTheTasksTabListsToShipFirstAndATaskWithoutATaskSpaceOpensItsDetail() {
        let app = launchTaskFixture()
        app.tabBars.buttons["Tasks"].tap()
        let toShip = app.descendants(matching: .any)["toastty-tasks-group-to-ship"]
        XCTAssertTrue(toShip.waitForExistence(timeout: 5))
        XCTAssertEqual(toShip.label, "To ship, 3")
        let lane = app.descendants(matching: .any)["toastty-tasks-lane-toastty"]
        XCTAssertTrue(lane.exists)
        let shipped = app.buttons["toastty-task-row-\(shippedTaskID)"]
        XCTAssertTrue(shipped.exists)
        let needsYou = app.descendants(matching: .any)["toastty-tasks-group-needsYou"]
        XCTAssertTrue(needsYou.exists)
        XCTAssertGreaterThan(needsYou.frame.minY, shipped.frame.minY)
        XCTAssertEqual(needsYou.label, "Needs you, 4")
        // Rows from several projects share the list, so each names its own.
        let question = app.buttons["toastty-subspace-row-\(questionSubspaceID)"]
        XCTAssertTrue(question.label.contains("Should the badge count tasks or sessions?, toastty"))
        attachScreenshot(named: "tasks-tab", of: app)

        // A review lists under Ready to review, apart from Needs you.
        let review = app.buttons["toastty-subspace-row-\(reviewSubspaceID)"]
        XCTAssertTrue(scrollTo(review, in: app, list: "toastty-mobile-tasks"))
        let readyToReview = app.descendants(matching: .any)["toastty-tasks-group-readyToReview"]
        XCTAssertEqual(readyToReview.label, "Ready to review, 1")
        XCTAssertGreaterThan(review.frame.minY, readyToReview.frame.minY)
        // A task Toastty is still setting up lists in Running, apart from
        // the task that started it, which needs the user.
        XCTAssertTrue(scrollTo(app.buttons["toastty-task-row-\(startingTaskID)"], in: app, list: "toastty-mobile-tasks"))
        XCTAssertGreaterThan(
            app.buttons["toastty-task-row-\(startingTaskID)"].frame.minY,
            app.descendants(matching: .any)["toastty-tasks-group-running"].frame.minY
        )
        XCTAssertTrue(scrollTo(app.descendants(matching: .any)["toastty-tasks-group-done"], in: app, list: "toastty-mobile-tasks"))
        attachScreenshot(named: "tasks-tab-end", of: app)

        let failed = app.buttons["toastty-task-row-\(setupFailedTaskID)"]
        XCTAssertTrue(scrollTo(failed, in: app, list: "toastty-mobile-tasks"))
        XCTAssertEqual(failed.label, "Composer blank line, ⚠ setup failed, toastty")
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

    func testEachTabKeepsItsStackAndASessionOpensFromTheTasksTab() {
        let app = launchTaskFixture()
        select(.all, in: app)
        // Home: the toastty workspace, then one of its sessions.
        let workspace = app.buttons["toastty-mobile-workspace-\(toasttyWorkspaceID)"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        workspace.tap()
        let homeSession = app.buttons["toastty-mobile-workspace-session-\(workingSessionID)"]
        XCTAssertTrue(homeSession.waitForExistence(timeout: 5))
        homeSession.tap()
        let conversationTitle = app.staticTexts["toastty-mobile-conversation-title"]
        XCTAssertTrue(conversationTitle.waitForExistence(timeout: 5))
        let homeTitle = conversationTitle.label

        // Tasks: the question task's session, opened from its row.
        app.tabBars.buttons["Tasks"].tap()
        let question = app.buttons["toastty-subspace-row-\(questionSubspaceID)"]
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        question.tap()
        XCTAssertTrue(app.descendants(matching: .any)["toastty-task-bar"].waitForExistence(timeout: 5))
        XCTAssertTrue(conversationTitle.waitForExistence(timeout: 5))
        let tasksTitle = conversationTitle.label
        XCTAssertNotEqual(tasksTitle, homeTitle)
        // The tab bar stays on a pushed session.
        XCTAssertTrue(app.tabBars.buttons["Home"].isHittable)
        attachScreenshot(named: "tasks-session-with-tab-bar", of: app)

        // Each tab shows its own session again.
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(waitForLabel(conversationTitle, homeTitle))
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(waitForLabel(conversationTitle, tasksTitle))

        // Back in Tasks returns to its list; Home kept its session and,
        // under it, its workspace.
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        XCTAssertTrue(waitUntilHittable(question))
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(waitForLabel(conversationTitle, homeTitle))
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        XCTAssertTrue(waitUntilHittable(homeSession))
    }

    /// Release… on a card's expanded To ship line and on the Tasks tab's
    /// lane: the phone asks first, Cancel sends nothing, and once the Mac
    /// starts the release both read Releasing… and are off.
    func testReleaseAsksFirstThenTheProjectReadsReleasing() {
        let app = launchTaskFixture()
        select(.all, in: app)
        let toggle = app.buttons["toastty-card-to-ship-toggle-\(toasttyWorkspaceID)"]
        XCTAssertTrue(scrollTo(toggle, in: app))
        let cardRelease = app.buttons["toastty-card-release-\(toasttyWorkspaceID)"]
        // Only the expanded line offers it.
        XCTAssertFalse(cardRelease.exists)
        toggle.tap()
        XCTAssertTrue(scrollTo(app.buttons["toastty-task-row-\(shareSheetTaskID)"], in: app))
        XCTAssertTrue(scrollTo(cardRelease, in: app))
        XCTAssertEqual(cardRelease.label, "Release toastty")
        XCTAssertTrue(cardRelease.isEnabled)
        attachScreenshot(named: "release-card-to-ship-line", of: app)

        // The phone asks first, naming the project and what ships.
        cardRelease.tap()
        let alert = app.alerts["Release \u{201C}toastty\u{201D}?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "3 merged tasks")).firstMatch.exists)
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Share sheet links")).firstMatch.exists)
        attachScreenshot(named: "release-confirmation", of: app)
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertEqual(cardRelease.label, "Release toastty")

        // The Tasks tab's lane offers the same release.
        app.tabBars.buttons["Tasks"].tap()
        let laneRelease = app.buttons["toastty-tasks-lane-release-toastty"]
        XCTAssertTrue(waitUntilHittable(laneRelease))
        XCTAssertEqual(laneRelease.label, "Release toastty")
        attachScreenshot(named: "release-tasks-lane", of: app)
        laneRelease.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Release"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(laneRelease, "Releasing toastty"))
        XCTAssertFalse(laneRelease.isEnabled)
        attachScreenshot(named: "release-tasks-lane-releasing", of: app)
        // The release task lists like any other task.
        XCTAssertTrue(scrollTo(app.buttons["toastty-task-row-\(releaseTaskID)"], in: app, list: "toastty-mobile-tasks"))

        // Home's card reads Releasing… too.
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(scrollTo(cardRelease, in: app))
        XCTAssertTrue(waitForLabel(cardRelease, "Releasing toastty"))
        XCTAssertFalse(cardRelease.isEnabled)
        attachScreenshot(named: "release-card-releasing", of: app)
    }

    func testACardsToShipAndDoneCountsOpenTheTasksTabAtTheirGroup() {
        let app = launchTaskFixture()
        select(.all, in: app)
        let toShip = app.buttons["toastty-card-to-ship-\(toasttyWorkspaceID)"]
        XCTAssertTrue(scrollTo(toShip, in: app))
        toShip.tap()
        XCTAssertTrue(app.tabBars.buttons["Tasks"].waitForSelection())
        XCTAssertTrue(waitUntilHittable(app.descendants(matching: .any)["toastty-tasks-lane-toastty"]))

        app.tabBars.buttons["Home"].tap()
        let done = app.buttons["toastty-card-done-\(toasttyWorkspaceID)"]
        XCTAssertTrue(waitUntilHittable(done))
        done.tap()
        XCTAssertTrue(app.tabBars.buttons["Tasks"].waitForSelection())
        XCTAssertTrue(waitUntilHittable(app.descendants(matching: .any)["toastty-tasks-group-done"]))
        attachScreenshot(named: "tasks-tab-done", of: app)
    }

    // MARK: - Helpers

    private enum Segment: String {
        case all
        case needsYou
    }

    /// Without `keepsCollapsedCards`, every project card shows expanded
    /// whatever an earlier test saved.
    private func launchTaskFixture(keepsCollapsedCards: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_TASKS"] = "1"
        if keepsCollapsedCards == false {
            app.launchArguments += ["-toastty-mobile-collapsed-project-cards", ""]
        }
        app.launch()
        XCTAssertTrue(app.buttons["toastty-mobile-home-segment-all"].waitForExistence(timeout: 10))
        return app
    }

    private func select(_ segment: Segment, in app: XCUIApplication) {
        let button = app.buttons["toastty-mobile-home-segment-\(segment.rawValue)"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        if button.isSelected == false { button.tap() }
        XCTAssertTrue(button.waitForSelection())
    }

    private func scrollTo(
        _ element: XCUIElement, in app: XCUIApplication, list identifier: String = "toastty-mobile-home", attempts: Int = 10
    ) -> Bool {
        let list = app.collectionViews[identifier].exists
            ? app.collectionViews[identifier]
            : app.collectionViews.firstMatch
        for _ in 0..<attempts {
            if isReachable(element, in: app, list: identifier) { return true }
            // A row under Home's header is above the visible rows.
            if identifier == "toastty-mobile-home", element.exists, let top = homeHeaderBottom(in: app),
               element.frame.minY < top {
                break
            }
            list.swipeUp(velocity: .slow)
        }
        for _ in 0..<attempts {
            if isReachable(element, in: app, list: identifier) { return true }
            list.swipeDown(velocity: .slow)
        }
        return isReachable(element, in: app, list: identifier)
    }

    /// The bottom of Home's pinned header, which covers list rows that
    /// XCTest still reports as hittable.
    private func homeHeaderBottom(in app: XCUIApplication) -> CGFloat? {
        let segment = app.buttons["toastty-mobile-home-segment-all"]
        return segment.exists ? segment.frame.maxY + 8 : nil
    }

    /// Visible, below Home's header when the row is in Home's list, and
    /// above the tab bar.
    private func isReachable(_ element: XCUIElement, in app: XCUIApplication, list identifier: String) -> Bool {
        guard element.exists, element.isHittable else { return false }
        if identifier == "toastty-mobile-home", let top = homeHeaderBottom(in: app), element.frame.minY < top {
            return false
        }
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists, element.frame.maxY > tabBar.frame.minY { return false }
        return true
    }

    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label == %@", label), object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
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
