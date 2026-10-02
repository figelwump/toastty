import XCTest

@MainActor
final class ToasttyMobilePreviewUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSessionScratchpadSheetPreservesDraftAndReturnsToChat() {
        let app = XCUIApplication()
        app.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_SCENARIO"] = "gated-send"
        app.launch()
        let home = app.descendants(matching: .any)["toastty-mobile-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        let session = app.buttons["toastty-mobile-grouped-card-B1000000-0000-0000-0000-000000000007"]
        for _ in 0..<12 where !session.isHittable { home.swipeUp() }
        session.tap()
        let input = app.descendants(matching: .any)["toastty-mobile-composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        app.typeText("Keep this draft while I check the Scratchpad.")
        app.buttons["toastty-conversation-scratchpad"].tap()
        XCTAssertTrue(app.buttons["toastty-preview-close"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["toastty-scratchpad-session"].exists)
        let counter = app.webViews.buttons["Tap to count"]
        XCTAssertTrue(counter.waitForExistence(timeout: 10))
        counter.tap()
        XCTAssertTrue(app.webViews.staticTexts["Count: 1"].waitForExistence(timeout: 5))
        attach(app, name: "session-scratchpad-sheet")
        app.buttons["toastty-preview-close"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "Keep this draft while I check the Scratchpad.")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    func testScratchpadSessionBackReturnsToSamePreviewAndThenWorkspace() {
        let app = launchWorkspace()
        tapPanel("C1000000-0000-0000-0000-000000000001", in: app)
        let counter = app.webViews.buttons["Tap to count"]
        XCTAssertTrue(counter.waitForExistence(timeout: 10))
        counter.tap()
        XCTAssertTrue(app.webViews.staticTexts["Count: 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["toastty-scratchpad-session"].exists)
        app.buttons["toastty-scratchpad-session"].tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-conversation-title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["toastty-mobile-conversation-title"].label, "Changelog + tag")
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["toastty-scratchpad-session"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.webViews.staticTexts["Count: 1"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["toastty-preview-close"].exists)
        attach(app, name: "scratchpad-after-session-back")
        returnToWorkspace(app)
    }

    func testWorkspaceDocumentAndHTMLPreviewReturnToWorkspace() {
        let app = launchWorkspace()
        tapPanel("C1000000-0000-0000-0000-000000000002", in: app)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(documentTargetLine(in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Edit"].exists)
        returnToWorkspace(app)
        tapPanel("C1000000-0000-0000-0000-000000000003", in: app)
        let sample = app.webViews.buttons["Read a sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 10))
        for _ in 0..<4 where !sample.isHittable { app.webViews.firstMatch.swipeUp() }
        sample.tap()
        XCTAssertTrue(app.webViews.staticTexts["Notice the small things."].waitForExistence(timeout: 5))
        attach(app, name: "html-preview-interaction")
        returnToWorkspace(app)
    }

    func testWorkspacePanelsShowFourThenExpandInRecencyOrder() {
        let app = launchWorkspace()
        // Panels follow the sessions and subspaces.
        let toggle = app.buttons["toastty-workspace-panels-toggle"]
        for _ in 0..<8 where !toggle.isHittable { app.swipeUp() }
        XCTAssertEqual(toggle.label, "Show 2 more")
        attach(app, name: "workspace-panels-collapsed")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "toastty-workspace-panel-"))
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.element(boundBy: 0).identifier, "toastty-workspace-panel-C1000000-0000-0000-0000-000000000001")
        XCTAssertEqual(rows.element(boundBy: 3).identifier, "toastty-workspace-panel-C1000000-0000-0000-0000-000000000004")
        XCTAssertEqual(rows.element(boundBy: 0).label, "Workspace map, Scratchpad, updated 2m ago")
        toggle.tap()
        for _ in 0..<4 where !toggle.isHittable { app.swipeUp() }
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows.element(boundBy: 4).label, "Earlier notes, Document, updated 2d ago")
        XCTAssertEqual(toggle.label, "Show less")
        toggle.tap()
        XCTAssertEqual(rows.count, 4)
    }

    func testWorkspaceBrowserUsesBackNavigation() {
        let app = launchWorkspace()
        tapPanel("C1000000-0000-0000-0000-000000000004", in: app)
        XCTAssertTrue(app.navigationBars["Example website"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        returnToWorkspace(app)
    }

    func testConversationFilenameRevealsLineAndReturnsThroughWorkspaceToHome() {
        let app = launchWorkspace()
        attach(app, name: "workspace-open-panels")
        let session = app.buttons["toastty-mobile-workspace-session-B1000000-0000-0000-0000-000000000001"]
        for _ in 0..<8 where !session.isHittable { app.swipeUp() }
        XCTAssertTrue(session.isHittable)
        session.tap()
        let transcript = app.scrollViews["toastty-mobile-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        let link = app.links["docs/mobile-preview.md:12"]
        for _ in 0..<12 where !link.isHittable { transcript.swipeDown() }
        XCTAssertTrue(link.isHittable)
        link.tap()
        let targetLine = documentTargetLine(in: app)
        XCTAssertTrue(targetLine.waitForExistence(timeout: 10))
        XCTAssertTrue(targetLine.isHittable)
        attach(app, name: "conversation-file-line-12")
        XCTAssertTrue(app.buttons["toastty-preview-close"].exists)
        app.buttons["toastty-preview-close"].tap()
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["toastty"].waitForExistence(timeout: 5))
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-home"].waitForExistence(timeout: 5))
        attach(app, name: "normal-back-home")
    }

    func testPanelOnlyWorkspaceIsReachableUnderAllButHiddenUnderActive() {
        let app = XCUIApplication()
        app.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        app.launch()
        let home = app.descendants(matching: .any)["toastty-mobile-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        let filter = app.segmentedControls["toastty-mobile-workspace-session-filter"]
        let workspace = app.buttons["toastty-mobile-workspace-A1000000-0000-0000-0000-000000000004"]
        // Active lists only workspaces with something happening, so a
        // workspace with open panels and no sessions is reached through All.
        filter.buttons["Active"].tap()
        for _ in 0..<6 where !workspace.exists { home.swipeUp() }
        XCTAssertFalse(workspace.exists)
        filter.buttons["All"].tap()
        for _ in 0..<12 where !workspace.isHittable { home.swipeUp() }
        XCTAssertTrue(workspace.isHittable)
        workspace.tap()
        let panel = app.buttons["toastty-workspace-panel-C1000000-0000-0000-0000-000000000005"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No sessions yet"].exists)
        XCTAssertTrue(app.staticTexts["Open a session in Toastty on your Mac and it will appear here."].exists)
        XCTAssertFalse(app.staticTexts["Choose All to show idle sessions in this workspace."].exists)
        // Two reports share a title, so each names its folder.
        let smokeReport = app.buttons["toastty-workspace-panel-C1000000-0000-0000-0000-000000000008"]
        for _ in 0..<4 where !smokeReport.isHittable { app.swipeUp() }
        XCTAssertEqual(smokeReport.label, "report.json, in smoke, Document")
        XCTAssertEqual(
            app.buttons["toastty-workspace-panel-C1000000-0000-0000-0000-000000000009"].label,
            "report.json, in remote, Document"
        )
        XCTAssertEqual(panel.label, "Navigation sketch, Scratchpad")
        attach(app, name: "panel-only-workspace")
        panel.tap()
        XCTAssertFalse(app.buttons["toastty-scratchpad-session"].exists)
        XCTAssertTrue(app.buttons["toastty-scratchpad-fit"].waitForExistence(timeout: 10))
        returnToWorkspace(app)
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        XCTAssertTrue(home.waitForExistence(timeout: 5))
    }

    func testScratchpadControlsRemainInteractiveAcrossZoomAndFit() {
        let app = launchWorkspace()
        tapPanel("C1000000-0000-0000-0000-000000000001", in: app)
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10))
        let counter = app.webViews.buttons["Tap to count"]
        XCTAssertTrue(counter.waitForExistence(timeout: 10))
        counter.tap()
        XCTAssertTrue(app.webViews.staticTexts["Count: 1"].waitForExistence(timeout: 5))
        let topHeading = app.webViews.staticTexts["Everything belongs to a workspace."]
        XCTAssertTrue(topHeading.isHittable)
        let bottomButton = app.webViews.buttons["Mark reviewed"]
        // WebKit can report scrollable, offscreen controls as hittable.
        // Verify physical visibility before and after scrolling instead.
        let contentTop = app.navigationBars.firstMatch.frame.maxY
        let visibleFrame = CGRect(x: app.frame.minX, y: contentTop,
                                  width: app.frame.width, height: app.frame.maxY - contentTop - 40)
        XCTAssertGreaterThan(bottomButton.frame.minY, visibleFrame.maxY)
        for _ in 0..<8 where !visibleFrame.contains(bottomButton.frame) { app.swipeUp() }
        XCTAssertTrue(visibleFrame.contains(bottomButton.frame))
        XCTAssertTrue(bottomButton.isHittable)
        bottomButton.tap()
        XCTAssertTrue(app.webViews.staticTexts["Reviewed"].exists)
        app.buttons["toastty-scratchpad-fit"].tap()
        XCTAssertTrue(topHeading.isHittable)
        XCTAssertTrue(counter.isHittable)
        let fittedWidth = counter.frame.width
        XCTAssertGreaterThan(fittedWidth, 0)
        web.pinch(withScale: 1.8, velocity: 1)
        XCTAssertGreaterThan(counter.frame.width, fittedWidth * 1.2, "Pinch must enlarge the actual rendered control")
        web.swipeLeft()
        attach(app, name: "scratchpad-zoomed-and-panned")
        app.buttons["toastty-scratchpad-fit"].tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(counter.frame.width - fittedWidth) <= 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed, "Fit restores the screen-width scale")
        XCTAssertEqual(counter.frame.width, fittedWidth, accuracy: 2)
        XCTAssertTrue(counter.isHittable)
        counter.tap()
        XCTAssertTrue(app.webViews.staticTexts["Count: 2"].waitForExistence(timeout: 5))
        attach(app, name: "scratchpad-fit-after-zoom")
        returnToWorkspace(app)
    }

    private func returnToWorkspace(_ app: XCUIApplication) {
        XCTAssertFalse(app.buttons["toastty-preview-close"].exists)
        XCTAssertFalse(app.sheets.firstMatch.exists)
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["toastty-mobile-workspace-detail"].waitForExistence(timeout: 5)
        )
    }

    /// Panels sit below the sessions and subspaces, so scroll to one first.
    private func tapPanel(_ panelID: String, in app: XCUIApplication) {
        let panel = app.buttons["toastty-workspace-panel-\(panelID)"]
        for _ in 0..<8 where !panel.isHittable { app.swipeUp() }
        XCTAssertTrue(panel.isHittable)
        panel.tap()
    }

    private func documentTargetLine(in app: XCUIApplication) -> XCUIElement {
        app.webViews.staticTexts.matching(NSPredicate(format: "label MATCHES %@",
            #"^Tap a filename in the conversation\.\s*$"#)).firstMatch
    }

    private func launchWorkspace() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        app.launch()
        let workspace = app.buttons["toastty-mobile-workspace-A1000000-0000-0000-0000-000000000001"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        for _ in 0..<6 where !workspace.isHittable { app.swipeUp() }
        workspace.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["toastty-mobile-workspace-detail"].waitForExistence(timeout: 5)
        )
        return app
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
