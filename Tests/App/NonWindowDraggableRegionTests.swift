@testable import ToasttyApp
import AppKit
import SwiftUI
import XCTest

final class NonWindowDraggableRegionTests: XCTestCase {
    @MainActor
    func testHostingViewDisablesWindowBackgroundDragging() {
        let view = NonWindowDraggableHostingView(
            rootView: AnyView(Color.clear.frame(width: 96, height: 28))
        )

        XCTAssertFalse(view.mouseDownCanMoveWindow)
    }

    @MainActor
    func testHostingViewSuppressesNestedSafeAreaInsets() {
        let view = NonWindowDraggableHostingView(
            rootView: AnyView(Color.clear.frame(width: 96, height: 28))
        )

        XCTAssertEqual(view.safeAreaInsets.top, 0)
        XCTAssertEqual(view.safeAreaInsets.left, 0)
        XCTAssertEqual(view.safeAreaInsets.bottom, 0)
        XCTAssertEqual(view.safeAreaInsets.right, 0)
    }

    @MainActor
    func testHostingViewUpdatesFittingSizeWhenRootViewChanges() {
        let view = NonWindowDraggableHostingView(
            rootView: AnyView(Color.clear.frame(width: 96, height: 28))
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        let initialSize = view.fittingSize

        view.rootView = AnyView(Color.clear.frame(width: 192, height: 28))
        view.invalidateIntrinsicContentSize()
        view.layoutSubtreeIfNeeded()
        let updatedSize = view.fittingSize

        XCTAssertGreaterThan(updatedSize.width, initialSize.width)
        XCTAssertEqual(updatedSize.height, initialSize.height, accuracy: 0.5)
    }

    @MainActor
    func testHostingViewAcceptsFirstMouseForInactiveWindowDrags() {
        let view = NonWindowDraggableHostingView(
            rootView: AnyView(Color.clear.frame(width: 96, height: 28))
        )

        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    @MainActor
    func testHitTestInsideBoundsReturnsViewWithWindowDragsDisabled() {
        // Mirror the real app window: hidden titlebar, transparent titlebar,
        // full-size content view. This reproduces the path where AppKit asks
        // the hit-tested view whether it can move the window.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false

        let wrappedHost = NonWindowDraggableHostingView(
            rootView: AnyView(
                Color.red
                    .frame(width: 200, height: 32)
                    .accessibilityIdentifier("non-window-draggable.content")
            )
        )
        wrappedHost.frame = NSRect(x: 100, y: 40, width: 200, height: 32)

        // Use a plain NSView container (not NSHostingView) so SwiftUI does
        // not complain about mixing a foreign NSHostingView subview into a
        // SwiftUI-managed hierarchy — and so the hit-test result is the raw
        // AppKit behavior we actually care about here.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        window.contentView = container
        container.addSubview(wrappedHost)
        window.makeKeyAndOrderFront(nil)
        container.layoutSubtreeIfNeeded()

        // Click a few sample points inside the wrapped bounds (corners and
        // center) to make sure every one resolves to a view whose
        // `mouseDownCanMoveWindow` is `false` — which is what AppKit's
        // titlebar drag recognizer consults.
        let samplePoints = [
            NSPoint(x: 101, y: 41),
            NSPoint(x: 299, y: 71),
            NSPoint(x: 200, y: 56),
        ]

        for point in samplePoints {
            let hit = container.hitTest(point)
            XCTAssertNotNil(hit, "expected hit test to return a view at \(point)")
            XCTAssertEqual(
                hit?.mouseDownCanMoveWindow,
                false,
                "hit view at \(point) should refuse to move the window"
            )
        }
    }

    @MainActor
    func testHitTestForwardsToInnerControlSubviewWithDragsAlreadyDisabled() {
        // If the wrapped SwiftUI content hosts a nested NSView that already
        // refuses window drags (e.g., an NSTextField for rename), the inner
        // subview should keep receiving events — do not swallow the hit at
        // the wrapper.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
        let wrappedHost = NonWindowDraggableHostingView(
            rootView: AnyView(Color.clear.frame(width: 200, height: 32))
        )
        wrappedHost.frame = NSRect(x: 0, y: 0, width: 200, height: 32)
        container.addSubview(wrappedHost)

        let innerControl = NSTextField(frame: NSRect(x: 20, y: 6, width: 160, height: 20))
        XCTAssertFalse(innerControl.mouseDownCanMoveWindow)
        wrappedHost.addSubview(innerControl)

        let hit = container.hitTest(NSPoint(x: 100, y: 16))
        XCTAssertIdentical(hit, innerControl)
    }
}
