import XCTest

/// Drives the system share sheet: Safari shares a page to the Toastty share
/// extension, which must open Toastty's new-session sheet with the link.
@MainActor
final class ToasttyMobileShareSheetUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testSharingAPageFromSafariOpensThePrefilledNewSessionSheet() throws {
        let toastty = XCUIApplication()
        toastty.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        toastty.launch()
        XCTAssertTrue(toastty.descendants(matching: .any)["toastty-mobile-home"].waitForExistence(timeout: 10))

        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.open(try XCTUnwrap(URL(string: "https://example.com/")))
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20))
        XCTAssertTrue(
            safari.descendants(matching: .any)["Example Domain"].waitForExistence(timeout: 30),
            dump(safari, "page")
        )

        try openShareSheet(in: safari)
        let extensionCell = safari.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Toastty"))
            .firstMatch
        XCTAssertTrue(extensionCell.waitForExistence(timeout: 10), dump(safari, "share-sheet"))
        attachScreenshot(named: "share-sheet", of: safari)
        extensionCell.tap()

        let start = toastty.buttons["toastty-mobile-new-session-start"]
        if toastty.wait(for: .runningForeground, timeout: 20) == false {
            attachScreenshot(named: "extension-did-not-open-app", of: safari)
            XCTFail("The extension did not open Toastty. \(dump(safari, "extension"))")
            return
        }
        XCTAssertTrue(start.waitForExistence(timeout: 15), dump(toastty, "toastty"))
        let message = toastty.textViews["toastty-mobile-new-session-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        let text = message.value as? String ?? ""
        XCTAssertTrue(text.contains("https://example.com/"), text)
        attachScreenshot(named: "shared-new-session-sheet", of: toastty)
    }

    /// Safari keeps Share in its toolbar on some layouts and in its More
    /// menu on others.
    private func openShareSheet(in safari: XCUIApplication) throws {
        for identifier in ["ShareButton", "Share"] {
            let share = safari.buttons[identifier].firstMatch
            if share.waitForExistence(timeout: 2), share.isHittable {
                share.tap()
                return
            }
        }
        for identifier in ["MoreMenuButton", "MoreButton", "More"] {
            let more = safari.buttons[identifier].firstMatch
            if more.exists, more.isHittable {
                more.tap()
                let share = safari.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == %@", "Share")).firstMatch
                if share.waitForExistence(timeout: 5) {
                    share.tap()
                    return
                }
            }
        }
        XCTFail("Safari has no Share control. \(dump(safari, "toolbar"))")
    }

    private func dump(_ app: XCUIApplication, _ name: String) -> String {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = "hierarchy-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        return "See attachment hierarchy-\(name)."
    }

    private func attachScreenshot(named name: String, of app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
