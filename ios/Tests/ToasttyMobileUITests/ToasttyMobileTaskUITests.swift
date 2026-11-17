import UIKit
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
    /// The task that waits for its workspace on the "pick-workspace" board.
    private let pickWorkspaceTaskID = "D1000000-0000-0000-0000-000000000020"
    private let startingTaskID = "D1000000-0000-0000-0000-000000000004"
    private let shippedTaskID = "D1000000-0000-0000-0000-000000000005"
    private let otherProjectTaskID = "D1000000-0000-0000-0000-000000000012"
    private let shareSheetTaskID = "D1000000-0000-0000-0000-000000000016"
    /// The release task the fixture starts.
    private let releaseTaskID = "D1000000-0000-0000-0000-000000000015"
    /// A working session in the toastty workspace.
    private let workingSessionID = "B1000000-0000-0000-0000-000000000002"
    /// The board whose project and tasks have long names.
    private let longNamesProject = "toastty-ios-coordinator-parity-integration"
    private let longNamesQuestionSubspaceID = "A3000000-0000-0000-0000-000000000011"
    private let longNamesStartingTaskID = "D3000000-0000-0000-0000-000000000002"
    private let longNamesShippedTaskID = "D3000000-0000-0000-0000-000000000003"
    private let longNamesOtherProjectTaskID = "D3000000-0000-0000-0000-000000000004"
    /// The "families" board: parents that wait on other tasks.
    private let familiesWorkspaceID = "A4000000-0000-0000-0000-000000000001"
    private let familiesUnreadSubspaceID = "A4000000-0000-0000-0000-000000000011"
    private let familiesUnreadParentSubspaceID = "A4000000-0000-0000-0000-000000000012"
    private let familiesUnreadChildSubspaceID = "A4000000-0000-0000-0000-000000000013"
    private let familiesReadParentSubspaceID = "A4000000-0000-0000-0000-000000000014"
    private let familiesReadChildSubspaceID = "A4000000-0000-0000-0000-000000000015"

    override func setUp() {
        continueAfterFailure = false
    }

    func testAllListsEachProjectAsACardWithBuckets() {
        let app = launchTaskFixture()
        // The Mac's switcher replaces All | Active.
        XCTAssertFalse(app.segmentedControls["toastty-mobile-workspace-session-filter"].exists)
        XCTAssertEqual(app.buttons["toastty-mobile-home-segment-all"].label, "All projects")
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
    }

    /// Needs you lists, per project, the rows All puts in Needs you, then
    /// those in Ready to review, on one line each; a question keeps its
    /// second line. The switcher counts both.
    func testNeedsYouListsEachProjectsNeedsYouThenReadyToReviewRows() {
        let app = launchTaskFixture()
        XCTAssertEqual(
            app.buttons["toastty-mobile-home-segment-needsYou"].label, "Only what needs you, 9, 1 ready for review"
        )
        select(.needsYou, in: app)

        // The toastty card's six Needs you rows from All, sessions included.
        let header = app.descendants(matching: .any)["toastty-needs-you-bucket-\(toasttyWorkspaceID)-needsYou"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertEqual(header.label, "Needs you, 6")
        XCTAssertTrue(app.buttons["toastty-mobile-workspace-\(toasttyWorkspaceID)"].label.hasSuffix("6 need you"))
        XCTAssertTrue(app.buttons["toastty-mobile-grouped-card-B1000000-0000-0000-0000-000000000001"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["toastty-needs-you-bucket-\(toasttyWorkspaceID)-readyToReview"].exists)

        // A question keeps its second line; an approval takes one line. Each
        // shows one tag, its pull request.
        let question = app.buttons["toastty-subspace-row-\(questionSubspaceID)"]
        XCTAssertTrue(scrollTo(question, in: app))
        XCTAssertTrue(question.label.contains("Asks: Should the badge count tasks or sessions?"), question.label)
        XCTAssertTrue(question.label.contains("PR #45"), question.label)
        XCTAssertFalse(question.label.contains("1/2 merged"), question.label)
        XCTAssertTrue(app.buttons["toastty-subspace-row-\(needsApprovalSubspaceID)"].exists)
        // A one-line row is the rows' 44 pt minimum; the question's second
        // line makes its row taller. (The approval row's query can match its
        // whole list cell, so it is no height reference.)
        XCTAssertGreaterThan(question.frame.height, 44 + 8, "question \(question.frame)")
        // Running work, such as the task the question started, stays in All.
        XCTAssertFalse(app.buttons["toastty-subspace-row-\(workingSubspaceID)"].exists)
        XCTAssertFalse(app.buttons["toastty-task-row-\(startingTaskID)"].exists)
        XCTAssertTrue(scrollTo(app.buttons["toastty-task-row-\(setupFailedTaskID)"], in: app))
        XCTAssertTrue(scrollTo(header, in: app))
        attachScreenshot(named: "home-needs-you", of: app)

        // emptyos lists its review under Ready to review, after its Needs
        // you row. The review's parent is Done, so the row names it.
        let review = app.buttons["toastty-subspace-row-\(reviewSubspaceID)"]
        XCTAssertTrue(scrollTo(review, in: app))
        let reviewHeader = app.descendants(matching: .any)["toastty-needs-you-bucket-\(emptyosWorkspaceID)-readyToReview"]
        let emptyosNeedsYou = app.descendants(matching: .any)["toastty-needs-you-bucket-\(emptyosWorkspaceID)-needsYou"]
        XCTAssertEqual(reviewHeader.label, "Ready to review, 1")
        XCTAssertEqual(emptyosNeedsYou.label, "Needs you, 1")
        XCTAssertLessThan(emptyosNeedsYou.frame.minY, reviewHeader.frame.minY)
        XCTAssertLessThan(reviewHeader.frame.minY, review.frame.minY)
        XCTAssertTrue(review.label.hasSuffix("started by Website refresh"), review.label)
        XCTAssertTrue(app.descendants(matching: .any)["toastty-needs-you-all-note"].exists)
        attachScreenshot(named: "home-needs-you-review", of: app)
    }

    func testNeedsYouSaysWhenNothingNeedsTheUser() {
        let app = launchTaskFixture(tasks: "quiet")
        XCTAssertEqual(app.buttons["toastty-mobile-home-segment-needsYou"].label, "Only what needs you")
        select(.needsYou, in: app)
        let empty = app.descendants(matching: .any)["toastty-needs-you-empty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        XCTAssertTrue(empty.label.contains("Nothing needs you"), empty.label)
        XCTAssertTrue(empty.label.contains("Running and idle work is in All."), empty.label)
        attachScreenshot(named: "home-needs-you-empty", of: app)
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

    /// The Tasks tab lists its groups in the Mac's Tasks view order: Needs
    /// you, Ready to review, Running, Idle, To ship, then Done.
    func testTheTasksTabListsGroupsInTheMacOrderAndATaskWithoutATaskSpaceOpensItsDetail() {
        let app = launchTaskFixture()
        app.tabBars.buttons["Tasks"].tap()
        let tasks = "toastty-mobile-tasks"
        let needsYou = app.descendants(matching: .any)["toastty-tasks-group-needsYou"]
        XCTAssertTrue(needsYou.waitForExistence(timeout: 5))
        XCTAssertEqual(needsYou.label, "Needs you, 4")
        // Rows from several projects share the list, so each names its own.
        let question = app.buttons["toastty-subspace-row-\(questionSubspaceID)"]
        XCTAssertTrue(question.label.contains("Should the badge count tasks or sessions?, toastty"))
        XCTAssertGreaterThan(question.frame.minY, needsYou.frame.minY)
        attachScreenshot(named: "tasks-tab", of: app)

        // A review lists under Ready to review, apart from Needs you.
        let review = app.buttons["toastty-subspace-row-\(reviewSubspaceID)"]
        XCTAssertTrue(scrollTo(review, in: app, list: tasks))
        let readyToReview = app.descendants(matching: .any)["toastty-tasks-group-readyToReview"]
        XCTAssertEqual(readyToReview.label, "Ready to review, 1")
        XCTAssertGreaterThan(review.frame.minY, readyToReview.frame.minY)
        // A task Toastty is still setting up lists in Running, apart from
        // the task that started it, which needs the user.
        let starting = app.buttons["toastty-task-row-\(startingTaskID)"]
        XCTAssertTrue(scrollTo(starting, in: app, list: tasks))
        XCTAssertGreaterThan(starting.frame.minY, app.descendants(matching: .any)["toastty-tasks-group-running"].frame.minY)
        // The lane's line follows the To ship header, and its tasks follow it.
        let toShip = app.descendants(matching: .any)["toastty-tasks-group-to-ship"]
        let shipped = app.buttons["toastty-task-row-\(shippedTaskID)"]
        XCTAssertTrue(scrollTo(shipped, in: app, list: tasks))
        XCTAssertTrue(scrollTo(toShip, in: app, list: tasks))
        XCTAssertEqual(toShip.label, "To ship, 3")
        let lane = app.descendants(matching: .any)["toastty-tasks-lane-toastty"]
        XCTAssertGreaterThan(lane.frame.minY, toShip.frame.minY)
        XCTAssertGreaterThan(shipped.frame.minY, lane.frame.minY)
        // The groups in the Mac's order, from the top of the list down.
        XCTAssertEqual(
            groupOrder(in: app, list: tasks),
            ["needsYou", "readyToReview", "running", "idle", "to-ship", "done"]
        )
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

    /// A parent whose agent ended its turn to wait on another task is
    /// Running on the Mac, but its unread turn waits for the user: the
    /// Tasks tab lists it in Needs you, as Home and the Mac sidebar do, and
    /// its child lists in Running. Once the turn is read, the parent lists
    /// in Running with its child under it.
    func testATaskThatWaitsOnAnotherTaskWithAnUnreadTurnListsInNeedsYou() {
        let app = launchTaskFixture(tasks: "families")
        select(.all, in: app)
        let card = app.buttons["toastty-mobile-workspace-\(familiesWorkspaceID)"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        attachScreenshot(named: "home-families", of: app)
        app.tabBars.buttons["Tasks"].tap()
        let running = app.descendants(matching: .any)["toastty-tasks-group-running"]
        XCTAssertTrue(running.waitForExistence(timeout: 5))
        attachScreenshot(named: "tasks-tab-families", of: app)

        // Home already lists both unread parents in Needs you.
        XCTAssertTrue(card.label.hasSuffix("2 need you, 3 running"), card.label)
        let needsYou = app.descendants(matching: .any)["toastty-tasks-group-needsYou"]
        XCTAssertTrue(needsYou.exists, "An unread parent that waits on a task should list in Needs you")
        XCTAssertEqual(needsYou.label, "Needs you, 2")
        XCTAssertEqual(running.label, "Running, 3")
        let unread = app.buttons["toastty-subspace-row-\(familiesUnreadSubspaceID)"]
        let unreadParent = app.buttons["toastty-subspace-row-\(familiesUnreadParentSubspaceID)"]
        let unreadChild = app.buttons["toastty-subspace-row-\(familiesUnreadChildSubspaceID)"]
        let readParent = app.buttons["toastty-subspace-row-\(familiesReadParentSubspaceID)"]
        let readChild = app.buttons["toastty-subspace-row-\(familiesReadChildSubspaceID)"]
        // The mark says why: the unread turn.
        XCTAssertTrue(unread.label.hasPrefix("EmptyOS.app step 4 and step 5 owner, task space, ready"), unread.label)
        XCTAssertEqual(
            [needsYou, unread, unreadParent, running, unreadChild, readParent, readChild].map(\.frame.minY),
            [needsYou, unread, unreadParent, running, unreadChild, readParent, readChild].map(\.frame.minY).sorted()
        )

        // At a large text size the nested row still lists under its parent;
        // the screenshot shows the ↳ level with its wrapped title.
        app.terminate()
        let large = launchTaskFixture(tasks: "families", contentSize: .accessibilityMedium)
        large.tabBars.buttons["Tasks"].tap()
        let largeChild = large.buttons["toastty-subspace-row-\(familiesReadChildSubspaceID)"]
        XCTAssertTrue(scrollTo(largeChild, in: large, list: "toastty-mobile-tasks"))
        XCTAssertGreaterThan(largeChild.frame.minY, large.buttons["toastty-subspace-row-\(familiesReadParentSubspaceID)"].frame.minY)
        attachScreenshot(named: "tasks-tab-families-large-text", of: large)
    }

    /// A session's screen has no tab bar, as a chat has none: the bar leaves
    /// when a session opens in either tab, and comes back on the list that
    /// Back returns to. Each tab keeps its own stack of screens.
    func testASessionScreenHasNoTabBarAndEachTabKeepsItsStack() {
        let app = launchTaskFixture()
        select(.all, in: app)
        // Home: the toastty workspace, then one of its sessions.
        let workspace = app.buttons["toastty-mobile-workspace-\(toasttyWorkspaceID)"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        workspace.tap()
        let homeSession = app.buttons["toastty-mobile-workspace-session-\(workingSessionID)"]
        XCTAssertTrue(homeSession.waitForExistence(timeout: 5))
        // A list screen keeps the tab bar.
        XCTAssertTrue(waitUntilHittable(app.tabBars.buttons["Tasks"]))
        homeSession.tap()
        let conversationTitle = app.staticTexts["toastty-mobile-conversation-title"]
        XCTAssertTrue(conversationTitle.waitForExistence(timeout: 5))
        let homeTitle = conversationTitle.label
        XCTAssertTrue(waitUntilTheTabBarLeaves(app))
        attachScreenshot(named: "home-session-without-tab-bar", of: app)
        let back = app.navigationBars.firstMatch.buttons.firstMatch
        back.tap()
        XCTAssertTrue(waitUntilHittable(homeSession))
        XCTAssertTrue(waitUntilHittable(app.tabBars.buttons["Tasks"]))
        attachScreenshot(named: "home-workspace-with-tab-bar-after-back", of: app)

        // Tasks: the question task's session, opened from its row.
        app.tabBars.buttons["Tasks"].tap()
        let question = app.buttons["toastty-subspace-row-\(questionSubspaceID)"]
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        question.tap()
        XCTAssertTrue(app.descendants(matching: .any)["toastty-task-bar"].waitForExistence(timeout: 5))
        XCTAssertTrue(conversationTitle.waitForExistence(timeout: 5))
        XCTAssertNotEqual(conversationTitle.label, homeTitle)
        XCTAssertTrue(waitUntilTheTabBarLeaves(app))
        attachScreenshot(named: "tasks-session-without-tab-bar", of: app)

        // Back in Tasks returns to its list and the tab bar. Home kept its
        // workspace screen.
        back.tap()
        XCTAssertTrue(waitUntilHittable(question))
        XCTAssertTrue(waitUntilHittable(app.tabBars.buttons["Home"]))
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(waitUntilHittable(homeSession))
    }

    /// Send in a task's session, under its task bar and without the tab bar,
    /// with the keyboard up: the message shows, the keyboard leaves, and the
    /// screen keeps answering. The app used to hang here: the composer
    /// dropped the keyboard inside SwiftUI's update, and the responder lookup
    /// that this starts spun in an AttributeGraph cycle.
    func testSendInATaskSessionDropsTheKeyboardAndTheAppKeepsAnswering() {
        let app = launchTaskFixture(environment: ["TOASTTY_MOBILE_FIXTURE_TASK_SESSION_SEND": "1"])
        app.tabBars.buttons["Tasks"].tap()
        let question = app.buttons["toastty-subspace-row-\(questionSubspaceID)"]
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        question.tap()
        XCTAssertTrue(app.descendants(matching: .any)["toastty-task-bar"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilTheTabBarLeaves(app))
        let input = app.descendants(matching: .any)["toastty-mobile-composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let keyboard = app.keyboards.firstMatch
        let send = app.buttons["toastty-mobile-composer-send"]
        for (index, message) in ["Check the composer after a send.", "And once more."].enumerated() {
            input.tap()
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            input.typeText(message)
            send.tap()
            let sent = app.descendants(matching: .any)["toastty-mobile-send-optimistic-fixture-task-session-\(index + 1)"]
            XCTAssertTrue(sent.waitForExistence(timeout: 5), message)
            XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), message)
        }
        attachScreenshot(named: "task-session-after-two-sends", of: app)
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(waitUntilHittable(question))
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
        XCTAssertTrue(app.descendants(matching: .any)["toastty-tasks-group-needsYou"].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollTo(laneRelease, in: app, list: "toastty-mobile-tasks"))
        XCTAssertEqual(laneRelease.label, "Release toastty")
        attachScreenshot(named: "release-tasks-lane", of: app)
        laneRelease.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Release"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        // The Tasks tab says what started, as Home does.
        let notice = app.staticTexts["toastty-subspace-done-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertEqual(notice.label, "Starting a release of \u{201C}toastty\u{201D} on your Mac.")
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

    /// At a large text size the groups above To ship are taller than the
    /// screen, so the tab has to scroll to put the lane's line in view.
    func testACardsToShipAndDoneCountsOpenTheTasksTabAtTheirGroup() {
        let app = launchTaskFixture(contentSize: .accessibilityMedium)
        select(.all, in: app)
        let toShip = app.buttons["toastty-card-to-ship-\(toasttyWorkspaceID)"]
        XCTAssertTrue(scrollTo(toShip, in: app))
        toShip.tap()
        XCTAssertTrue(app.tabBars.buttons["Tasks"].waitForSelection())
        let lane = app.descendants(matching: .any)["toastty-tasks-lane-toastty"]
        XCTAssertTrue(waitUntilHittable(lane))
        // The lane's line shows under the navigation bar, and the groups
        // above it are scrolled off the top.
        let navigationBar = app.navigationBars["Tasks"]
        XCTAssertTrue(navigationBar.exists)
        XCTAssertGreaterThanOrEqual(lane.frame.minY, navigationBar.frame.maxY - 1, "\(lane.frame)")
        XCTAssertLessThan(lane.frame.maxY, app.tabBars.firstMatch.frame.minY, "\(lane.frame)")
        let needsYou = app.descendants(matching: .any)["toastty-tasks-group-needsYou"]
        XCTAssertFalse(needsYou.exists && needsYou.isHittable)
        attachScreenshot(named: "tasks-tab-to-ship", of: app)

        // Back to the top, where Done is off the screen, so the Done tap
        // has to scroll to it.
        scrollTasksToTop(in: app)
        let doneGroup = app.descendants(matching: .any)["toastty-tasks-group-done"]
        XCTAssertFalse(doneGroup.exists && doneGroup.isHittable)
        app.tabBars.buttons["Home"].tap()
        let done = app.buttons["toastty-card-done-\(toasttyWorkspaceID)"]
        XCTAssertTrue(scrollTo(done, in: app))
        done.tap()
        XCTAssertTrue(app.tabBars.buttons["Tasks"].waitForSelection())
        XCTAssertTrue(waitUntilHittable(doneGroup))
        // The Mac sends a count for Done, not the tasks, so the group says
        // where they are listed.
        let doneOnMac = app.staticTexts["toastty-tasks-done-on-mac"]
        XCTAssertTrue(scrollTo(doneOnMac, in: app, list: "toastty-mobile-tasks"))
        XCTAssertEqual(doneOnMac.label, "Done tasks are listed on your Mac, in Tasks (⌘⇧T).")
        XCTAssertGreaterThan(doneOnMac.frame.minY, doneGroup.frame.maxY - 1)
        attachScreenshot(named: "tasks-tab-done", of: app)
    }

    /// Until the Mac has a coordinator, the end of All says where it
    /// starts. The Coordinator tab takes the card's place once it exists.
    func testHomeSaysWhereTheCoordinatorStartsUntilItExists() {
        let app = launchTaskFixture()
        XCTAssertFalse(app.tabBars.buttons["Coordinator"].exists)
        let hint = app.descendants(matching: .any)["toastty-mobile-home-coordinator-hint"]
        XCTAssertTrue(scrollTo(hint, in: app, attempts: 16))
        XCTAssertEqual(
            hint.label,
            "Coordinator, Not started yet. It starts on your Mac: choose Open Coordinator in the Agent menu."
        )
        attachScreenshot(named: "home-coordinator-hint", of: app)
        // Needs you lists only what needs the user.
        select(.needsYou, in: app)
        XCTAssertTrue(hint.waitForNonExistence(timeout: 5))
        app.terminate()

        let withCoordinator = launchTaskFixture(environment: ["TOASTTY_MOBILE_FIXTURE_COORDINATOR": "quiet"])
        XCTAssertTrue(withCoordinator.tabBars.buttons["Coordinator"].waitForExistence(timeout: 5))
        let list = withCoordinator.collectionViews["toastty-mobile-home"]
        for _ in 0..<16 { list.swipeUp(velocity: .fast) }
        XCTAssertFalse(withCoordinator.descendants(matching: .any)["toastty-mobile-home-coordinator-hint"].exists)
    }

    /// A Mac from before tasks sends no task board and no `tasks`
    /// capability: Home asks the user to update Toastty on the Mac.
    func testHomeAsksToUpdateAMacFromBeforeTasks() {
        let app = XCUIApplication()
        app.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_HOST_TASKS"] = "unsupported"
        app.launch()
        XCTAssertTrue(app.segmentedControls["toastty-mobile-workspace-session-filter"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.buttons["Tasks"].exists)
        let hint = app.descendants(matching: .any)["toastty-mobile-home-update-mac-hint"]
        XCTAssertTrue(scrollTo(hint, in: app, attempts: 16))
        XCTAssertEqual(hint.label, "Tasks and the coordinator, Update Toastty on your Mac to see them here.")
        attachScreenshot(named: "home-update-mac-hint", of: app)
    }

    /// No action on the phone picks a task's workspace, so its detail says
    /// where to pick it on the Mac, above the actions the phone can take.
    func testATaskThatWaitsForAWorkspaceSaysToPickItOnTheMac() {
        let app = launchTaskFixture(tasks: "pick-workspace")
        app.tabBars.buttons["Tasks"].tap()
        let row = app.buttons["toastty-task-row-\(pickWorkspaceTaskID)"]
        XCTAssertTrue(scrollTo(row, in: app, list: "toastty-mobile-tasks"))
        XCTAssertEqual(row.label, "Fix the settings typo, ⚠ pick a workspace")
        row.tap()
        let step = app.descendants(matching: .any)["toastty-task-detail-mac-step"]
        XCTAssertTrue(step.waitForExistence(timeout: 5))
        XCTAssertEqual(
            step.label,
            "Pick the workspace on your Mac: open Tasks with ⌘⇧T, select this task, and choose a workspace."
        )
        let delete = app.buttons["Delete Task"]
        XCTAssertTrue(delete.exists)
        XCTAssertLessThan(step.frame.maxY, delete.frame.minY + 1)
        attachScreenshot(named: "task-detail-pick-workspace", of: app)

        // A task the phone can act on has no Mac step.
        app.buttons["Done"].tap()
        let starting = app.buttons["toastty-task-row-\(startingTaskID)"]
        XCTAssertTrue(scrollTo(starting, in: app, list: "toastty-mobile-tasks"))
        starting.tap()
        XCTAssertTrue(app.staticTexts["toastty-task-detail-title"].waitForExistence(timeout: 5))
        XCTAssertFalse(step.exists)
    }

    func testTaskLinksDrawAsChipsThatOpenTheTaskSpace() {
        let app = launchTaskFixture(taskLinks: true)
        select(.all, in: app)
        // Every fixture conversation shows the transcript with task links.
        let workspace = app.buttons["toastty-mobile-workspace-\(toasttyWorkspaceID)"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        workspace.tap()
        let session = app.buttons["toastty-mobile-workspace-session-\(workingSessionID)"]
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()
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

        // A chip opens the task's space as its row does, in place of the
        // conversation, so Back returns to the workspace the conversation
        // opened from. early-session-titles's space holds one session, so
        // its transcript opens.
        let taskBar = app.descendants(matching: .any)["toastty-task-bar"]
        XCTAssertFalse(taskBar.exists)
        question.tap()
        XCTAssertTrue(taskBar.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["toastty-mobile-conversation-title"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["toastty-mobile-workspace-detail"].exists)
        attachScreenshot(named: "task-link-chip-opens-one-session", of: app)
        // That session's own chip opens nothing more: Back still returns to
        // the workspace.
        let sameSession = link(containing: "early-session-titles", in: app)
        XCTAssertTrue(waitUntilHittable(sameSession))
        sameSession.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(taskBar.exists)
        XCTAssertFalse(app.descendants(matching: .any)["toastty-mobile-workspace-detail"].exists)
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(waitUntilHittable(session))

        // compact-session-rows's space holds two sessions, so its screen
        // opens.
        session.tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-conversation-title"].waitForExistence(timeout: 5))
        let severalSessions = link(containing: "compact-session-rows", in: app)
        XCTAssertTrue(waitUntilHittable(severalSessions))
        severalSessions.tap()
        let taskSpace = app.navigationBars["compact-session-rows"]
        XCTAssertTrue(taskSpace.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-workspace-detail"].exists)
        XCTAssertFalse(app.staticTexts["toastty-mobile-conversation-title"].exists)
        attachScreenshot(named: "task-link-chip-opens-task-space", of: app)
        taskSpace.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(waitUntilHittable(session))
    }

    /// The Tasks tab shows Home's +. It opens the same New Task sheet, and
    /// the tab says that the Mac saved the task. For a Mac that takes no new
    /// tasks from this phone it starts a session, as Home's does.
    func testNewTaskFromTheTasksTabCreatesATask() {
        var app = launchTaskFixture()
        app.tabBars.buttons["Tasks"].tap()
        let newTask = app.buttons["toastty-mobile-tasks-new-task"]
        XCTAssertTrue(newTask.waitForExistence(timeout: 5))
        XCTAssertEqual(newTask.label, "New task")
        // The same button as Home's, so the same size.
        XCTAssertEqual(newTask.frame.width, 44, accuracy: 1)
        XCTAssertEqual(newTask.frame.height, 44, accuracy: 1)
        attachScreenshot(named: "tasks-tab-new-task-button", of: app)
        newTask.tap()

        let create = app.buttons["toastty-mobile-new-task-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertFalse(create.isEnabled, "A task needs its text")
        let text = app.textViews["toastty-mobile-new-task-text"]
        text.tap()
        text.typeText("Add a share extension for links.")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: create)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        attachScreenshot(named: "tasks-tab-new-task-sheet", of: app)
        create.tap()

        let notice = app.staticTexts["toastty-subspace-done-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertEqual(notice.label, "Task saved on your Mac. It's setting up now.")
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-new-task-sheet"].waitForNonExistence(timeout: 5))
        // The Tasks tab still shows: the sheet opened over it.
        XCTAssertTrue(app.tabBars.buttons["Tasks"].isSelected)
        attachScreenshot(named: "tasks-tab-new-task-created", of: app)
        app.terminate()

        app = launchTaskFixture(environment: ["TOASTTY_MOBILE_FIXTURE_TASK_CREATE": "unsupported"])
        app.tabBars.buttons["Tasks"].tap()
        let newSession = app.buttons["toastty-mobile-tasks-new-session"]
        XCTAssertTrue(newSession.waitForExistence(timeout: 5))
        XCTAssertEqual(newSession.label, "New session")
        XCTAssertFalse(app.buttons["toastty-mobile-tasks-new-task"].exists)
        newSession.tap()
        XCTAssertTrue(app.buttons["toastty-mobile-new-session-start"].waitForExistence(timeout: 5))
    }

    /// While the connection is not live, the Tasks tab says that its list
    /// may be out of date, as Home does, and offers no release.
    func testTheTasksTabSaysWhenTheConnectionIsNotLive() {
        let app = launchTaskFixture(environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "reconnecting"])
        app.tabBars.buttons["Tasks"].tap()
        let notice = app.descendants(matching: .any)["toastty-mobile-connection-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(notice.label.hasPrefix("Reconnecting"), notice.label)
        XCTAssertTrue(app.buttons["toastty-mobile-connection-retry"].exists)
        let lane = app.descendants(matching: .any)["toastty-tasks-lane-toastty"]
        XCTAssertTrue(scrollTo(lane, in: app, list: "toastty-mobile-tasks"))
        XCTAssertFalse(app.buttons["toastty-tasks-lane-release-toastty"].exists)
        attachScreenshot(named: "tasks-tab-reconnecting", of: app)
    }

    /// Long project and task names shorten inside their rows. No row leaves
    /// the screen in Home or in the Tasks tab, at the default text size and
    /// at a large one, and a row names its project only where its heading
    /// does not.
    func testLongNamesKeepEveryRowOnTheScreen() {
        let question = "toastty-subspace-row-\(longNamesQuestionSubspaceID)"
        let starting = "toastty-task-row-\(longNamesStartingTaskID)"
        let shipped = "toastty-task-row-\(longNamesShippedTaskID)"
        let otherProject = "toastty-task-row-\(longNamesOtherProjectTaskID)"
        for size in [UIContentSizeCategory.large, .accessibilityLarge] {
            let name = size == .large ? "default" : "large-text"
            let app = launchTaskFixture(tasks: "long-names", contentSize: size)
            let width = app.windows.firstMatch.frame.width
            // Scrolls the row into the list and returns its spoken label.
            // A row at a large text size can be taller than the list's
            // visible part, so the row only has to be listed, not reachable.
            func labelOfRowOnScreen(_ identifier: String, list: String) -> String {
                let row = app.buttons[identifier]
                let rows = app.collectionViews[list]
                for _ in 0..<12 where row.exists == false { rows.swipeUp(velocity: .slow) }
                for _ in 0..<12 where row.exists == false { rows.swipeDown(velocity: .slow) }
                guard row.exists else {
                    XCTFail("\(name): \(identifier) is not listed")
                    return ""
                }
                XCTAssertGreaterThanOrEqual(row.frame.minX, 0, "\(name): \(identifier) \(row.frame)")
                XCTAssertLessThanOrEqual(row.frame.maxX, width, "\(name): \(identifier) \(row.frame)")
                return row.label
            }

            select(.all, in: app)
            let home = "toastty-mobile-home"
            // The card names the project; Other tasks mixes projects.
            let startingInCard = labelOfRowOnScreen(starting, list: home)
            XCTAssertFalse(startingInCard.contains(longNamesProject), startingInCard)
            XCTAssertTrue(labelOfRowOnScreen(otherProject, list: home).contains("linux-port-with-a-long-name"))
            _ = labelOfRowOnScreen(question, list: home)
            attachScreenshot(named: "long-names-home-\(name)", of: app)

            app.tabBars.buttons["Tasks"].tap()
            let tasks = "toastty-mobile-tasks"
            // A lane names its project; the groups below mix projects.
            let shippedInLane = labelOfRowOnScreen(shipped, list: tasks)
            XCTAssertFalse(shippedInLane.contains(longNamesProject), shippedInLane)
            let startingInTasks = labelOfRowOnScreen(starting, list: tasks)
            XCTAssertTrue(startingInTasks.contains(longNamesProject), startingInTasks)
            _ = labelOfRowOnScreen(otherProject, list: tasks)
            let questionInTasks = labelOfRowOnScreen(question, list: tasks)
            XCTAssertTrue(questionInTasks.contains("Asks: Should the app badge count"), questionInTasks)
            attachScreenshot(named: "long-names-tasks-\(name)", of: app)
            app.terminate()
        }
    }

    // MARK: - Helpers

    /// A chip keeps its text on one line with no-break spaces and word
    /// joiners; compare its words without them.
    private func link(containing text: String, in app: XCUIApplication) -> XCUIElement {
        let matches = app.links.allElementsBoundByIndex.filter { Self.words($0.label).contains(text) }
        return matches.first ?? app.links["no link contains \(text)"]
    }

    private static func words(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2060}", with: "").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private enum Segment: String {
        case all
        case needsYou
    }

    /// Without `keepsCollapsedCards`, every project card shows expanded
    /// whatever an earlier test saved.
    private func launchTaskFixture(
        keepsCollapsedCards: Bool = false, tasks: String = "1", taskLinks: Bool = false,
        contentSize: UIContentSizeCategory? = nil, environment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_TASKS"] = tasks
        if taskLinks { app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_TASK_LINKS"] = "1" }
        for (key, value) in environment { app.launchEnvironment[key] = value }
        if keepsCollapsedCards == false {
            app.launchArguments += ["-toastty-mobile-collapsed-project-cards", ""]
        }
        if let contentSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize.rawValue]
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

    /// The Tasks tab's group headers in the order they first show while
    /// the list scrolls down from its top. Rows above a header can leave
    /// the list as it scrolls, so frames are compared only on one screen.
    private func groupOrder(in app: XCUIApplication, list identifier: String) -> [String] {
        let groups = ["needsYou", "readyToReview", "running", "idle", "to-ship", "done"]
        let list = app.collectionViews[identifier]
        scrollTasksToTop(in: app)
        var order: [String] = []
        for _ in 0..<16 {
            let visible = groups
                .filter { order.contains($0) == false }
                .map { ($0, app.descendants(matching: .any)["toastty-tasks-group-\($0)"]) }
                .filter { $0.1.exists && $0.1.isHittable }
                .sorted { $0.1.frame.minY < $1.1.frame.minY }
            order += visible.map(\.0)
            if order.count == groups.count { break }
            list.swipeUp(velocity: .slow)
        }
        return order
    }

    /// Scrolls the Tasks tab until its first group, Needs you, shows.
    private func scrollTasksToTop(in app: XCUIApplication) {
        let list = app.collectionViews["toastty-mobile-tasks"]
        let first = app.descendants(matching: .any)["toastty-tasks-group-needsYou"]
        for _ in 0..<12 where (first.exists && first.isHittable) == false {
            list.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(first.exists && first.isHittable)
    }

    /// The tab bar is off the screen: gone, or not reachable by a tap.
    private func waitUntilTheTabBarLeaves(_ app: XCUIApplication, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let home = app.tabBars.buttons["Home"]
            if home.exists == false || home.isHittable == false { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return false
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
