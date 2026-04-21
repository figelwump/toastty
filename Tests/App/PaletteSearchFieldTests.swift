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
}
