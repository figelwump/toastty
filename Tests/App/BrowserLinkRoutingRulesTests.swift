@testable import ToasttyApp
import AppKit
import Foundation
import WebKit
import XCTest

final class BrowserLinkRoutingRulesTests: XCTestCase {
    func testRegularHTTPLinkNavigatesInPlace() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/docs"))

        XCTAssertEqual(
            BrowserLinkRoutingRules.navigationPolicyDecision(
                url: url,
                navigationType: .linkActivated,
                modifierFlags: [],
                targetFrameIsNil: false
            ),
            .allow
        )
    }

    func testCommandClickHTTPLinkOpensSecondary() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/docs"))

        XCTAssertEqual(
            BrowserLinkRoutingRules.navigationPolicyDecision(
                url: url,
                navigationType: .linkActivated,
                modifierFlags: [.command],
                targetFrameIsNil: false
            ),
            .openSecondary(url)
        )
    }

    func testCustomSchemeLinkOpensSecondary() throws {
        let url = try XCTUnwrap(URL(string: "mailto:test@example.com"))

        XCTAssertEqual(
            BrowserLinkRoutingRules.navigationPolicyDecision(
                url: url,
                navigationType: .linkActivated,
                modifierFlags: [],
                targetFrameIsNil: false
            ),
            .openSecondary(url)
        )
    }

    func testNewWindowLinkStaysOutOfPolicyRouting() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/popup"))

        XCTAssertEqual(
            BrowserLinkRoutingRules.navigationPolicyDecision(
                url: url,
                navigationType: .linkActivated,
                modifierFlags: [.command],
                targetFrameIsNil: true
            ),
            .allow
        )
    }

    func testPopupRoutingOpensDirectNonBlankURL() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/popup"))

        XCTAssertEqual(
            BrowserLinkRoutingRules.popupRoutingDecision(requestURL: url),
            .openSecondary(url)
        )
    }

    func testPopupRoutingAwaitsNilURL() {
        XCTAssertEqual(
            BrowserLinkRoutingRules.popupRoutingDecision(requestURL: nil),
            .awaitCapturedURL
        )
    }

    func testPopupRoutingAwaitsAboutBlankURL() throws {
        let url = try XCTUnwrap(URL(string: "about:blank"))

        XCTAssertEqual(
            BrowserLinkRoutingRules.popupRoutingDecision(requestURL: url),
            .awaitCapturedURL
        )
    }

    func testPopupCaptureURLRejectsBlankURLs() throws {
        XCTAssertNil(BrowserLinkRoutingRules.popupCaptureURL(nil))
        XCTAssertNil(BrowserLinkRoutingRules.popupCaptureURL(URL(string: "about:blank")))
        XCTAssertEqual(
            BrowserLinkRoutingRules.popupCaptureURL(URL(string: "https://example.com/real")),
            URL(string: "https://example.com/real")
        )
    }
}
