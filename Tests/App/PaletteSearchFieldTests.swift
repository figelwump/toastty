@testable import ToasttyApp
import AppKit
import SwiftUI
import XCTest

@MainActor
final class PaletteSearchFieldTests: XCTestCase {
    func testInsertNewlineCallsSubmitHandlerWithoutShift() {
        var text = "package"
        var submitCallCount = 0
        var alternateSubmitCallCount = 0
        let coordinator = PaletteSearchField.Coordinator(
            text: Binding(
                get: { text },
                set: { text = $0 }
            ),
            onMoveUp: {},
            onMoveDown: {},
            onSubmit: {
                submitCallCount += 1
            },
            onAlternateSubmit: {
                alternateSubmitCallCount += 1
            },
            currentEventModifierFlagsProvider: { _ in [] },
            onCancel: {}
        )
        let textField = NSTextField(string: text)
        let textView = NSTextView()

        let handled = coordinator.control(
            textField,
            textView: textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(submitCallCount, 1)
        XCTAssertEqual(alternateSubmitCallCount, 0)
    }

    func testInsertNewlineCallsAlternateSubmitHandlerWithShift() {
        var text = "package"
        var submitCallCount = 0
        var alternateSubmitCallCount = 0
        let coordinator = PaletteSearchField.Coordinator(
            text: Binding(
                get: { text },
                set: { text = $0 }
            ),
            onMoveUp: {},
            onMoveDown: {},
            onSubmit: {
                submitCallCount += 1
            },
            onAlternateSubmit: {
                alternateSubmitCallCount += 1
            },
            currentEventModifierFlagsProvider: { _ in [.shift] },
            onCancel: {}
        )
        let textField = NSTextField(string: text)
        let textView = NSTextView()

        let handled = coordinator.control(
            textField,
            textView: textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(submitCallCount, 0)
        XCTAssertEqual(alternateSubmitCallCount, 1)
    }

    func testInitialFocusPlacesCursorAfterFileModePrefix() {
        var text = "@"
        let coordinator = PaletteSearchField.Coordinator(
            text: Binding(
                get: { text },
                set: { text = $0 }
            ),
            onMoveUp: {},
            onMoveDown: {},
            onSubmit: {},
            onAlternateSubmit: {},
            onCancel: {}
        )
        let window = PaletteSearchTestWindow()
        let textField = PaletteTextField(string: text)

        window.contentView?.addSubview(textField)
        XCTAssertTrue(coordinator.focusAndApplyInitialSelection(in: textField))

        XCTAssertTrue(window.makeFirstResponderCalled)
        XCTAssertEqual(
            window.activeFieldEditor?.selectedRange(),
            NSRange(location: 1, length: 0)
        )
    }

    func testInitialFocusSelectsExistingCommandText() {
        var text = "split"
        let coordinator = PaletteSearchField.Coordinator(
            text: Binding(
                get: { text },
                set: { text = $0 }
            ),
            onMoveUp: {},
            onMoveDown: {},
            onSubmit: {},
            onAlternateSubmit: {},
            onCancel: {}
        )
        let window = PaletteSearchTestWindow()
        let textField = PaletteTextField(string: text)

        window.contentView?.addSubview(textField)
        XCTAssertTrue(coordinator.focusAndApplyInitialSelection(in: textField))

        XCTAssertEqual(
            window.activeFieldEditor?.selectedRange(),
            NSRange(location: 0, length: text.count)
        )
    }
}

@MainActor
private final class PaletteSearchTestWindow: NSWindow {
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

        if let textField = responder as? PaletteTextField {
            fieldEditorView.delegate = textField
            fieldEditorView.string = textField.stringValue
            storedFirstResponder = fieldEditorView
            return true
        }

        storedFirstResponder = responder
        return true
    }
}
