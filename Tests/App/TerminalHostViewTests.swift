import AppKit
@testable import ToasttyApp
import XCTest

#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit

@MainActor
final class TerminalHostViewTests: XCTestCase {
    func testFlagsChangedReturnsPressForLeftCommandPress() {
        let action = TerminalHostView.ghosttyModifierActionForFlagsChanged(
            keyCode: 0x37,
            modifierFlags: [.command]
        )

        XCTAssertEqual(action?.rawValue, GHOSTTY_ACTION_PRESS.rawValue)
    }

    func testFlagsChangedReturnsReleaseForRightCommandReleaseWhileLeftRemainsHeld() {
        let action = TerminalHostView.ghosttyModifierActionForFlagsChanged(
            keyCode: 0x36,
            modifierFlags: [.command]
        )

        XCTAssertEqual(action?.rawValue, GHOSTTY_ACTION_RELEASE.rawValue)
    }

    func testFlagsChangedReturnsPressForRightShiftPress() {
        let modifierFlags = NSEvent.ModifierFlags(
            rawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICERSHIFTKEYMASK)
        )
        let action = TerminalHostView.ghosttyModifierActionForFlagsChanged(
            keyCode: 0x3C,
            modifierFlags: modifierFlags
        )

        XCTAssertEqual(action?.rawValue, GHOSTTY_ACTION_PRESS.rawValue)
    }

    func testFlagsChangedReturnsNilForNonModifierKeyCode() {
        let action = TerminalHostView.ghosttyModifierActionForFlagsChanged(
            keyCode: 0x24,
            modifierFlags: []
        )

        XCTAssertNil(action)
    }

    func testUnshiftedCodepointSkipsCharacterLookupForFlagsChangedEvents() {
        var providerWasCalled = false

        let codepoint = TerminalHostView.ghosttyUnshiftedCodepoint(eventType: .flagsChanged) {
            providerWasCalled = true
            return "x"
        }

        XCTAssertEqual(codepoint, 0)
        XCTAssertFalse(providerWasCalled)
    }

    func testUnshiftedCodepointUsesFirstScalarForKeyDownEvents() {
        let codepoint = TerminalHostView.ghosttyUnshiftedCodepoint(eventType: .keyDown) {
            "A"
        }

        XCTAssertEqual(codepoint, UnicodeScalar("A").value)
    }

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

        hostView.setGhosttyMouseShape(GHOSTTY_MOUSE_SHAPE_POINTER)

        XCTAssertTrue(scrollView.documentCursor === NSCursor.pointingHand)
    }

    func testSurfaceScrollViewAppliesGhosttyTextCursorToDocumentCursor() {
        let hostView = TerminalHostView()
        let scrollView = TerminalSurfaceScrollView(terminalHostView: hostView)

        hostView.setGhosttyMouseShape(GHOSTTY_MOUSE_SHAPE_TEXT)

        XCTAssertTrue(scrollView.documentCursor === NSCursor.iBeam)
    }

    func testSurfaceScrollViewTracksGhosttyCursorVisibility() {
        let hostView = TerminalHostView()
        let scrollView = TerminalSurfaceScrollView(terminalHostView: hostView)

        hostView.setGhosttyMouseVisibility(GHOSTTY_MOUSE_HIDDEN)
        XCTAssertFalse(scrollView.ghosttyCursorVisible)

        hostView.setGhosttyMouseVisibility(GHOSTTY_MOUSE_VISIBLE)
        XCTAssertTrue(scrollView.ghosttyCursorVisible)
    }

    func testSurfaceScrollViewDisablesNativeScrollbars() {
        let scrollView = TerminalSurfaceScrollView()

        XCTAssertFalse(scrollView.hasVerticalScroller)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
    }

    func testSurfaceScrollViewKeepsDocumentViewSizedToClipViewBounds() {
        let scrollView = TerminalSurfaceScrollView()
        scrollView.frame = CGRect(x: 0, y: 0, width: 160, height: 90)
        scrollView.layoutSubtreeIfNeeded()

        XCTAssertEqual(scrollView.terminalHostView.frame.size, scrollView.contentView.bounds.size)
    }

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
}

private final class TestWindow: NSWindow {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }
}
#endif
