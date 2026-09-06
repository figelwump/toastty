import UIKit
import XCTest

@MainActor
final class ToasttyMobileMarkdownUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTablesKeepColumnsAndAllowHorizontalScrolling() {
        let app = openTables()
        let transcript = app.scrollViews["toastty-mobile-transcript"]
        transcript.swipeDown()
        let component = app.staticTexts["Component"]
        let responsibility = app.staticTexts["Responsibility"]
        XCTAssertTrue(component.waitForExistence(timeout: 5))
        XCTAssertTrue(responsibility.exists)
        XCTAssertEqual(component.frame.minY, responsibility.frame.minY, accuracy: 3)
        XCTAssertGreaterThan(responsibility.frame.minX, component.frame.maxX)
        let gateway = app.staticTexts["Gateway"]
        let routes = app.staticTexts["Routes authenticated requests to the correct workspace."]
        XCTAssertEqual(gateway.frame.minY, routes.frame.minY, accuracy: 3)
        XCTAssertEqual(gateway.frame.minX, component.frame.minX, accuracy: 3)
        attach("table-columns", app)
        transcript.swipeUp()
        let wide = app.scrollViews.matching(identifier: "toastty-mobile-markdown-table").element(boundBy: 1)
        XCTAssertTrue(wide.exists)
        wide.swipeLeft()
        XCTAssertTrue(app.staticTexts["Final column is readable."].isHittable)
        attach("table-horizontal-scroll", app)
    }

    func testTablesRemainReadableAtAccessibilityTextSize() {
        let app = openTables(accessibility: true)
        let transcript = app.scrollViews["toastty-mobile-transcript"]
        for _ in 0..<5 where !app.staticTexts["Component"].isHittable { transcript.swipeDown() }
        XCTAssertTrue(app.staticTexts["Component"].isHittable)
        // At AXXXL the table extends below the composer. Swipe within its
        // visible header instead of the offscreen center of its full frame.
        let headerY = app.staticTexts["Component"].frame.midY / app.frame.height
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: headerY))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: headerY))
        for _ in 0..<3 where !app.staticTexts["Responsibility"].isHittable {
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(app.staticTexts["Responsibility"].isHittable)
        attach("table-accessibility-size", app)
    }

    private func openTables(accessibility: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_SCENARIO"] = "transcript-tables"
        if accessibility {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue]
        }
        app.launch()
        let card = app.buttons["toastty-mobile-grouped-card-B1000000-0000-0000-0000-000000000007"]
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-home"].waitForExistence(timeout: 10))
        for _ in 0..<12 where !card.isHittable { app.swipeUp() }
        XCTAssertTrue(card.isHittable)
        card.tap()
        XCTAssertTrue(app.staticTexts["toastty-mobile-conversation-title"].waitForExistence(timeout: 5))
        return app
    }

    private func attach(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
