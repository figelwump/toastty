@testable import ToasttyApp
import AppKit
import CoreState
import XCTest

@MainActor
final class BrowserPanelRuntimeTests: XCTestCase {
    func testUpdateReattachesImmediatelyAfterDetachWithNewAttachment() async {
        let runtime = BrowserPanelRuntime(panelID: UUID()) { _, _, _ in }
        let firstContainer = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let secondContainer = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let webState = WebPanelState(definition: .browser)
        let firstAttachment = PanelHostAttachmentToken.next()
        let secondAttachment = PanelHostAttachmentToken.next()

        runtime.update(
            webState: webState,
            sourceContainer: firstContainer,
            attachment: firstAttachment
        )

        XCTAssertEqual(firstContainer.subviews.count, 1)
        XCTAssertEqual(runtime.lifecycleState.attachmentToken, firstAttachment)

        runtime.detachHost(attachment: firstAttachment)
        runtime.update(
            webState: webState,
            sourceContainer: secondContainer,
            attachment: secondAttachment
        )

        await Task.yield()

        XCTAssertEqual(firstContainer.subviews.count, 0)
        XCTAssertEqual(secondContainer.subviews.count, 1)
        XCTAssertEqual(runtime.lifecycleState.attachmentToken, secondAttachment)
    }
}
