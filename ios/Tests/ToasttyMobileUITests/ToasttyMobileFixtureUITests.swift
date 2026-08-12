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
        XCTAssertTrue(readOnlyInteraction.exists)
        XCTAssertTrue(app.staticTexts["Respond on the desktop"].exists)
        XCTAssertFalse(app.buttons["Approve"].exists)
        XCTAssertFalse(app.buttons["Deny"].exists)
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

    private func launchFixtureApp(launchArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        app.launchArguments += launchArguments
        app.launch()
        return app
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
