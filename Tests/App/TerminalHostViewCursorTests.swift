import AppKit
@testable import ToasttyApp
import XCTest

#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit

@MainActor
final class TerminalHostViewCursorTests: TerminalHostViewTestCase {
    func testMouseShapeMapsPointerToLinkCursorStyle() {
        let cursorStyle = TerminalHostView.ghosttyMouseCursorStyle(for: GHOSTTY_MOUSE_SHAPE_POINTER)

        XCTAssertEqual(cursorStyle, .link)
    }

    func testMouseShapeMapsTextToHorizontalTextCursorStyle() {
        let cursorStyle = TerminalHostView.ghosttyMouseCursorStyle(for: GHOSTTY_MOUSE_SHAPE_TEXT)

        XCTAssertEqual(cursorStyle, .horizontalText)
    }

    func testMouseShapeReturnsNilForUnknownShape() {
        let cursorStyle = TerminalHostView.ghosttyMouseCursorStyle(
            for: ghostty_action_mouse_shape_e(rawValue: UInt32.max)
        )

        XCTAssertNil(cursorStyle)
    }

    func testSurfaceScrollViewAppliesGhosttyPointerCursorToDocumentCursor() {
        let hostView = TerminalHostView()
        let scrollView = TerminalSurfaceScrollView(terminalHostView: hostView)
        _ = attachToVisibleWindow(scrollView)

        hostView.setGhosttyMouseShape(GHOSTTY_MOUSE_SHAPE_POINTER)

        XCTAssertTrue(scrollView.documentCursor === NSCursor.pointingHand)
    }

    func testSurfaceScrollViewAppliesGhosttyTextCursorToDocumentCursor() {
        let hostView = TerminalHostView()
        let scrollView = TerminalSurfaceScrollView(terminalHostView: hostView)
        _ = attachToVisibleWindow(scrollView)

        hostView.setGhosttyMouseShape(GHOSTTY_MOUSE_SHAPE_TEXT)

        XCTAssertTrue(scrollView.documentCursor === NSCursor.iBeam)
    }

    func testSurfaceScrollViewTracksGhosttyCursorVisibility() {
        let hostView = TerminalHostView()
        let scrollView = TerminalSurfaceScrollView(terminalHostView: hostView)
        _ = attachToVisibleWindow(scrollView)

        hostView.setGhosttyMouseVisibility(GHOSTTY_MOUSE_HIDDEN)
        XCTAssertFalse(scrollView.ghosttyCursorVisible)

        hostView.setGhosttyMouseVisibility(GHOSTTY_MOUSE_VISIBLE)
        XCTAssertTrue(scrollView.ghosttyCursorVisible)
    }

    func testSurfaceScrollViewUsesLinkCursorForMouseOverLinkFallback() {
        let hostView = TerminalHostView()
        let scrollView = TerminalSurfaceScrollView(terminalHostView: hostView)
        _ = attachToVisibleWindow(scrollView)

        hostView.setGhosttyMouseShape(GHOSTTY_MOUSE_SHAPE_TEXT)
        hostView.setGhosttyMouseOverLink("https://example.com")

        XCTAssertTrue(scrollView.documentCursor === NSCursor.pointingHand)
    }

    func testSurfaceScrollViewRestoresBaseCursorWhenMouseOverLinkClears() {
        let hostView = TerminalHostView()
        let scrollView = TerminalSurfaceScrollView(terminalHostView: hostView)
        _ = attachToVisibleWindow(scrollView)

        hostView.setGhosttyMouseShape(GHOSTTY_MOUSE_SHAPE_TEXT)
        hostView.setGhosttyMouseOverLink("https://example.com")
        hostView.setGhosttyMouseOverLink(nil)

        XCTAssertTrue(scrollView.documentCursor === NSCursor.iBeam)
    }

    func testSurfaceScrollViewDoesNotApplyGhosttyPointerCursorWhenAncestorIsTransparent() {
        let hostView = TerminalHostView()
        let scrollView = TerminalSurfaceScrollView(terminalHostView: hostView)
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let ancestor = NSView(frame: contentView.bounds)
        window.forcedOcclusionState = [.visible]
        window.contentView = contentView
        ancestor.alphaValue = 0

        contentView.addSubview(ancestor)
        ancestor.addSubview(scrollView)

        hostView.setGhosttyMouseShape(GHOSTTY_MOUSE_SHAPE_POINTER)

        XCTAssertNil(scrollView.documentCursor)
    }

    func testSurfaceScrollViewRelinquishesCursorWhenPresentationVisibilityTurnsHidden() {
        let hostView = TerminalHostView()
        let scrollView = TerminalSurfaceScrollView(terminalHostView: hostView)
        let window = TestWindow()
        let contentView = NSView(frame: window.frame)
        let ancestor = NSView(frame: contentView.bounds)
        window.forcedOcclusionState = [.visible]
        window.contentView = contentView

        contentView.addSubview(ancestor)
        ancestor.addSubview(scrollView)

        hostView.setGhosttyMouseShape(GHOSTTY_MOUSE_SHAPE_POINTER)
        XCTAssertTrue(scrollView.documentCursor === NSCursor.pointingHand)

        ancestor.alphaValue = 0

        XCTAssertFalse(hostView.synchronizePresentationVisibility(reason: "test_cursor_hidden"))
        XCTAssertNil(scrollView.documentCursor)
    }
}
#endif
