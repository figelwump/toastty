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
