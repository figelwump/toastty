import UIKit
import XCTest

@MainActor
final class ToasttyMobileFixtureUITests: XCTestCase {
    private let toasttyWorkspaceID = "A1000000-0000-0000-0000-000000000001"
    private let pendingInteractionID = "B1000000-0000-0000-0000-000000000001"
    private let firstToasttyConversationID = "B1000000-0000-0000-0000-000000000003"
    private let fourthToasttyConversationID = "B1000000-0000-0000-0000-000000000004"
    private let releaseWorkspaceID = "A1000000-0000-0000-0000-000000000003"
    private let openPromptConversationID = "B1000000-0000-0000-0000-000000000007"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFixtureNavigationShowsWorkspaceAndReadOnlyInteraction() {
        let app = launchFixtureApp()

        let home = app.descendants(matching: .any)["toastty-mobile-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        let readySection = app.staticTexts["toastty-mobile-ready-section"]
        XCTAssertTrue(readySection.exists)
        XCTAssertEqual(readySection.label, "READY · 3")
        let readyCard = app.buttons[
            "toastty-mobile-ready-card-\(openPromptConversationID)"
        ]
        XCTAssertTrue(scrollHomeTo(readyCard, in: app))
        XCTAssertTrue(readyCard.label.contains("Ready for your reply"))
        XCTAssertFalse(app.buttons["toastty-mobile-open-\(openPromptConversationID)"].exists)
        XCTAssertFalse(app.buttons["toastty-mobile-reply-\(openPromptConversationID)"].exists)
        attachScreenshot(named: "fixture-home", of: app)

        let approvalCard = app.buttons[
            "toastty-mobile-needs-approval-card-\(pendingInteractionID)"
        ]
        let approvalSection = app.staticTexts["toastty-mobile-needs-approval-section"]
        XCTAssertTrue(scrollHomeTo(approvalSection, in: app))
        XCTAssertEqual(approvalSection.label, "NEEDS APPROVAL · 1")
        XCTAssertTrue(scrollHomeTo(approvalCard, in: app))
        approvalCard.tap()

        let conversationTitle = app.staticTexts["toastty-mobile-conversation-title"]
        XCTAssertTrue(conversationTitle.waitForExistence(timeout: 5))
        XCTAssertLessThan(
            conversationTitle.frame.minY,
            app.frame.height * 0.2,
            "The default large conversation sheet should place its header near the top of the screen"
        )
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 1))

        let readOnlyInteraction = app.descendants(matching: .any)["toastty-mobile-readonly-interaction"]
        XCTAssertTrue(readOnlyInteraction.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Respond on the desktop"].exists)
        XCTAssertEqual(
            app.descendants(matching: .any)["toastty-mobile-composer-status"].label,
            "Composer locked. Respond to the pending interaction on the Mac"
        )
        XCTAssertFalse(app.buttons["Approve"].exists)
        XCTAssertFalse(app.buttons["Deny"].exists)
        XCTAssertFalse(app.staticTexts["Reply shortcut preview — sending arrives in the gated-send milestone"].exists)
        attachScreenshot(named: "fixture-conversation-sheet", of: app)

        let close = app.buttons["toastty-mobile-conversation-close"]
        XCTAssertGreaterThanOrEqual(close.frame.width, 44)
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
    }

    func testFixtureWorkspaceReflowsAtAccessibilityTextSize() {
        let app = launchFixtureApp(
            launchArguments: [
                "-UIPreferredContentSizeCategoryName",
                UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue,
            ]
        )

        openWorkspace(toasttyWorkspaceID, in: app)

        assertToasttyWorkspace(in: app)
        attachScreenshot(named: "fixture-workspace-accessibility-xxxl", of: app)

        let firstSession = app.buttons[
            "toastty-mobile-workspace-session-\(firstToasttyConversationID)"
        ]
        XCTAssertTrue(firstSession.isHittable)
        firstSession.tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-conversation-title"].waitForExistence(timeout: 5))
    }

    func testFixtureReadyCardFocusesComposerWithoutTypingOrSending() {
        let app = launchFixtureApp(
            environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "gated-send"]
        )
        let home = app.descendants(matching: .any)["toastty-mobile-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))

        let readyCard = app.buttons[
            "toastty-mobile-ready-card-\(openPromptConversationID)"
        ]
        XCTAssertTrue(scrollHomeTo(readyCard, in: app))
        XCTAssertTrue(readyCard.label.contains("Ready for your reply"))
        readyCard.tap()

        let input = app.textFields["toastty-mobile-composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "Message Codex…")
        XCTAssertFalse(app.buttons["toastty-mobile-composer-send"].isEnabled)
    }

    func testFixtureCurrentBuildDeepLinksRouteWorkspaceAndConversation() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_SCENARIO"] = "gated-send"

        let workspaceURL = try XCTUnwrap(URL(
            string: "toastty-mobile-dev://workspace/\(releaseWorkspaceID)"
        ))
        app.open(workspaceURL)

        XCTAssertTrue(
            app.descendants(matching: .any)["toastty-mobile-workspace-detail"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.navigationBars["release 0.9.0"].exists)

        let conversationURL = try XCTUnwrap(URL(
            string: "toastty-mobile-dev://conversation/\(openPromptConversationID)"
        ))
        app.open(conversationURL)

        XCTAssertTrue(
            app.staticTexts["toastty-mobile-conversation-title"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.textFields["toastty-mobile-composer-input"].exists)
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 1))
        XCTAssertFalse(app.buttons["toastty-mobile-composer-send"].isEnabled)
        attachScreenshot(named: "fixture-current-build-deep-link", of: app)
    }

    func testFixtureWorkspaceCardExpandsAndCollapsesInline() {
        let app = launchFixtureApp()
        let home = app.descendants(matching: .any)["toastty-mobile-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))

        let fourthSession = app.buttons[
            "toastty-mobile-session-\(fourthToasttyConversationID)"
        ]
        XCTAssertFalse(fourthSession.exists)

        let toggle = app.buttons[
            "toastty-mobile-workspace-more-toggle-\(toasttyWorkspaceID)"
        ]
        XCTAssertTrue(scrollHomeTo(toggle, in: app))
        XCTAssertEqual(toggle.value as? String, "Collapsed")
        toggle.tap()

        XCTAssertTrue(fourthSession.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "Expanded")
        XCTAssertTrue(scrollHomeTo(toggle, in: app))
        toggle.tap()

        XCTAssertTrue(fourthSession.waitForNonExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "Collapsed")
    }

    func testFixtureHomeAtEveryAccessibilityContentSize() {
        for category in accessibilityContentSizeCategories {
            let app = launchFixtureApp(
                launchArguments: ["-UIPreferredContentSizeCategoryName", category.rawValue]
            )

            let home = app.descendants(matching: .any)["toastty-mobile-home"]
            XCTAssertTrue(
                home.waitForExistence(timeout: 10),
                "Home must load at \(category.rawValue)"
            )
            XCTAssertTrue(app.buttons["toastty-mobile-settings-button"].isHittable)
            XCTAssertEqual(
                app.descendants(matching: .any)["toastty-mobile-connection"].label,
                "Connection live to mac-studio"
            )
            let approvalCard = app.buttons[
                "toastty-mobile-needs-approval-card-\(pendingInteractionID)"
            ]
            XCTAssertTrue(scrollHomeTo(approvalCard, in: app))
            XCTAssertEqual(
                approvalCard.label,
                "Mobile gateway design, needs approval, toastty, 2m, Review the gateway command on the Mac"
            )
            app.terminate()
        }
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
                scrollToOlder(row, in: app, requireHittable: false),
                "Expected stable transcript row identifier for sequence \(sequence)"
            )
            XCTAssertTrue(
                row.label.localizedCaseInsensitiveContains(labelFragment),
                "Sequence \(sequence) should expose its semantic content to accessibility; got \(row.label)"
            )
        }

        let toolDisclosure = app.buttons["toastty-mobile-transcript-tool-4"]
        XCTAssertTrue(toolDisclosure.exists)
        XCTAssertTrue(toolDisclosure.label.contains("1 tool call"))
        // XCTest scrolls a known SwiftUI button into view more reliably as part
        // of tap synthesis than repeated directional swipes after a large row
        // has changed height.
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

    func testGatedSendClearsDraftOnlyAfterEnqueueAndShowsOptimisticBubble() {
        let app = launchFixtureApp(
            environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "gated-send"]
        )
        openGatedSendConversation(in: app)

        let input = app.textFields["toastty-mobile-composer-input"]
        let send = app.buttons["toastty-mobile-composer-send"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(input.isEnabled)
        XCTAssertFalse(send.isEnabled)

        input.tap()
        input.typeText("Use build 413")
        XCTAssertTrue(send.isEnabled)
        send.tap()

        let optimistic = app.descendants(matching: .any)[
            "toastty-mobile-send-optimistic-fixture-enqueued-1"
        ]
        XCTAssertTrue(optimistic.waitForExistence(timeout: 5))
        XCTAssertTrue(optimistic.label.contains("Use build 413"))
        XCTAssertTrue(optimistic.label.contains("Sending"))
        XCTAssertEqual(input.value as? String, "Draft saved on this iPhone")
        XCTAssertFalse(input.isEnabled)
        XCTAssertFalse(send.isEnabled)
        let status = app.descendants(matching: .any)["toastty-mobile-composer-status"]
        XCTAssertTrue(status.exists)
        XCTAssertEqual(
            status.label,
            "Composer locked. A message is already being sent at this prompt"
        )
        attachScreenshot(named: "fixture-gated-send-optimistic", of: app)
    }

    func testGatedSendUnconfirmedReceiptShowsAttemptedTextAndDismisses() {
        let app = launchFixtureApp(
            environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "gated-send-receipt"]
        )
        openGatedSendConversation(in: app)

        let receipt = app.descendants(matching: .any)[
            "toastty-mobile-send-receipt-fixture-delivery-unconfirmed"
        ]
        let dismiss = app.buttons[
            "toastty-mobile-send-receipt-dismiss-fixture-delivery-unconfirmed"
        ]
        XCTAssertTrue(receipt.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["Toastty could not correlate this send after reconnecting"].exists
        )
        XCTAssertTrue(
            app.staticTexts["Use build 413 and keep the release as a draft."].exists
        )
        if dismiss.isHittable == false {
            let jumpToLatest = app.buttons["toastty-mobile-transcript-jump-latest"]
            XCTAssertTrue(jumpToLatest.waitForExistence(timeout: 5))
            jumpToLatest.tap()
        }
        XCTAssertTrue(dismiss.isHittable)
        attachScreenshot(named: "fixture-gated-send-unconfirmed-receipt", of: app)

        dismiss.tap()
        XCTAssertTrue(receipt.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.textFields["toastty-mobile-composer-input"].isEnabled)
    }

    func testGatedSendComposerReflowsAtAccessibilityXXXL() {
        let app = launchFixtureApp(
            launchArguments: [
                "-UIPreferredContentSizeCategoryName",
                UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue,
            ],
            environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "gated-send"]
        )
        openGatedSendConversation(in: app)

        let input = app.textFields["toastty-mobile-composer-input"]
        let send = app.buttons["toastty-mobile-composer-send"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(
            keyboard.waitForExistence(timeout: 5),
            "Opening a reply-capable row should focus the composer without another tap"
        )
        XCTAssertTrue(input.isHittable)
        input.typeText("Accessible send")
        let title = app.staticTexts["toastty-mobile-conversation-title"]
        let close = app.buttons["toastty-mobile-conversation-close"]
        attachScreenshot(named: "fixture-gated-send-accessibility-xxxl", of: app)
        XCTAssertEqual(title.label, "Changelog + tag")
        XCTAssertTrue(title.isHittable)
        XCTAssertTrue(close.isHittable)
        let keyboardObstructionTop = topOfKeyboardObstruction(keyboard)
        XCTAssertLessThanOrEqual(
            input.frame.maxY,
            keyboardObstructionTop + 1,
            "The focused message field must remain fully visible above the keyboard and prediction bar"
        )
        XCTAssertTrue(send.isHittable)
        XCTAssertTrue(send.isEnabled)
        XCTAssertGreaterThan(
            send.frame.minX,
            input.frame.minX,
            "The compact Send control should follow the message field visually"
        )
        XCTAssertLessThanOrEqual(
            send.frame.maxY,
            keyboardObstructionTop + 1,
            "Send must remain fully visible above the keyboard and prediction bar"
        )
    }

    private func topOfKeyboardObstruction(_ keyboard: XCUIElement) -> CGFloat {
        var top = keyboard.frame.minY
        for element in keyboard.descendants(matching: .any).allElementsBoundByIndex {
            let frame = element.frame
            if frame.isEmpty == false, frame.minY > 0 {
                top = min(top, frame.minY)
            }
        }
        return top
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

    private var accessibilityContentSizeCategories: [UIContentSizeCategory] {
        [
            .accessibilityMedium,
            .accessibilityLarge,
            .accessibilityExtraLarge,
            .accessibilityExtraExtraLarge,
            .accessibilityExtraExtraExtraLarge,
        ]
    }

    private func openFixtureConversation(in app: XCUIApplication) {
        openWorkspace(toasttyWorkspaceID, in: app)

        let sessionButton = app.buttons["toastty-mobile-workspace-session-\(pendingInteractionID)"]
        XCTAssertTrue(sessionButton.waitForExistence(timeout: 5))
        sessionButton.tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-conversation-title"].waitForExistence(timeout: 5))
    }

    private func openGatedSendConversation(in app: XCUIApplication) {
        let readyCard = app.buttons[
            "toastty-mobile-ready-card-\(openPromptConversationID)"
        ]
        XCTAssertTrue(scrollHomeTo(readyCard, in: app))
        readyCard.tap()
        XCTAssertTrue(
            app.staticTexts["toastty-mobile-conversation-title"].waitForExistence(timeout: 5)
        )
    }

    private func openWorkspace(
        _ workspaceID: String,
        in app: XCUIApplication,
        attempts: Int = 12
    ) {
        let home = app.descendants(matching: .any)["toastty-mobile-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))

        let workspace = app.buttons["toastty-mobile-workspace-\(workspaceID)"]
        for _ in 0..<attempts {
            if workspace.exists, workspace.isHittable {
                workspace.tap()
                return
            }
            home.swipeUp()
        }

        XCTFail("Workspace \(workspaceID) was not reachable from Home after \(attempts) swipes")
    }

    private func scrollHomeTo(
        _ element: XCUIElement,
        in app: XCUIApplication,
        attempts: Int = 12
    ) -> Bool {
        let home = app.descendants(matching: .any)["toastty-mobile-home"]
        for _ in 0..<attempts {
            if element.exists, element.isHittable { return true }
            home.swipeUp()
        }
        return element.exists && element.isHittable
    }

    private func scrollToOlder(
        _ element: XCUIElement,
        in app: XCUIApplication,
        attempts: Int = 12,
        requireHittable: Bool = true
    ) -> Bool {
        let transcript = app.descendants(matching: .any)["toastty-mobile-transcript"]
        for _ in 0..<attempts {
            if element.exists, requireHittable == false || element.isHittable { return true }
            transcript.swipeDown()
        }
        return element.exists && (requireHittable == false || element.isHittable)
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
    }

    private func attachScreenshot(named name: String, of app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
