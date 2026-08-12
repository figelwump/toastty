import XCTest

final class ToasttyMobileFixtureUITests: XCTestCase {
    private let toasttyWorkspaceID = "A1000000-0000-0000-0000-000000000001"
    private let pendingInteractionID = "B1000000-0000-0000-0000-000000000001"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFixtureNavigationShowsWorkspaceAndReadOnlyInteraction() {
        let app = launchFixtureApp()

        let home = app.descendants(matching: .any)["toastty-mobile-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["NEEDS YOU · 3"].exists)
        XCTAssertTrue(app.staticTexts["WORKSPACES"].exists)
        XCTAssertTrue(app.staticTexts["toastty"].exists)
        XCTAssertFalse(app.buttons["Reply"].exists)
        attachScreenshot(named: "fixture-home", of: app)

        let workspaceLink = app.buttons["toastty-mobile-workspace-\(toasttyWorkspaceID)"]
        XCTAssertTrue(workspaceLink.waitForExistence(timeout: 5))
        workspaceLink.tap()

        assertToasttyWorkspace(in: app)
        attachScreenshot(named: "fixture-workspace", of: app)

        let sessionButton = app.buttons["toastty-mobile-workspace-session-\(pendingInteractionID)"]
        XCTAssertTrue(sessionButton.waitForExistence(timeout: 5))
        sessionButton.tap()

        let conversationTitle = app.staticTexts["toastty-mobile-conversation-title"]
        let readOnlyInteraction = app.descendants(matching: .any)["toastty-mobile-readonly-interaction"]
        XCTAssertTrue(conversationTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(readOnlyInteraction.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Respond on the desktop"].exists)
        XCTAssertFalse(app.buttons["Approve"].exists)
        XCTAssertFalse(app.buttons["Deny"].exists)
        XCTAssertFalse(app.buttons["Reply"].exists)
        XCTAssertFalse(app.staticTexts["Reply shortcut preview — sending arrives in the gated-send milestone"].exists)
        attachScreenshot(named: "fixture-conversation-sheet", of: app)

        app.buttons["toastty-mobile-conversation-close"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-workspace-detail"].waitForExistence(timeout: 5))
    }

    func testFixtureWorkspaceReflowsAtAccessibilityTextSize() {
        let app = launchFixtureApp(
            launchArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
            ]
        )

        let workspaceLink = app.buttons["toastty-mobile-workspace-\(toasttyWorkspaceID)"]
        XCTAssertTrue(workspaceLink.waitForExistence(timeout: 10))
        workspaceLink.tap()

        assertToasttyWorkspace(in: app)
        attachScreenshot(named: "fixture-workspace-accessibility-xxxl", of: app)

        let firstSession = app.buttons["toastty-mobile-workspace-session-\(pendingInteractionID)"]
        XCTAssertTrue(firstSession.isHittable)
        firstSession.tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-conversation-title"].waitForExistence(timeout: 5))
    }

    func testFixtureTranscriptExposesEveryEventKindWithStableSequenceIdentifiers() {
        let app = launchFixtureConversation()
        let transcript = app.descendants(matching: .any)["toastty-mobile-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))

        let hugeMessage = app.buttons["toastty-mobile-transcript-expand-13"]
        XCTAssertTrue(hugeMessage.waitForExistence(timeout: 5))
        XCTAssertEqual(hugeMessage.label, "Show more")
        hugeMessage.tap()
        XCTAssertEqual(hugeMessage.label, "Show less")
        attachScreenshot(named: "fixture-transcript-huge-message-expanded", of: app)
        hugeMessage.tap()
        XCTAssertEqual(hugeMessage.label, "Show more")

        let expectedRows: [(UInt64, String)] = [
            (1, "session connected"),
            (2, "Extract the gateway protocol"),
            (3, "inspect the shared contract"),
            (6, "Transcript QA"),
            (7, "Choose the safe rollout strategy"),
            (8, "waiting for input"),
            (9, "interaction resolved"),
            (10, "session resumed"),
            (11, "Transcript ready"),
            (12, "sent remotely"),
            (13, "deliberately long transcript fixture"),
            (14, "Choose the safe rollout strategy"),
        ]
        for (sequence, labelFragment) in expectedRows.reversed() {
            let row = app.descendants(matching: .any)["toastty-mobile-transcript-row-\(sequence)"]
            XCTAssertTrue(
                scrollToOlder(row, in: app),
                "Expected stable transcript row identifier for sequence \(sequence)"
            )
            XCTAssertTrue(
                row.label.localizedCaseInsensitiveContains(labelFragment),
                "Sequence \(sequence) should expose its semantic content to accessibility; got \(row.label)"
            )
        }

        let toolDisclosure = app.buttons["toastty-mobile-transcript-tool-4"]
        XCTAssertTrue(scrollToNewer(toolDisclosure, in: app))
        XCTAssertTrue(toolDisclosure.label.contains("1 tool call"))
        toolDisclosure.tap()
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-transcript-row-4"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-transcript-row-5"].exists)

        let interaction = app.descendants(matching: .any)["toastty-mobile-readonly-interaction"]
        XCTAssertTrue(scrollToNewer(interaction, in: app))
        XCTAssertTrue(interaction.label.contains("Respond on the desktop"))
        XCTAssertFalse(app.buttons["Canary"].exists)
        XCTAssertFalse(app.buttons["All workspaces"].exists)
        attachScreenshot(named: "fixture-transcript-event-kinds", of: app)
    }

    func testSlowReaderKeepsPositionAndCanJumpBackToLiveTail() {
        let app = launchFixtureConversation()
        let oldestRow = app.descendants(matching: .any)["toastty-mobile-transcript-row-1"]
        XCTAssertTrue(scrollToOlder(oldestRow, in: app))

        let jumpToLatest = app.buttons["toastty-mobile-transcript-jump-latest"]
        XCTAssertTrue(jumpToLatest.waitForExistence(timeout: 5))
        XCTAssertTrue(oldestRow.exists, "Showing the jump affordance must not move a slow reader")
        jumpToLatest.tap()

        let newestRow = app.descendants(matching: .any)["toastty-mobile-transcript-row-14"]
        XCTAssertTrue(newestRow.waitForExistence(timeout: 5))
        XCTAssertTrue(newestRow.isHittable)
        attachScreenshot(named: "fixture-transcript-jumped-to-latest", of: app)
    }

    func testBackwardPagingPrependsStableRowsWithoutMovingTheReader() {
        let app = launchFixtureApp(
            environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "transcript-paging"]
        )
        openFixtureConversation(in: app)

        let loadEarlier = app.buttons["toastty-mobile-transcript-load-older"]
        XCTAssertTrue(scrollToOlder(loadEarlier, in: app))
        let anchorRow = app.descendants(matching: .any)["toastty-mobile-transcript-row-9"]
        XCTAssertTrue(anchorRow.exists)
        let anchorYBeforePrepend = anchorRow.frame.minY

        loadEarlier.tap()

        XCTAssertTrue(loadEarlier.waitForNonExistence(timeout: 5))
        XCTAssertTrue(anchorRow.waitForExistence(timeout: 5))
        XCTAssertTrue(anchorRow.isHittable)
        XCTAssertEqual(
            anchorRow.frame.minY,
            anchorYBeforePrepend,
            accuracy: 80,
            "Prepending history should restore the reader's visible anchor"
        )
        XCTAssertFalse(app.descendants(matching: .any)["toastty-mobile-transcript-loading-older"].exists)

        let oldestRow = app.descendants(matching: .any)["toastty-mobile-transcript-row-1"]
        XCTAssertTrue(scrollToOlder(oldestRow, in: app))
        XCTAssertTrue(oldestRow.label.localizedCaseInsensitiveContains("session connected"))
        attachScreenshot(named: "fixture-transcript-backward-paging", of: app)
    }

    func testFiveThousandRowFixtureReportsSimulatorReadiness() {
        let app = launchFixtureApp(
            environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "transcript-performance"]
        )
        openFixtureConversation(in: app)
        let clock = ContinuousClock()
        let startedAt = clock.now

        let readiness = app.descendants(matching: .any)["toastty-mobile-transcript-ready-5000"]
        XCTAssertTrue(readiness.waitForExistence(timeout: 10))
        let elapsed = startedAt.duration(to: clock.now)
        print("TOASTTY_TRANSCRIPT_SIMULATOR_READINESS rows=5000 elapsed=\(elapsed)")

        let attachment = XCTAttachment(
            string: "Fixture rows: 5000\nOpen-to-readiness elapsed: \(elapsed)\nTarget: remote iOS Simulator (not physical-device Instruments evidence)."
        )
        attachment.name = "fixture-transcript-5000-readiness"
        attachment.lifetime = .keepAlways
        add(attachment)
        attachScreenshot(named: "fixture-transcript-5000", of: app)
    }

    func testTranscriptRecoveryFixturesExposeResyncStaleAndTruncatedHistoryUX() {
        let scenarios = [
            (
                name: "transcript-resyncing",
                identifier: "toastty-mobile-transcript-resyncing",
                screenshot: "fixture-transcript-resyncing"
            ),
            (
                name: "transcript-stale",
                identifier: "toastty-mobile-transcript-stale",
                screenshot: "fixture-transcript-stale"
            ),
            (
                name: "transcript-truncated",
                identifier: "toastty-mobile-transcript-history-truncated",
                screenshot: "fixture-transcript-history-truncated"
            ),
        ]

        for scenario in scenarios {
            let app = launchFixtureApp(
                environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": scenario.name]
            )
            openFixtureConversation(in: app)

            let banner = app.descendants(matching: .any)[scenario.identifier]
            XCTAssertTrue(
                banner.waitForExistence(timeout: 5),
                "Fixture scenario \(scenario.name) must expose \(scenario.identifier)"
            )
            XCTAssertTrue(
                app.descendants(matching: .any)["toastty-mobile-transcript-row-13"].exists,
                "Recovery UX should keep the transcript readable"
            )
            attachScreenshot(named: scenario.screenshot, of: app)
            app.terminate()
        }
    }

    private func launchFixtureApp(
        launchArguments: [String] = [],
        environment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        app.launchArguments += launchArguments
        app.launch()
        return app
    }

    private func launchFixtureConversation() -> XCUIApplication {
        let app = launchFixtureApp()
        openFixtureConversation(in: app)
        return app
    }

    private func openFixtureConversation(in app: XCUIApplication) {
        let workspaceLink = app.buttons["toastty-mobile-workspace-\(toasttyWorkspaceID)"]
        XCTAssertTrue(workspaceLink.waitForExistence(timeout: 10))
        workspaceLink.tap()

        let sessionButton = app.buttons["toastty-mobile-workspace-session-\(pendingInteractionID)"]
        XCTAssertTrue(sessionButton.waitForExistence(timeout: 5))
        sessionButton.tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-conversation-title"].waitForExistence(timeout: 5))
    }

    private func scrollToOlder(
        _ element: XCUIElement,
        in app: XCUIApplication,
        attempts: Int = 12
    ) -> Bool {
        let transcript = app.descendants(matching: .any)["toastty-mobile-transcript"]
        for _ in 0..<attempts {
            if element.exists, element.isHittable { return true }
            transcript.swipeDown()
        }
        return element.exists && element.isHittable
    }

    private func scrollToNewer(
        _ element: XCUIElement,
        in app: XCUIApplication,
        attempts: Int = 12
    ) -> Bool {
        let transcript = app.descendants(matching: .any)["toastty-mobile-transcript"]
        for _ in 0..<attempts {
            if element.exists, element.isHittable { return true }
            transcript.swipeUp()
        }
        return element.exists && element.isHittable
    }

    private func assertToasttyWorkspace(in app: XCUIApplication) {
        let detail = app.descendants(matching: .any)["toastty-mobile-workspace-detail"]
        let context = app.descendants(matching: .any)["toastty-mobile-workspace-context"]

        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["toastty"].exists)
        XCTAssertTrue(context.exists)
        XCTAssertEqual(context.label, "4 sessions · ~/GiantThings/repos/toastty")
        XCTAssertTrue(app.buttons["toastty-mobile-workspace-session-\(pendingInteractionID)"].exists)
    }

    private func attachScreenshot(named name: String, of app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
