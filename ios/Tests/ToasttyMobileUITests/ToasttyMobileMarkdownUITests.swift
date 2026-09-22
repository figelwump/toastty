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
        // The scroll view's accessibility frame includes the navigation and
        // composer insets. A default swipe can hit Jump to latest or the
        // composer at large text sizes. Drag through the visible left gutter.
        let profile = app.staticTexts["toastty-mobile-session-execution-profile"]
        let input = app.textViews["toastty-mobile-composer-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertFalse(input.isEnabled)
        XCTAssertFalse(app.buttons["toastty-mobile-attachment-add"].isEnabled)
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-composer-status"].exists)
        XCTAssertFalse(app.staticTexts["Update Toastty on your Mac to attach files."].exists,
                       "An existing composer gate should explain the disabled controls without a second update notice")
        let navigationBar = app.navigationBars.firstMatch
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 5))
        let bottom = min(transcript.frame.maxY, profile.exists ? profile.frame.minY : input.frame.minY) - 20
        let top = max(transcript.frame.minY, navigationBar.frame.maxY) + 20
        XCTAssertGreaterThan(bottom, top, "The transcript must have visible space above the composer")
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let component = app.staticTexts["Component"]
        let jump = app.buttons["toastty-mobile-transcript-jump-latest"]
        func visibleViewport() -> CGRect {
            let unobscuredBottom = jump.exists ? min(bottom, jump.frame.minY - 8) : bottom
            return CGRect(x: transcript.frame.minX, y: top, width: transcript.frame.width,
                          height: max(0, unobscuredBottom - top))
        }
        func visibleHeader() -> CGRect {
            component.exists ? component.frame.intersection(visibleViewport()) : .null
        }
        for _ in 0..<12 {
            let header = visibleHeader()
            if !header.isNull, header.height >= 12 { break }
            let viewport = visibleViewport()
            XCTAssertGreaterThan(viewport.height, 12)
            // Move toward the visible viewport, reversing if a previous drag
            // placed the header below it. Hold at the end to avoid a flick.
            let displacement = component.exists ? viewport.midY - component.frame.midY : bottom - top
            let distance = min(bottom - top, max(12, abs(displacement)))
            let startY = displacement >= 0 ? top : bottom
            let endY = startY + (displacement >= 0 ? distance : -distance)
            let scrollStart = origin.withOffset(CGVector(dx: transcript.frame.minX + 8, dy: startY))
            let scrollEnd = origin.withOffset(CGVector(dx: transcript.frame.minX + 8, dy: endY))
            scrollStart.press(forDuration: 0.1, thenDragTo: scrollEnd,
                              withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        attach("table-header-positioned-accessibility-size", app)
        let header = visibleHeader()
        XCTAssertFalse(header.isNull, "The table header must intersect the unobscured transcript")
        XCTAssertGreaterThanOrEqual(header.height, 12)
        // Accessibility can report a header hittable while its midpoint is
        // behind navigation. Drag within its visible portion, above Jump to latest.
        let startPoint = CGPoint(x: transcript.frame.minX + transcript.frame.width * 0.85, y: header.midY)
        let endPoint = CGPoint(x: transcript.frame.minX + transcript.frame.width * 0.15, y: header.midY)
        XCTAssertTrue(visibleViewport().contains(startPoint))
        XCTAssertTrue(visibleViewport().contains(endPoint))
        let start = origin.withOffset(CGVector(dx: startPoint.x, dy: startPoint.y))
        let end = origin.withOffset(CGVector(dx: endPoint.x, dy: endPoint.y))
        for _ in 0..<3 where !app.staticTexts["Responsibility"].isHittable {
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        let responsibility = app.staticTexts["Responsibility"]
        XCTAssertTrue(responsibility.isHittable)
        XCTAssertFalse(responsibility.frame.intersection(visibleViewport()).isEmpty)
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
