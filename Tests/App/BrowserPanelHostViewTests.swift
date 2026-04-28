@testable import ToasttyApp
import AppKit
import CoreState
import WebKit
import XCTest

@MainActor
final class BrowserPanelHostViewTests: XCTestCase {
    func testCoordinatorDefersBrowserStateApplyUntilScheduledCallbackRuns() {
        let recorder = ScheduledBrowserPanelApplyRecorder()
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = BrowserPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )
        let webState = WebPanelState(definition: .browser, currentURL: "about:blank")

        coordinator.scheduleApply(webState: webState, runtime: runtime)

        XCTAssertEqual(recorder.callbacks.count, 1)
        XCTAssertNil(runtime.navigationState.displayedURLString)

        recorder.callbacks.removeFirst()()

        XCTAssertEqual(runtime.navigationState.displayedURLString, "about:blank")
        XCTAssertEqual(coordinator.lastAppliedWebState, webState)
    }

    func testCoordinatorIgnoresStaleScheduledBrowserStateApply() {
        let recorder = ScheduledBrowserPanelApplyRecorder()
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = BrowserPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )
        let firstState = WebPanelState(definition: .browser, currentURL: "about:blank")
        let secondState = WebPanelState(definition: .browser, currentURL: "https://example.com")

        coordinator.scheduleApply(webState: firstState, runtime: runtime)
        coordinator.scheduleApply(webState: secondState, runtime: runtime)

        XCTAssertEqual(recorder.callbacks.count, 2)

        recorder.callbacks.removeFirst()()
        XCTAssertNil(runtime.navigationState.displayedURLString)

        recorder.callbacks.removeFirst()()

        XCTAssertEqual(runtime.navigationState.displayedURLString, "https://example.com")
        XCTAssertEqual(coordinator.lastAppliedWebState, secondState)
    }

    func testCoordinatorAppliesLatestScheduledBrowserStateWhenUpdatesBounce() {
        let recorder = ScheduledBrowserPanelApplyRecorder()
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = BrowserPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )
        let firstState = WebPanelState(definition: .browser, currentURL: "about:blank")
        let secondState = WebPanelState(definition: .browser, currentURL: "https://example.com")

        coordinator.scheduleApply(webState: firstState, runtime: runtime)
        coordinator.scheduleApply(webState: secondState, runtime: runtime)
        coordinator.scheduleApply(webState: firstState, runtime: runtime)

        XCTAssertEqual(recorder.callbacks.count, 3)

        for callback in recorder.callbacks {
            callback()
        }

        XCTAssertEqual(runtime.navigationState.displayedURLString, "about:blank")
        XCTAssertEqual(coordinator.lastAppliedWebState, firstState)
    }

    func testCoordinatorDoesNotReschedulePendingBrowserState() {
        let recorder = ScheduledBrowserPanelApplyRecorder()
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = BrowserPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )
        let webState = WebPanelState(definition: .browser, currentURL: "about:blank")

        coordinator.scheduleApply(webState: webState, runtime: runtime)
        coordinator.scheduleApply(webState: webState, runtime: runtime)

        XCTAssertEqual(recorder.callbacks.count, 1)
    }

    func testCoordinatorResetPreventsPendingBrowserStateApply() {
        let recorder = ScheduledBrowserPanelApplyRecorder()
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = BrowserPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )
        let webState = WebPanelState(definition: .browser, currentURL: "about:blank")

        coordinator.scheduleApply(webState: webState, runtime: runtime)
        coordinator.reset()

        recorder.callbacks.removeFirst()()

        XCTAssertNil(runtime.navigationState.displayedURLString)
        XCTAssertNil(coordinator.lastAppliedWebState)
    }

    func testCoordinatorDefersWebViewFocusUntilAttachmentSucceeds() throws {
        let recorder = ScheduledBrowserPanelApplyRecorder()
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = BrowserPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )

        coordinator.requestFocusIfNeeded(shouldFocusWebView: true, runtime: runtime)
        XCTAssertEqual(recorder.callbacks.count, 1)

        let window = BrowserFocusTestWindow()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let attachment = PanelHostAttachmentToken.next()
        window.contentView?.addSubview(container)
        runtime.attachHost(to: container, attachment: attachment)

        recorder.callbacks.removeFirst()()

        let webView = try XCTUnwrap(container.subviews.first as? WKWebView)
        XCTAssertTrue(window.makeFirstResponderCalled)
        XCTAssertTrue(window.firstResponder === webView)
    }

    func testCoordinatorDoesNotRefocusWebViewWhileFocusRequestRemainsActive() {
        let recorder = ScheduledBrowserPanelApplyRecorder()
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = BrowserPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )
        let window = BrowserFocusTestWindow()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let attachment = PanelHostAttachmentToken.next()
        window.contentView?.addSubview(container)
        runtime.attachHost(to: container, attachment: attachment)

        coordinator.requestFocusIfNeeded(shouldFocusWebView: true, runtime: runtime)
        XCTAssertEqual(window.makeFirstResponderCallCount, 1)
        XCTAssertTrue(recorder.callbacks.isEmpty)

        coordinator.requestFocusIfNeeded(shouldFocusWebView: true, runtime: runtime)
        XCTAssertEqual(window.makeFirstResponderCallCount, 1)
        XCTAssertTrue(recorder.callbacks.isEmpty)
    }

    func testCoordinatorCancelsDeferredFocusWhenFocusNoLongerRequested() throws {
        let recorder = ScheduledBrowserPanelApplyRecorder()
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let coordinator = BrowserPanelHostView.Coordinator(
            scheduleOnMainActor: { operation in
                recorder.callbacks.append(operation)
            }
        )

        coordinator.requestFocusIfNeeded(shouldFocusWebView: true, runtime: runtime)
        XCTAssertEqual(recorder.callbacks.count, 1)
        coordinator.requestFocusIfNeeded(shouldFocusWebView: false, runtime: runtime)

        let window = BrowserFocusTestWindow()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let attachment = PanelHostAttachmentToken.next()
        window.contentView?.addSubview(container)
        runtime.attachHost(to: container, attachment: attachment)

        recorder.callbacks.removeFirst()()

        let webView = try XCTUnwrap(container.subviews.first as? WKWebView)
        XCTAssertFalse(window.makeFirstResponderCalled)
        XCTAssertFalse(window.firstResponder === webView)
    }

    func testShouldRequestWebViewFocusOnlyForInactiveToActiveTransition() {
        XCTAssertFalse(
            BrowserPanelHostView.Coordinator.shouldRequestWebViewFocus(
                previousShouldFocusWebView: false,
                nextShouldFocusWebView: false
            )
        )
        XCTAssertTrue(
            BrowserPanelHostView.Coordinator.shouldRequestWebViewFocus(
                previousShouldFocusWebView: false,
                nextShouldFocusWebView: true
            )
        )
        XCTAssertFalse(
            BrowserPanelHostView.Coordinator.shouldRequestWebViewFocus(
                previousShouldFocusWebView: true,
                nextShouldFocusWebView: true
            )
        )
        XCTAssertFalse(
            BrowserPanelHostView.Coordinator.shouldRequestWebViewFocus(
                previousShouldFocusWebView: true,
                nextShouldFocusWebView: false
            )
        )
    }
}

private final class ScheduledBrowserPanelApplyRecorder: @unchecked Sendable {
    var callbacks: [@MainActor @Sendable () -> Void] = []
}

@MainActor
private final class BrowserFocusTestWindow: NSWindow {
    private(set) var makeFirstResponderCalled = false
    private(set) var makeFirstResponderCallCount = 0
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
        makeFirstResponderCallCount += 1
        storedFirstResponder = responder
        return true
    }
}
