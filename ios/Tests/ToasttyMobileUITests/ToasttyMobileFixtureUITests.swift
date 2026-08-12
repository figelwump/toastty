import XCTest

final class ToasttyMobileFixtureUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFixtureHomeShowsHierarchyAndOpensReadOnlyInteraction() {
        let app = XCUIApplication()
        app.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        app.launch()

        let home = app.descendants(matching: .any)["toastty-mobile-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["NEEDS YOU · 3"].exists)
        XCTAssertTrue(app.staticTexts["WORKSPACES"].exists)
        XCTAssertTrue(app.staticTexts["toastty"].exists)

        let pendingInteractionID = "B1000000-0000-0000-0000-000000000001"
        let openButton = app.buttons["toastty-mobile-open-\(pendingInteractionID)"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 5))
        openButton.tap()

        let conversationTitle = app.staticTexts["toastty-mobile-conversation-title"]
        let readOnlyInteraction = app.descendants(matching: .any)["toastty-mobile-readonly-interaction"]
        XCTAssertTrue(conversationTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(readOnlyInteraction.exists)
        XCTAssertTrue(app.staticTexts["Respond on the desktop"].exists)
        XCTAssertFalse(app.buttons["Approve"].exists)
        XCTAssertFalse(app.buttons["Deny"].exists)

        app.buttons["toastty-mobile-conversation-close"].tap()
        XCTAssertTrue(home.waitForExistence(timeout: 5))
    }
}
