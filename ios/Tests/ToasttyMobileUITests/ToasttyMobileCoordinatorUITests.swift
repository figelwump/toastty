import UIKit
import XCTest

/// The Coordinator tab, from a fixture Mac that runs the task system and has
/// a coordinator: the second tab, its badge, its chat as the tab's own
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

    /// The Coordinator tab shows only while the Mac has a coordinator, second
    /// between Home and Tasks, and the tab bar itself only with a task
    /// board. Without a board, the coordinator's
    /// workspace lists as an ordinary one, as an older Mac's does.
    func testTheCoordinatorTabShowsOnlyWithACoordinatorAndATaskBoard() {
        let withoutCoordinator = launch(coordinator: nil)
        XCTAssertEqual(withoutCoordinator.tabBars.buttons.allElementsBoundByIndex.map { $0.label }, ["Home", "Tasks"])
        withoutCoordinator.terminate()

        let app = launch(coordinator: "quiet")
        XCTAssertEqual(app.tabBars.buttons.allElementsBoundByIndex.map { $0.label }, ["Home", "Coordinator", "Tasks"])
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
        // The chat opens at its newest message; the chip is near the top.
        for _ in 0..<4 where chip.isHittable == false { app.swipeDown() }
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

    // MARK: - New Task to the coordinator

    func testNewTaskSendsToTheCoordinatorWithAutoPillsAndSaysItWasSent() {
        let app = launch(coordinator: "quiet")
        let newTask = app.buttons["toastty-mobile-home-new-task"]
        XCTAssertTrue(newTask.waitForExistence(timeout: 10))
        newTask.tap()

        // The Mac's panel with a coordinator: To coordinator, Send first,
        // both pills on Auto, and Create Task kept.
        let send = app.buttons["toastty-mobile-new-task-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["To Coordinator"].exists)
        XCTAssertFalse(send.isEnabled, "A message needs its text")
        let workspace = app.buttons["toastty-mobile-new-task-workspace"]
        let agent = app.buttons["toastty-mobile-new-task-agent"]
        XCTAssertEqual(workspace.value as? String, "Auto")
        XCTAssertEqual(agent.value as? String, "Auto")
        XCTAssertFalse(app.buttons["toastty-mobile-new-task-model"].exists, "Model and Effort belong to a chosen agent")
        XCTAssertFalse(app.buttons["toastty-mobile-new-task-effort"].exists)
        XCTAssertTrue(app.buttons["toastty-mobile-new-task-create"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["toastty-mobile-new-task-coordinator-note"].exists,
                       "A coordinator at its prompt takes the message at once")
        attachScreenshot(named: "coordinator-new-task-empty", of: app)

        let text = app.textViews["toastty-mobile-new-task-text"]
        text.tap()
        text.typeText("Unread dot stays on after reading on the phone.")
        XCTAssertTrue(waitUntil(timeout: 5) { send.isEnabled })

        // The first row of a list sets the pill back to Auto.
        workspace.tap()
        let research = app.buttons["herdr research"]
        XCTAssertTrue(research.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Auto"].exists)
        attachScreenshot(named: "coordinator-new-task-workspace-menu", of: app)
        research.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { workspace.value as? String == "herdr research" })
        agent.tap()
        let claude = app.buttons["Claude"]
        XCTAssertTrue(claude.waitForExistence(timeout: 5))
        claude.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { agent.value as? String == "Claude" })
        XCTAssertEqual(app.buttons["toastty-mobile-new-task-model"].value as? String, "Default")
        agent.tap()
        let auto = app.buttons["Auto"]
        XCTAssertTrue(auto.waitForExistence(timeout: 5))
        auto.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { agent.value as? String == "Auto" })
        attachScreenshot(named: "coordinator-new-task-filled", of: app)

        send.tap()
        let notice = app.staticTexts["toastty-subspace-done-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertEqual(notice.label, "Sent to the coordinator")
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-new-task-sheet"].waitForNonExistence(timeout: 5))
        attachScreenshot(named: "coordinator-new-task-sent", of: app)
    }

    func testTheSheetSaysWhenTheCoordinatorIsNotRunningAndTheMessageWaits() {
        let app = launch(coordinator: "not-running")
        app.tabBars.buttons["Tasks"].tap()
        let newTask = app.buttons["toastty-mobile-tasks-new-task"]
        XCTAssertTrue(newTask.waitForExistence(timeout: 10))
        newTask.tap()

        let send = app.buttons["toastty-mobile-new-task-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        let note = app.descendants(matching: .any)["toastty-mobile-new-task-coordinator-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertTrue(note.label.contains("The coordinator is not running. Your message waits on your Mac until it starts."),
                      note.label)
        let text = app.textViews["toastty-mobile-new-task-text"]
        text.tap()
        text.typeText("Check the release notes.")
        XCTAssertTrue(waitUntil(timeout: 5) { send.isEnabled })
        attachScreenshot(named: "coordinator-new-task-not-running", of: app)

        send.tap()
        let notice = app.staticTexts["toastty-subspace-done-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertEqual(notice.label, "Waits on your Mac: the coordinator is not running")
        attachScreenshot(named: "coordinator-new-task-waits", of: app)
    }

    func testCreateInTheCoordinatorFormMakesTheTaskDirectly() {
        let app = launch(coordinator: "quiet")
        let newTask = app.buttons["toastty-mobile-home-new-task"]
        XCTAssertTrue(newTask.waitForExistence(timeout: 10))
        newTask.tap()
        let create = app.buttons["toastty-mobile-new-task-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertFalse(create.isEnabled, "A task needs its text")
        let text = app.textViews["toastty-mobile-new-task-text"]
        text.tap()
        text.typeText("Composer keeps a blank line after send.")
        XCTAssertTrue(waitUntil(timeout: 5) { create.isEnabled })
        // The line under Create Task names what Auto falls back to.
        let footer = app.descendants(matching: .any)["toastty-mobile-new-task-footer"]
        XCTAssertTrue(footer.label.contains("Create Task makes it now in toastty with codex · gpt-6.1-sol · high."),
                      footer.label)
        create.tap()

        let notice = app.staticTexts["toastty-subspace-done-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertEqual(notice.label, "Task saved on your Mac. It's setting up now.")
    }

    /// A Mac with a coordinator that does not take a message from the
    /// phone, such as one from before the phone could send to it: the sheet
    /// is as it was.
    func testWithoutTheCapabilityTheSheetCreatesTheTaskAsBefore() {
        let app = launch(coordinator: "quiet", environment: ["TOASTTY_MOBILE_FIXTURE_COORDINATOR_SEND": "unsupported"])
        let newTask = app.buttons["toastty-mobile-home-new-task"]
        XCTAssertTrue(newTask.waitForExistence(timeout: 10))
        newTask.tap()
        let create = app.buttons["toastty-mobile-new-task-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["New Task"].exists)
        XCTAssertFalse(app.buttons["toastty-mobile-new-task-send"].exists)
        XCTAssertEqual(app.buttons["toastty-mobile-new-task-workspace"].value as? String, "toastty")
        XCTAssertEqual(app.buttons["toastty-mobile-new-task-agent"].value as? String, "Codex")
        attachScreenshot(named: "coordinator-new-task-without-capability", of: app)
    }

    func testSharedContentOpensTheCoordinatorForm() throws {
        let app = launch(coordinator: "working", environment: ["TOASTTY_MOBILE_FIXTURE_SHARED_DRAFT": "link"])
        let link = try XCTUnwrap(URL(string: "toastty-mobile-dev://shared-draft/5A4E0D2A-0000-4000-8000-000000000001"))
        app.open(link)
        let send = app.buttons["toastty-mobile-new-task-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        let text = app.textViews["toastty-mobile-new-task-text"]
        XCTAssertEqual(text.value as? String, "Toastty fixture page\nhttps://example.com/toastty")
        XCTAssertTrue(app.staticTexts["Shared screenshot.png"].exists)
        XCTAssertTrue(waitUntil(timeout: 5) { send.isEnabled })
        attachScreenshot(named: "coordinator-new-task-shared-draft", of: app)
        send.tap()

        // A working coordinator keeps a quick entry message for its turn's end.
        let notice = app.staticTexts["toastty-subspace-done-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertEqual(notice.label, "Waits on your Mac: the coordinator is working")
    }

    /// Toastty's messages in the coordinator's chat show as the Mac's
    /// coordinator chat shows them (mockup A): a digest folds to one line, a
    /// task's message is a card with its sender, a reply names the message
    /// it answers, and a quick entry message shows the user's text with the
    /// choices and the names of its files. Toastty's first lines never show.
    func testToasttysMessagesShowAsTheMacsCoordinatorChatShowsThem() {
        let app = launch(coordinator: "quiet")
        app.tabBars.buttons["Coordinator"].tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-coordinator-title"].waitForExistence(timeout: 5))

        // The newest messages show first: the quick entry message and the
        // answer to it.
        let quickEntry = textView(containing: "Add a CSV export to the Tasks tab", in: app)
        XCTAssertTrue(quickEntry.waitForExistence(timeout: 5))
        let shown = (quickEntry.value as? String) ?? ""
        XCTAssertTrue(
            shown.contains("project \"toastty\" · codex, model gpt-6.1-sol, effort high · csv-mockup.png"), shown
        )
        XCTAssertFalse(shown.contains("/Users/me"), shown)
        XCTAssertFalse(textView(containing: "[Toastty]", in: app).exists)
        attachScreenshot(named: "coordinator-chat-quick-entry", of: app)

        // A reply names the message it answers, and a tap shows that message.
        let quote = app.descendants(matching: .any)["toastty-transcript-reply-quote"]
        XCTAssertTrue(quote.waitForExistence(timeout: 5))
        XCTAssertTrue(quote.label.contains("I asked it to keep the old API"), quote.label)
        let reply = textView(containing: "Good. Release toastty once the export API merges.", in: app)
        XCTAssertTrue(reply.exists)
        XCTAssertFalse(((reply.value as? String) ?? "").contains(">"))

        // The top of the chat, as in mockup A: the digest's line, the
        // coordinator's answer with chips, and the task's card.
        for _ in 0..<4 { app.swipeDown() }
        // The row's identifier covers the line's own, so the line is found
        // by what it says.
        let digest = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Toastty · 2 updates · ")).firstMatch
        XCTAssertTrue(waitUntilHittable(digest))
        XCTAssertEqual(digest.value as? String, "Collapsed")
        XCTAssertTrue(app.staticTexts["task early-session-titles"].exists)
        XCTAssertTrue(textView(containing: "Should the old API stay for one release?", in: app).exists)
        XCTAssertFalse(textView(containing: "[Toastty]", in: app).exists)
        attachScreenshot(named: "coordinator-chat-mockup-a", of: app)

        // The digest's line opens to the whole digest.
        digest.tap()
        XCTAssertTrue(waitForValue("Expanded", of: digest))
        XCTAssertTrue(textView(containing: "[Toastty] Wake", in: app).waitForExistence(timeout: 5))
        attachScreenshot(named: "coordinator-chat-digest-open", of: app)

        // Back at the bottom, the reply's line scrolls to the answer.
        for _ in 0..<4 { app.swipeUp() }
        XCTAssertTrue(waitUntilHittable(quote))
        quote.tap()
        XCTAssertTrue(waitUntilHittable(textView(containing: "I asked it to keep the old API", in: app)))
    }

    /// A chip opens its task over the chat, inside the Coordinator tab, as
    /// the task's row opens it: a task space's one session, the screen of a
    /// task space with several, or the task's detail when the phone lists no
    /// space for it. A task that the Mac does not list stays text. Back
    /// returns to the chat with the tab bar.
    func testATaskChipInTheCoordinatorsChatOpensItsTaskOverTheChat() {
        let app = launch(coordinator: "quiet")
        app.tabBars.buttons["Coordinator"].tap()
        let coordinatorTitle = app.staticTexts["toastty-mobile-coordinator-title"]
        XCTAssertTrue(coordinatorTitle.waitForExistence(timeout: 5))
        let unlisted = textView(containing: "Old export spike", in: app)
        XCTAssertTrue(unlisted.waitForExistence(timeout: 5))
        XCTAssertFalse(link(containing: "Old export spike", in: app).exists)

        // early-session-titles's space holds one session: the chip opens its
        // transcript, with no tab bar, as every session screen.
        let oneSession = link(containing: "early-session-titles", in: app)
        XCTAssertTrue(oneSession.waitForExistence(timeout: 5))
        for _ in 0..<4 where oneSession.isHittable == false { app.swipeDown() }
        XCTAssertTrue(waitUntilHittable(oneSession))
        attachScreenshot(named: "coordinator-chip-one-session-before", of: app)
        oneSession.tap()
        let taskBar = app.descendants(matching: .any)["toastty-task-bar"]
        XCTAssertTrue(taskBar.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["toastty-mobile-conversation-title"].exists)
        XCTAssertFalse(coordinatorTitle.exists)
        XCTAssertFalse(app.descendants(matching: .any)["toastty-mobile-workspace-detail"].exists)
        XCTAssertTrue(waitUntilTheTabBarLeaves(app))
        attachScreenshot(named: "coordinator-chip-one-session-after", of: app)
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(coordinatorTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilHittable(app.tabBars.buttons["Home"]))
        XCTAssertTrue(app.tabBars.buttons["Coordinator"].isSelected)
        XCTAssertFalse(app.navigationBars.firstMatch.buttons["Back"].exists)

        for _ in 0..<4 { app.swipeDown() }
        let noSpace = link(containing: "#259", in: app)
        XCTAssertTrue(noSpace.waitForExistence(timeout: 5))
        noSpace.tap()
        let detailTitle = app.staticTexts["toastty-task-detail-title"]
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(detailTitle.label, "Parent task rollup")
        attachScreenshot(named: "coordinator-chip-opens-task-detail", of: app)
        app.navigationBars["Task"].buttons["Done"].tap()
        XCTAssertTrue(detailTitle.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Coordinator"].isSelected)

        let withSpace = link(containing: "compact-session-rows", in: app)
        XCTAssertTrue(waitUntilHittable(withSpace))
        withSpace.tap()
        let taskSpace = app.navigationBars["compact-session-rows"]
        XCTAssertTrue(taskSpace.waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Coordinator"].isSelected)
        attachScreenshot(named: "coordinator-chip-opens-task-space", of: app)
        taskSpace.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-coordinator-title"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilHittable(app.tabBars.buttons["Home"]))
        XCTAssertFalse(app.navigationBars.firstMatch.buttons["Back"].exists)
        attachScreenshot(named: "coordinator-chip-back-to-chat", of: app)
    }

    /// While the coordinator works, Send steers into its turn by default, as
    /// the Mac's coordinator chat does; Queue stays a choice for one message.
    func testTheComposerSteersByDefaultWhileTheCoordinatorWorks() {
        let app = launch(coordinator: "working")
        app.tabBars.buttons["Coordinator"].tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-coordinator-title"].waitForExistence(timeout: 5))
        let input = app.descendants(matching: .any)["toastty-mobile-composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["toastty-mobile-composer-stop"].exists)

        input.tap()
        input.typeText("Also check the release notes")
        let mode = app.buttons["toastty-mobile-composer-mode"]
        let send = app.buttons["toastty-mobile-composer-send"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertEqual(mode.label, "Steer selected")
        XCTAssertEqual(send.label, "Steer message")
        attachScreenshot(named: "coordinator-composer-steer", of: app)
        send.tap()
        let steered = app.descendants(matching: .any)["toastty-mobile-send-optimistic-fixture-queued-1"]
        XCTAssertTrue(steered.waitForExistence(timeout: 5))
        attachScreenshot(named: "coordinator-composer-steered", of: app)

        input.tap()
        input.typeText("Then summarize")
        XCTAssertTrue(waitForLabel("Steer selected", of: mode))
        mode.tap()
        let queueChoice = app.buttons["toastty-mobile-composer-mode-queue"]
        XCTAssertTrue(queueChoice.waitForExistence(timeout: 5))
        queueChoice.tap()
        XCTAssertTrue(waitForLabel("Queue selected", of: mode))
        XCTAssertEqual(send.label, "Queue message")
        send.tap()
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-send-queued-fixture-queued-2"]
            .waitForExistence(timeout: 5))
    }

    // MARK: - Copy and Reply

    /// As in the Mac's coordinator chat: Copy under the user's and the
    /// coordinator's messages, Reply under the coordinator's, always shown
    /// on a phone. A long message has them once, under its last row, and
    /// Copy takes all of it. Digests and sender cards have neither, and
    /// another session's chat has neither.
    @MainActor
    func testCopyAndReplyAreUnderTheCoordinatorsMessagesOnly() {
        UIPasteboard.general.string = ""
        let app = launch(coordinator: "quiet", environment: ["TOASTTY_MOBILE_FIXTURE_COORDINATOR_LONG_MESSAGE": "1"])
        app.tabBars.buttons["Coordinator"].tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-coordinator-title"].waitForExistence(timeout: 5))

        // Row 10 is the long message, drawn as several rows; row 9 is the
        // user's question.
        let ending = textView(containing: "That is everything that moved this week.", in: app)
        XCTAssertTrue(ending.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-transcript-row-10-c1"].exists,
                      "The fixture's long message must draw as several rows")
        let copyLong = app.buttons["toastty-mobile-transcript-copy-10"]
        let replyLong = app.buttons["toastty-mobile-transcript-reply-10"]
        XCTAssertTrue(waitUntilHittable(copyLong))
        XCTAssertEqual(app.buttons.matching(identifier: "toastty-mobile-transcript-copy-10").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "toastty-mobile-transcript-reply-10").count, 1)
        XCTAssertGreaterThanOrEqual(copyLong.frame.minY, ending.frame.maxY - 2, "The buttons sit under the last row")
        XCTAssertEqual(replyLong.frame.minY, copyLong.frame.minY, accuracy: 1)
        XCTAssertTrue(app.buttons["toastty-mobile-transcript-copy-9"].exists)
        XCTAssertFalse(app.buttons["toastty-mobile-transcript-reply-9"].exists, "The user's own message has no Reply")
        // The digest's line and the task's card.
        for row in [1, 3] {
            XCTAssertFalse(app.buttons["toastty-mobile-transcript-copy-\(row)"].exists, "row \(row)")
            XCTAssertFalse(app.buttons["toastty-mobile-transcript-reply-\(row)"].exists, "row \(row)")
        }
        attachScreenshot(named: "coordinator-copy-reply-buttons", of: app)

        // Copy shows its mark for a moment.
        copyLong.tap()
        XCTAssertTrue(waitUntil(timeout: 1.4) { copyLong.label == "Copied" })
        attachScreenshot(named: "coordinator-copy-copied", of: app)
        XCTAssertTrue(waitUntil(timeout: 5) { copyLong.label == "Copy message" })

        // Another session's chat has neither button.
        let oneSession = link(containing: "early-session-titles", in: app)
        XCTAssertTrue(oneSession.waitForExistence(timeout: 5))
        for _ in 0..<10 where oneSession.isHittable == false { app.swipeDown() }
        XCTAssertTrue(waitUntilHittable(oneSession))
        oneSession.tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-conversation-title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-transcript"].waitForExistence(timeout: 5))
        let anyCopy = NSPredicate(format: "identifier BEGINSWITH 'toastty-mobile-transcript-copy-'")
        let anyReply = NSPredicate(format: "identifier BEGINSWITH 'toastty-mobile-transcript-reply-'")
        XCTAssertGreaterThan(app.textViews.count, 0, "The session's chat shows its messages")
        XCTAssertEqual(app.buttons.matching(anyCopy).count, 0)
        XCTAssertEqual(app.buttons.matching(anyReply).count, 0)
        attachScreenshot(named: "ordinary-session-no-copy-reply", of: app)
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-coordinator-title"].waitForExistence(timeout: 5))

        // The pasteboard holds the whole message, not the last row's part.
        let input = app.descendants(matching: .any)["toastty-mobile-composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"]
        guard paste.waitForExistence(timeout: 5) else {
            return XCTFail("Paste menu did not open: \(app.debugDescription)")
        }
        paste.tap()
        let pasted = (input.value as? String) ?? ""
        XCTAssertTrue(pasted.hasPrefix("Here is the week, task by task."), pasted)
        XCTAssertTrue(pasted.hasSuffix("That is everything that moved this week."), pasted)
    }

    /// Reply puts the coordinator's message above the field, and the field
    /// takes the keyboard; a second Reply replaces it, and ✕ removes it.
    /// Sent, the message shows under its quote and the bar goes. A queued
    /// reply shows its quote too, and Edit brings it back as a reply.
    func testReplyShowsItsMessageAboveTheFieldAndSendsWithItsQuote() {
        let app = launch(coordinator: "working")
        app.tabBars.buttons["Coordinator"].tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-coordinator-title"].waitForExistence(timeout: 5))
        let bar = app.descendants(matching: .any)["toastty-mobile-composer-reply"]
        let excerpt = app.staticTexts["toastty-mobile-composer-reply-excerpt"]
        let input = app.descendants(matching: .any)["toastty-mobile-composer-input"]

        let replyLast = app.buttons["toastty-mobile-transcript-reply-8"]
        XCTAssertTrue(waitUntilHittable(replyLast))
        attachScreenshot(named: "coordinator-reply-buttons-working", of: app)
        replyLast.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertTrue(excerpt.label.hasPrefix("I made a task for it in toastty"), excerpt.label)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The field takes the keyboard")
        attachScreenshot(named: "coordinator-reply-bar", of: app)

        // With the keyboard up, the chat scrolls above it.
        let replyEarlier = app.buttons["toastty-mobile-transcript-reply-6"]
        XCTAssertTrue(scrollUntilHittable(replyEarlier, toOlder: true, in: app))
        replyEarlier.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { excerpt.label.hasPrefix("Noted. I will start the release") }, excerpt.label)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "toastty-mobile-composer-reply").count, 1)
        app.buttons["toastty-mobile-composer-reply-cancel"].tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5))

        // Steer, the default while the coordinator works.
        XCTAssertTrue(scrollUntilHittable(replyLast, toOlder: false, in: app))
        replyLast.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        input.typeText("Only on click.")
        let send = app.buttons["toastty-mobile-composer-send"]
        XCTAssertEqual(send.label, "Steer message")
        send.tap()
        let steered = app.descendants(matching: .any)["toastty-mobile-send-optimistic-fixture-queued-1"]
        XCTAssertTrue(steered.waitForExistence(timeout: 5))
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5), "The bar goes with the send")
        XCTAssertTrue(steered.label.hasPrefix("Only on click."), steered.label)
        XCTAssertFalse(steered.label.contains("[Toastty]"), steered.label)
        XCTAssertTrue(quote(containing: "I made a task for it in toastty", in: app).waitForExistence(timeout: 5))
        attachScreenshot(named: "coordinator-reply-sent", of: app)

        // Queue: the waiting message shows its quote, and Edit brings it
        // back as a reply.
        XCTAssertTrue(scrollUntilHittable(replyLast, toOlder: true, in: app))
        replyLast.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        input.typeText("Then summarize")
        let mode = app.buttons["toastty-mobile-composer-mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.tap()
        let queueChoice = app.buttons["toastty-mobile-composer-mode-queue"]
        XCTAssertTrue(queueChoice.waitForExistence(timeout: 5))
        queueChoice.tap()
        XCTAssertTrue(waitForLabel("Queue selected", of: mode))
        send.tap()
        let queued = app.descendants(matching: .any)["toastty-mobile-send-queued-fixture-queued-2"]
        XCTAssertTrue(queued.waitForExistence(timeout: 5))
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5))
        XCTAssertTrue(textView(containing: "[Toastty]", in: app).exists == false)
        XCTAssertGreaterThanOrEqual(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == 'toastty-transcript-reply-quote' AND label CONTAINS %@",
                                      "I made a task for it in toastty"))
                .count,
            2,
            "The steered and the queued reply each show the quote"
        )
        attachScreenshot(named: "coordinator-reply-queued", of: app)
        let edit = app.buttons["toastty-mobile-queued-edit-fixture-queued-2"]
        XCTAssertTrue(scrollUntilHittable(edit, toOlder: false, in: app))
        edit.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertTrue(excerpt.label.hasPrefix("I made a task for it in toastty"), excerpt.label)
        XCTAssertEqual(input.value as? String, "Then summarize")
        XCTAssertTrue(queued.waitForNonExistence(timeout: 5))
        attachScreenshot(named: "coordinator-reply-edit", of: app)
    }

    // MARK: - Helpers

    /// Drags the chat in its upper part, clear of the composer and the
    /// keyboard, until `element` can be tapped.
    private func scrollUntilHittable(_ element: XCUIElement, toOlder: Bool, in app: XCUIApplication) -> Bool {
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22))
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        for _ in 0..<8 where element.isHittable == false {
            if toOlder {
                upper.press(forDuration: 0.05, thenDragTo: lower)
            } else {
                lower.press(forDuration: 0.05, thenDragTo: upper)
            }
        }
        return waitUntilHittable(element)
    }

    private func quote(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'toastty-transcript-reply-quote' AND label CONTAINS %@", text))
            .firstMatch
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return condition()
    }

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

    private func textView(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch
    }

    private func waitForValue(_ value: String, of element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }

    private func waitForLabel(_ label: String, of element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
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
