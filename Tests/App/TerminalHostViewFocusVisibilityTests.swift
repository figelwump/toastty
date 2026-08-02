import AppKit
@testable import ToasttyApp
import XCTest

#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit

@MainActor
final class TerminalHostViewFocusVisibilityTests: TerminalHostViewTestCase {
    func testHostViewRequestsFirstResponderRestorationWhenAttachedToWindow() {
        let hostView = TerminalHostView()
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        var requestCount = 0

        window.contentView = contentView
        hostView.requestFirstResponderIfNeeded = {
            requestCount += 1
        }

        contentView.addSubview(hostView)

        XCTAssertEqual(requestCount, 1)
    }

    func testHostViewAcceptsFirstMouse() {
        let hostView = TerminalHostView()

        XCTAssertTrue(hostView.acceptsFirstMouse(for: nil))
    }

    func testVisibilityTraceSnapshotReportsTransparentAncestorWhileWindowAttached() {
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let outer = NSView(frame: contentView.bounds)
        let inner = NSView(frame: outer.bounds)
        let hostView = TerminalHostView()
        window.forcedOcclusionState = [.visible]
        window.contentView = contentView
        outer.alphaValue = 0.4
        inner.alphaValue = 0

        contentView.addSubview(outer)
        outer.addSubview(inner)
        inner.addSubview(hostView)

        let snapshot = hostView.visibilityTraceSnapshot()

        XCTAssertTrue(snapshot.hasWindow)
        XCTAssertTrue(snapshot.windowVisible)
        XCTAssertEqual(snapshot.selfAlphaThousandths, 1_000)
        XCTAssertEqual(snapshot.minAncestorAlphaThousandths, 0)
        XCTAssertEqual(snapshot.minChainAlphaThousandths, 0)
        XCTAssertTrue(snapshot.visuallyTransparent)
        XCTAssertTrue(snapshot.logicallyVisibleIgnoringTransparency)
        XCTAssertFalse(snapshot.resolvedVisible)
    }

    func testVisibilityTraceSnapshotTreatsDetachedHostAsOpaqueChain() {
        let hostView = TerminalHostView()

        let snapshot = hostView.visibilityTraceSnapshot()

        XCTAssertEqual(snapshot.selfAlphaThousandths, 1_000)
        XCTAssertEqual(snapshot.minAncestorAlphaThousandths, 1_000)
        XCTAssertEqual(snapshot.minChainAlphaThousandths, 1_000)
        XCTAssertFalse(snapshot.visuallyTransparent)
        XCTAssertFalse(snapshot.resolvedVisible)
    }

    func testMouseDownActivatesPanelBeforeFocusingHostView() throws {
        let hostView = TerminalHostView()
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        var activationCount = 0
        var firstResponderDuringActivation: NSResponder?

        window.contentView = contentView
        contentView.addSubview(hostView)
        hostView.activatePanelIfNeeded = {
            activationCount += 1
            firstResponderDuringActivation = window.firstResponder
            return true
        }

        hostView.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, window: window))

        XCTAssertEqual(activationCount, 1)
        XCTAssertNil(firstResponderDuringActivation)
        XCTAssertTrue(window.firstResponder === hostView)
    }

    func testRightMouseDownActivatesPanelBeforeFocusingHostView() throws {
        let hostView = TerminalHostView()
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        var activationCount = 0
        var firstResponderDuringActivation: NSResponder?

        window.contentView = contentView
        contentView.addSubview(hostView)
        hostView.activatePanelIfNeeded = {
            activationCount += 1
            firstResponderDuringActivation = window.firstResponder
            return true
        }

        hostView.rightMouseDown(with: try makeMouseEvent(type: .rightMouseDown, window: window))

        XCTAssertEqual(activationCount, 1)
        XCTAssertNil(firstResponderDuringActivation)
        XCTAssertTrue(window.firstResponder === hostView)
    }

    func testSynchronizePresentationVisibilityTracksHiddenAncestorTransition() {
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let ancestor = NSView(frame: contentView.bounds)
        let hostView = TerminalHostView()
        window.forcedOcclusionState = [.visible]
        window.contentView = contentView
        ancestor.isHidden = true

        contentView.addSubview(ancestor)
        ancestor.addSubview(hostView)

        XCTAssertFalse(hostView.synchronizePresentationVisibility(reason: "test_hidden_ancestor"))
        XCTAssertFalse(hostView.isEffectivelyVisible)

        ancestor.isHidden = false

        XCTAssertTrue(hostView.synchronizePresentationVisibility(reason: "test_revealed_ancestor"))
        XCTAssertTrue(hostView.isEffectivelyVisible)
    }

    func testSynchronizePresentationVisibilityTracksWindowOcclusionTransition() {
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let hostView = TerminalHostView()
        window.forcedOcclusionState = [.visible]
        window.contentView = contentView
        contentView.addSubview(hostView)

        XCTAssertTrue(hostView.synchronizePresentationVisibility(reason: "test_window_visible"))
        XCTAssertTrue(hostView.isEffectivelyVisible)

        window.forcedOcclusionState = []

        XCTAssertFalse(hostView.synchronizePresentationVisibility(reason: "test_window_hidden"))
        XCTAssertFalse(hostView.isEffectivelyVisible)
    }

    func testSynchronizePresentationVisibilityTreatsTransparentAncestorAsHidden() {
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let ancestor = NSView(frame: contentView.bounds)
        let hostView = TerminalHostView()
        window.forcedOcclusionState = [.visible]
        window.contentView = contentView
        ancestor.alphaValue = 0

        contentView.addSubview(ancestor)
        ancestor.addSubview(hostView)

        XCTAssertFalse(hostView.synchronizePresentationVisibility(reason: "test_transparent_ancestor"))
        XCTAssertFalse(hostView.isEffectivelyVisible)

        ancestor.alphaValue = 1

        XCTAssertTrue(hostView.synchronizePresentationVisibility(reason: "test_opaque_ancestor"))
        XCTAssertTrue(hostView.isEffectivelyVisible)
    }

    func testResolvedGhosttySurfaceFocusStateRequiresActiveKeyFocusedHost() {
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let hostView = TerminalHostView()
        hostView.applicationIsActiveProvider = { true }
        window.forcedOcclusionState = [.visible]
        window.forcedIsKeyWindow = true
        window.contentView = contentView

        contentView.addSubview(hostView)
        _ = hostView.synchronizePresentationVisibility(reason: "test_focus_visible")
        _ = window.makeFirstResponder(hostView)

        XCTAssertTrue(hostView.resolvedGhosttySurfaceFocusState())
    }

    func testResolvedGhosttySurfaceFocusStateReturnsFalseWhenApplicationInactive() {
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let hostView = TerminalHostView()
        hostView.applicationIsActiveProvider = { false }
        window.forcedOcclusionState = [.visible]
        window.forcedIsKeyWindow = true
        window.contentView = contentView

        contentView.addSubview(hostView)
        _ = hostView.synchronizePresentationVisibility(reason: "test_focus_inactive")
        _ = window.makeFirstResponder(hostView)

        XCTAssertFalse(hostView.resolvedGhosttySurfaceFocusState())
    }
}
#endif
