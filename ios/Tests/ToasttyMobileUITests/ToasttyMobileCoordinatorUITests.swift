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

    /// The tab's … menu, in Panels' place left of Next, opens the
    /// coordinator's policy, ledger and friction notes read-only. It lists
    /// the workspace's panels after them, without the panel that already
    /// shows the policy. The ledger opens at its newest entry, the others at
    /// their top, and only the policy says how to change it.
    func testTheMenuOpensThePolicyLedgerAndFrictionNotes() {
        let app = openCoordinatorChat()
        let menu = app.buttons["toastty-coordinator-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["toastty-conversation-panels"].exists)
        let next = app.buttons["toastty-conversation-next"]
        if next.exists { XCTAssertLessThanOrEqual(menu.frame.maxX, next.frame.minX) }
        attachScreenshot(named: "coordinator-top-bar", of: app)

        menu.tap()
        let entries = ["Policy", "Ledger", "Friction Notes", "Release plan"].map { menuItem($0, in: app) }
        XCTAssertTrue(entries[0].waitForExistence(timeout: 5))
        XCTAssertTrue(entries.allSatisfy { $0.exists })
        let tops = entries.map { $0.frame.minY }
        XCTAssertEqual(tops, tops.sorted())
        // iOS 27 reads a native menu item's subtitle as part of its label;
        // iOS 26 reports it to no element, so there the screenshot shows it.
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            XCTAssertTrue(entries[0].label.contains("Your rules for the coordinator"), entries[0].label)
        }
        XCTAssertFalse(menuItem("policy.md", in: app).exists)
        attachScreenshot(named: "coordinator-menu", of: app)

        entries[0].tap()
        XCTAssertTrue(sheetTitle(in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(sheetTitle(in: app).label.contains("policy.md · on your Mac"))
        XCTAssertTrue(webText(containing: "Name tasks by title", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntilHittable(webText(containing: "Coordinator policy", in: app)))
        // The page's own identifier covers its footer's, so find it by its text.
        let footer = app.staticTexts["To change a rule, ask the coordinator in the chat."]
        XCTAssertTrue(footer.exists)
        attachScreenshot(named: "coordinator-policy-sheet", of: app)
        closeSheet(in: app)

        menu.tap()
        menuItem("Ledger", in: app).tap()
        let newest = webText(containing: "17:29 created", in: app)
        XCTAssertTrue(newest.waitForExistence(timeout: 10))
        // The reveal scrolls a frame or two after the text appears.
        XCTAssertTrue(waitUntilHittable(newest))
        XCTAssertFalse(webText(containing: "09:02 started", in: app).isHittable)
        XCTAssertFalse(footer.exists)
        attachScreenshot(named: "coordinator-ledger-sheet", of: app)
        closeSheet(in: app)

        menu.tap()
        menuItem("Friction Notes", in: app).tap()
        XCTAssertTrue(webText(containing: "Remote checks wait", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntilHittable(webText(containing: "Friction notes", in: app)))
        attachScreenshot(named: "coordinator-friction-sheet", of: app)
        closeSheet(in: app)

        menu.tap()
        menuItem("Release plan", in: app).tap()
        XCTAssertTrue(app.buttons["toastty-scratchpad-fit"].waitForExistence(timeout: 10))
        closeSheet(in: app)
    }

    /// A folder from before the coordinator wrote a file says so instead of
    /// the generic text. A Mac without file previews gets no file entries,
    /// and its policy panel lists as before.
    func testTheMenuSaysWhenAFileIsMissingAndHidesFilesWithoutPreviews() {
        let missing = openCoordinatorChat(environment: ["TOASTTY_MOBILE_FIXTURE_COORDINATOR_FILES": "missing"])
        missing.buttons["toastty-coordinator-menu"].tap()
        menuItem("Ledger", in: missing).tap()
        let message = missing.staticTexts["The coordinator has not written its ledger yet."]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertTrue(missing.buttons["Retry"].exists)
        attachScreenshot(named: "coordinator-ledger-missing", of: missing)
        missing.terminate()

        let older = openCoordinatorChat(environment: ["TOASTTY_MOBILE_FIXTURE_FILE_PREVIEW": "unsupported"])
        older.buttons["toastty-coordinator-menu"].tap()
        XCTAssertTrue(menuItem("Release plan", in: older).waitForExistence(timeout: 5))
        XCTAssertTrue(menuItem("policy.md", in: older).exists)
        XCTAssertFalse(menuItem("Ledger", in: older).exists)
        XCTAssertFalse(menuItem("Policy", in: older).exists)
        attachScreenshot(named: "coordinator-menu-without-file-previews", of: older)
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
        XCTAssertTrue(app.descendants(matching: .any)["toastty-tasks-group-needsYou"].waitForExistence(timeout: 5))
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

        // Back at the bottom, the reply's line scrolls to the answer. At the
        // chat's end the line can sit under the navigation bar: a short drag
        // down shows it.
        for _ in 0..<4 { app.swipeUp() }
        if quote.isHittable == false {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 200)))
        }
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

    /// A chip for one of the Mac's Done tasks, which leave its task board,
    /// opens the task's detail over the chat, as a chip for a task with no
    /// task space does. The Coordinator tab stays selected.
    func testAFinishedTaskChipInTheCoordinatorsChatOpensItsDetail() {
        let app = openCoordinatorChat()
        let done = link(containing: "signup-feedback-form", in: app)
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        let label = done.label.replacingOccurrences(of: "\u{2060}", with: "").replacingOccurrences(of: "\u{00A0}", with: " ")
        XCTAssertTrue(label.contains("#212"), done.label)
        // The chat opens at its newest message; the chip is above it.
        for _ in 0..<4 where done.isHittable == false { app.swipeDown() }
        XCTAssertTrue(waitUntilHittable(done))
        attachScreenshot(named: "coordinator-finished-task-chip", of: app)
        done.tap()
        let detailTitle = app.staticTexts["toastty-task-detail-title"]
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(detailTitle.label, "signup-feedback-form")
        XCTAssertFalse(app.buttons["toastty-task-detail-open-task-space"].exists)
        attachScreenshot(named: "coordinator-finished-task-chip-opens-detail", of: app)
        app.navigationBars["Task"].buttons["Done"].tap()
        XCTAssertTrue(detailTitle.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Coordinator"].isSelected)
        XCTAssertTrue(app.staticTexts["toastty-mobile-coordinator-title"].exists)
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
        let queued = queuedRow("fixture-queued-2", in: app)
        XCTAssertTrue(queued.waitForExistence(timeout: 5))

        let edit = queuedAction("edit", "fixture-queued-2", in: app)
        XCTAssertTrue(scrollIntoView(edit, in: app))
        edit.tap()
        XCTAssertTrue(queued.waitForNonExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "Then summarize")
        XCTAssertTrue(waitForLabel("Queue selected", of: mode))
        XCTAssertEqual(send.label, "Queue message")
        input.typeText(" the results")
        attachScreenshot(named: "coordinator-edited-message-queue-selected", of: app)
        send.tap()
        let edited = queuedRow("fixture-queued-3", in: app)
        XCTAssertTrue(edited.waitForExistence(timeout: 5))
        XCTAssertTrue(edited.label.contains("Then summarize the results"), edited.label)
        attachScreenshot(named: "coordinator-edited-message-queued", of: app)

        input.tap()
        input.typeText("A new message")
        XCTAssertTrue(waitForLabel("Steer selected", of: mode), "A new draft still defaults to Steer")
    }

    // MARK: - The coordinator's waiting messages

    private static let waitingRows = ["fixture-chat-1", "fixture-chat-2", "fixture-own-1", "fixture-own-2", "fixture-own-3"]

    /// The messages that wait in both of the coordinator's queues show as
    /// one list, in the order they go: this phone's queued messages, then
    /// the Mac's quick entry with its files, a task's message under its
    /// sender, and a reply under its quote. A row of the coordinator's own
    /// queue offers Remove, not Edit.
    func testTheCoordinatorsWaitingMessagesShowAsOneListInSendOrder() {
        let app = openWaitingMessages()
        for id in Self.waitingRows {
            XCTAssertTrue(queuedRow(id, in: app).waitForExistence(timeout: 5), id)
        }
        let tops = Self.waitingRows.map { queuedRow($0, in: app).frame.minY }
        XCTAssertEqual(tops, tops.sorted())
        XCTAssertTrue(queuedRow("fixture-own-2", in: app).label.contains("From task iOS parity with the Mac coordinator UI"))
        XCTAssertTrue(queuedRow("fixture-own-1", in: app).label.contains("notes.txt, sketch.png"))
        XCTAssertTrue(quote(containing: "PR #431 is ready", in: app).exists)
        XCTAssertTrue(queuedAction("edit", "fixture-chat-1", in: app).exists)
        for id in ["fixture-own-1", "fixture-own-2", "fixture-own-3"] {
            XCTAssertFalse(queuedAction("edit", id, in: app).exists, id)
            XCTAssertFalse(queuedAction("steer", id, in: app).exists, id)
            XCTAssertTrue(queuedAction("remove", id, in: app).exists, id)
        }
        XCTAssertFalse(app.descendants(matching: .any).matching(identifierPrefix: "toastty-mobile-queued-resume-").firstMatch.exists)
        attachScreenshot(named: "coordinator-queue-waiting", of: app)
    }

    /// A Stop holds the messages of both queues. One Resume, on the first
    /// held row, names them all and lets them all go.
    func testOneResumeLetsGoWhatAStopHoldsInBothQueues() {
        let app = openWaitingMessages()
        XCTAssertTrue(queuedRow("fixture-own-3", in: app).waitForExistence(timeout: 5))
        app.buttons["toastty-mobile-composer-stop"].tap()
        let resume = queuedAction("resume", "fixture-chat-1", in: app)
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertEqual(resume.label, "Resume all 5")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifierPrefix: "toastty-mobile-queued-resume-").count, 1)
        for id in Self.waitingRows {
            XCTAssertTrue(queuedRow(id, in: app).label.hasSuffix("Paused in queue"), id)
            // A Stop is no interrupted typing, and a Mac that marks none
            // gets no warning either.
            XCTAssertFalse(queuedNote("warning", id, in: app).exists, id)
        }
        attachScreenshot(named: "coordinator-queue-held", of: app)

        XCTAssertTrue(scrollIntoView(resume, in: app))
        resume.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { resume.exists == false })
        for id in Self.waitingRows {
            XCTAssertTrue(queuedRow(id, in: app).label.hasSuffix("Queued, sends after this turn"), id)
        }
        XCTAssertFalse(app.descendants(matching: .any).matching(identifierPrefix: "toastty-mobile-queued-resume-").firstMatch.exists)
        attachScreenshot(named: "coordinator-queue-resumed", of: app)
    }

    /// Remove takes a row out of whichever queue holds it, and the one
    /// Resume counts what is left.
    func testRemoveTakesARowOutOfEitherQueue() {
        let app = openWaitingMessages()
        XCTAssertTrue(queuedRow("fixture-own-3", in: app).waitForExistence(timeout: 5))
        app.buttons["toastty-mobile-composer-stop"].tap()
        XCTAssertTrue(queuedAction("resume", "fixture-chat-1", in: app).waitForExistence(timeout: 5))
        for id in ["fixture-chat-2", "fixture-own-2"] {
            let remove = queuedAction("remove", id, in: app)
            XCTAssertTrue(scrollIntoView(remove, in: app), id)
            remove.tap()
            XCTAssertTrue(waitUntil(timeout: 5) { queuedRow(id, in: app).exists == false }, id)
        }
        for id in ["fixture-chat-1", "fixture-own-1", "fixture-own-3"] {
            XCTAssertTrue(queuedRow(id, in: app).exists, id)
        }
        XCTAssertEqual(queuedAction("resume", "fixture-chat-1", in: app).label, "Resume all 3")
        attachScreenshot(named: "coordinator-queue-removed", of: app)
    }

    /// An older Mac does not share the coordinator's own queue: the chat
    /// lists this phone's queued messages as before, each with Send next
    /// after a Stop.
    func testAnOlderMacListsOnlyTheConversationsQueueAsBefore() {
        let app = openWaitingMessages(environment: ["TOASTTY_MOBILE_FIXTURE_COORDINATOR_QUEUE": "unsupported"])
        XCTAssertTrue(queuedRow("fixture-chat-2", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(queuedRow("fixture-own-1", in: app).exists)
        app.buttons["toastty-mobile-composer-stop"].tap()
        for id in ["fixture-chat-1", "fixture-chat-2"] {
            let resume = queuedAction("resume", id, in: app)
            XCTAssertTrue(resume.waitForExistence(timeout: 5), id)
            XCTAssertEqual(resume.label, "Send next")
            XCTAssertTrue(queuedAction("edit", id, in: app).exists, id)
        }
        attachScreenshot(named: "coordinator-queue-older-mac", of: app)
    }

    /// At the largest text size each queue's actions stay reachable and
    /// whole, one above the other: the one Resume on the first row and
    /// Remove on the last.
    func testWaitingMessagesStayReachableAtTheLargestTextSize() {
        let app = openWaitingMessages(
            arguments: ["-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue]
        )
        XCTAssertTrue(queuedRow("fixture-own-3", in: app).waitForExistence(timeout: 5))
        app.buttons["toastty-mobile-composer-stop"].tap()
        let resume = queuedAction("resume", "fixture-chat-1", in: app)
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        let removeLast = queuedAction("remove", "fixture-own-3", in: app)
        XCTAssertTrue(scrollIntoUncoveredTranscript(removeLast, in: app))
        attachScreenshot(named: "coordinator-queue-large-text-remove", of: app)
        removeLast.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { queuedRow("fixture-own-3", in: app).exists == false })
        XCTAssertTrue(scrollIntoUncoveredTranscript(resume, in: app))
        XCTAssertEqual(resume.label, "Resume all 4")
        // The actions stand one above the other, so no title breaks.
        let edit = queuedAction("edit", "fixture-chat-1", in: app)
        XCTAssertGreaterThanOrEqual(edit.frame.minY, resume.frame.maxY - 1)
        attachScreenshot(named: "coordinator-queue-large-text-resume", of: app)
        resume.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { resume.exists == false })
    }

    /// A message longer than the Mac sends comes shortened, ends with an
    /// ellipsis, and keeps its Remove.
    func testALongWaitingMessageComesShortenedWithItsRemove() {
        let app = openWaitingMessages(environment: ["TOASTTY_MOBILE_FIXTURE_COORDINATOR_QUEUE_LONG": "1"])
        let row = queuedRow("fixture-own-1", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("retry budget"))
        XCTAssertTrue(row.label.contains("…"))
        let remove = queuedAction("remove", "fixture-own-1", in: app)
        XCTAssertTrue(scrollIntoUncoveredTranscript(remove, in: app))
        attachScreenshot(named: "coordinator-queue-long-message", of: app)
        remove.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { row.exists == false })
        XCTAssertTrue(queuedRow("fixture-own-2", in: app).exists)
    }

    /// After Toastty on the Mac quit while it typed a message, that message
    /// waits, held, and its row alone warns that the coordinator may have
    /// it already, above its Resume and Remove. Resume sends it again, and
    /// the warning goes.
    func testAnInterruptedMessageWarnsOnItsRowUntilResume() {
        let app = openWaitingMessages(environment: ["TOASTTY_MOBILE_FIXTURE_COORDINATOR_QUEUE_INTERRUPTED": "1"])
        let row = queuedRow("fixture-own-1", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.hasSuffix("Paused in queue"))
        let warning = queuedNote("warning", "fixture-own-1", in: app)
        XCTAssertTrue(warning.exists)
        XCTAssertTrue(warning.label.contains("Toastty on the Mac quit while it typed this message"), warning.label)
        XCTAssertTrue(warning.label.contains("If the message is there, choose Remove"), warning.label)
        XCTAssertTrue(warning.label.contains("If it is not, choose Resume to send it"), warning.label)
        for id in ["fixture-chat-1", "fixture-chat-2", "fixture-own-2", "fixture-own-3"] {
            XCTAssertFalse(queuedNote("warning", id, in: app).exists, id)
        }
        let resume = queuedAction("resume", "fixture-own-1", in: app)
        XCTAssertEqual(resume.label, "Resume")
        XCTAssertTrue(queuedAction("remove", "fixture-own-1", in: app).exists)
        XCTAssertTrue(scrollIntoUncoveredTranscript(resume, in: app))
        XCTAssertGreaterThanOrEqual(resume.frame.minY, warning.frame.maxY - 1)
        attachScreenshot(named: "coordinator-queue-interrupted-warning", of: app)

        resume.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { warning.exists == false })
        XCTAssertTrue(row.label.hasSuffix("Queued, sends after this turn"))
        attachScreenshot(named: "coordinator-queue-interrupted-resumed", of: app)
    }

    /// When the Mac cannot remove a message, its row stays and says so.
    func testAFailedRemoveLeavesTheRowAndSaysSo() {
        let app = openWaitingMessages(environment: ["TOASTTY_MOBILE_FIXTURE_COORDINATOR_QUEUE_REMOVE_FAILS": "1"])
        let row = queuedRow("fixture-own-2", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let remove = queuedAction("remove", "fixture-own-2", in: app)
        XCTAssertTrue(scrollIntoUncoveredTranscript(remove, in: app))
        remove.tap()
        let failure = queuedNote("failure", "fixture-own-2", in: app)
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        XCTAssertEqual(failure.label, "The Mac could not remove this message. It still waits.")
        XCTAssertTrue(row.exists)
        XCTAssertTrue(remove.exists)
        for id in ["fixture-own-1", "fixture-own-3"] {
            XCTAssertFalse(queuedNote("failure", id, in: app).exists, id)
        }
        XCTAssertTrue(scrollIntoUncoveredTranscript(failure, in: app))
        attachScreenshot(named: "coordinator-queue-remove-failed", of: app)
    }

    /// Scrolls the chat until `element` shows whole between the header and
    /// the composer, where Jump to latest does not cover it, with drags long
    /// enough for the largest text size.
    private func scrollIntoUncoveredTranscript(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let jump = app.buttons["toastty-mobile-transcript-jump-latest"]
        for _ in 0..<60 {
            let navigationBar = app.navigationBars.firstMatch
            let top = navigationBar.exists ? navigationBar.frame.maxY : app.frame.minY
            let bottom = composerTop(in: app)
            let frame = element.frame
            let covered = jump.exists && jump.frame.intersects(frame)
            if element.exists, frame.minY >= top, frame.maxY <= bottom, covered == false, element.isHittable {
                return true
            }
            // Long drags until the element shows, then short ones, so that a
            // drag does not carry it past the room it fits in.
            let onScreen = element.exists && frame.maxY > top && frame.minY < bottom
            let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: onScreen ? 0.26 : 0.15))
            let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: onScreen ? 0.31 : 0.34))
            // Toward the end of the chat while the element is in its lower
            // part or covered; toward its start otherwise.
            if element.exists, frame.maxY > top + (bottom - top) / 2 || covered {
                lower.press(forDuration: 0.05, thenDragTo: upper, withVelocity: .slow, thenHoldForDuration: 0.3)
            } else {
                upper.press(forDuration: 0.05, thenDragTo: lower, withVelocity: .slow, thenHoldForDuration: 0.3)
            }
        }
        return false
    }

    private func openWaitingMessages(
        environment: [String: String] = [:],
        arguments: [String] = []
    ) -> XCUIApplication {
        var environment = environment
        if environment["TOASTTY_MOBILE_FIXTURE_COORDINATOR_QUEUE"] == nil {
            environment["TOASTTY_MOBILE_FIXTURE_COORDINATOR_QUEUE"] = "1"
        }
        let app = launch(coordinator: "working", environment: environment, arguments: arguments)
        app.tabBars.buttons["Coordinator"].tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-coordinator-title"].waitForExistence(timeout: 5))
        return app
    }

    private func queuedRow(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["toastty-mobile-send-queued-\(id)"]
    }

    private func queuedAction(_ key: String, _ id: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons["toastty-mobile-queued-\(key)-\(id)"]
    }

    /// A line on a waiting message's row: `warning` or `failure`.
    private func queuedNote(_ key: String, _ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["toastty-mobile-queued-\(key)-\(id)"]
    }

    // MARK: - The New line

    /// The coordinator's chat opens at the line above the first message
    /// that neither the Mac nor this phone showed, and Jump to latest
    /// counts the coordinator's messages below it. The fixture Mac read
    /// through the chat's second message; three answers came after it.
    func testTheChatOpensAtTheNewLineAndJumpToLatestCountsWhatIsNew() {
        let app = launch(coordinator: "working", environment: ["TOASTTY_MOBILE_FIXTURE_COORDINATOR_READ_THROUGH": "2"])
        app.tabBars.buttons["Coordinator"].tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-coordinator-title"].waitForExistence(timeout: 5))
        let line = app.descendants(matching: .any)["toastty-transcript-new-messages"]
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        XCTAssertEqual(line.label, "New messages")
        // At the top of the chat, under the navigation bar, and the
        // messages above it are scrolled away.
        let top = app.navigationBars.firstMatch.frame.maxY
        XCTAssertTrue(waitUntil(timeout: 5) { line.frame.minY >= top - 1 && line.frame.minY < top + 140 },
                      "The line is at \(line.frame), the navigation bar ends at \(top)")
        let readAnswer = textView(containing: "Two tasks moved", in: app)
        XCTAssertTrue(readAnswer.exists == false || readAnswer.frame.maxY <= top + 1,
                      "The answer read before is at \(readAnswer.frame)")
        attachScreenshot(named: "coordinator-new-line", of: app)

        // Scrolled up into what was read, Jump to latest says how many are
        // new.
        let jump = app.buttons["toastty-mobile-transcript-jump-latest"]
        for _ in 0..<4 where jump.exists == false {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 160)),
                        withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        XCTAssertTrue(jump.label.contains("3 new"), "Jump to latest reads \(jump.label)")
        attachScreenshot(named: "coordinator-jump-3-new", of: app)
    }

    /// The user's own message answers: the line goes.
    func testASendInTheCoordinatorsChatRemovesTheNewLine() {
        let app = launch(coordinator: "working", environment: ["TOASTTY_MOBILE_FIXTURE_COORDINATOR_READ_THROUGH": "2"])
        app.tabBars.buttons["Coordinator"].tap()
        let line = app.descendants(matching: .any)["toastty-transcript-new-messages"]
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        let input = app.descendants(matching: .any)["toastty-mobile-composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Thanks, start the release")
        app.buttons["toastty-mobile-composer-send"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-send-optimistic-fixture-queued-1"]
            .waitForExistence(timeout: 5))
        XCTAssertTrue(line.waitForNonExistence(timeout: 5))
        attachScreenshot(named: "coordinator-new-line-after-send", of: app)
    }

    /// A Mac that does not share the chat's read point: no line, as before.
    func testNoNewLineWhenTheMacDoesNotShareItsReadPoint() {
        let app = launch(coordinator: "working", environment: [
            "TOASTTY_MOBILE_FIXTURE_COORDINATOR_READ_THROUGH": "2",
            "TOASTTY_MOBILE_FIXTURE_COORDINATOR_CHAT_READ": "unsupported",
        ])
        app.tabBars.buttons["Coordinator"].tap()
        XCTAssertTrue(textView(containing: "I made a task for it", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["toastty-transcript-new-messages"].exists)
        let jump = app.buttons["toastty-mobile-transcript-jump-latest"]
        if jump.exists { XCTAssertFalse(jump.label.contains("new")) }
    }

    // MARK: - Quiet wake turns

    /// The chat of the user's report: two wake turns in which the
    /// coordinator found nothing for the user. With a Mac that shares which
    /// turns are quiet, each folds whole under its digest's line, as on the
    /// Mac: no work strip and no answer. The two quiet turns in a row show
    /// as one line, "Toastty · 2 quiet checks · …", that opens into the two
    /// digests' lines. A digest's line opens the digest, the work and the
    /// answer, and closes them again. The row's line closes it all.
    func testAQuietWakeTurnFoldsWholeUnderItsDigestsLine() {
        let app = launch(coordinator: "quiet", environment: ["TOASTTY_MOBILE_FIXTURE_COORDINATOR_QUIET_TURNS": "1"])
        app.tabBars.buttons["Coordinator"].tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-coordinator-title"].waitForExistence(timeout: 5))
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Toastty · 2 quiet checks · ")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The two quiet turns show as one line")
        XCTAssertTrue(waitUntilHittable(row))
        XCTAssertEqual(row.value as? String, "Collapsed")
        XCTAssertEqual(row.identifier.hasPrefix("toastty-mobile-transcript-quiet-checks-"), true, row.identifier)
        // The row's identifier covers the line's own, so a digest's line is
        // found by what it says.
        let lines = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Toastty · 1 update · "))
        XCTAssertEqual(lines.count, 0, "A closed row shows no digest's line")
        for answer in ToasttyQuietTurnText.answers {
            XCTAssertFalse(textView(containing: answer, in: app).exists, "\(answer) shows while its turn is folded")
        }
        XCTAssertFalse(workStrips(in: app).firstMatch.exists, "A quiet turn has no work strip")
        // The answer before the quiet turns still shows.
        XCTAssertTrue(textView(containing: "I made a task for it", in: app).exists)
        attachScreenshot(named: "coordinator-quiet-turns-folded", of: app)

        row.tap()
        XCTAssertTrue(waitForValue("Expanded", of: row))
        XCTAssertTrue(lines.element(boundBy: 1).waitForExistence(timeout: 5), "The open row shows both digests' lines")
        let last = lines.element(boundBy: 1)
        XCTAssertTrue(waitUntilHittable(last))
        XCTAssertEqual(last.value as? String, "Collapsed")
        XCTAssertEqual(lines.element(boundBy: 0).value as? String, "Collapsed")
        for answer in ToasttyQuietTurnText.answers {
            XCTAssertFalse(textView(containing: answer, in: app).exists, "Opening the row opened a turn: \(answer)")
        }
        attachScreenshot(named: "coordinator-quiet-checks-open", of: app)

        last.tap()
        XCTAssertTrue(waitForValue("Expanded", of: last))
        XCTAssertTrue(textView(containing: "Nothing needs you.", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(textView(containing: "[Toastty] Wake", in: app).exists)
        XCTAssertFalse(textView(containing: "Nothing new needs you.", in: app).exists, "The other quiet turn opened too")
        attachScreenshot(named: "coordinator-quiet-turn-open", of: app)

        tapTheLine(of: last)
        XCTAssertTrue(waitForValue("Collapsed", of: last))
        XCTAssertTrue(textView(containing: "Nothing needs you.", in: app).waitForNonExistence(timeout: 5))

        row.tap()
        XCTAssertTrue(waitForValue("Collapsed", of: row))
        XCTAssertTrue(lines.firstMatch.waitForNonExistence(timeout: 5), "A closed row hides the digests' lines")
    }

    /// An older Mac does not share which turns are quiet: their answers
    /// show, as before. Their work folds under the digest's line, as the
    /// work of every turn in the coordinator's chat does, so they have no
    /// work strip.
    func testQuietWakeTurnsStayOpenWithAMacThatDoesNotShareTheMarks() {
        let app = launch(coordinator: "quiet", environment: ["TOASTTY_MOBILE_FIXTURE_COORDINATOR_QUIET_TURNS": "unsupported"])
        app.tabBars.buttons["Coordinator"].tap()
        for answer in ToasttyQuietTurnText.answers {
            XCTAssertTrue(textView(containing: answer, in: app).waitForExistence(timeout: 5), answer)
        }
        XCTAssertFalse(workStrips(in: app).firstMatch.exists, "A digest's line is its turn's line")
        XCTAssertFalse(textView(containing: "[Toastty] Wake", in: app).exists, "A digest shows open")
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "quiet checks"))
        XCTAssertEqual(rows.count, 0, "Turns that are not known to be quiet do not join into a row")
        attachScreenshot(named: "coordinator-quiet-turns-older-mac", of: app)
    }

    /// The New line's count leaves the quiet turns out, as on the Mac: the
    /// fixture Mac read through the chat's second message, and three
    /// answers and two quiet turns came after it.
    func testTheNewLineDoesNotCountQuietWakeTurns() {
        for (marks, count) in [("1", 3), ("unsupported", 5)] {
            let app = launch(coordinator: "working", environment: [
                "TOASTTY_MOBILE_FIXTURE_COORDINATOR_READ_THROUGH": "2",
                "TOASTTY_MOBILE_FIXTURE_COORDINATOR_QUIET_TURNS": marks,
            ])
            app.tabBars.buttons["Coordinator"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["toastty-transcript-new-messages"].waitForExistence(timeout: 5))
            let jump = app.buttons["toastty-mobile-transcript-jump-latest"]
            for _ in 0..<4 where jump.exists == false {
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 160)),
                            withVelocity: .slow, thenHoldForDuration: 0.3)
            }
            XCTAssertTrue(jump.waitForExistence(timeout: 5))
            XCTAssertTrue(jump.label.contains("\(count) new"), "With marks \(marks), Jump to latest reads \(jump.label)")
            if marks == "1" { attachScreenshot(named: "coordinator-jump-new-without-quiet-turns", of: app) }
            app.terminate()
        }
    }

    // MARK: - Scroll position

    /// The chat opens at its New line, also when what is new is shorter than
    /// the screen: the chat then shows its end, with the line on screen, and
    /// no empty space under the last message. In a long chat, which the
    /// transcript lays out lazily, the line went to the top of the screen
    /// and left the rest of it empty until the user dragged.
    func testTheNewLineOverAShortEndLeavesNoEmptySpace() {
        let app = launch(coordinator: "quiet", environment: [
            "TOASTTY_MOBILE_FIXTURE_COORDINATOR_WAKE_TURNS": "60",
            // Through the last wake turn's tool call: only its answer is new.
            "TOASTTY_MOBILE_FIXTURE_COORDINATOR_READ_THROUGH": "-2",
            "TOASTTY_MOBILE_FIXTURE_SCROLL_TRACE": "1",
        ])
        app.tabBars.buttons["Coordinator"].tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-coordinator-title"].waitForExistence(timeout: 5))
        let line = app.descendants(matching: .any)["toastty-transcript-new-messages"]
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        let answer = textView(containing: "Wake 60.", in: app)
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        // The opening moves for a moment after the chat shows.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(waitUntil(timeout: 5) { isAtTheChatsEnd(app) },
                      "The chat rests past its end: \(scrollMetrics(in: app) ?? [:])")
        let top = app.navigationBars.firstMatch.frame.maxY
        XCTAssertTrue(line.frame.minY >= top - 1 && line.frame.maxY <= answer.frame.minY + 1,
                      "The line is at \(line.frame), the answer at \(answer.frame)")
        XCTAssertFalse(app.buttons["toastty-mobile-transcript-jump-latest"].exists)
        attachScreenshot(named: "coordinator-new-line-short-end", of: app)
    }

    /// Back on the Coordinator tab, the chat opens at its end again, also
    /// after the user scrolled up in it. The phone loads the chat again each
    /// time it opens; the chat opened at its first message.
    func testTheChatOpensAtItsEndAgainAfterAnotherTab() {
        let app = launch(coordinator: "quiet", environment: [
            "TOASTTY_MOBILE_FIXTURE_COORDINATOR_WAKE_TURNS": "20",
            "TOASTTY_MOBILE_FIXTURE_COORDINATOR_REOPENS": "1",
            "TOASTTY_MOBILE_FIXTURE_SCROLL_TRACE": "1",
        ])
        app.tabBars.buttons["Coordinator"].tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-coordinator-title"].waitForExistence(timeout: 5))
        let newest = textView(containing: "Wake 20.", in: app)
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5) { isAtTheChatsEnd(app) })

        let jump = app.buttons["toastty-mobile-transcript-jump-latest"]
        for _ in 0..<4 where jump.exists == false {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 220)),
                        withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTAssertTrue(jump.waitForExistence(timeout: 5))

        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.buttons["toastty-mobile-home-segment-all"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Coordinator"].tap()
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(waitUntil(timeout: 5) { isAtTheChatsEnd(app) && newest.isHittable },
                      "The chat opened at \(scrollMetrics(in: app) ?? [:])")
        XCTAssertFalse(jump.exists)
        attachScreenshot(named: "coordinator-end-after-another-tab", of: app)
    }

    /// The transcript's latest scroll geometry, from the fixture's scroll
    /// trace (`TOASTTY_MOBILE_FIXTURE_SCROLL_TRACE=1`).
    private func scrollMetrics(in app: XCUIApplication) -> [String: Double]? {
        let element = app.descendants(matching: .any)["toastty-mobile-transcript-scroll-metrics"]
        guard element.exists, let value = element.value as? String,
              let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any]
        else { return nil }
        return object.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    /// The screen's bottom is at the transcript's end: not above it, and
    /// not past it.
    private func isAtTheChatsEnd(_ app: XCUIApplication) -> Bool {
        guard let metrics = scrollMetrics(in: app),
              let content = metrics["contentHeight"], let bottom = metrics["visibleMaxY"]
        else { return false }
        return abs(content - bottom) <= 2
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

        copyLong.tap()

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
        XCTAssertTrue(scrollIntoView(replyEarlier, in: app))
        replyEarlier.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { excerpt.label.hasPrefix("Noted. I will start the release") }, excerpt.label)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "toastty-mobile-composer-reply").count, 1)
        app.buttons["toastty-mobile-composer-reply-cancel"].tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5))

        // Steer, the default while the coordinator works.
        XCTAssertTrue(scrollIntoView(replyLast, in: app))
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
        XCTAssertTrue(scrollIntoView(replyLast, in: app))
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
        XCTAssertTrue(scrollIntoView(edit, in: app))
        edit.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertTrue(excerpt.label.hasPrefix("I made a task for it in toastty"), excerpt.label)
        XCTAssertEqual(input.value as? String, "Then summarize")
        XCTAssertTrue(queued.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForLabel("Queue message", of: send))
        attachScreenshot(named: "coordinator-reply-edit", of: app)
    }

    // MARK: - Attached images

    /// The name the fixture Mac gave the photo that the phone sent.
    private let phonePhoto = "9B1E4C2A-7D3F-4E21-8C5B-2A6F1D0E9C47.jpg"

    /// With a Mac that serves them, a message's images show as thumbnails
    /// in its bubble, as in the Mac's chat: images attached on the Mac, and
    /// a photo sent from the phone. Every image has the same 200 × 120 box,
    /// loaded, still loading, or gone from the Mac (its name in the box),
    /// so a loading image does not move the chat. A file that is not an
    /// image keeps its name chip, and the text no longer names the files.
    func testAttachedImagesShowAsThumbnailsInTheBubble() {
        let app = launch(coordinator: "quiet", environment: ["TOASTTY_MOBILE_FIXTURE_COORDINATOR_IMAGES": "1"])
        app.tabBars.buttons["Coordinator"].tap()
        let text = textView(containing: "Here is the crash screen", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertFalse(((text.value as? String) ?? "").contains("crash-screen.png"), "The text no longer names the files")

        let photoText = textView(containing: "And the photo I took of the phone.", in: app)
        XCTAssertTrue(photoText.waitForExistence(timeout: 5))
        XCTAssertFalse(((photoText.value as? String) ?? "").contains("[Attachment:"), "The photo shows by itself")
        XCTAssertTrue(app.buttons["Image \(phonePhoto)"].waitForExistence(timeout: 10))

        // The Mac's message is above: its boxes load as they come on screen.
        let crashBox = attachedImage("crash-screen.png", in: app)
        XCTAssertTrue(crashBox.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollIntoView(crashBox, in: app))
        // Loaded thumbnails open the full-size view, so they are buttons.
        XCTAssertTrue(app.buttons["Image crash-screen.png"].waitForExistence(timeout: 10))
        let slow = attachedImage("slow-capture.png", in: app)
        XCTAssertTrue(slow.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollIntoView(slow, in: app))
        let gone = attachedImage("Photo-91C2.jpg", in: app)
        XCTAssertTrue(waitForValue("Not available", of: gone))
        XCTAssertEqual(slow.value as? String, "Loading")
        XCTAssertFalse(app.buttons["Image Photo-91C2.jpg"].exists)
        XCTAssertFalse(app.buttons["Image slow-capture.png"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["File notes.txt"].exists)
        // The Mac's chat shows the quick entry message's image too.
        XCTAssertTrue(attachedImage("csv-mockup.png", in: app).exists)

        for name in ["crash-screen.png", phonePhoto, "Photo-91C2.jpg", "slow-capture.png"] {
            let frame = attachedImage(name, in: app).frame
            XCTAssertEqual(frame.width, 200, accuracy: 1, name)
            XCTAssertEqual(frame.height, 120, accuracy: 1, name)
        }
        attachScreenshot(named: "coordinator-images-thumbnails", of: app)
    }

    /// An older Mac does not serve the images: the bubble names the files
    /// in its text, as before.
    func testAnOlderMacsAttachedFilesShowByName() {
        let app = launch(coordinator: "quiet", environment: ["TOASTTY_MOBILE_FIXTURE_COORDINATOR_IMAGES": "unsupported"])
        app.tabBars.buttons["Coordinator"].tap()
        let text = textView(containing: "Here is the crash screen", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollIntoView(text, in: app))
        let shown = (text.value as? String) ?? ""
        XCTAssertTrue(shown.contains("crash-screen.png, Photo-91C2.jpg, slow-capture.png, notes.txt"), shown)
        XCTAssertFalse(shown.contains("/Users/me"), shown)
        XCTAssertTrue(textView(containing: "[Attachment: Photo-3213AEE3.jpg]", in: app).exists)
        XCTAssertFalse(attachedImage(phonePhoto, in: app).exists)
        XCTAssertFalse(attachedImage("crash-screen.png", in: app).exists)
        XCTAssertFalse(attachedImage("csv-mockup.png", in: app).exists)
        attachScreenshot(named: "coordinator-images-older-mac", of: app)
    }

    /// A tap on a thumbnail shows the image full size, from the Mac. A pinch
    /// zooms it; Done closes the view, and so does a swipe down while the
    /// image fits the screen.
    func testATapOnAThumbnailShowsTheImageFullSize() {
        let app = launch(coordinator: "quiet", environment: ["TOASTTY_MOBILE_FIXTURE_COORDINATOR_IMAGES": "1"])
        app.tabBars.buttons["Coordinator"].tap()
        // A box loads its image once it is on screen; then it is a button.
        let crashBox = attachedImage("crash-screen.png", in: app)
        XCTAssertTrue(crashBox.waitForExistence(timeout: 10))
        XCTAssertTrue(scrollIntoView(crashBox, in: app))
        let crash = app.buttons["Image crash-screen.png"]
        XCTAssertTrue(crash.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntilHittable(crash))
        crash.tap()

        let viewer = app.descendants(matching: .any)["toastty-mobile-attachment-viewer-image"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue("Full size, Fits the screen", of: viewer), "\(viewer.value ?? "")")
        XCTAssertEqual(viewer.label, "Image crash-screen.png")
        XCTAssertTrue(app.staticTexts["crash-screen.png"].exists)
        attachScreenshot(named: "coordinator-image-full-size", of: app)

        viewer.pinch(withScale: 3, velocity: 3)
        XCTAssertTrue(waitForValue("Full size, Zoomed", of: viewer), "\(viewer.value ?? "")")
        attachScreenshot(named: "coordinator-image-zoomed", of: app)
        app.buttons["toastty-mobile-attachment-viewer-done"].tap()
        XCTAssertTrue(viewer.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitUntilHittable(crash))

        // The phone's own photo, and a swipe down to close.
        let photo = app.buttons["Image \(phonePhoto)"]
        XCTAssertTrue(scrollIntoView(photo, in: app))
        photo.tap()
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue("Full size, Fits the screen", of: viewer), "\(viewer.value ?? "")")
        attachScreenshot(named: "coordinator-image-phone-photo", of: app)
        viewer.swipeDown(velocity: .fast)
        XCTAssertTrue(viewer.waitForNonExistence(timeout: 5))
        XCTAssertTrue(textView(containing: "Here is the crash screen", in: app).exists)
    }

    // MARK: - Helpers

    /// An attached image's box, loaded or not.
    private func attachedImage(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Image \(name)")).firstMatch
    }

    /// Drags the chat in its upper part, clear of the composer and the
    /// keyboard, until `element` shows between the navigation bar and the
    /// composer. The chat scrolls under the composer, and XCUITest calls a
    /// button there hittable although a tap reaches the composer. Each drag
    /// holds before it lifts, so the chat does not fling past the element.
    private func scrollIntoView(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22))
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
        for _ in 0..<12 {
            let navigationBar = app.navigationBars.firstMatch
            let top = navigationBar.exists ? navigationBar.frame.maxY : app.frame.minY
            let bottom = composerTop(in: app)
            let frame = element.frame
            if element.exists, frame.minY >= top, frame.maxY <= bottom {
                return waitUntilHittable(element)
            }
            if element.exists, frame.maxY > bottom {
                lower.press(forDuration: 0.05, thenDragTo: upper, withVelocity: .slow, thenHoldForDuration: 0.3)
            } else {
                upper.press(forDuration: 0.05, thenDragTo: lower, withVelocity: .slow, thenHoldForDuration: 0.3)
            }
        }
        return false
    }

    /// The top of the composer: the reply bar, the attach line or the field,
    /// whichever shows highest.
    private func composerTop(in app: XCUIApplication) -> CGFloat {
        let parts = [
            app.descendants(matching: .any)["toastty-mobile-composer-reply"],
            app.staticTexts["Update Toastty on your Mac to attach files."],
            app.descendants(matching: .any)["toastty-mobile-composer-input"],
        ]
        return parts.filter { $0.exists }.map { $0.frame.minY }.min() ?? app.frame.maxY
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

    private func launch(
        coordinator: String?,
        environment: [String: String] = [:],
        arguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_TASKS"] = "1"
        if let coordinator { app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_COORDINATOR"] = coordinator }
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launchArguments += ["-toastty-mobile-collapsed-project-cards", ""] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["toastty-mobile-home-segment-all"].waitForExistence(timeout: 10))
        return app
    }

    private func openCoordinatorChat(environment: [String: String] = [:]) -> XCUIApplication {
        let app = launch(coordinator: "quiet", environment: environment)
        app.tabBars.buttons["Coordinator"].tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-coordinator-title"].waitForExistence(timeout: 5))
        return app
    }

    /// Native menu actions expose their title, with any subtitle after it,
    /// and not the SwiftUI identifier.
    private func menuItem(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, "\(title),")).firstMatch
    }

    private func sheetTitle(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["toastty-preview-title"]
    }

    private func webText(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func closeSheet(in app: XCUIApplication) {
        app.buttons["toastty-preview-close"].tap()
        XCTAssertTrue(app.buttons["toastty-preview-close"].waitForNonExistence(timeout: 5))
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

    /// Waits 15 s: on a slow hosted runner one accessibility snapshot with the
    /// keyboard up took over 4 s, after the label had already changed.
    private func waitForLabel(_ label: String, of element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 15) == .completed
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

    /// Taps a digest's line. While its turn is open the row's element covers
    /// the digest's text too, and a tap in its middle lands on the text.
    private func tapTheLine(of row: XCUIElement) {
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 12)).tap()
    }

    /// The work strips of turns that do not fold whole.
    private func workStrips(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "toastty-mobile-transcript-turn-"))
    }

    private func attachScreenshot(named name: String, of app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// The fixture's quiet turns, as `ToasttyConversationFixture` writes them.
private enum ToasttyQuietTurnText {
    static let answers = ["Nothing new needs you.", "Nothing needs you."]
}

private extension XCUIElement {
    func waitForSelection(timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}

private extension XCUIElementQuery {
    func matching(identifierPrefix prefix: String) -> XCUIElementQuery {
        matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }
}
