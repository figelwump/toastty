import XCTest

/// Task actions from a fixture Mac that runs the task system: the Merge
/// control in each state under a task session's title, the confirmation
/// before a merge, the archive sheet, and the task detail's actions.
final class ToasttyMobileTaskActionUITests: XCTestCase {
    private struct ControlState {
        let name: String
        let subspaceID: String
        /// A task space with several sessions opens its screen; this one.
        var sessionID: String?
        let kind: String
        let title: String
    }

    private let reviewSubspaceID = "A1000000-0000-0000-0000-000000000011"
    private let reviewSessionID = "B1000000-0000-0000-0000-000000000009"
    private let archiveSubspaceID = "A1000000-0000-0000-0000-000000000026"
    private let cleanupSubspaceID = "A1000000-0000-0000-0000-000000000023"
    private let setupFailedTaskID = "D1000000-0000-0000-0000-000000000003"

    private var states: [ControlState] {
        [
            ControlState(name: "merge", subspaceID: reviewSubspaceID, sessionID: reviewSessionID, kind: "merge", title: "Merge PR #36"),
            ControlState(name: "open-pr", subspaceID: "A1000000-0000-0000-0000-000000000012", kind: "open_pull_request", title: "Open PR #45"),
            ControlState(name: "merging", subspaceID: "A1000000-0000-0000-0000-000000000021", kind: "merging", title: "Merging PR #88…"),
            ControlState(name: "complete-task", subspaceID: "A1000000-0000-0000-0000-000000000022", kind: "complete_task", title: "Complete Task"),
            ControlState(name: "cleanup-stopped", subspaceID: cleanupSubspaceID, kind: "cleanup_stopped", title: "Cleanup Stopped · PR #91"),
            ControlState(name: "done-pr", subspaceID: "A1000000-0000-0000-0000-000000000024", kind: "done", title: "Done · PR #93"),
            ControlState(name: "done", subspaceID: "A1000000-0000-0000-0000-000000000025", kind: "done", title: "Done"),
            ControlState(name: "archive", subspaceID: archiveSubspaceID, kind: "archive", title: "Archive Task…"),
        ]
    }

    override func setUp() {
        continueAfterFailure = false
    }

    func testEachMergeControlStateShowsInItsTaskSession() {
        let app = launchTaskFixture()
        for state in states {
            openSession(of: state, in: app)
            let control = app.descendants(matching: .any)["toastty-task-merge-control-primary"].exists
                ? app.descendants(matching: .any)["toastty-task-merge-control-primary"]
                : app.descendants(matching: .any)["toastty-task-merge-control-menu"]
            XCTAssertTrue(control.waitForExistence(timeout: 5), state.name)
            XCTAssertTrue(control.label.hasPrefix(state.title), "\(state.name): \(control.label)")
            XCTAssertTrue(app.descendants(matching: .any)["toastty-task-bar-stage"].exists, state.name)
            attachScreenshot(named: "task-bar-\(state.name)", of: app)
            goBackToHome(in: app)
        }
    }

    func testMergeAsksFirstThenTheTaskStartsMerging() {
        let app = launchTaskFixture()
        openSession(of: states[0], in: app)
        let merge = app.buttons["toastty-task-merge-control-primary"]
        XCTAssertTrue(merge.waitForExistence(timeout: 5))
        XCTAssertEqual(merge.label, "Merge PR #36")

        // The phone asks first; Cancel sends nothing.
        merge.tap()
        let alert = app.alerts["Merge PR #36?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "check PR #36")).firstMatch.exists)
        attachScreenshot(named: "task-merge-confirmation", of: app)
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertEqual(merge.label, "Merge PR #36")

        merge.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Merge PR #36"].firstMatch.tap()
        let merging = app.descendants(matching: .any)["toastty-task-merge-control-menu"]
        XCTAssertTrue(merging.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabelPrefix(merging, "Merging PR #36…"))
        attachScreenshot(named: "task-merge-started", of: app)
    }

    func testArchiveShowsTheMacsCheckAndUncommittedChangesBlockIt() {
        let app = launchTaskFixture()
        openSession(of: states[0], in: app)
        let menu = app.buttons["toastty-task-merge-control-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let archiveItem = app.buttons["Archive Task…"]
        XCTAssertTrue(archiveItem.waitForExistence(timeout: 5))
        archiveItem.tap()

        let title = app.staticTexts["toastty-task-archive-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Archive \u{201C}compact-session-rows\u{201D}?")
        let checks = app.descendants(matching: .any)["toastty-task-archive-checks"]
        XCTAssertTrue(checks.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Worktree has no uncommitted changes"].exists)
        XCTAssertTrue(app.staticTexts["2 commits are not on the remote. The local branch stays."].exists)
        XCTAssertTrue(app.switches["toastty-task-archive-close-pull-request"].exists)
        XCTAssertTrue(app.buttons["toastty-task-archive-confirm"].isEnabled)
        attachScreenshot(named: "task-archive-sheet", of: app)
        app.buttons["toastty-task-archive-cancel"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        goBackToHome(in: app)

        // Uncommitted changes stay on the Mac.
        openSession(of: states[7], in: app)
        let archive = app.buttons["toastty-task-merge-control-primary"]
        XCTAssertTrue(archive.waitForExistence(timeout: 5))
        archive.tap()
        let blocked = app.staticTexts["toastty-task-archive-blocked"]
        XCTAssertTrue(blocked.waitForExistence(timeout: 5))
        XCTAssertTrue(blocked.label.contains("3 uncommitted files"))
        XCTAssertFalse(app.buttons["toastty-task-archive-confirm"].isEnabled)
        attachScreenshot(named: "task-archive-sheet-blocked", of: app)
    }

    func testTaskDetailOffersTheMacsActions() {
        let app = launchTaskFixture()
        // ⓘ in a task session opens the detail with the task's actions.
        openSession(of: states[4], in: app)
        let info = app.buttons["toastty-conversation-task-detail"]
        XCTAssertTrue(info.waitForExistence(timeout: 5))
        info.tap()
        let cleanUp = app.buttons["toastty-task-action-clean_up"]
        XCTAssertTrue(cleanUp.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["toastty-task-action-keep_as_is"].exists)
        attachScreenshot(named: "task-detail-cleanup-actions", of: app)

        // Clean Up runs without asking; the fixture Mac refuses it and the
        // phone says why.
        cleanUp.tap()
        let failure = app.alerts["Couldn\u{2019}t clean up \u{201C}Gateway test flake\u{201D}"]
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        XCTAssertTrue(failure.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "uncommitted changes")).firstMatch.exists)
        attachScreenshot(named: "task-action-refused", of: app)
        failure.buttons["OK"].tap()
        app.navigationBars["Task"].buttons["Done"].tap()
        goBackToHome(in: app)

        // A task whose setup failed offers Retry and Delete; Delete asks.
        app.buttons["toastty-mobile-home-segment-needsYou"].tap()
        let failed = app.buttons["toastty-task-row-\(setupFailedTaskID)"]
        XCTAssertTrue(scrollTo(failed, in: app))
        failed.tap()
        let retry = app.buttons["toastty-task-action-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertEqual(retry.label, "Retry Setup")
        attachScreenshot(named: "task-detail-setup-failed-actions", of: app)
        app.buttons["toastty-task-action-delete"].tap()
        let confirm = app.alerts["Delete \u{201C}Composer blank line\u{201D}?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        attachScreenshot(named: "task-delete-confirmation", of: app)
        confirm.buttons["Cancel"].tap()
        XCTAssertTrue(retry.exists)
    }

    func testARowsMenuOffersItsTasksActionsAndMergeStillAsks() {
        let app = launchTaskFixture()
        let row = app.buttons["toastty-subspace-row-\(reviewSubspaceID)"]
        XCTAssertTrue(scrollTo(row, in: app))
        row.press(forDuration: 1.2)
        let merge = app.buttons["Merge"]
        XCTAssertTrue(merge.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Archive…"].exists)
        attachScreenshot(named: "task-row-menu", of: app)
        merge.tap()
        let alert = app.alerts["Merge PR #36?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
    }

    // MARK: - Helpers

    private func launchTaskFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_TASKS"] = "1"
        // Every project card expanded, whatever an earlier test saved.
        app.launchArguments += ["-toastty-mobile-collapsed-project-cards", ""]
        app.launch()
        let all = app.buttons["toastty-mobile-home-segment-all"]
        XCTAssertTrue(all.waitForExistence(timeout: 10))
        if all.isSelected == false { all.tap() }
        return app
    }

    /// Opens the task space's session from All.
    private func openSession(of state: ControlState, in app: XCUIApplication) {
        let row = app.buttons["toastty-subspace-row-\(state.subspaceID)"]
        XCTAssertTrue(scrollTo(row, in: app), state.name)
        row.tap()
        if let sessionID = state.sessionID {
            let session = app.buttons["toastty-mobile-workspace-session-\(sessionID)"]
            XCTAssertTrue(session.waitForExistence(timeout: 5), state.name)
            session.tap()
        }
        XCTAssertTrue(app.staticTexts["toastty-mobile-conversation-title"].waitForExistence(timeout: 5), state.name)
        XCTAssertTrue(app.descendants(matching: .any)["toastty-task-bar"].waitForExistence(timeout: 5), state.name)
    }

    private func goBackToHome(in app: XCUIApplication) {
        let home = app.descendants(matching: .any)["toastty-mobile-home"]
        for _ in 0..<3 where home.exists == false || home.isHittable == false {
            app.navigationBars.firstMatch.buttons.firstMatch.tap()
            _ = home.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(home.waitForExistence(timeout: 5))
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 12) -> Bool {
        let list = app.collectionViews["toastty-mobile-home"].exists
            ? app.collectionViews["toastty-mobile-home"]
            : app.collectionViews.firstMatch
        for _ in 0..<attempts {
            if isReachable(element, in: app) { return true }
            list.swipeUp(velocity: .slow)
        }
        for _ in 0..<attempts {
            if isReachable(element, in: app) { return true }
            list.swipeDown(velocity: .slow)
        }
        return isReachable(element, in: app)
    }

    /// Visible and clear of Home's pinned header and the tab bar, which
    /// cover list rows that XCTest still reports as hittable.
    private func isReachable(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let segment = app.buttons["toastty-mobile-home-segment-all"]
        if segment.exists, segment.isHittable, element.frame.minY < segment.frame.maxY + 8 { return false }
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists, element.frame.maxY > tabBar.frame.minY { return false }
        return true
    }

    private func waitForLabelPrefix(_ element: XCUIElement, _ prefix: String, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", prefix), object: element
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
