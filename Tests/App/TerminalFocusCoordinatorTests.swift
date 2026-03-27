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
