@testable import ToasttyApp
import AppKit
import SwiftUI
import XCTest

@MainActor
final class BrowserAddressTextFieldTests: XCTestCase {
    func testAddressEditingActivationSkipsAlreadyActivePanel() {
        XCTAssertFalse(
            BrowserPanelView.shouldActivatePanelWhenAddressEditingChanges(
                isEditing: true,
                isActivePanel: true
            )
        )
    }

    func testAddressEditingActivationFocusesInactivePanel() {
        XCTAssertTrue(
            BrowserPanelView.shouldActivatePanelWhenAddressEditingChanges(
                isEditing: true,
                isActivePanel: false
            )
        )
        XCTAssertFalse(
            BrowserPanelView.shouldActivatePanelWhenAddressEditingChanges(
                isEditing: false,
                isActivePanel: false
            )
        )
    }

    func testRequestFocusActivatesFieldEditorAndSelectsAllAddressText() {
        var text = "https://example.com/docs"
        let coordinator = BrowserAddressTextField.Coordinator(
            text: Binding(
                get: { text },
                set: { text = $0 }
            ),
            onSubmit: {},
            onCancel: {},
            onEditingChanged: { _ in }
        )
        let window = BrowserAddressTestWindow()
        let textField = BrowserChromeTextField(string: text)

        window.contentView?.addSubview(textField)
        coordinator.requestFocusIfNeeded(requestID: UUID(), in: textField)

        XCTAssertTrue(window.makeFirstResponderCalled)
        XCTAssertEqual(
            window.activeFieldEditor?.selectedRange(),
            NSRange(location: 0, length: text.count)
        )
    }
}

@MainActor
private final class BrowserAddressTestWindow: NSWindow {
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
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        makeFirstResponderCalled = true

        if let textField = responder as? BrowserChromeTextField {
            fieldEditorView.delegate = textField
            fieldEditorView.string = textField.stringValue
            storedFirstResponder = fieldEditorView
            return true
        }

        storedFirstResponder = responder
        return true
    }
}
