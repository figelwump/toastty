@testable import ToasttyApp
import AppKit
import CoreState
import WebKit
import XCTest

@MainActor
final class LocalDocumentPanelHostViewTests: XCTestCase {
    func testCoordinatorRequestsFocusOnlyWhenPanelBecomesActive() {
        let recorder = ScheduledLocalDocumentFocusRecorder()
        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = LocalDocumentPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )

        coordinator.requestFocusIfNeeded(isActivePanel: false, runtime: runtime)
        coordinator.requestFocusIfNeeded(isActivePanel: true, runtime: runtime)
        coordinator.requestFocusIfNeeded(isActivePanel: true, runtime: runtime)

        XCTAssertEqual(recorder.callbacks.count, 1)

        coordinator.requestFocusIfNeeded(isActivePanel: false, runtime: runtime)
        coordinator.requestFocusIfNeeded(isActivePanel: true, runtime: runtime)

        XCTAssertEqual(recorder.callbacks.count, 2)
    }

    func testCoordinatorDeferredFocusTargetsWebViewAfterAttachment() throws {
        let recorder = ScheduledLocalDocumentFocusRecorder()
        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = LocalDocumentPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )

        coordinator.requestFocusIfNeeded(isActivePanel: true, runtime: runtime)
        XCTAssertEqual(recorder.callbacks.count, 1)

        let window = LocalDocumentFocusTestWindow()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let attachment = PanelHostAttachmentToken.next()
        window.contentView?.addSubview(container)
        runtime.attachHost(to: container, attachment: attachment)

        recorder.callbacks.removeFirst()()

        let webView = try XCTUnwrap(container.subviews.first as? WKWebView)
        XCTAssertTrue(window.makeFirstResponderCalled)
        XCTAssertTrue(window.firstResponder === webView)
    }

    func testCoordinatorDeferredFocusRetriesUntilAttachmentSucceeds() throws {
        let recorder = ScheduledLocalDocumentFocusRecorder()
        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = LocalDocumentPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )

        coordinator.requestFocusIfNeeded(isActivePanel: true, runtime: runtime)
        XCTAssertEqual(recorder.callbacks.count, 1)

        recorder.callbacks.removeFirst()()
        XCTAssertEqual(recorder.callbacks.count, 1)

        let window = LocalDocumentFocusTestWindow()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let attachment = PanelHostAttachmentToken.next()
        window.contentView?.addSubview(container)
        runtime.attachHost(to: container, attachment: attachment)

        recorder.callbacks.removeFirst()()

        let webView = try XCTUnwrap(container.subviews.first as? WKWebView)
        XCTAssertTrue(window.makeFirstResponderCalled)
        XCTAssertTrue(window.firstResponder === webView)
        XCTAssertTrue(recorder.callbacks.isEmpty)
    }

    func testCoordinatorResetCancelsPendingDeferredFocus() throws {
        let recorder = ScheduledLocalDocumentFocusRecorder()
        let runtime = LocalDocumentPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = LocalDocumentPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )

        coordinator.requestFocusIfNeeded(isActivePanel: true, runtime: runtime)
        XCTAssertEqual(recorder.callbacks.count, 1)

        let window = LocalDocumentFocusTestWindow()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let attachment = PanelHostAttachmentToken.next()
        window.contentView?.addSubview(container)
        runtime.attachHost(to: container, attachment: attachment)

        coordinator.reset()
        recorder.callbacks.removeFirst()()

        let webView = try XCTUnwrap(container.subviews.first as? WKWebView)
        XCTAssertFalse(window.makeFirstResponderCalled)
        XCTAssertFalse(window.firstResponder === webView)
    }

    func testShouldRequestWebViewFocusOnlyForInactiveToActiveTransition() {
        XCTAssertFalse(
            LocalDocumentPanelHostView.Coordinator.shouldRequestWebViewFocus(
                previousIsActivePanel: false,
                nextIsActivePanel: false
            )
        )
        XCTAssertTrue(
            LocalDocumentPanelHostView.Coordinator.shouldRequestWebViewFocus(
                previousIsActivePanel: false,
                nextIsActivePanel: true
            )
        )
        XCTAssertFalse(
            LocalDocumentPanelHostView.Coordinator.shouldRequestWebViewFocus(
                previousIsActivePanel: true,
                nextIsActivePanel: true
            )
        )
        XCTAssertFalse(
            LocalDocumentPanelHostView.Coordinator.shouldRequestWebViewFocus(
                previousIsActivePanel: true,
                nextIsActivePanel: false
            )
        )
    }
}

private final class ScheduledLocalDocumentFocusRecorder: @unchecked Sendable {
    var callbacks: [@MainActor @Sendable () -> Void] = []
}

@MainActor
private final class LocalDocumentFocusTestWindow: NSWindow {
    private(set) var makeFirstResponderCalled = false
    private var storedFirstResponder: NSResponder?

    override var firstResponder: NSResponder? {
        storedFirstResponder
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        makeFirstResponderCalled = true
        storedFirstResponder = responder
        return true
    }
}
