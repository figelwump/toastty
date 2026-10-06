import AppKit
@testable import ToasttyApp
import XCTest

@MainActor
final class BrowserAnnotationCommentInputViewTests: XCTestCase {
    // A popover keeps its first responder while its key status moves to the
    // main window. Exercise that transition without activating the test host.
    func testApplicationReturnPreservesTextAndSelectionForContinuedTyping() {
        let fixture = makeFixture()
        defer { fixture.close() }
        fixture.editor.string = "before middle after"
        fixture.editor.setSelectedRange(NSRange(location: 7, length: 6))

        fixture.editor.captureFocusBeforeApplicationDeactivation()
        fixture.editorWindow.forcedIsKeyWindow = false
        fixture.editor.restoreFocusAfterApplicationActivation(
            keyWindow: fixture.parentWindow,
            modalWindow: nil,
            activatingEvent: nil
        )

        XCTAssertEqual(fixture.editorWindow.makeKeyCount, 1)
        XCTAssertTrue(fixture.editorWindow.firstResponder === fixture.editor)
        XCTAssertEqual(fixture.editor.string, "before middle after")
        XCTAssertEqual(fixture.editor.selectedRange(), NSRange(location: 7, length: 6))
        fixture.editor.insertText("CHECK", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(fixture.editor.string, "before CHECK after")

        // An old activation notification must not reclaim focus a second time.
        fixture.editorWindow.forcedIsKeyWindow = false
        fixture.editor.restoreFocusAfterApplicationActivation(
            keyWindow: fixture.parentWindow, modalWindow: nil, activatingEvent: nil
        )
        XCTAssertEqual(fixture.editorWindow.makeKeyCount, 1)
    }

    func testInactiveEditorDoesNotReclaimFocus() {
        let fixture = makeFixture()
        defer { fixture.close() }
        fixture.editorWindow.forcedIsKeyWindow = false
        fixture.editor.captureFocusBeforeApplicationDeactivation()
        fixture.editor.restoreFocusAfterApplicationActivation(
            keyWindow: fixture.parentWindow, modalWindow: nil, activatingEvent: nil
        )
        XCTAssertEqual(fixture.editorWindow.makeKeyCount, 0)
    }

    func testDifferentResponderInEditorWindowDoesNotReclaimFocus() {
        let fixture = makeFixture()
        defer { fixture.close() }
        fixture.editorWindow.makeFirstResponder(nil)
        fixture.editor.captureFocusBeforeApplicationDeactivation()
        fixture.editor.restoreFocusAfterApplicationActivation(
            keyWindow: fixture.parentWindow, modalWindow: nil, activatingEvent: nil
        )
        XCTAssertEqual(fixture.editorWindow.makeKeyCount, 0)
    }

    func testClosedOrRemovedEditorDoesNotReclaimFocus() {
        for removeEditor in [false, true] {
            let fixture = makeFixture()
            defer { fixture.close() }
            fixture.editor.captureFocusBeforeApplicationDeactivation()
            if removeEditor {
                fixture.editor.removeFromSuperview()
            } else {
                fixture.editorWindow.forcedIsVisible = false
            }
            fixture.editor.restoreFocusAfterApplicationActivation(
                keyWindow: fixture.parentWindow, modalWindow: nil, activatingEvent: nil
            )
            XCTAssertEqual(fixture.editorWindow.makeKeyCount, 0)
        }
    }

    func testAnotherWindowOrModalDoesNotLoseFocus() {
        for isModal in [false, true] {
            let fixture = makeFixture()
            defer { fixture.close() }
            let otherWindow = AnnotationFocusTestWindow()
            defer { otherWindow.close() }
            fixture.editor.captureFocusBeforeApplicationDeactivation()
            fixture.editor.restoreFocusAfterApplicationActivation(
                keyWindow: isModal ? fixture.parentWindow : otherWindow,
                modalWindow: isModal ? otherWindow : nil,
                activatingEvent: nil
            )
            XCTAssertEqual(fixture.editorWindow.makeKeyCount, 0)
        }
    }

    func testClickToActivateParentKeepsItsFocus() throws {
        let fixture = makeFixture()
        defer { fixture.close() }
        fixture.editor.captureFocusBeforeApplicationDeactivation()
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: fixture.parentWindow.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        XCTAssertTrue(click.window === fixture.parentWindow)
        fixture.editor.restoreFocusAfterApplicationActivation(
            keyWindow: fixture.parentWindow, modalWindow: nil, activatingEvent: click
        )
        XCTAssertEqual(fixture.editorWindow.makeKeyCount, 0)
    }

    func testMouseDownBeforeActivationEventKeepsClickedWindowFocus() {
        let fixture = makeFixture()
        defer { fixture.close() }
        fixture.editor.captureFocusBeforeApplicationDeactivation()
        fixture.editor.restoreFocusAfterApplicationActivation(
            keyWindow: fixture.parentWindow,
            modalWindow: nil,
            activatingEvent: nil,
            mouseDownWindowNumber: fixture.parentWindow.windowNumber
        )
        XCTAssertEqual(fixture.editorWindow.makeKeyCount, 0)
    }

    func testClickInEditorAndStaleClickAllowRestoration() throws {
        for clickInEditor in [false, true] {
            let fixture = makeFixture()
            defer { fixture.close() }
            fixture.editor.captureFocusBeforeApplicationDeactivation()
            let clickedWindow = clickInEditor ? fixture.editorWindow : fixture.parentWindow
            let click = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [],
                timestamp: clickInEditor ? ProcessInfo.processInfo.systemUptime : 0,
                windowNumber: clickedWindow.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1
            ))
            XCTAssertTrue(click.window === clickedWindow)
            fixture.editor.restoreFocusAfterApplicationActivation(
                keyWindow: fixture.parentWindow,
                modalWindow: nil,
                activatingEvent: click,
                mouseDownWindowNumber: clickInEditor ? clickedWindow.windowNumber : nil
            )
            XCTAssertEqual(fixture.editorWindow.makeKeyCount, 1)
        }
    }

    func testApplicationNotificationsRestoreOnceAndStopAfterRemoval() {
        let fixture = makeFixture()
        defer { fixture.close() }
        // The real app may already have a key window in the test host. Use it
        // as the editor's owner so notification wiring can be tested without
        // changing system focus.
        fixture.editor.parentWindow = NSApp.keyWindow ?? fixture.parentWindow
        let center = NotificationCenter.default
        center.post(name: NSApplication.willResignActiveNotification, object: NSApp)
        fixture.editorWindow.forcedIsKeyWindow = false
        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertEqual(fixture.editorWindow.makeKeyCount, 1)
        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertEqual(fixture.editorWindow.makeKeyCount, 1)

        fixture.editorWindow.forcedIsKeyWindow = true
        center.post(name: NSApplication.willResignActiveNotification, object: NSApp)
        fixture.editor.removeFromSuperview()
        center.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertEqual(fixture.editorWindow.makeKeyCount, 1)
    }

    func testDetachmentUsesCurrentWindowWithoutResettingSelection() {
        let fixture = makeFixture()
        defer { fixture.close() }
        let detachedWindow = AnnotationFocusTestWindow()
        defer { detachedWindow.close() }
        fixture.editor.string = "draft comment"
        fixture.editor.setSelectedRange(NSRange(location: 3, length: 2))
        detachedWindow.contentView?.addSubview(fixture.editor)
        detachedWindow.makeFirstResponder(fixture.editor)
        detachedWindow.forcedIsKeyWindow = true
        fixture.editor.captureFocusBeforeApplicationDeactivation()
        detachedWindow.forcedIsKeyWindow = false
        fixture.parentWindow.forcedIsVisible = false
        fixture.editor.restoreFocusAfterApplicationActivation(
            keyWindow: fixture.parentWindow, modalWindow: nil, activatingEvent: nil
        )
        XCTAssertEqual(fixture.editorWindow.makeKeyCount, 0)
        XCTAssertEqual(detachedWindow.makeKeyCount, 1)
        XCTAssertEqual(fixture.editor.selectedRange(), NSRange(location: 3, length: 2))
    }

    private func makeFixture() -> AnnotationFocusFixture {
        let parentWindow = AnnotationFocusTestWindow()
        let editorWindow = AnnotationFocusTestWindow()
        let editor = BrowserAnnotationCommentInputView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        editor.parentWindow = parentWindow
        editorWindow.contentView?.addSubview(editor)
        XCTAssertTrue(editorWindow.makeFirstResponder(editor))
        editorWindow.forcedIsKeyWindow = true
        return AnnotationFocusFixture(parentWindow: parentWindow, editorWindow: editorWindow, editor: editor)
    }
}

@MainActor
private struct AnnotationFocusFixture {
    let parentWindow: AnnotationFocusTestWindow
    let editorWindow: AnnotationFocusTestWindow
    let editor: BrowserAnnotationCommentInputView

    func close() {
        editor.removeFromSuperview()
        editorWindow.close()
        parentWindow.close()
    }
}

@MainActor
private final class AnnotationFocusTestWindow: NSWindow {
    var forcedIsKeyWindow = false
    var forcedIsVisible = true
    var makeKeyCount = 0

    override var isKeyWindow: Bool { forcedIsKeyWindow }
    override var isVisible: Bool { forcedIsVisible }
    override var canBecomeKey: Bool { true }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                   styleMask: [.titled], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }

    override func makeKey() {
        makeKeyCount += 1
        forcedIsKeyWindow = true
    }
}
