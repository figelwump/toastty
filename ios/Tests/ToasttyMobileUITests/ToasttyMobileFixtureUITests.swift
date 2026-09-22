import UIKit
import Vision
import XCTest

@MainActor
final class ToasttyMobileFixtureUITests: XCTestCase {
    private let toasttyWorkspaceID = "A1000000-0000-0000-0000-000000000001"
    private let pendingInteractionID = "B1000000-0000-0000-0000-000000000001"
    private let workingConversationID = "B1000000-0000-0000-0000-000000000002"
    private let firstToasttyConversationID = "B1000000-0000-0000-0000-000000000003"
    private let fourthToasttyConversationID = "B1000000-0000-0000-0000-000000000004"
    private let researchWorkspaceID = "A1000000-0000-0000-0000-000000000002"
    private let activeResearchConversationID = "B1000000-0000-0000-0000-000000000005"
    private let idleResearchConversationID = "B1000000-0000-0000-0000-000000000006"
    private let releaseWorkspaceID = "A1000000-0000-0000-0000-000000000003"
    private let openPromptConversationID = "B1000000-0000-0000-0000-000000000007"

    private struct TranscriptScrollTraceSample: Decodable {
        let elapsed: Double
        let contentHeight: CGFloat
        let visibleMaxY: CGFloat
        let visibleHeight: CGFloat
        let topInset: CGFloat
        let bottomInset: CGFloat
        let containerHeight: CGFloat
        let hasSendItems: Bool
        var distanceFromBottom: CGFloat { contentHeight - visibleMaxY }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFixtureNavigationShowsWorkspaceAndReadOnlyInteraction() {
        let app = launchFixtureApp()

        let home = app.descendants(matching: .any)["toastty-mobile-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        XCTAssertFalse(app.segmentedControls["toastty-mobile-home-mode"].exists)
        let filter = app.segmentedControls["toastty-mobile-workspace-session-filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        let all = filter.buttons["All"]
        let active = filter.buttons["Active"]
        XCTAssertTrue(all.exists)
        XCTAssertTrue(active.exists)
        XCTAssertLessThan(all.frame.minX, active.frame.minX)
        XCTAssertTrue(filter.buttons["All"].isSelected)
        XCTAssertFalse(app.staticTexts["toastty-mobile-ready-section"].exists)
        XCTAssertFalse(app.staticTexts["toastty-mobile-needs-approval-section"].exists)
        let readyCard = app.buttons[
            "toastty-mobile-grouped-card-\(openPromptConversationID)"
        ]
        XCTAssertTrue(scrollHomeTo(readyCard, in: app))
        XCTAssertTrue(readyCard.label.contains("Which build number should I use?"))
        XCTAssertTrue(readyCard.label.contains("release 0.9.0"))
        XCTAssertFalse(app.buttons["toastty-mobile-open-\(openPromptConversationID)"].exists)
        XCTAssertFalse(app.buttons["toastty-mobile-reply-\(openPromptConversationID)"].exists)
        attachScreenshot(named: "fixture-home", of: app)

        let approvalCard = app.buttons[
            "toastty-mobile-grouped-card-\(pendingInteractionID)"
        ]
        XCTAssertTrue(scrollHomeTo(approvalCard, in: app))
        XCTAssertTrue(approvalCard.label.contains("Allow Toastty to run the focused iOS tests?"))
        approvalCard.tap()

        let conversationTitle = app.staticTexts["toastty-mobile-conversation-title"]
        XCTAssertTrue(conversationTitle.waitForExistence(timeout: 5))
        XCTAssertLessThan(
            conversationTitle.frame.minY,
            app.frame.height * 0.2,
            "The pushed conversation screen should place its header near the top of the screen"
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
        attachScreenshot(named: "fixture-conversation-screen", of: app)

        // Popping via the navigation back button must clear the selection so
        // tapping the same card reopens the conversation.
        let back = app.navigationBars.firstMatch.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        XCTAssertTrue(conversationTitle.waitForNonExistence(timeout: 5))
        XCTAssertTrue(scrollHomeTo(approvalCard, in: app))
        approvalCard.tap()
        XCTAssertTrue(conversationTitle.waitForExistence(timeout: 5))
    }

    func testConnectingScenarioShowsUnifiedLoadingScreen() {
        let app = launchFixtureApp(
            environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "connecting"]
        )

        let loading = app.descendants(matching: .any)["toastty-mobile-session-connecting"]
        XCTAssertTrue(loading.waitForExistence(timeout: 10))
        XCTAssertEqual(loading.label, "Connecting to mac-studio…")
        XCTAssertEqual(loading.value as? String, "In progress")
        XCTAssertFalse(app.descendants(matching: .any)["toastty-mobile-home"].exists)
        attachScreenshot(named: "fixture-connecting-loading", of: app)
    }

    func testReconnectingNoticeShowsGuidanceAndRetry() {
        let app = launchFixtureApp(
            environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "reconnecting"]
        )

        let notice = app.descendants(matching: .any)["toastty-mobile-connection-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertEqual(
            notice.label,
            "Reconnecting. Toastty is still trying to connect to your Mac. Make sure the Mac is awake, Toastty is running with Remote Access enabled, and Tailscale is connected on both devices. If those are already true, restart Toastty. After making changes, tap Retry or wait for Toastty to try automatically."
        )
        XCTAssertEqual(notice.value as? String, "In progress")

        let workingCard = app.buttons[
            "toastty-mobile-grouped-card-\(workingConversationID)"
        ]
        XCTAssertTrue(scrollHomeTo(workingCard, in: app))
        XCTAssertTrue(workingCard.label.contains("Last seen working. Updates paused."))
        workingCard.tap()

        let conversationStatus = app.descendants(matching: .any)[
            "toastty-mobile-conversation-status"
        ]
        XCTAssertTrue(conversationStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(
            conversationStatus.label,
            "Last seen working. Updates paused."
        )
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        XCTAssertTrue(notice.waitForExistence(timeout: 5))

        let retry = app.buttons["toastty-mobile-connection-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertEqual(retry.label, "Retry connection")
        XCTAssertTrue(retry.isHittable)
        retry.tap()
        XCTAssertTrue(notice.exists)
        attachScreenshot(named: "fixture-reconnecting-progress", of: app)
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
        XCTAssertTrue(scrollWorkspaceTo(firstSession, in: app))
        firstSession.tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-conversation-title"].waitForExistence(timeout: 5))
    }

    func testWorkingConversationExposesIndeterminateComposerStatus() {
        let app = launchFixtureApp()
        openWorkspace(toasttyWorkspaceID, in: app)
        attachScreenshot(named: "fixture-workspace-shared-cards", of: app)

        let session = app.buttons[
            "toastty-mobile-workspace-session-\(workingConversationID)"
        ]
        XCTAssertTrue(scrollWorkspaceTo(session, in: app))
        session.tap()

        let status = app.descendants(matching: .any)["toastty-mobile-composer-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "Agent working. Composer locked.")
        XCTAssertEqual(status.value as? String, "In progress")
        XCTAssertEqual(composerInput(in: app).value as? String, "Agent working…")
        attachScreenshot(named: "fixture-conversation-working", of: app)

        // A conversation pushed from a workspace pops back to that workspace,
        // not home.
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["toastty"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["toastty-mobile-workspace-detail"].exists
        )
    }

    func testFixtureReadyCardDoesNotFocusComposerUntilTapped() {
        let app = launchFixtureApp(
            environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "gated-send"]
        )
        let home = app.descendants(matching: .any)["toastty-mobile-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))

        let readyCard = app.buttons[
            "toastty-mobile-grouped-card-\(openPromptConversationID)"
        ]
        XCTAssertTrue(scrollHomeTo(readyCard, in: app))
        XCTAssertTrue(readyCard.label.contains("Which build number should I use?"))
        readyCard.tap()

        let input = composerInput(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let keyboard = app.keyboards.firstMatch
        XCTAssertFalse(
            keyboard.waitForExistence(timeout: 2),
            "Opening a reply-capable conversation should not present the keyboard"
        )
        XCTAssertEqual(input.value as? String, "Message Codex…")
        XCTAssertFalse(app.buttons["toastty-mobile-composer-send"].isEnabled)
        attachScreenshot(named: "fixture-ready-composer-unfocused", of: app)

        input.tap()
        XCTAssertTrue(
            keyboard.waitForExistence(timeout: 5),
            "Tapping the composer should present the keyboard"
        )
        attachScreenshot(named: "fixture-ready-composer-focused", of: app)
    }

    func testQuestionFixtureSubmitsSingleMultiAndCustomAnswersThenShowsAcceptedResult() {
        let app = launchFixtureApp(
            environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "interaction-answer"]
        )
        openGatedSendConversation(in: app)
        let transcript = app.scrollViews["toastty-mobile-transcript"]
        let prefix = "toastty-mobile-interaction-fixture-question-interaction-question-"
        for _ in 0..<4 { transcript.swipeDown() }
        attachScreenshot(named: "fixture-question-answer-form", of: app)

        func tap(_ identifier: String) {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.waitForExistence(timeout: 5), identifier)
            // XCUITest can report a partially clipped row as hittable even
            // when its synthesized tap lands below the composer inset.
            for _ in 0..<8 {
                let status = app.descendants(matching: .any)["toastty-mobile-composer-status"].firstMatch
                let bottom = min(transcript.frame.maxY, status.exists ? status.frame.minY : transcript.frame.maxY) - 16
                let top = transcript.frame.minY + 8
                if button.isHittable, button.frame.minY >= top, button.frame.maxY <= bottom { break }
                if button.frame.minY < top { transcript.swipeDown() } else { transcript.swipeUp() }
            }
            XCTAssertTrue(button.isHittable, identifier)
            button.tap()
        }

        tap("\(prefix)0-option-0")
        tap("\(prefix)1-option-0")
        tap("\(prefix)1-option-1")
        tap("\(prefix)2-custom")

        let custom = app.textFields["\(prefix)2-custom-text"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["\(prefix)2-custom"].value as? String, "Selected")
        custom.tap()
        custom.typeText("Mention the semantic answer flow")

        tap("toastty-mobile-interaction-submit-fixture-question-interaction")
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "toastty-mobile-interaction-accepted-fixture-question-interaction"
            ].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["Claude accepted"].exists)
        XCTAssertTrue(app.staticTexts["Approach"].exists)
        XCTAssertTrue(app.staticTexts["Checks"].exists)
        XCTAssertTrue(app.staticTexts["Release note"].exists)
        XCTAssertTrue(app.staticTexts["Small change"].exists)
        XCTAssertTrue(app.staticTexts["Domain tests, UI test"].exists)
        XCTAssertTrue(app.staticTexts["Mention the semantic answer flow"].exists)
        attachScreenshot(named: "fixture-question-answer-accepted", of: app)
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
        XCTAssertTrue(composerInput(in: app).exists)
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 1))
        XCTAssertFalse(app.buttons["toastty-mobile-composer-send"].isEnabled)
        attachScreenshot(named: "fixture-current-build-deep-link", of: app)
    }

    func testFixtureHomeShowsEverySessionWithoutInlineExpander() {
        let app = launchFixtureApp()
        let home = app.descendants(matching: .any)["toastty-mobile-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))

        XCTAssertTrue(
            app.buttons["toastty-mobile-workspace-\(toasttyWorkspaceID)"]
                .waitForExistence(timeout: 5)
        )

        let fourthSession = app.buttons[
            "toastty-mobile-grouped-card-\(fourthToasttyConversationID)"
        ]
        XCTAssertTrue(scrollHomeTo(fourthSession, in: app))
        XCTAssertTrue(fourthSession.label.contains("Release note generation failed"))
        XCTAssertFalse(
            app.buttons["toastty-mobile-workspace-more-toggle-\(toasttyWorkspaceID)"].exists
        )
    }

    func testWorkspaceAnnotationsFoldIntoHomeHeaderAndOpenLinksInBrowserSheet() {
        let app = launchFixtureApp()
        let header = app.buttons["toastty-mobile-workspace-\(toasttyWorkspaceID)"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        XCTAssertEqual(
            header.label,
            "toastty, build: build 0.8.3-35, git-branch: feat/ios-workspace-annotations-and-chip-colors, "
                + "github-pr: PR #12, review: review: 2 open, task-status: Working, 4 sessions"
        )
        attachScreenshot(named: "fixture-home-annotations", of: app)

        // The chip block sits above the open panels.
        header.tap()
        let block = app.descendants(matching: .any)["toastty-workspace-annotations"]
        XCTAssertTrue(block.waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.descendants(matching: .any)["toastty-workspace-annotation-review"].label,
            "review: review: 2 open"
        )
        XCTAssertEqual(app.buttons["toastty-workspace-annotation-github-pr"].label, "github-pr: PR #12, link")
        attachScreenshot(named: "fixture-workspace-annotations-with-panels", of: app)
        app.navigationBars.firstMatch.buttons.firstMatch.tap()

        // A workspace without annotations keeps its original header.
        let research = app.buttons["toastty-mobile-workspace-\(researchWorkspaceID)"]
        XCTAssertTrue(scrollHomeTo(research, in: app))
        XCTAssertEqual(research.label, "herdr research, 2 sessions")
        attachScreenshot(named: "fixture-home-unannotated-workspace", of: app)

        openWorkspace(releaseWorkspaceID, in: app)
        XCTAssertTrue(block.waitForExistence(timeout: 5))
        attachScreenshot(named: "fixture-workspace-annotations", of: app)

        // An address only the Mac can reach shows the browser fallback.
        app.buttons["toastty-workspace-annotation-preview"].tap()
        XCTAssertTrue(app.staticTexts["Browser unavailable"].waitForExistence(timeout: 5))
        attachScreenshot(named: "fixture-annotation-link-fallback", of: app)
        app.buttons["toastty-preview-close"].tap()
        XCTAssertTrue(block.waitForExistence(timeout: 5))
    }

    func testWorkspaceFilterDefaultsToAllAndIsSharedWithWorkspaceDetail() throws {
        let app = launchFixtureApp()

        var filter = app.segmentedControls["toastty-mobile-workspace-session-filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        XCTAssertTrue(filter.buttons["All"].isSelected)

        let groupedIdle = app.buttons[
            "toastty-mobile-grouped-card-\(idleResearchConversationID)"
        ]
        XCTAssertTrue(scrollHomeTo(groupedIdle, in: app))

        filter = app.segmentedControls["toastty-mobile-workspace-session-filter"]
        filter.buttons["Active"].tap()
        XCTAssertTrue(groupedIdle.waitForNonExistence(timeout: 5))

        let workspaceURL = try XCTUnwrap(URL(
            string: "toastty-mobile-dev://workspace/\(researchWorkspaceID)"
        ))
        app.open(workspaceURL)
        XCTAssertTrue(
            app.descendants(matching: .any)["toastty-mobile-workspace-detail"]
                .waitForExistence(timeout: 10)
        )

        filter = app.segmentedControls["toastty-mobile-workspace-session-filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        XCTAssertTrue(filter.buttons["Active"].isSelected)
        XCTAssertTrue(app.buttons[
            "toastty-mobile-workspace-session-\(activeResearchConversationID)"
        ].exists)
        XCTAssertFalse(app.buttons[
            "toastty-mobile-workspace-session-\(idleResearchConversationID)"
        ].exists)

        filter.buttons["All"].tap()
        let detailIdle = app.buttons[
            "toastty-mobile-workspace-session-\(idleResearchConversationID)"
        ]
        XCTAssertTrue(scrollWorkspaceTo(detailIdle, in: app))
    }

    func testFixtureWorkspaceFilterPersistsAcrossRelaunch() {
        var app = launchFixtureApp()

        var filter = app.segmentedControls["toastty-mobile-workspace-session-filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        XCTAssertTrue(filter.buttons["All"].isSelected)
        filter.buttons["Active"].tap()
        XCTAssertTrue(filter.buttons["Active"].isSelected)
        app.terminate()

        app = launchFixtureApp()
        filter = app.segmentedControls["toastty-mobile-workspace-session-filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        XCTAssertTrue(filter.buttons["Active"].isSelected)
        XCTAssertFalse(
            app.buttons["toastty-mobile-grouped-card-\(idleResearchConversationID)"].exists
        )
        XCTAssertTrue(app.buttons["toastty-mobile-workspace-\(toasttyWorkspaceID)"].exists)

        filter.buttons["All"].tap()
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
                "toastty-mobile-grouped-card-\(pendingInteractionID)"
            ]
            XCTAssertTrue(scrollHomeTo(approvalCard, in: app))
            XCTAssertTrue(approvalCard.label.contains("needs approval"))
            XCTAssertTrue(approvalCard.label.contains("Allow Toastty to run the focused iOS tests?"))
            XCTAssertTrue(approvalCard.label.contains("~/GiantThings/repos/toastty"))
            app.terminate()
        }
    }

    func testFixtureTranscriptPreservesContentWithoutHistoricalStatusRows() {
        let app = launchFixtureConversation()
        let transcript = app.descendants(matching: .any)["toastty-mobile-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))

        XCTAssertFalse(app.buttons["toastty-mobile-transcript-expand-13"].exists)

        // The settled turn's work opens folded behind its strip; expand it so
        // every event row is reachable, then return to the live tail.
        let workStrip = app.buttons["toastty-mobile-transcript-turn-2"]
        XCTAssertTrue(scrollToOlder(workStrip, in: app))
        XCTAssertTrue(workStrip.label.contains("worked"))
        XCTAssertTrue(workStrip.label.contains("1 tool call"))
        XCTAssertFalse(
            app.descendants(matching: .any)["toastty-mobile-transcript-row-3"].exists,
            "Folded work rows stay out of the transcript until expanded"
        )
        workStrip.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["toastty-mobile-transcript-row-3"]
                .waitForExistence(timeout: 5),
            "Expanding the strip must reveal the turn's work rows"
        )
        let jumpToLatest = app.buttons["toastty-mobile-transcript-jump-latest"]
        XCTAssertTrue(jumpToLatest.waitForExistence(timeout: 5))
        jumpToLatest.tap()
        XCTAssertTrue(jumpToLatest.waitForNonExistence(timeout: 5))

        let expectedRows: [(UInt64, String)] = [
            (1, "session connected"),
            (2, "Extract the gateway protocol"),
            (3, "inspect the shared contract"),
            (6, "Transcript QA"),
            (7, "Choose the safe rollout strategy"),
            (9, "interaction resolved"),
            (10, "session resumed"),
            (11, "Transcript ready"),
            (12, "sent remotely"),
            (13, "Full transcript tail remains visible"),
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
        XCTAssertFalse(app.descendants(matching: .any)["toastty-mobile-transcript-row-8"].exists)
        let oldestRow = app.descendants(matching: .any)["toastty-mobile-transcript-row-1"]
        XCTAssertTrue(
            scrollToOlder(oldestRow, in: app),
            "Scrolling forward should start from a visible oldest-row anchor"
        )
        let toolDisclosure = app.buttons["toastty-mobile-transcript-tool-4"]
        XCTAssertTrue(scrollToNewer(toolDisclosure, in: app))
        XCTAssertTrue(toolDisclosure.label.contains("1 tool call"))

        let interaction = app.descendants(matching: .any)["toastty-mobile-readonly-interaction"]
        XCTAssertTrue(scrollToNewer(interaction, in: app))
        XCTAssertTrue(interaction.label.contains("Respond on the desktop"))
        XCTAssertFalse(app.buttons["Canary"].exists)
        XCTAssertFalse(app.buttons["All workspaces"].exists)
        attachScreenshot(named: "fixture-transcript-event-kinds", of: app)
    }

    func testFixtureToolCardExpandsDetailsInlineWithoutPresentingSheet() {
        let app = launchFixtureApp(
            environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "tool-activity"]
        )
        openFixtureConversation(in: app)
        let toolDisclosure = app.buttons["toastty-mobile-transcript-tool-4"]
        XCTAssertTrue(toolDisclosure.waitForExistence(timeout: 5))
        XCTAssertTrue(toolDisclosure.isHittable)
        XCTAssertTrue(toolDisclosure.label.contains("1 tool call"))

        toolDisclosure.tap()

        let toolStarted = app.descendants(matching: .any)["toastty-mobile-transcript-row-4"]
        let toolFinished = app.descendants(matching: .any)["toastty-mobile-transcript-row-5"]
        XCTAssertTrue(toolStarted.waitForExistence(timeout: 5))
        XCTAssertTrue(toolStarted.label.contains("Read · running"))
        XCTAssertTrue(toolFinished.waitForExistence(timeout: 5))
        XCTAssertTrue(toolFinished.label.contains("Read · succeeded"))
        XCTAssertFalse(
            app.descendants(matching: .any)["toastty-mobile-tool-activity-sheet"].exists
        )
        attachScreenshot(named: "fixture-tool-activity-inline", of: app)

        toolDisclosure.tap()
        XCTAssertTrue(toolStarted.waitForNonExistence(timeout: 5))
        XCTAssertTrue(toolFinished.waitForNonExistence(timeout: 5))
    }

    func testSlowReaderKeepsPositionAndCanJumpBackToLiveTail() {
        let app = launchFixtureConversation()
        let jumpToLatest = app.buttons["toastty-mobile-transcript-jump-latest"]
        let newestRow = app.descendants(matching: .any)["toastty-mobile-transcript-row-14"]
        XCTAssertTrue(newestRow.waitForExistence(timeout: 5))
        XCTAssertTrue(newestRow.isHittable, "The conversation should open at its live tail")
        XCTAssertFalse(
            jumpToLatest.waitForExistence(timeout: 1),
            "Opening at the live tail must not show the jump affordance"
        )

        XCTAssertFalse(app.descendants(matching: .any)["toastty-mobile-transcript-row-8"].exists)
        let oldestRow = app.descendants(matching: .any)["toastty-mobile-transcript-row-1"]
        XCTAssertTrue(scrollToOlder(oldestRow, in: app))

        XCTAssertTrue(jumpToLatest.waitForExistence(timeout: 5))
        XCTAssertTrue(oldestRow.exists, "Showing the jump affordance must not move a slow reader")
        jumpToLatest.tap()
        XCTAssertTrue(jumpToLatest.waitForNonExistence(timeout: 5))

        XCTAssertTrue(newestRow.waitForExistence(timeout: 5))
        XCTAssertTrue(newestRow.isHittable)
        let liveEdgeY = newestRow.frame.minY
        let transcript = app.descendants(matching: .any)["toastty-mobile-transcript"]
        transcript.swipeUp()
        XCTAssertEqual(
            newestRow.frame.minY,
            liveEdgeY,
            accuracy: 4,
            "The live-edge target should leave no remaining downward scroll travel"
        )
        attachScreenshot(named: "fixture-transcript-jumped-to-latest", of: app)
    }

    func testLongMessageChunksScrollIndependentlyAndJumpToLatestRecovers() {
        let app = launchFixtureApp(
            environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "transcript-long-message"]
        )
        openFixtureConversation(in: app)

        let newestRow = app.descendants(matching: .any)["toastty-mobile-transcript-row-4"]
        let jumpToLatest = app.buttons["toastty-mobile-transcript-jump-latest"]
        XCTAssertTrue(newestRow.waitForExistence(timeout: 5))
        XCTAssertTrue(newestRow.isHittable, "The conversation should open at its live tail")

        // Scrolling up through the giant message must keep moving backwards —
        // the message renders as independent chunks instead of one cell whose
        // deferred measurement snaps the reader back down.
        // The first chunk retains the bare row ID. Later chunks can already
        // intersect the viewport at the live tail as semantic chunk sizes vary.
        let earlyChunk = app.descendants(matching: .any)["toastty-mobile-transcript-row-3"]
        XCTAssertTrue(
            scrollToOlder(earlyChunk, in: app),
            "An early chunk of the giant message should be visible after scrolling up"
        )

        XCTAssertTrue(jumpToLatest.waitForExistence(timeout: 5))
        jumpToLatest.tap()
        XCTAssertTrue(
            jumpToLatest.waitForNonExistence(timeout: 5),
            "The jump affordance must dismiss once the live tail is reached"
        )
        XCTAssertTrue(newestRow.waitForExistence(timeout: 5))
        XCTAssertTrue(newestRow.isHittable)
        attachScreenshot(named: "fixture-transcript-long-message-jump", of: app)
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

        XCTAssertFalse(app.descendants(matching: .any)["toastty-mobile-transcript-row-8"].exists)
        let oldestRow = app.descendants(matching: .any)["toastty-mobile-transcript-row-1"]
        XCTAssertTrue(scrollToOlder(oldestRow, in: app))
        XCTAssertTrue(oldestRow.label.localizedCaseInsensitiveContains("session connected"))
        attachScreenshot(named: "fixture-transcript-backward-paging", of: app)
    }

    func testFiveThousandRowFixtureReportsSimulatorReadiness() {
        let app = launchFixtureApp(
            environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "transcript-performance"]
        )
        let clock = ContinuousClock()
        let startedAt = clock.now
        openFixtureConversation(in: app)

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

    func testAttachmentChooserCancelLeavesDraftUnchanged() {
        let app = launchFixtureApp(environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "gated-send"])
        openGatedSendConversation(in: app)
        let attach = app.buttons["toastty-mobile-attachment-add"]
        XCTAssertTrue(attach.waitForExistence(timeout: 5))
        attach.tap()
        XCTAssertTrue(app.buttons["Photo Library"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Take Photo"].exists)
        XCTAssertTrue(app.buttons["Choose File"].exists)
        attachScreenshot(named: "fixture-attachment-chooser", of: app)
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else {
            // iOS 26 presents this as a popover without a Cancel action.
            // Tapping the inert title dismisses it without choosing a source.
            app.staticTexts["toastty-mobile-conversation-title"].tap()
        }
        XCTAssertTrue(app.buttons["Photo Library"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(attach.isEnabled)
        XCTAssertFalse(app.buttons["toastty-mobile-composer-send"].isEnabled)
        XCTAssertFalse(app.buttons["toastty-mobile-attachment-remove"].exists)
    }

    func testAttachmentFilesPickerCancelLeavesDraftUnchanged() {
        let app = launchFixtureApp(environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "gated-send"])
        openGatedSendConversation(in: app)
        app.buttons["toastty-mobile-attachment-add"].tap()
        let files = app.buttons["Choose File"].firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        files.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        attachScreenshot(named: "fixture-attachment-system-files", of: app)
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["toastty-mobile-attachment-add"].isEnabled)
        XCTAssertFalse(app.buttons["toastty-mobile-attachment-remove"].exists)
        XCTAssertFalse(app.buttons["toastty-mobile-composer-send"].isEnabled)
    }

    func testAttachmentPhotoLibraryCancelLeavesDraftUnchanged() {
        let app = launchFixtureApp(environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "gated-send"])
        openGatedSendConversation(in: app)
        app.buttons["toastty-mobile-attachment-add"].tap()
        let photos = app.buttons["Photo Library"].firstMatch
        XCTAssertTrue(photos.waitForExistence(timeout: 5))
        photos.tap()
        let close = app.buttons.matching(NSPredicate(format: "label == 'Cancel' OR label == 'Close'")).firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), app.debugDescription)
        attachScreenshot(named: "fixture-attachment-system-photos", of: app)
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["toastty-mobile-attachment-add"].isEnabled)
        XCTAssertFalse(app.buttons["toastty-mobile-attachment-remove"].exists)
        XCTAssertFalse(app.buttons["toastty-mobile-composer-send"].isEnabled)
    }

    func testAttachmentCameraUnavailableExplainsAlternativeSources() {
        let app = launchFixtureApp(environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "gated-send"])
        openGatedSendConversation(in: app)
        app.buttons["toastty-mobile-attachment-add"].tap()
        let camera = app.buttons["Take Photo"].firstMatch
        XCTAssertTrue(camera.waitForExistence(timeout: 5))
        camera.tap()
        let message = app.staticTexts["This device has no available camera. Choose Photo Library or Files instead."]
        XCTAssertTrue(message.waitForExistence(timeout: 5), app.debugDescription)
        attachScreenshot(named: "fixture-attachment-camera-unavailable", of: app)
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["toastty-mobile-attachment-add"].isEnabled)
        XCTAssertFalse(app.buttons["toastty-mobile-composer-send"].isEnabled)
    }

    func testAttachmentPreviewRemovalAndEnablesAttachmentOnlySend() {
        let app = launchFixtureApp(environment: [
            "TOASTTY_MOBILE_FIXTURE_SCENARIO": "gated-send",
            "TOASTTY_MOBILE_FIXTURE_ATTACHMENT_DRAFT": "1"
        ])
        openGatedSendConversation(in: app)
        let remove = app.buttons["toastty-mobile-attachment-remove"]
        attachScreenshot(named: "fixture-attachment-preview-before-removal", of: app)
        XCTAssertTrue(app.staticTexts["fixture-notes.txt"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(remove.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["toastty-mobile-composer-send"].isEnabled)
        attachScreenshot(named: "fixture-attachment-preview", of: app)
        remove.tap()
        XCTAssertFalse(remove.exists)
        XCTAssertFalse(app.buttons["toastty-mobile-composer-send"].isEnabled)
    }

    func testGatedSendClearsDraftOnlyAfterEnqueueAndShowsOptimisticBubble() {
        let app = launchFixtureApp(
            environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "gated-send"]
        )
        openGatedSendConversation(in: app)

        let input = composerInput(in: app)
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
        XCTAssertEqual(input.value as? String, "Sending message…")
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

    func testGatedSendWithChangingComposerHeightJumpsToLiveEdgeAndFollowsAppendedTail() {
        let app = launchFixtureApp(
            environment: [
                "TOASTTY_MOBILE_FIXTURE_SCENARIO": "gated-send",
                "TOASTTY_MOBILE_FIXTURE_SCROLL_TRACE": "1",
            ]
        )
        openGatedSendConversation(in: app)

        let transcript = app.scrollViews["toastty-mobile-transcript"]
        let jumpToLatest = app.buttons["toastty-mobile-transcript-jump-latest"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        transcript.swipeDown()
        XCTAssertTrue(jumpToLatest.waitForExistence(timeout: 5))

        let input = composerInput(in: app)
        let send = app.buttons["toastty-mobile-composer-send"]
        XCTAssertTrue(input.isHittable)
        input.tap()
        input.typeText("Send from the older transcript position\nwith a changing composer height")
        XCTAssertTrue(send.isEnabled)
        send.tap()

        let optimistic = app.descendants(matching: .any)[
            "toastty-mobile-send-optimistic-fixture-enqueued-1"
        ]
        XCTAssertTrue(optimistic.waitForExistence(timeout: 5))
        XCTAssertTrue(optimistic.label.contains("with a changing composer height"))
        XCTAssertTrue(
            jumpToLatest.waitForNonExistence(timeout: 5),
            "Sending must jump from a slow-reader position to the live edge"
        )
        XCTAssertTrue(
            optimistic.isHittable,
            "The newly appended optimistic message should remain visible at the live edge"
        )
        assertSendStayedAtBottom(in: app, startedAtBottom: false)
        attachScreenshot(named: "fixture-gated-send-from-slow-reader", of: app)

        transcript.swipeDown()
        XCTAssertTrue(jumpToLatest.waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(jumpToLatest.exists, "A deliberate drag must release post-send following")
    }

    func testGatedSendDelayedOptimisticRowKeepsTranscriptStableWhileComposerCollapses() {
        let app = launchFixtureApp(
            environment: [
                "TOASTTY_MOBILE_FIXTURE_SCENARIO": "gated-send",
                "TOASTTY_MOBILE_FIXTURE_DELAYED_SUBMIT": "1",
                "TOASTTY_MOBILE_FIXTURE_SCROLL_TRACE": "1",
            ]
        )
        openGatedSendConversation(in: app)

        let newestStableRow = app.descendants(matching: .any)[
            "toastty-mobile-transcript-row-13"
        ]
        let optimistic = app.descendants(matching: .any)[
            "toastty-mobile-send-optimistic-fixture-enqueued-1"
        ]
        let jumpToLatest = app.buttons["toastty-mobile-transcript-jump-latest"]
        let input = composerInput(in: app)
        let send = app.buttons["toastty-mobile-composer-send"]
        let draft = "Line 01\nLine 02\nLine 03\nLine 04\nLine 05"

        XCTAssertTrue(newestStableRow.waitForExistence(timeout: 5))
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        input.typeText(draft)
        XCTAssertTrue(send.isEnabled)
        XCTAssertTrue(newestStableRow.isHittable)
        XCTAssertFalse(jumpToLatest.exists)
        let expandedComposerHeight = input.frame.height

        send.tap()

        var awaitingOptimisticCount = 0
        var optimisticWithDraftCount = 0
        var collapsedCount = 0
        let deadline = Date().addingTimeInterval(7)
        while Date() < deadline {
            let hasOptimistic = optimistic.exists
            let hasCollapsedDraft = (input.value as? String) != draft
            if hasCollapsedDraft {
                collapsedCount += 1
            } else if hasOptimistic {
                optimisticWithDraftCount += 1
            } else {
                awaitingOptimisticCount += 1
            }
            if collapsedCount >= 3 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.06))
        }

        XCTAssertGreaterThanOrEqual(awaitingOptimisticCount, 2)
        XCTAssertGreaterThanOrEqual(optimisticWithDraftCount, 2)
        XCTAssertGreaterThanOrEqual(collapsedCount, 3)
        assertSendStayedAtBottom(in: app, startedAtBottom: true)
        XCTAssertLessThan(
            input.frame.height,
            expandedComposerHeight - 20,
            "The five-line draft should collapse only after the optimistic row is presented"
        )
        XCTAssertTrue(optimistic.exists)
        XCTAssertTrue(optimistic.isHittable)
        XCTAssertFalse(
            jumpToLatest.exists,
            "Delayed submission must finish at the live edge"
        )
    }

    func testGatedSendAtBottomKeepsMultilineSubmitPinned() {
        let app = launchFixtureApp(environment: [
            "TOASTTY_MOBILE_FIXTURE_SCENARIO": "gated-send",
            "TOASTTY_MOBILE_FIXTURE_SCROLL_TRACE": "1",
        ])
        openGatedSendConversation(in: app)
        let input = composerInput(in: app)
        input.tap()
        input.typeText("Line 01\nLine 02\nLine 03\nLine 04\nLine 05")
        XCTAssertFalse(app.buttons["toastty-mobile-transcript-jump-latest"].exists)
        app.buttons["toastty-mobile-composer-send"].tap()

        let optimistic = app.descendants(matching: .any)[
            "toastty-mobile-send-optimistic-fixture-enqueued-1"
        ]
        XCTAssertTrue(optimistic.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(optimistic.isHittable)
        assertSendStayedAtBottom(in: app, startedAtBottom: true)
    }

    private func assertSendStayedAtBottom(
        in app: XCUIApplication,
        startedAtBottom: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let trace = app.descendants(matching: .any)["toastty-mobile-transcript-scroll-trace"]
        guard let json = trace.value as? String,
              let samples = try? JSONDecoder().decode(
                  [TranscriptScrollTraceSample].self,
                  from: Data(json.utf8)
              )
        else {
            XCTFail("Missing coherent send geometry trace", file: file, line: line)
            return
        }
        let attachment = XCTAttachment(string: json)
        attachment.name = "post-send-scroll-geometry"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThan(samples.count, 1, file: file, line: line)
        guard let acquisition = samples.firstIndex(where: { $0.distanceFromBottom <= 1 }) else {
            XCTFail("Submit never acquired the bottom: \(json)", file: file, line: line)
            return
        }
        if startedAtBottom {
            XCTAssertEqual(acquisition, 0, "Fixture must begin at the bottom", file: file, line: line)
        }
        let followed = samples[acquisition...]
        let baseline = samples[acquisition].distanceFromBottom
        for sample in followed {
            XCTAssertEqual(
                sample.distanceFromBottom,
                baseline,
                accuracy: 3,
                "Submit moved away from its acquired bottom during layout: \(json)",
                file: file,
                line: line
            )
        }
        XCTAssertTrue(samples.contains(where: \.hasSendItems), file: file, line: line)
        XCTAssertGreaterThan(
            (samples.map(\.visibleHeight).max() ?? 0) - (samples.map(\.visibleHeight).min() ?? 0),
            20,
            "The trace must cover keyboard dismissal and composer resize",
            file: file,
            line: line
        )
    }

    func testGatedSendBackgroundResumeDoesNotRestoreKeyboard() {
        let app = launchFixtureApp(
            environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "gated-send"]
        )
        openGatedSendConversation(in: app)

        let input = composerInput(in: app)
        let keyboard = app.keyboards.firstMatch
        let draft = "Keep this unsent draft"
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        input.typeText(draft)

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(
            app.wait(for: .runningBackground, timeout: 5)
                || app.wait(for: .runningBackgroundSuspended, timeout: 5),
            "The fixture app should leave the foreground"
        )
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertFalse(
            keyboard.waitForExistence(timeout: 2),
            "Returning from the background must not restore composer focus"
        )
        XCTAssertEqual(
            input.value as? String,
            draft,
            "Background focus suppression must preserve the draft"
        )

        input.tap()
        XCTAssertTrue(
            keyboard.waitForExistence(timeout: 5),
            "The composer should focus normally after an explicit tap"
        )
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
            app.staticTexts[
                "The Mac accepted this send, but it did not appear in the session transcript"
            ]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts["Use build 413 and keep the release as a draft."]
                .waitForExistence(timeout: 5)
        )
        if dismiss.isHittable == false {
            let jumpToLatest = app.buttons["toastty-mobile-transcript-jump-latest"]
            XCTAssertTrue(jumpToLatest.waitForExistence(timeout: 5))
            jumpToLatest.tap()
        }
        XCTAssertTrue(dismiss.isHittable)
        let copy = app.buttons["toastty-mobile-send-receipt-copy-fixture-delivery-unconfirmed"]
        XCTAssertTrue(copy.isHittable)
        copy.tap()
        XCTAssertTrue(receipt.exists, "Copying must keep the delivery receipt available")
        attachScreenshot(named: "fixture-gated-send-unconfirmed-receipt", of: app)

        dismiss.tap()
        XCTAssertTrue(receipt.waitForNonExistence(timeout: 5))
        XCTAssertTrue(composerInput(in: app).isEnabled)
    }

    func testGatedSendTranscriptDragDismissesKeyboard() {
        let app = launchFixtureApp(
            environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "gated-send"]
        )
        openGatedSendConversation(in: app)

        let input = composerInput(in: app)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))

        let transcript = app.scrollViews["toastty-mobile-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        XCTAssertTrue(transcript.isHittable)
        let dragStart = transcript.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)
        )
        let dragEnd = transcript.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)
        )
        dragStart.press(
            forDuration: 0.1,
            thenDragTo: dragEnd,
            withVelocity: .slow,
            thenHoldForDuration: 0.1
        )

        XCTAssertTrue(
            keyboard.waitForNonExistence(timeout: 5),
            "Dragging the transcript down should interactively dismiss the keyboard"
        )
    }

    func testGatedSendComposerDragDoesNotFocus() {
        let app = launchFixtureApp(
            environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "gated-send"]
        )
        openGatedSendConversation(in: app)

        let input = composerInput(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(input.isHittable)
        let start = input.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        let end = input.coordinate(
            withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
        )
        start.press(
            forDuration: 0.1,
            thenDragTo: end,
            withVelocity: .fast,
            thenHoldForDuration: 0
        )

        XCTAssertFalse(
            app.keyboards.firstMatch.waitForExistence(timeout: 1),
            "Dragging away from the composer should cancel its touch-down focus request"
        )
    }

    func testGatedSendFocusedComposerDragKeepsFocus() {
        let app = launchFixtureApp(
            environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "gated-send"]
        )
        openGatedSendConversation(in: app)

        let input = composerInput(in: app)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(input.isHittable)
        input.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))

        // A rightward drag can invoke iOS navigation back. Drag left so
        // this checks composer focus without requesting a page transition.
        let start = input.coordinate(
            withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)
        )
        let end = input.coordinate(
            withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)
        )
        start.press(
            forDuration: 0.1,
            thenDragTo: end,
            withVelocity: .fast,
            thenHoldForDuration: 0
        )

        XCTAssertTrue(
            keyboard.waitForExistence(timeout: 1),
            "Dragging within a focused composer should preserve keyboard focus"
        )
    }

    func testGatedSendComposerKeepsLatestLineVisibleAfterOverflow() throws {
        let app = launchFixtureApp(
            environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "gated-send"]
        )
        openGatedSendConversation(in: app)

        let input = composerInput(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))

        input.typeText("Line 01\nLine 02\nLine 03\nLine 04\nLine 05")
        let cappedHeight = input.frame.height
        input.typeText("\nLine 06\nLine 07\nZEBRA888")

        XCTAssertEqual(
            input.frame.height,
            cappedHeight,
            accuracy: 2,
            "The composer should stop growing after five visible lines"
        )
        let screenshot = input.screenshot()
        attachScreenshot(named: "fixture-gated-send-composer-overflow", screenshot: screenshot)
        let visibleText = try recognizedText(in: screenshot)
        XCTAssertTrue(
            visibleText.contains("ZEBRA888"),
            "The composer should scroll to reveal its latest line; visible text was: \(visibleText)"
        )

        input.swipeDown()
        let oldestScreenshot = input.screenshot()
        let oldestVisibleText = try recognizedText(in: oldestScreenshot)
        XCTAssertTrue(
            oldestVisibleText.contains("Line 01"),
            "The focused composer should scroll to its oldest line; visible text was: \(oldestVisibleText)"
        )
        XCTAssertTrue(app.keyboards.firstMatch.exists)

        input.swipeUp()
        let latestScreenshot = input.screenshot()
        let latestVisibleText = try recognizedText(in: latestScreenshot)
        XCTAssertTrue(
            latestVisibleText.contains("ZEBRA888"),
            "The focused composer should scroll back to its latest line; visible text was: \(latestVisibleText)"
        )
        XCTAssertTrue(app.keyboards.firstMatch.exists)
    }

    func testGatedSendComposerKeepsLatestWrappedTextVisibleInLongDraft() throws {
        let app = launchFixtureApp(
            environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "gated-send"]
        )
        openGatedSendConversation(in: app)

        let input = composerInput(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))

        input.typeText(String(repeating: "alpha beta gamma delta ", count: 12))
        let cappedHeight = input.frame.height
        input.typeText(
            String(repeating: "epsilon zeta eta theta ", count: 60)
                + " ZEBRA888"
        )

        XCTAssertEqual(
            input.frame.height,
            cappedHeight,
            accuracy: 2,
            "A long naturally wrapping draft should keep the composer clamped"
        )
        let screenshot = input.screenshot()
        attachScreenshot(
            named: "fixture-gated-send-composer-long-wrapped-overflow",
            screenshot: screenshot
        )
        let visibleText = try recognizedText(in: screenshot)
        XCTAssertTrue(
            visibleText.contains("ZEBRA888"),
            "The long draft should keep its latest wrapped text visible; visible text was: \(visibleText)"
        )
    }

    func testGatedSendKeyboardPresentationKeepsLiveTailVisible() {
        let app = launchFixtureApp(
            environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "gated-send"]
        )
        openGatedSendConversation(in: app)

        let newestRow = app.descendants(matching: .any)[
            "toastty-mobile-transcript-row-13"
        ]
        let jumpToLatest = app.buttons["toastty-mobile-transcript-jump-latest"]
        XCTAssertTrue(newestRow.waitForExistence(timeout: 5))
        XCTAssertTrue(newestRow.isHittable)
        XCTAssertFalse(jumpToLatest.exists)
        let tailMaxYBeforeKeyboard = newestRow.frame.maxY

        let input = composerInput(in: app)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(input.isHittable)
        input.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))

        XCTAssertTrue(newestRow.isHittable)
        XCTAssertLessThan(
            newestRow.frame.maxY,
            tailMaxYBeforeKeyboard,
            "The live tail should move up when the keyboard reduces the transcript viewport"
        )
        XCTAssertLessThanOrEqual(
            newestRow.frame.maxY,
            input.frame.minY + 1,
            "The live tail should remain visible above the focused composer"
        )
        XCTAssertFalse(
            jumpToLatest.exists,
            "Keyboard presentation should preserve live-edge following"
        )
    }

    func testGatedSendJumpButtonStaysAboveFocusedComposer() {
        let app = launchFixtureApp(
            environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "gated-send"]
        )
        openGatedSendConversation(in: app)

        let transcript = app.scrollViews["toastty-mobile-transcript"]
        let jumpToLatest = app.buttons["toastty-mobile-transcript-jump-latest"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        transcript.swipeDown()
        XCTAssertTrue(jumpToLatest.waitForExistence(timeout: 5))

        let input = composerInput(in: app)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(input.isHittable)
        input.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertTrue(jumpToLatest.isHittable)
        XCTAssertLessThanOrEqual(
            jumpToLatest.frame.maxY,
            input.frame.minY,
            "The floating jump control must remain above the focused composer"
        )
    }

    func testFourAttachmentsRemainScrollableAboveKeyboardAtAccessibilityXXXL() throws {
        let app = launchFixtureApp(
            launchArguments: [
                "-UIPreferredContentSizeCategoryName",
                UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue,
            ],
            environment: [
                "TOASTTY_MOBILE_FIXTURE_SCENARIO": "gated-send",
                "TOASTTY_MOBILE_FIXTURE_ATTACHMENT_DRAFT": "4",
            ]
        )
        openGatedSendConversation(in: app)
        let input = composerInput(in: app)
        let send = app.buttons["toastty-mobile-composer-send"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(input.isHittable)
        // XCTest selected the text view's fractional top edge on CI. Tap its
        // visible center so the gesture lands inside the editor's bounds.
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        attachScreenshot(named: "fixture-attachment-composer-after-tap-accessibility-xxxl", of: app)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        input.typeText("Review these files")
        let list = app.scrollViews["toastty-mobile-attachment-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertLessThanOrEqual(list.frame.height, 133)
        let tab = app.staticTexts["toastty-mobile-workspace-tab"]
        XCTAssertTrue(tab.isHittable, "Tab context must remain visible with attachments and the keyboard")
        XCTAssertEqual(tab.label, "Mac tab: Release preparation — changelog, signing, and TestFlight verification")
        XCTAssertLessThanOrEqual(tab.frame.maxY, list.frame.minY)
        let scaledBodyFont = UIFont.preferredFont(
            forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        )
        XCTAssertGreaterThanOrEqual(
            input.frame.height, ceil(scaledBodyFont.lineHeight),
            "The UIKit text field must retain at least one scaled line instead of overflowing a compressed border"
        )
        let attach = app.buttons["toastty-mobile-attachment-add"]
        XCTAssertEqual(attach.label, "Attach")
        XCTAssertGreaterThanOrEqual(attach.frame.width, 44)
        XCTAssertGreaterThanOrEqual(attach.frame.height, 44)
        XCTAssertTrue(input.isHittable)
        XCTAssertTrue(send.isHittable)
        XCTAssertTrue(send.isEnabled)
        let keyboardTop = topOfKeyboardObstruction(keyboard)
        XCTAssertLessThanOrEqual(input.frame.maxY, keyboardTop + 1)
        XCTAssertLessThanOrEqual(send.frame.maxY, keyboardTop + 1)
        let removeLast = app.buttons["Remove fixture-notes-4.txt"]
        for _ in 0..<6 where !removeLast.isHittable || !list.frame.insetBy(dx: -1, dy: -1).contains(removeLast.frame) {
            list.swipeUp()
        }
        XCTAssertTrue(removeLast.isHittable, app.debugDescription)
        XCTAssertTrue(list.frame.insetBy(dx: -1, dy: -1).contains(removeLast.frame),
                      "The complete 44-point Remove control must fit inside the attachment list")
        let filenameLast = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "fixture-notes-4.txt")).firstMatch
        XCTAssertTrue(filenameLast.isHittable)
        XCTAssertTrue(list.frame.insetBy(dx: -1, dy: -1).contains(filenameLast.frame),
                      "The attachment filename must remain visible alongside Remove")
        attachScreenshot(named: "fixture-four-attachments-keyboard-accessibility-xxxl", of: app)
        removeLast.tap()
        XCTAssertTrue(removeLast.waitForNonExistence(timeout: 5))
        XCTAssertTrue(keyboard.exists)
        XCTAssertTrue(app.buttons["toastty-mobile-attachment-add"].isEnabled)
        XCTAssertTrue(input.isHittable)
        XCTAssertTrue(send.isHittable)

        let twoLineHeight = input.frame.height
        input.typeText("\n3\n4\n5\n6\nFOX7")
        XCTAssertEqual(input.frame.height, twoLineHeight, accuracy: 2,
                       "Accessibility drafts with attachments must scroll after two visible lines")
        XCTAssertTrue(try recognizedText(in: input.screenshot()).contains("FOX7"),
                      "The capped composer must scroll to its newest text")
        XCTAssertLessThanOrEqual(input.frame.maxY, topOfKeyboardObstruction(keyboard) + 1)
        XCTAssertLessThanOrEqual(send.frame.maxY, topOfKeyboardObstruction(keyboard) + 1)
        XCTAssertLessThanOrEqual(attach.frame.maxY, topOfKeyboardObstruction(keyboard) + 1)
        attachScreenshot(named: "fixture-attachments-long-draft-accessibility-xxxl", of: app)

        let draftLength = (input.value as? String)?.count ?? 0
        XCTAssertGreaterThan(draftLength, 0)
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: draftLength))
        XCTAssertLessThan(input.frame.height, twoLineHeight,
                          "Clearing a long draft must return the composer to one visible line")
        XCTAssertTrue(input.isHittable)
        XCTAssertTrue(send.isHittable)
        XCTAssertTrue(send.isEnabled, "The remaining attachments allow an attachment-only send")
        attachScreenshot(named: "fixture-attachments-cleared-draft-accessibility-xxxl", of: app)
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

        let input = composerInput(in: app)
        let send = app.buttons["toastty-mobile-composer-send"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let keyboard = app.keyboards.firstMatch
        XCTAssertFalse(
            keyboard.waitForExistence(timeout: 2),
            "Opening a conversation should not focus the composer"
        )
        XCTAssertTrue(input.isHittable)
        input.tap()
        XCTAssertTrue(
            keyboard.waitForExistence(timeout: 5),
            "Tapping the composer should present the keyboard"
        )
        input.typeText("Accessible send")
        let title = app.staticTexts["toastty-mobile-conversation-title"]
        let back = app.navigationBars.firstMatch.buttons.firstMatch
        attachScreenshot(named: "fixture-gated-send-accessibility-xxxl", of: app)
        XCTAssertEqual(title.label, "Changelog + tag")
        XCTAssertTrue(title.isHittable)
        XCTAssertTrue(back.isHittable)
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

    func testExecutionProfileRemainsAboveComposerWithKeyboardAndDisabledNotice() {
        let app = launchFixtureApp(
            environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "gated-send"]
        )
        openGatedSendConversation(in: app)
        let profile = app.staticTexts["toastty-mobile-session-execution-profile"]
        let input = composerInput(in: app)
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        XCTAssertEqual(profile.label, "Model: gpt-6. Reasoning: xhigh")
        XCTAssertLessThanOrEqual(profile.frame.maxY, input.frame.minY)
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        input.typeText("Use build 413")
        XCTAssertTrue(profile.isHittable)
        XCTAssertLessThanOrEqual(profile.frame.maxY, input.frame.minY)
        let tab = app.staticTexts["toastty-mobile-workspace-tab"]
        XCTAssertEqual(tab.label, "Mac tab: Release preparation — changelog, signing, and TestFlight verification")
        XCTAssertTrue(tab.isHittable)
        XCTAssertGreaterThanOrEqual(tab.frame.minX, profile.frame.maxX)
        XCTAssertLessThanOrEqual(tab.frame.maxY, input.frame.minY)
        XCTAssertEqual(input.value as? String, "Use build 413")
        attachScreenshot(named: "execution-profile-keyboard", of: app)
        app.buttons["toastty-mobile-composer-send"].tap()
        let status = app.descendants(matching: .any)["toastty-mobile-composer-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(profile.exists)
        XCTAssertLessThanOrEqual(profile.frame.maxY, input.frame.minY)
        XCTAssertLessThanOrEqual(input.frame.maxY, status.frame.minY)
        attachScreenshot(named: "execution-profile-disabled-notice", of: app)
    }

    func testLongExecutionProfileWrapsAtAccessibilityXXXLAboveDisabledComposer() {
        let app = launchFixtureApp(launchArguments: [
            "-UIPreferredContentSizeCategoryName",
            UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue,
        ])
        openFixtureConversation(in: app)
        let profile = app.staticTexts["toastty-mobile-session-execution-profile"]
        let input = composerInput(in: app)
        let status = app.descendants(matching: .any)["toastty-mobile-composer-status"]
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        XCTAssertEqual(profile.label,
                       "Model: claude-opus-long-provider-model-identifier-for-accessibility-layout. Reasoning: high")
        XCTAssertGreaterThan(profile.frame.height, 40, "The long identifier should wrap at accessibility size")
        XCTAssertGreaterThanOrEqual(profile.frame.minX, 0)
        XCTAssertLessThanOrEqual(profile.frame.maxX, app.frame.maxX)
        XCTAssertLessThanOrEqual(profile.frame.maxY, input.frame.minY)
        XCTAssertTrue(status.exists)
        XCTAssertLessThanOrEqual(input.frame.maxY, status.frame.minY)
        let tab = app.staticTexts["toastty-mobile-workspace-tab"]
        XCTAssertTrue(tab.exists)
        XCTAssertGreaterThan(tab.frame.width, 0)
        XCTAssertLessThanOrEqual(tab.frame.maxX, app.frame.maxX)
        XCTAssertLessThanOrEqual(tab.frame.maxY, input.frame.minY)
        attachScreenshot(named: "execution-profile-accessibility-xxxl", of: app)
    }

    func testUnreportedExecutionProfileHasNoComposerRow() {
        let app = launchFixtureApp()
        openWorkspace(toasttyWorkspaceID, in: app)
        let session = app.buttons["toastty-mobile-workspace-session-\(workingConversationID)"]
        XCTAssertTrue(scrollWorkspaceTo(session, in: app))
        session.tap()
        XCTAssertTrue(composerInput(in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["toastty-mobile-session-execution-profile"].exists)
        XCTAssertFalse(app.staticTexts["toastty-mobile-workspace-tab"].exists)
    }

    func testTabWithoutExecutionProfileUsesTrailingComposerRow() {
        let app = launchFixtureApp()
        openWorkspace(releaseWorkspaceID, in: app)
        let session = app.buttons["toastty-mobile-workspace-session-B1000000-0000-0000-0000-000000000008"]
        XCTAssertTrue(scrollWorkspaceTo(session, in: app))
        session.tap()
        let input = composerInput(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let tab = app.staticTexts["toastty-mobile-workspace-tab"]
        XCTAssertTrue(tab.exists)
        XCTAssertFalse(app.staticTexts["toastty-mobile-session-execution-profile"].exists)
        XCTAssertGreaterThan(tab.frame.midX, app.frame.midX)
        XCTAssertLessThanOrEqual(tab.frame.maxY, input.frame.minY)
        attachScreenshot(named: "tab-only-composer-row", of: app)
    }

    func testDisconnectedExecutionProfileIsLastReported() {
        let app = launchFixtureApp(
            environment: ["TOASTTY_MOBILE_FIXTURE_SCENARIO": "reconnecting"]
        )
        openFixtureConversation(in: app)
        let profile = app.staticTexts["toastty-mobile-session-execution-profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        XCTAssertTrue(profile.label.hasPrefix("Last reported. Model: "))
        XCTAssertTrue(app.staticTexts["toastty-mobile-workspace-tab"].label.hasPrefix("Last reported. Mac tab: "))
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-composer-status"].exists)
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

    private func composerInput(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["toastty-mobile-composer-input"]
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
        XCTAssertTrue(scrollWorkspaceTo(sessionButton, in: app))
        sessionButton.tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-conversation-title"].waitForExistence(timeout: 5))
    }

    private func openGatedSendConversation(in app: XCUIApplication) {
        let readyCard = app.buttons[
            "toastty-mobile-grouped-card-\(openPromptConversationID)"
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

    private func scrollWorkspaceTo(
        _ element: XCUIElement,
        in app: XCUIApplication,
        attempts: Int = 12
    ) -> Bool {
        for _ in 0..<attempts {
            if element.exists, element.isHittable { return true }
            app.swipeUp()
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
        XCTAssertEqual(context.label, "4 sessions")
    }

    private func attachScreenshot(named name: String, of app: XCUIApplication) {
        attachScreenshot(named: name, screenshot: app.screenshot())
    }

    private func attachScreenshot(named name: String, screenshot: XCUIScreenshot) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func recognizedText(in screenshot: XCUIScreenshot) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        guard let image = screenshot.image.cgImage else {
            XCTFail("The composer screenshot did not contain a CGImage")
            return ""
        }

        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
    }
}
