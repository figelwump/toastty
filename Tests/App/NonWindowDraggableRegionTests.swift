@testable import ToasttyApp
import AppKit
import SwiftUI
import XCTest

final class NonWindowDraggableRegionTests: XCTestCase {
    @MainActor
    func testContainerViewDisablesWindowBackgroundDragging() {
        let view = NonWindowDraggableContainerView(
            rootView: AnyView(Color.clear.frame(width: 96, height: 28))
        )

        XCTAssertFalse(view.mouseDownCanMoveWindow)
    }

    @MainActor
    func testContainerViewSuppressesNestedSafeAreaInsets() {
        let view = NonWindowDraggableContainerView(
            rootView: AnyView(Color.clear.frame(width: 96, height: 28))
        )

        XCTAssertEqual(view.safeAreaInsets.top, 0)
        XCTAssertEqual(view.safeAreaInsets.left, 0)
        XCTAssertEqual(view.safeAreaInsets.bottom, 0)
        XCTAssertEqual(view.safeAreaInsets.right, 0)
    }

    @MainActor
    func testContainerViewUpdatesFittingSizeWhenRootViewChanges() {
        let view = NonWindowDraggableContainerView(
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
    func testContainerViewAcceptsFirstMouseForInactiveWindowDrags() {
        let view = NonWindowDraggableContainerView(
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

        let wrappedHost = NonWindowDraggableContainerView(
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
        let wrappedHost = NonWindowDraggableContainerView(
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

    @MainActor
    func testHitTestRoutesWindowMovableHelperHitsToHostingView() throws {
        // SwiftUI can put helper views inside the hosting hierarchy whose
        // default AppKit behavior allows window dragging. Route those hits to
        // the hosting view instead of the plain container so SwiftUI gestures
        // still receive the mouse sequence while titlebar movement stays off.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
        let wrappedHost = NonWindowDraggableContainerView(
            rootView: AnyView(
                HStack(spacing: 0) {
                    Color.clear.frame(width: 20)
                    WindowMovableProbeRepresentable()
                        .frame(width: 160, height: 20)
                    Color.clear.frame(width: 20)
                }
                .frame(width: 200, height: 32)
            )
        )
        wrappedHost.frame = NSRect(x: 0, y: 0, width: 200, height: 32)
        container.addSubview(wrappedHost)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        container.layoutSubtreeIfNeeded()

        let hostingView = try XCTUnwrap(findDescendantView(in: wrappedHost, ofType: NonWindowDraggableHostingView.self))
        let helperView = try XCTUnwrap(findDescendantView(in: hostingView, ofType: WindowMovableProbeView.self))
        XCTAssertTrue(helperView.mouseDownCanMoveWindow)

        let hit = container.hitTest(NSPoint(x: 100, y: 16))
        XCTAssertIdentical(hit, hostingView)
        XCTAssertFalse(hit?.mouseDownCanMoveWindow ?? true)
    }

    @MainActor
    func testMountedSwiftUIRegionClaimsHitTestsInsideHiddenTitlebarWindow() throws {
        struct MountedRegionHarness: View {
            var body: some View {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 9)
                    HStack(spacing: 0) {
                        Color.clear.frame(width: 100)
                        NonWindowDraggableRegion {
                            HStack(spacing: 0) {
                                Color.red.frame(width: 72, height: 34)
                                Color.clear.frame(width: 56, height: 34)
                                Button("Tab") {}
                                    .buttonStyle(.plain)
                                    .frame(width: 72, height: 34)
                            }
                            .frame(width: 200, height: 34)
                        }
                        .frame(width: 200, height: 34)
                        Color.clear
                    }
                    .frame(height: 34)
                    Spacer(minLength: 0)
                }
                .frame(width: 400, height: 120)
            }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        let hostingView = NSHostingView(rootView: MountedRegionHarness())
        hostingView.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()

        let region = try XCTUnwrap(findDescendantView(in: hostingView, ofType: NonWindowDraggableContainerView.self))
        let frameView = try XCTUnwrap(hostingView.superview)
        let samplePoints = [
            NSPoint(x: 1, y: 1),
            NSPoint(x: 72, y: 17),
            NSPoint(x: 100, y: 17),
            NSPoint(x: 199, y: 33),
        ]

        for localPoint in samplePoints {
            let windowPoint = region.convert(localPoint, to: nil)
            let hit = frameView.hitTest(frameView.convert(windowPoint, from: nil))
            XCTAssertNotNil(hit, "expected mounted hit test to return a view at \(localPoint)")
            XCTAssertEqual(
                hit?.mouseDownCanMoveWindow,
                false,
                "mounted hit view at \(localPoint) should refuse to move the window"
            )
        }
    }

    @MainActor
    private func findDescendantView<T: NSView>(in root: NSView, ofType viewType: T.Type) -> T? {
        if let matchingView = root as? T {
            return matchingView
        }

        for subview in root.subviews {
            if let matchingView = findDescendantView(in: subview, ofType: viewType) {
                return matchingView
            }
        }

        return nil
    }
}

private struct WindowMovableProbeRepresentable: NSViewRepresentable {
    func makeNSView(context _: Context) -> WindowMovableProbeView {
        WindowMovableProbeView(frame: .zero)
    }

    func updateNSView(_: WindowMovableProbeView, context _: Context) {}
}

private final class WindowMovableProbeView: NSView {}
