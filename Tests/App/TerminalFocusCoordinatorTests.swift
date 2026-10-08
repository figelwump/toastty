@testable import ToasttyApp
import AppKit
import XCTest

@MainActor
final class TerminalFocusCoordinatorTests: XCTestCase {
    func testFocusIfPossibleReturnsFalseWhenTargetIsUnavailable() {
        let coordinator = TerminalFocusCoordinator(
            maxAttempts: 1,
            retryDelayNanoseconds: 1,
            isApplicationActive: { true },
            shouldAvoidStealingKeyboardFocus: { false }
        )

        let didFocus = coordinator.focusIfPossible {
            nil
        }

        XCTAssertFalse(didFocus)
    }

    func testFocusIfPossibleReturnsResolvedFocusResult() {
        let coordinator = TerminalFocusCoordinator(
            maxAttempts: 1,
            retryDelayNanoseconds: 1,
            isApplicationActive: { true },
            shouldAvoidStealingKeyboardFocus: { false }
        )
        var focusCalls = 0

        let didFocus = coordinator.focusIfPossible {
            TerminalFocusCoordinator.FocusTarget(
                isReadyForFocus: true,
                focusHostViewIfNeeded: {
                    focusCalls += 1
                    return true
                }
            )
        }

        XCTAssertTrue(didFocus)
        XCTAssertEqual(focusCalls, 1)
    }

    func testScheduleFocusRestoreStopsWhenAvoidingFieldEditor() async {
        let coordinator = TerminalFocusCoordinator(
            maxAttempts: 2,
            retryDelayNanoseconds: 1_000_000,
            isApplicationActive: { true },
            shouldAvoidStealingKeyboardFocus: { true }
        )
        var restoreAttempts = 0

        coordinator.scheduleFocusRestore {
            restoreAttempts += 1
            return false
        }

        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(restoreAttempts, 0)
    }

    func testScheduledFocusRestorePreservesAnnotationTypingUnlessExplicitlyRequested() async {
        for explicitlyFocusTerminal in [false, true] {
            let window = AnnotationEditorFocusTestWindow()
            defer { window.close() }
            let editor = BrowserAnnotationCommentInputView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
            let terminalTarget = AnnotationEditorFocusTestTarget()
            window.contentView?.addSubview(editor)
            window.contentView?.addSubview(terminalTarget)

            // Let the editor's normal initial-focus request finish before
            // selecting text and simulating a later window activation.
            let initialFocus = expectation(description: "initial editor focus")
            DispatchQueue.main.async { initialFocus.fulfill() }
            await fulfillment(of: [initialFocus], timeout: 1)
            XCTAssertTrue(window.firstResponder === editor)
            editor.string = "before middle after"
            editor.setSelectedRange(NSRange(location: 7, length: 6))

            let checkedFocus = expectation(description: "focus restoration completed")
            let coordinator = TerminalFocusCoordinator(
                maxAttempts: 1,
                retryDelayNanoseconds: 1,
                isApplicationActive: { true },
                shouldAvoidStealingKeyboardFocus: {
                    let shouldProtect = TerminalFocusCoordinator.shouldAvoidStealingKeyboardFocus(in: window)
                    if shouldProtect { checkedFocus.fulfill() }
                    return shouldProtect
                }
            )
            coordinator.scheduleFocusRestore(avoidStealingKeyboardFocus: !explicitlyFocusTerminal) {
                let result = window.makeFirstResponder(terminalTarget)
                checkedFocus.fulfill()
                return result
            }
            await fulfillment(of: [checkedFocus], timeout: 1)

            if explicitlyFocusTerminal {
                XCTAssertTrue(window.firstResponder === terminalTarget)
                XCTAssertEqual(editor.string, "before middle after")
            } else {
                XCTAssertTrue(window.firstResponder === editor)
                XCTAssertEqual(editor.selectedRange(), NSRange(location: 7, length: 6))
                (window.firstResponder as? NSTextView)?.insertText(
                    "CHECK", replacementRange: NSRange(location: NSNotFound, length: 0)
                )
                XCTAssertEqual(editor.string, "before CHECK after")
            }
        }
    }

    func testNativePopoverCommentProtectsParentWindowResponder() async throws {
        let parentWindow = AnnotationEditorFocusTestWindow()
        defer { parentWindow.close() }
        let anchor = try XCTUnwrap(parentWindow.contentView)
        parentWindow.orderFront(nil)

        let editor = BrowserAnnotationCommentInputView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        let controller = NSViewController()
        controller.view = editor
        let session = BrowserAnnotationPopoverSession(purpose: .create)
        let popover = session.popover
        popover.contentViewController = controller
        defer { popover.performClose(nil) }
        popover.show(relativeTo: NSRect(x: 10, y: 10, width: 20, height: 20), of: anchor, preferredEdge: .maxY)

        let initialFocus = expectation(description: "popover editor initial focus")
        DispatchQueue.main.async { initialFocus.fulfill() }
        await fulfillment(of: [initialFocus], timeout: 1)

        XCTAssertTrue(popover.isShown)
        let popoverWindow = try XCTUnwrap(editor.window)
        XCTAssertFalse(popoverWindow === parentWindow)
        XCTAssertTrue(popoverWindow.firstResponder === editor)
        // The native popover exposes its editor through the parent window.
        // Automatic terminal restore inspects that parent, not the content window.
        XCTAssertTrue(parentWindow.firstResponder === editor)
        XCTAssertTrue(TerminalFocusCoordinator.shouldAvoidStealingKeyboardFocus(in: parentWindow))
    }

    func testScheduleFocusRestoreRetriesWhenIgnoringFieldEditor() async {
        let coordinator = TerminalFocusCoordinator(
            maxAttempts: 4,
            retryDelayNanoseconds: 1_000_000,
            isApplicationActive: { true },
            shouldAvoidStealingKeyboardFocus: { true }
        )
        let restored = expectation(description: "restored focus")
        var restoreAttempts = 0

        coordinator.scheduleFocusRestore(avoidStealingKeyboardFocus: false) {
            restoreAttempts += 1
            let didRestore = restoreAttempts == 3
            if didRestore {
                restored.fulfill()
            }
            return didRestore
        }

        await fulfillment(of: [restored], timeout: 1.0)
        XCTAssertEqual(restoreAttempts, 3)
    }

    func testScheduleFocusRestoreCancelsPreviousTask() async {
        let coordinator = TerminalFocusCoordinator(
            maxAttempts: 4,
            retryDelayNanoseconds: 50_000_000,
            isApplicationActive: { true },
            shouldAvoidStealingKeyboardFocus: { false }
        )
        let restored = expectation(description: "latest restore request wins")
        var firstRestoreAttempts = 0
        var secondRestoreAttempts = 0

        coordinator.scheduleFocusRestore {
            firstRestoreAttempts += 1
            return false
        }

        try? await Task.sleep(nanoseconds: 5_000_000)

        coordinator.scheduleFocusRestore {
            secondRestoreAttempts += 1
            restored.fulfill()
            return true
        }

        await fulfillment(of: [restored], timeout: 1.0)
        try? await Task.sleep(nanoseconds: 70_000_000)

        XCTAssertLessThanOrEqual(firstRestoreAttempts, 1)
        XCTAssertEqual(secondRestoreAttempts, 1)
    }

    func testShouldAvoidStealingKeyboardFocusReturnsTrueForFieldEditor() {
        let window = FocusProtectionTestWindow()
        let textField = NSTextField(string: "Workspace")

        window.contentView?.addSubview(textField)

        XCTAssertTrue(window.makeFirstResponder(textField))
        XCTAssertTrue(TerminalFocusCoordinator.shouldAvoidStealingKeyboardFocus(in: window))
    }

    func testShouldAvoidStealingKeyboardFocusReturnsFalseForNilWindow() {
        XCTAssertFalse(TerminalFocusCoordinator.shouldAvoidStealingKeyboardFocus(in: nil))
    }

    func testShouldAvoidStealingKeyboardFocusReturnsFalseForNonFieldEditorResponder() {
        let window = FocusProtectionTestWindow()
        let focusTarget = NSView()

        window.contentView?.addSubview(focusTarget)

        XCTAssertTrue(window.makeFirstResponder(focusTarget))
        XCTAssertFalse(TerminalFocusCoordinator.shouldAvoidStealingKeyboardFocus(in: window))
    }

    func testOrdinaryTextViewDoesNotBlockTerminalFocusRestore() {
        let textView = NSTextView()
        XCTAssertFalse(TerminalFocusCoordinator.shouldAvoidStealingKeyboardFocus(firstResponder: textView))
    }
}

@MainActor
private final class AnnotationEditorFocusTestWindow: NSWindow {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                   styleMask: [.titled], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }

    // Keep the real AppKit responder chain without activating a test window.
    override func makeKey() {}
}

@MainActor
private final class AnnotationEditorFocusTestTarget: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private final class FocusProtectionTestWindow: NSWindow {
    private let fieldEditorView = NSTextView()
    private var storedFirstResponder: NSResponder?

    override var firstResponder: NSResponder? {
        storedFirstResponder
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        fieldEditorView.isFieldEditor = true
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let textField = responder as? NSTextField {
            fieldEditorView.string = textField.stringValue
            storedFirstResponder = fieldEditorView
            return true
        }

        storedFirstResponder = responder
        return true
    }
}
