@testable import ToasttyApp
import AppKit
import CoreState
import XCTest

@MainActor
final class BrowserPanelRuntimeTests: XCTestCase {
    func testNormalizedUserEnteredURLStringPrefixesHTTPSForBareHostname() {
        XCTAssertEqual(
            BrowserPanelRuntime.normalizedUserEnteredURLString("example.com/docs"),
            "https://example.com/docs"
        )
    }

    func testNormalizedUserEnteredURLStringPrefixesHTTPForLocalAddresses() {
        XCTAssertEqual(
            BrowserPanelRuntime.normalizedUserEnteredURLString("localhost:3000"),
            "http://localhost:3000"
        )
        XCTAssertEqual(
            BrowserPanelRuntime.normalizedUserEnteredURLString("127.0.0.1:8080/path"),
            "http://127.0.0.1:8080/path"
        )
    }

    func testNormalizedUserEnteredURLStringDoesNotMangleCustomSchemeLikeInput() {
        XCTAssertEqual(
            BrowserPanelRuntime.normalizedUserEnteredURLString("mailto:test@example.com"),
            "mailto:test@example.com"
        )
        XCTAssertEqual(
            BrowserPanelRuntime.normalizedUserEnteredURLString("obsidian://open?vault=toastty"),
            "obsidian://open?vault=toastty"
        )
    }

    func testDefaultStartPageUsesToasttyCopyWithoutExternalDemoLinks() {
        let html = BrowserPanelRuntime.defaultStartPageHTML

        XCTAssertTrue(html.contains("Toastty Browser"))
        XCTAssertTrue(html.contains("Cmd+L"))
        XCTAssertTrue(html.contains("Cmd+R"))
        XCTAssertFalse(html.contains("example.com"))
        XCTAssertFalse(html.contains("WebKit docs"))
    }

    func testFaviconCandidateURLsResolveRelativeLinksAndAppendRootFallback() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://www.espn.com/nhl/story"))

        let candidateURLs = BrowserPanelRuntime.faviconCandidateURLs(
            linkHrefs: [
                "/apple-touch-icon.png",
                "https://cdn.espn.com/favicon-32.png",
                "/apple-touch-icon.png",
            ],
            pageURL: pageURL
        )

        XCTAssertEqual(
            candidateURLs,
            [
                URL(string: "https://www.espn.com/apple-touch-icon.png"),
                URL(string: "https://cdn.espn.com/favicon-32.png"),
                URL(string: "https://www.espn.com/favicon.ico"),
            ].compactMap { $0 }
        )
    }

    func testFaviconCandidateURLsPreferRegularIconsBeforeMaskIcons() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://www.espn.com/nhl/story"))

        let candidateURLs = BrowserPanelRuntime.faviconCandidateURLs(
            linkReferences: [
                FaviconLinkReference(
                    href: "https://a.espncdn.com/prod/assets/icons/E.svg",
                    rel: "mask-icon"
                ),
                FaviconLinkReference(
                    href: "https://a.espncdn.com/favicon.ico",
                    rel: "shortcut icon"
                ),
                FaviconLinkReference(
                    href: "https://a.espncdn.com/wireless/mw5/r1/images/bookmark-icons-v2/espn-icon-180x180.png",
                    rel: "apple-touch-icon"
                ),
            ],
            pageURL: pageURL
        )

        XCTAssertEqual(
            candidateURLs,
            [
                URL(string: "https://a.espncdn.com/favicon.ico"),
                URL(string: "https://a.espncdn.com/wireless/mw5/r1/images/bookmark-icons-v2/espn-icon-180x180.png"),
                URL(string: "https://www.espn.com/favicon.ico"),
                URL(string: "https://a.espncdn.com/prod/assets/icons/E.svg"),
            ].compactMap { $0 }
        )
    }

    func testFaviconCandidateURLsSkipFallbackForNonHTTPPages() throws {
        let pageURL = try XCTUnwrap(URL(string: "data:text/html,hello"))

        XCTAssertEqual(
            BrowserPanelRuntime.faviconCandidateURLs(
                linkHrefs: [],
                pageURL: pageURL
            ),
            []
        )
    }

    func testLoadUserEnteredURLPublishesPendingDisplayedURLImmediately() {
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )

        XCTAssertTrue(runtime.loadUserEnteredURL("example.com/docs"))
        XCTAssertEqual(
            runtime.navigationState.displayedURLString,
            "https://example.com/docs"
        )
    }

    func testUpdateReattachesImmediatelyAfterDetachWithNewAttachment() async {
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let firstContainer = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let secondContainer = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let webState = WebPanelState(definition: .browser)
        let firstAttachment = PanelHostAttachmentToken.next()
        let secondAttachment = PanelHostAttachmentToken.next()

        runtime.attachHost(to: firstContainer, attachment: firstAttachment)
        runtime.apply(webState: webState)

        XCTAssertEqual(firstContainer.subviews.count, 1)
        XCTAssertEqual(runtime.lifecycleState.attachmentToken, firstAttachment)

        runtime.detachHost(attachment: firstAttachment)
        runtime.attachHost(to: secondContainer, attachment: secondAttachment)
        runtime.apply(webState: webState)

        await Task.yield()

        XCTAssertEqual(firstContainer.subviews.count, 0)
        XCTAssertEqual(secondContainer.subviews.count, 1)
        XCTAssertEqual(runtime.lifecycleState.attachmentToken, secondAttachment)
    }
}
