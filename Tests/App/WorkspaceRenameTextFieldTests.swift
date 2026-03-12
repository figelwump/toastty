@testable import ToasttyApp
import AppKit
import SwiftUI
import XCTest

@MainActor
final class WorkspaceRenameTextFieldTests: XCTestCase {
    func testFocusAndSelectAllActivatesFieldEditorForRenameField() {
        var text = "Planning"
        let coordinator = WorkspaceRenameTextField.Coordinator(
            text: Binding(
                get: { text },
                set: { text = $0 }
            ),
            onSubmit: {},
            onCancel: {}
        )
        let window = WorkspaceRenameTestWindow()
        let textField = WorkspaceRenameTestTextField(string: text)

        window.contentView?.addSubview(textField)

        let didFocus = coordinator.focusAndSelectAll(in: textField)

        XCTAssertTrue(didFocus)
        XCTAssertTrue(window.makeFirstResponderCalled)
        XCTAssertEqual(window.activeFieldEditor?.selectedRange(), NSRange(location: 0, length: text.count))
    }

    func testControlTextDidChangeUpdatesBinding() {
        var text = "Planning"
        let coordinator = WorkspaceRenameTextField.Coordinator(
            text: Binding(
                get: { text },
                set: { text = $0 }
            ),
            onSubmit: {},
            onCancel: {}
        )
        let textField = NSTextField(string: "Infra")

        coordinator.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: textField)
        )

        XCTAssertEqual(text, "Infra")
    }

    func testSynchronizeDisplayedTextSkipsActiveFieldEditor() {
        let coordinator = WorkspaceRenameTextField.Coordinator(
            text: .constant("Planning"),
            onSubmit: {},
            onCancel: {}
        )
        let window = WorkspaceRenameTestWindow()
        let textField = WorkspaceRenameTestTextField(string: "Planning")

        window.contentView?.addSubview(textField)
        XCTAssertTrue(coordinator.focusAndSelectAll(in: textField))

        window.activeFieldEditor?.string = "Infra"
        coordinator.synchronizeDisplayedText(with: "Infra", in: textField)

        XCTAssertEqual(textField.stringValue, "Planning")

        window.clearFirstResponder()
        coordinator.synchronizeDisplayedText(with: "Infra", in: textField)

        XCTAssertEqual(textField.stringValue, "Infra")
    }

    func testInsertNewlineCallsSubmitHandler() {
        var text = "Planning"
        var submitCallCount = 0
        let coordinator = WorkspaceRenameTextField.Coordinator(
            text: Binding(
                get: { text },
                set: { text = $0 }
            ),
            onSubmit: {
                submitCallCount += 1
            },
            onCancel: {}
        )
        let textField = WorkspaceRenameTestTextField(string: text)
        let textView = NSTextView()

        let handled = coordinator.control(
            textField,
            textView: textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(submitCallCount, 1)
    }

    func testCancelOperationCallsCancelHandler() {
        var text = "Planning"
        var cancelCallCount = 0
        let coordinator = WorkspaceRenameTextField.Coordinator(
            text: Binding(
                get: { text },
                set: { text = $0 }
            ),
            onSubmit: {},
            onCancel: {
                cancelCallCount += 1
            }
        )
        let textField = NSTextField(string: text)
        let textView = NSTextView()

        let handled = coordinator.control(
            textField,
            textView: textView,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(cancelCallCount, 1)
    }

    func testDismantleResetsSelectionStateForRepeatedRename() {
        let workspaceID = UUID()
        let coordinator = WorkspaceRenameTextField.Coordinator(
            text: .constant("Planning"),
            onSubmit: {},
            onCancel: {}
        )
        let window = WorkspaceRenameTestWindow()
        let firstField = WorkspaceRenameTestTextField(string: "Planning")

        window.contentView?.addSubview(firstField)
        coordinator.requestInitialSelection(for: workspaceID, in: firstField)
        XCTAssertTrue(window.makeFirstResponderCalled)

        WorkspaceRenameTextField.dismantleNSView(firstField, coordinator: coordinator)

        window.clearFirstResponder()
        window.resetMakeFirstResponderTracking()

        let secondField = WorkspaceRenameTestTextField(string: "Planning")
        window.contentView?.addSubview(secondField)
        coordinator.requestInitialSelection(for: workspaceID, in: secondField)

        XCTAssertTrue(window.makeFirstResponderCalled)
        XCTAssertEqual(window.activeFieldEditor?.selectedRange(), NSRange(location: 0, length: secondField.stringValue.count))
    }
}

@MainActor
private final class WorkspaceRenameTestWindow: NSWindow {
    private(set) var makeFirstResponderCalled = false
    private let fieldEditorView = NSTextView()
    private var storedFirstResponder: NSResponder?

    var activeFieldEditor: NSTextView? {
        storedFirstResponder as? NSTextView
    }

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
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        makeFirstResponderCalled = true

        if let textField = responder as? WorkspaceRenameTestTextField {
            fieldEditorView.delegate = textField
            fieldEditorView.string = textField.stringValue
            storedFirstResponder = fieldEditorView
            return true
        }

        storedFirstResponder = responder
        return true
    }

    func clearFirstResponder() {
        storedFirstResponder = nil
    }

    func resetMakeFirstResponderTracking() {
        makeFirstResponderCalled = false
    }
}

private final class WorkspaceRenameTestTextField: NSTextField, NSTextViewDelegate {}
