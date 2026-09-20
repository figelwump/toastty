import AppKit
import XCTest
@testable import ToasttyApp

@MainActor
final class NavigationMouseInterceptorTests: XCTestCase {
    func testSideButtonsNavigateAndConsumeReleaseEvenAfterWindowOrOverlayChanges() {
        for (button, expected) in [(3, NavigationMouseGestureState.Action.back), (4, .forward)] {
            var gesture = NavigationMouseGestureState()
            XCTAssertEqual(gesture.action(for: .otherMouseDown, button: button, allowsNavigation: true), expected)
            XCTAssertEqual(gesture.action(for: .otherMouseDragged, button: button, allowsNavigation: false), .consume)
            XCTAssertEqual(gesture.action(for: .otherMouseUp, button: button, allowsNavigation: false), .consume)
            XCTAssertEqual(gesture.action(for: .otherMouseUp, button: button, allowsNavigation: true), .passThrough)
        }
    }

    func testBlockedAndOtherMouseButtonsPassThroughWithoutClaimingRelease() {
        var gesture = NavigationMouseGestureState()
        for button in [2, 5, 6] {
            XCTAssertEqual(gesture.action(for: .otherMouseDown, button: button, allowsNavigation: true), .passThrough)
            XCTAssertEqual(gesture.action(for: .otherMouseUp, button: button, allowsNavigation: true), .passThrough)
        }
        XCTAssertEqual(gesture.action(for: .otherMouseDown, button: 3, allowsNavigation: false), .passThrough)
        XCTAssertEqual(gesture.action(for: .otherMouseUp, button: 3, allowsNavigation: true), .passThrough)
    }

    func testRepeatedDownDoesNotNavigateAgainAndDeactivationReleasesOwnership() {
        var gesture = NavigationMouseGestureState()
        XCTAssertEqual(gesture.action(for: .otherMouseDown, button: 3, allowsNavigation: true), .back)
        XCTAssertEqual(gesture.action(for: .otherMouseDown, button: 3, allowsNavigation: true), .consume)
        gesture.reset()
        XCTAssertEqual(gesture.action(for: .otherMouseDragged, button: 3, allowsNavigation: true), .passThrough)
        XCTAssertEqual(gesture.action(for: .otherMouseUp, button: 3, allowsNavigation: true), .passThrough)
        XCTAssertEqual(gesture.action(for: .otherMouseDown, button: 3, allowsNavigation: true), .back)
    }

    func testTwoSideButtonsMaintainIndependentReleaseOwnership() {
        var gesture = NavigationMouseGestureState()
        XCTAssertEqual(gesture.action(for: .otherMouseDown, button: 3, allowsNavigation: true), .back)
        XCTAssertEqual(gesture.action(for: .otherMouseDown, button: 4, allowsNavigation: true), .forward)
        XCTAssertEqual(gesture.action(for: .otherMouseUp, button: 3, allowsNavigation: true), .consume)
        XCTAssertEqual(gesture.action(for: .otherMouseUp, button: 4, allowsNavigation: true), .consume)
    }

    func testNavigationRequiresActiveKeyContentWindowWithoutBlockingPresentation() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let windowID = UUID()
        window.identifier = NSUserInterfaceItemIdentifier(windowID.uuidString)
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        defer {
            window.close()
            other.close()
        }
        func target(keyWindow: NSWindow?, modalWindow: NSWindow? = nil,
                    active: Bool = true, overlay: Bool = false) -> UUID? {
            NavigationMouseInterceptor.navigationWindowID(
                eventWindow: window, keyWindow: keyWindow, modalWindow: modalWindow,
                appIsActive: active, isBlockingOverlayPresented: overlay
            )
        }
        XCTAssertEqual(target(keyWindow: window), windowID)
        XCTAssertNil(target(keyWindow: other))
        XCTAssertNil(target(keyWindow: nil))
        XCTAssertNil(target(keyWindow: window, modalWindow: other))
        XCTAssertNil(target(keyWindow: window, active: false))
        XCTAssertNil(target(keyWindow: window, overlay: true))
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        XCTAssertNil(target(keyWindow: window))
    }
}
