import XCTest

/// The Coordinator tab, from a fixture Mac that runs the task system and has
/// a coordinator: the third tab, its badge, its chat as the tab's own
/// screen, what shows while the coordinator does not run, Home without the
/// coordinator's workspace, and notifications from the coordinator.
final class ToasttyMobileCoordinatorUITests: XCTestCase {
    private let coordinatorWorkspaceID = "A1000000-0000-0000-0000-000000000090"
    private let coordinatorConversationID = "B1000000-0000-0000-0000-000000000090"
    private let toasttyWorkspaceID = "A1000000-0000-0000-0000-000000000001"
    private let workingSessionID = "B1000000-0000-0000-0000-000000000002"

    override func setUp() {
        continueAfterFailure = false
    }

    /// The third tab shows only while the Mac has a coordinator, and the tab
    /// bar itself only with a task board. Without a board, the coordinator's
    /// workspace lists as an ordinary one, as an older Mac's does.
    func testTheCoordinatorTabShowsOnlyWithACoordinatorAndATaskBoard() {
        let withoutCoordinator = launch(coordinator: nil)
        XCTAssertTrue(withoutCoordinator.tabBars.buttons["Tasks"].exists)
        XCTAssertFalse(withoutCoordinator.tabBars.buttons["Coordinator"].exists)
        withoutCoordinator.terminate()

        let app = launch(coordinator: "quiet")
        XCTAssertEqual(app.tabBars.buttons.allElementsBoundByIndex.map { $0.label }, ["Home", "Tasks", "Coordinator"])
        XCTAssertTrue(app.tabBars.buttons["Home"].isSelected)
        attachScreenshot(named: "tab-bar-three-tabs", of: app)
        app.terminate()

        let noBoard = XCUIApplication()
        noBoard.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        noBoard.launchEnvironment["TOASTTY_MOBILE_FIXTURE_COORDINATOR"] = "quiet"
        noBoard.launch()
        XCTAssertTrue(noBoard.segmentedControls["toastty-mobile-workspace-session-filter"].waitForExistence(timeout: 10))
        XCTAssertFalse(noBoard.tabBars.firstMatch.exists)
        // Its only session is idle, so it lists last.
        let coordinatorWorkspace = noBoard.buttons["toastty-mobile-workspace-\(coordinatorWorkspaceID)"]
        for _ in 0..<8 where coordinatorWorkspace.exists == false || coordinatorWorkspace.isHittable == false {
            noBoard.swipeUp()
        }
        XCTAssertTrue(coordinatorWorkspace.exists)
        attachScreenshot(named: "no-task-board-coordinator-is-a-workspace", of: noBoard)
    }

    /// The coordinator is not a project: Home has no card for it, and its
    /// approval adds nothing to the Needs you numbers.
    func testHomeLeavesOutTheCoordinatorsWorkspace() {
        let app = launch(coordinator: "approval")
        select("all", in: app)
        XCTAssertTrue(app.buttons["toastty-mobile-workspace-\(toasttyWorkspaceID)"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["toastty-mobile-workspace-\(coordinatorWorkspaceID)"].exists)
        XCTAssertFalse(app.buttons["toastty-mobile-workspace-session-\(coordinatorConversationID)"].exists)
        // The same numbers as the board without a coordinator.
        XCTAssertEqual(
            app.buttons["toastty-mobile-home-segment-needsYou"].label, "Only what needs you, 9, 1 ready for review"
        )
        attachScreenshot(named: "home-without-coordinator-card", of: app)
        select("needsYou", in: app)
        XCTAssertFalse(app.buttons["toastty-mobile-workspace-session-\(coordinatorConversationID)"].exists)
        attachScreenshot(named: "home-needs-you-without-coordinator", of: app)
    }

    /// While another tab shows, the badge says what the coordinator waits
    /// for: unread output, an approval or an error. A working or quiet
    /// coordinator has none, and the badge leaves while its tab shows.
    /// iOS 26 draws the badge but reports it to no accessibility element, so
    /// there the test keeps only the screenshots; iOS 27 reports it as the
    /// tab's value.
    func testTheBadgeShowsUnreadApprovalAndErrorWhileAnotherTabShows() {
        let readsBadges = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
        for (state, badge) in [("unread", "New"), ("approval", "!"), ("error", "Error"), ("working", nil), ("quiet", nil)] {
            let app = launch(coordinator: state)
            let tab = app.tabBars.buttons["Coordinator"]
            XCTAssertTrue(tab.waitForExistence(timeout: 5))
            if readsBadges {
                XCTAssertTrue(waitForBadge(badge, on: tab, in: app), "\(state)")
            } else {
                RunLoop.current.run(until: Date().addingTimeInterval(1))
            }
            attachScreenshot(named: "badge-\(state)", of: app)
            if badge != nil {
                tab.tap()
                XCTAssertTrue(tab.waitForSelection())
                if readsBadges {
                    XCTAssertTrue(waitForBadge(nil, on: tab, in: app), "\(state) on screen")
                }
            }
            app.terminate()
        }
    }

    /// The tab's own screen is the coordinator's chat, with the golden
    /// Toasty in its title, a composer, and the tab bar, because Back has
    /// nowhere to go.
    func testTheCoordinatorsChatIsTheTabsOwnScreenAndKeepsTheTabBar() {
        let app = launch(coordinator: "working")
        app.tabBars.buttons["Coordinator"].tap()
        let title = app.staticTexts["toastty-mobile-coordinator-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Coordinator")
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Two tasks moved")).firstMatch
            .waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilHittable(app.tabBars.buttons["Home"]))
        XCTAssertFalse(app.navigationBars.firstMatch.buttons["Back"].exists)
        attachScreenshot(named: "coordinator-chat-working", of: app)
    }

    /// Without a session the tab says the coordinator does not run and that
    /// it starts on the Mac.
    func testTheTabSaysWhenTheCoordinatorIsNotRunning() {
        let app = launch(coordinator: "not-running")
        app.tabBars.buttons["Coordinator"].tap()
        let message = app.staticTexts["toastty-mobile-coordinator-not-running"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "starts on your Mac")).firstMatch.exists)
        XCTAssertTrue(waitUntilHittable(app.tabBars.buttons["Home"]))
        attachScreenshot(named: "coordinator-not-running", of: app)
    }

    /// Each tab keeps its own stack. A task the coordinator's chat links to
    /// opens over the chat, and Back returns to the chat.
    func testEachTabKeepsItsStackWhileSwitching() {
        let app = launch(coordinator: "quiet")
        select("all", in: app)
        let workspace = app.buttons["toastty-mobile-workspace-\(toasttyWorkspaceID)"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        workspace.tap()
        let homeSession = app.buttons["toastty-mobile-workspace-session-\(workingSessionID)"]
        XCTAssertTrue(homeSession.waitForExistence(timeout: 5))

        app.tabBars.buttons["Coordinator"].tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-coordinator-title"].waitForExistence(timeout: 5))
        let chip = link(containing: "compact-session-rows", in: app)
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        chip.tap()
        let taskSpace = app.navigationBars["compact-session-rows"]
        XCTAssertTrue(taskSpace.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilHittable(app.tabBars.buttons["Tasks"]))
        attachScreenshot(named: "coordinator-tab-task-space-over-chat", of: app)

        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["toastty-tasks-group-to-ship"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Coordinator"].tap()
        XCTAssertTrue(taskSpace.waitForExistence(timeout: 5))
        taskSpace.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-coordinator-title"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilHittable(app.tabBars.buttons["Home"]))

        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(waitUntilHittable(homeSession))
    }

    /// A notification from the coordinator's session opens its tab's chat,
    /// over whatever shows. Another session's notification still opens in
    /// Home.
    func testACoordinatorNotificationOpensItsTabAndOthersOpenInHome() {
        let app = launch(coordinator: "unread", environment: [
            "TOASTTY_MOBILE_FIXTURE_NOTIFICATIONS": "enabled",
            "TOASTTY_MOBILE_FIXTURE_NOTIFICATION_TAPS": "1",
        ])
        let coordinatorAlert = app.buttons["toastty-mobile-fixture-tap-coordinator-notification"]
        XCTAssertTrue(coordinatorAlert.waitForExistence(timeout: 10))
        coordinatorAlert.tap()
        XCTAssertTrue(app.tabBars.buttons["Coordinator"].waitForSelection())
        XCTAssertTrue(app.staticTexts["toastty-mobile-coordinator-title"].waitForExistence(timeout: 5))
        attachScreenshot(named: "coordinator-notification-opens-tab", of: app)

        app.buttons["toastty-mobile-fixture-tap-session-notification"].tap()
        let conversationTitle = app.staticTexts["toastty-mobile-conversation-title"]
        XCTAssertTrue(conversationTitle.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["toastty-mobile-coordinator-title"].exists)
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForSelection())

        // From a session screen, too.
        coordinatorAlert.tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-coordinator-title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Coordinator"].waitForSelection())
    }

    // MARK: - Helpers

    private func launch(coordinator: String?, environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_TASKS"] = "1"
        if let coordinator { app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_COORDINATOR"] = coordinator }
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launchArguments += ["-toastty-mobile-collapsed-project-cards", ""]
        app.launch()
        XCTAssertTrue(app.buttons["toastty-mobile-home-segment-all"].waitForExistence(timeout: 10))
        return app
    }

    private func select(_ segment: String, in app: XCUIApplication) {
        let button = app.buttons["toastty-mobile-home-segment-\(segment)"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        if button.isSelected == false { button.tap() }
        XCTAssertTrue(button.waitForSelection())
    }

    private func link(containing text: String, in app: XCUIApplication) -> XCUIElement {
        let words = { (label: String) in
            label.replacingOccurrences(of: "\u{2060}", with: "").replacingOccurrences(of: "\u{00A0}", with: " ")
        }
        let matches = app.links.allElementsBoundByIndex.filter { words($0.label).contains(text) }
        return matches.first ?? app.links["no link contains \(text)"]
    }

    /// Waits until the tab shows exactly `badge`, or no badge for `nil`.
    private func waitForBadge(_ badge: String?, on tab: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let shown = ["New", "!", "Error"].filter { showsBadge($0, on: tab, in: app) }
            if shown == (badge.map { [$0] } ?? []) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return false
    }

    /// iOS 27 reports a tab's badge as the tab's value.
    private func showsBadge(_ text: String, on tab: XCUIElement, in app: XCUIApplication) -> Bool {
        ((tab.value as? String) ?? "").contains(text)
    }

    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element
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
