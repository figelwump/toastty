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
}
