import XCTest

@MainActor
final class ToasttyMobilePreviewUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testWorkspaceDocumentAndHTMLPreviewReturnToWorkspace() {
        let app = launchWorkspace()
        app.buttons["toastty-workspace-panel-C1000000-0000-0000-0000-000000000002"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(documentTargetLine(in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Edit"].exists)
        app.buttons["toastty-preview-close"].tap()
        XCTAssertTrue(app.staticTexts["Open panels"].waitForExistence(timeout: 5))
        app.buttons["toastty-workspace-panel-C1000000-0000-0000-0000-000000000003"].tap()
        let sample = app.webViews.buttons["Read a sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 10))
        for _ in 0..<4 where !sample.isHittable { app.webViews.firstMatch.swipeUp() }
        sample.tap()
        XCTAssertTrue(app.webViews.staticTexts["Notice the small things."].waitForExistence(timeout: 5))
        attach(app, name: "html-preview-interaction")
        app.buttons["toastty-preview-close"].tap()
        XCTAssertTrue(app.staticTexts["Open panels"].waitForExistence(timeout: 5))
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
        app.buttons["toastty-preview-close"].tap()
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["toastty"].waitForExistence(timeout: 5))
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-home"].waitForExistence(timeout: 5))
        attach(app, name: "normal-back-home")
    }

    func testPanelOnlyWorkspaceRemainsAvailableUnderActiveFilter() {
        let app = XCUIApplication()
        app.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        app.launch()
        let home = app.descendants(matching: .any)["toastty-mobile-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        app.segmentedControls["toastty-mobile-workspace-session-filter"].buttons["Active"].tap()
        let workspace = app.buttons["toastty-mobile-workspace-A1000000-0000-0000-0000-000000000004"]
        for _ in 0..<12 where !workspace.isHittable { home.swipeUp() }
        XCTAssertTrue(workspace.isHittable)
        workspace.tap()
        let panel = app.buttons["toastty-workspace-panel-C1000000-0000-0000-0000-000000000005"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No sessions yet"].exists)
        XCTAssertTrue(app.staticTexts["Open a session in Toastty on your Mac and it will appear here."].exists)
        XCTAssertFalse(app.staticTexts["Choose All to show idle sessions in this workspace."].exists)
        attach(app, name: "panel-only-workspace")
        panel.tap()
        XCTAssertTrue(app.buttons["toastty-scratchpad-fit"].waitForExistence(timeout: 10))
        app.buttons["toastty-preview-close"].tap()
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        XCTAssertTrue(home.waitForExistence(timeout: 5))
    }

    func testScratchpadControlsRemainInteractiveAcrossZoomAndFit() {
        let app = launchWorkspace()
        app.buttons["toastty-workspace-panel-C1000000-0000-0000-0000-000000000001"].tap()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10))
        let counter = app.webViews.buttons["Tap to count"]
        XCTAssertTrue(counter.waitForExistence(timeout: 10))
        counter.tap()
        XCTAssertTrue(app.webViews.staticTexts["Count: 1"].waitForExistence(timeout: 5))
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
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed, "Fit restores the overview scale")
        XCTAssertEqual(counter.frame.width, fittedWidth, accuracy: 2)
        XCTAssertTrue(counter.isHittable)
        counter.tap()
        XCTAssertTrue(app.webViews.staticTexts["Count: 2"].waitForExistence(timeout: 5))
        attach(app, name: "scratchpad-fit-after-zoom")
        app.buttons["toastty-preview-close"].tap()
        XCTAssertTrue(app.staticTexts["Open panels"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.staticTexts["Open panels"].waitForExistence(timeout: 5))
        return app
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
