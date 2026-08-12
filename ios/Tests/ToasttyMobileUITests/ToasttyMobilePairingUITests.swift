import UIKit
import XCTest

@MainActor
final class ToasttyMobilePairingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testManualPairingRequiresFullHostnameConfirmationBeforeShowingHome() {
        let app = launchPairingFixture("unpaired")
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-session-unpaired"].waitForExistence(timeout: 10))
        app.buttons["toastty-mobile-session-begin-pairing"].tap()
        XCTAssertTrue(
            app.staticTexts[
                "On your Mac, choose Toastty → Remote Access…, then create a native pairing offer."
            ].exists
        )
        app.buttons["toastty-mobile-pairing-manual"].tap()

        let hostnameField = app.textFields["toastty-mobile-pairing-hostname"]
        let pairingCodeField = app.secureTextFields["toastty-mobile-pairing-code"]
        XCTAssertEqual(hostnameField.label, "Tailscale hostname")
        XCTAssertEqual(pairingCodeField.label, "Pairing code")
        hostnameField.tap()
        hostnameField.typeText("fixture-mac.example.ts.net")
        pairingCodeField.tap()
        pairingCodeField.typeText("2345-6789-ABCD")
        app.buttons["toastty-mobile-pairing-manual-continue"].tap()

        let hostname = app.staticTexts["toastty-mobile-pairing-confirm-hostname"]
        XCTAssertTrue(hostname.waitForExistence(timeout: 5))
        XCTAssertEqual(hostname.label, "Authoritative hostname, fixture-mac.example.ts.net")
        XCTAssertFalse(app.descendants(matching: .any)["toastty-mobile-home"].exists)

        app.buttons["toastty-mobile-pairing-confirm"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-home"].waitForExistence(timeout: 10))
    }

    func testFixtureQRScanConfirmsCanonicalHostnameAndPairs() {
        let app = launchPairingFixture("unpaired")
        app.buttons["toastty-mobile-session-begin-pairing"].tap()
        app.buttons["toastty-mobile-pairing-scan"].tap()

        let scan = app.buttons["toastty-mobile-pairing-fixture-scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        scan.tap()

        let hostname = app.staticTexts["toastty-mobile-pairing-confirm-hostname"]
        XCTAssertTrue(hostname.waitForExistence(timeout: 5))
        XCTAssertEqual(hostname.label, "Authoritative hostname, fixture-mac.example.ts.net")
        app.buttons["toastty-mobile-pairing-confirm"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-home"].waitForExistence(timeout: 10))
    }

    func testCameraDeniedAndUnsupportedOfferManualAlternative() {
        for scenario in ["camera-denied", "scanner-unsupported"] {
            let app = launchPairingFixture(scenario)
            app.buttons["toastty-mobile-session-begin-pairing"].tap()
            app.buttons["toastty-mobile-pairing-scan"].tap()

            let explanationID = scenario == "camera-denied"
                ? "toastty-mobile-pairing-camera-denied"
                : "toastty-mobile-pairing-scanner-unsupported"
            XCTAssertTrue(app.descendants(matching: .any)[explanationID].waitForExistence(timeout: 5))
            let manual = app.buttons["toastty-mobile-pairing-scan-manual"]
            XCTAssertTrue(manual.exists)
            manual.tap()
            XCTAssertTrue(app.textFields["toastty-mobile-pairing-hostname"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.secureTextFields["toastty-mobile-pairing-code"].exists)
            app.terminate()
        }
    }

    func testPairingFailureUsesClassifiedCopyWithoutHostMessage() {
        let app = launchPairingFixture("pairing-failure")
        app.buttons["toastty-mobile-session-begin-pairing"].tap()
        app.buttons["toastty-mobile-pairing-manual"].tap()
        app.textFields["toastty-mobile-pairing-hostname"].tap()
        app.textFields["toastty-mobile-pairing-hostname"].typeText("fixture-mac.example.ts.net")
        app.secureTextFields["toastty-mobile-pairing-code"].tap()
        app.secureTextFields["toastty-mobile-pairing-code"].typeText("2345-6789-ABCD")
        app.buttons["toastty-mobile-pairing-manual-continue"].tap()
        app.buttons["toastty-mobile-pairing-confirm"].tap()

        XCTAssertTrue(app.staticTexts["Pairing offer unavailable"].waitForExistence(timeout: 10))
    }

    func testInactivePairingFixtureRendersPrivacyShield() {
        let app = launchPairingFixture("pairing-privacy")
        XCTAssertTrue(app.descendants(matching: .any)["toastty-mobile-pairing-privacy-shield"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["toastty-mobile-pairing-hostname"].exists)
        XCTAssertFalse(app.secureTextFields["toastty-mobile-pairing-code"].exists)
    }

    func testManualFallbackRemainsReachableAtAccessibilityXXXL() {
        let app = launchPairingFixture(
            "unpaired",
            preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge
        )
        app.buttons["toastty-mobile-session-begin-pairing"].tap()

        XCTAssertTrue(app.buttons["toastty-mobile-pairing-scan"].exists)
        let manual = app.buttons["toastty-mobile-pairing-manual"]
        XCTAssertTrue(manual.exists)
        for _ in 0..<4 where manual.isHittable == false {
            app.swipeUp()
        }
        XCTAssertTrue(manual.isHittable)
        manual.tap()

        XCTAssertTrue(
            app.textFields["toastty-mobile-pairing-hostname"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.secureTextFields["toastty-mobile-pairing-code"].exists)
    }

    private func launchPairingFixture(
        _ scenario: String,
        preferredContentSizeCategory: UIContentSizeCategory? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOASTTY_MOBILE_USE_FIXTURE"] = "1"
        app.launchEnvironment["TOASTTY_MOBILE_FIXTURE_SCENARIO"] = scenario
        if let preferredContentSizeCategory {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName",
                preferredContentSizeCategory.rawValue,
            ]
        }
        app.launch()
        return app
    }
}
