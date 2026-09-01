@testable import ToasttyApp
import AppKit
import CoreState
import WebKit
import XCTest

@MainActor
final class BrowserPanelHostViewTests: XCTestCase {
    func testHistoryContextMenuItemsExposeNavigationState() {
        let webView = FocusAwareWKWebView(
            frame: .zero,
            configuration: WKWebViewConfiguration()
        )

        let items = FocusAwareWKWebView.historyContextMenuItems(
            target: webView,
            canGoBack: true,
            canGoForward: false
        )

        XCTAssertEqual(items.map(\.title), ["Back", "Forward"])
        XCTAssertEqual(
            items.map(\.identifier),
            [
                FocusAwareWKWebView.historyBackMenuItemIdentifier,
                FocusAwareWKWebView.historyForwardMenuItemIdentifier,
            ]
        )
        XCTAssertTrue(items[0].isEnabled)
        XCTAssertFalse(items[1].isEnabled)
        XCTAssertTrue(items.allSatisfy { $0.target === webView })
    }

    func testHistoryContextMenuAugmentationIsOptInAndPreservesExistingItems() {
        let webView = FocusAwareWKWebView(
            frame: .zero,
            configuration: WKWebViewConfiguration()
        )
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: nil, keyEquivalent: "")

        webView.augmentHistoryContextMenu(menu)
        XCTAssertEqual(menu.items.map(\.title), ["Copy"])

        webView.showsHistoryContextMenuItems = true
        webView.augmentHistoryContextMenu(menu)
        webView.augmentHistoryContextMenu(menu)

        XCTAssertEqual(menu.items.map(\.title), ["Copy", "", "Back", "Forward"])
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertFalse(menu.items[2].isEnabled)
        XCTAssertFalse(menu.items[3].isEnabled)
    }

    func testPendingHistoryContextMenuAugmentationOnlyMutatesNextTrackedMenu() {
        let webView = FocusAwareWKWebView(
            frame: .zero,
            configuration: WKWebViewConfiguration()
        )
        webView.showsHistoryContextMenuItems = true
        let firstMenu = NSMenu()
        let secondMenu = NSMenu()

        webView.prepareToAugmentNextContextMenu()
        NotificationCenter.default.post(
            name: NSMenu.didBeginTrackingNotification,
            object: firstMenu
        )
        NotificationCenter.default.post(
            name: NSMenu.didBeginTrackingNotification,
            object: secondMenu
        )

        XCTAssertEqual(firstMenu.items.map(\.title), ["Back", "Forward"])
        XCTAssertTrue(secondMenu.items.isEmpty)
    }

    func testCancelledHistoryContextMenuAugmentationDoesNotMutateLaterMenu() {
        let webView = FocusAwareWKWebView(
            frame: .zero,
            configuration: WKWebViewConfiguration()
        )
        webView.showsHistoryContextMenuItems = true
        let unrelatedMenu = NSMenu()

        webView.prepareToAugmentNextContextMenu()
        webView.cancelPendingContextMenuAugmentation()
        NotificationCenter.default.post(
            name: NSMenu.didBeginTrackingNotification,
            object: unrelatedMenu
        )

        XCTAssertTrue(unrelatedMenu.items.isEmpty)
    }

    func testHistoryContextMenuGestureFromWebContentAugmentsTrackedMenu() {
        let fixture = makeHistoryContextMenuFixture()

        fixture.webView.handleHistoryContextMenuGesture(
            eventType: .rightMouseDown,
            modifierFlags: [],
            eventWindow: fixture.window,
            hitView: fixture.contentView
        )
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: nil, keyEquivalent: "")
        NotificationCenter.default.post(
            name: NSMenu.didBeginTrackingNotification,
            object: menu
        )

        XCTAssertEqual(menu.items.map(\.title), ["Copy", "", "Back", "Forward"])
    }

    func testHistoryContextMenuGestureWaitsForDeferredWebKitMenu() async {
        let fixture = makeHistoryContextMenuFixture()

        fixture.webView.handleHistoryContextMenuGesture(
            eventType: .rightMouseDown,
            modifierFlags: [],
            eventWindow: fixture.window,
            hitView: fixture.contentView
        )
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }

        let menu = NSMenu()
        NotificationCenter.default.post(
            name: NSMenu.didBeginTrackingNotification,
            object: menu
        )

        XCTAssertEqual(menu.items.map(\.title), ["Back", "Forward"])
    }

    func testNewMouseGestureCancelsPendingHistoryContextMenu() {
        let fixture = makeHistoryContextMenuFixture()

        fixture.webView.handleHistoryContextMenuGesture(
            eventType: .rightMouseDown,
            modifierFlags: [],
            eventWindow: fixture.window,
            hitView: fixture.contentView
        )
        fixture.webView.handleHistoryContextMenuGesture(
            eventType: .leftMouseDown,
            modifierFlags: [],
            eventWindow: fixture.window,
            hitView: fixture.contentView
        )

        let unrelatedMenu = NSMenu()
        NotificationCenter.default.post(
            name: NSMenu.didBeginTrackingNotification,
            object: unrelatedMenu
        )

        XCTAssertTrue(unrelatedMenu.items.isEmpty)
    }

    func testRepeatedContextMenuGestureAugmentsMenuOnlyOnce() {
        let fixture = makeHistoryContextMenuFixture()

        fixture.webView.handleHistoryContextMenuGesture(
            eventType: .leftMouseDown,
            modifierFlags: [.control],
            eventWindow: fixture.window,
            hitView: fixture.contentView
        )
        fixture.webView.handleHistoryContextMenuGesture(
            eventType: .rightMouseDown,
            modifierFlags: [.control],
            eventWindow: fixture.window,
            hitView: fixture.contentView
        )

        let menu = NSMenu()
        NotificationCenter.default.post(
            name: NSMenu.didBeginTrackingNotification,
            object: menu
        )

        XCTAssertEqual(menu.items.map(\.title), ["Back", "Forward"])
    }

    func testHistoryContextMenuGestureMatchesRightClickAndControlClickInsideWebView() {
        let fixture = makeHistoryContextMenuFixture()
        let outsideView = NSView(frame: .zero)

        XCTAssertTrue(
            FocusAwareWKWebView.shouldPrepareHistoryContextMenu(
                eventType: .rightMouseDown,
                modifierFlags: [],
                eventWindow: fixture.window,
                webViewWindow: fixture.window,
                hitView: fixture.contentView,
                webView: fixture.webView
            )
        )
        XCTAssertTrue(
            FocusAwareWKWebView.shouldPrepareHistoryContextMenu(
                eventType: .leftMouseDown,
                modifierFlags: [.control],
                eventWindow: fixture.window,
                webViewWindow: fixture.window,
                hitView: fixture.contentView,
                webView: fixture.webView
            )
        )
        XCTAssertFalse(
            FocusAwareWKWebView.shouldPrepareHistoryContextMenu(
                eventType: .leftMouseDown,
                modifierFlags: [],
                eventWindow: fixture.window,
                webViewWindow: fixture.window,
                hitView: fixture.contentView,
                webView: fixture.webView
            )
        )
        XCTAssertFalse(
            FocusAwareWKWebView.shouldPrepareHistoryContextMenu(
                eventType: .rightMouseDown,
                modifierFlags: [],
                eventWindow: fixture.window,
                webViewWindow: fixture.window,
                hitView: outsideView,
                webView: fixture.webView
            )
        )
    }

    func testHistoryContextMenuGestureRejectsAnotherWindow() {
        let fixture = makeHistoryContextMenuFixture()
        let otherWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        XCTAssertFalse(
            FocusAwareWKWebView.shouldPrepareHistoryContextMenu(
                eventType: .rightMouseDown,
                modifierFlags: [],
                eventWindow: otherWindow,
                webViewWindow: fixture.window,
                hitView: fixture.contentView,
                webView: fixture.webView
            )
        )
    }

    private func makeHistoryContextMenuFixture() -> (
        window: NSWindow,
        webView: FocusAwareWKWebView,
        contentView: NSView
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let webView = FocusAwareWKWebView(
            frame: window.contentView?.bounds ?? .zero,
            configuration: WKWebViewConfiguration()
        )
        let contentView = NSView(frame: webView.bounds)
        window.contentView?.addSubview(webView)
        webView.addSubview(contentView)
        webView.showsHistoryContextMenuItems = true
        return (window, webView, contentView)
    }

    func testBrowserRuntimeOptsIntoHistoryContextMenuItems() throws {
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))

        runtime.attachHost(to: container, attachment: PanelHostAttachmentToken.next())

        let webView = try XCTUnwrap(container.subviews.first as? FocusAwareWKWebView)
        XCTAssertTrue(webView.showsHistoryContextMenuItems)
    }

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

    func testRuntimeDetachAndReattachReusesWebViewAndDelegates() async throws {
        let runtime = BrowserPanelRuntime(
            panelID: UUID(),
            metadataDidChange: { _, _, _ in },
            interactionDidRequestFocus: { _ in }
        )
        let firstContainer = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let firstAttachment = PanelHostAttachmentToken.next()
        runtime.attachHost(to: firstContainer, attachment: firstAttachment)
        let webView = try XCTUnwrap(firstContainer.subviews.first as? WKWebView)

        runtime.detachHost(attachment: firstAttachment)
        try await waitForDetachment(of: webView, from: firstContainer)

        XCTAssertNil(webView.superview)
        XCTAssertTrue(firstContainer.subviews.isEmpty)

        let secondContainer = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let secondAttachment = PanelHostAttachmentToken.next()
        runtime.attachHost(to: secondContainer, attachment: secondAttachment)

        XCTAssertTrue(secondContainer.subviews.first === webView)
        XCTAssertEqual(
            ObjectIdentifier(try XCTUnwrap(webView.navigationDelegate as AnyObject?)),
            ObjectIdentifier(runtime)
        )
        XCTAssertEqual(
            ObjectIdentifier(try XCTUnwrap(webView.uiDelegate as AnyObject?)),
            ObjectIdentifier(runtime)
        )
    }

    private func waitForDetachment(of webView: WKWebView, from container: NSView) async throws {
        let deadline = Date().addingTimeInterval(2)

        while webView.superview != nil || !container.subviews.isEmpty {
            guard Date() < deadline else { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
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
