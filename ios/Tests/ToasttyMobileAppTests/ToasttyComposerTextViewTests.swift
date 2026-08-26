import UIKit
import XCTest
@testable import ToasttyMobileApp

@MainActor
final class ToasttyComposerTextViewTests: XCTestCase {
    func testHeightGrowsFromOneLineAndStopsAtFiveLines() {
        XCTAssertEqual(
            ToasttyComposerTextView.clampedHeight(
                naturalHeight: 12,
                lineHeight: 20
            ),
            20
        )
        XCTAssertEqual(
            ToasttyComposerTextView.clampedHeight(
                naturalHeight: 63.2,
                lineHeight: 20
            ),
            64
        )
        XCTAssertEqual(
            ToasttyComposerTextView.clampedHeight(
                naturalHeight: 240,
                lineHeight: 20
            ),
            100
        )
    }

    func testProgrammaticTextUpdateClampsSelectionWithoutMovingValidRange() {
        XCTAssertEqual(
            ToasttyComposerTextView.clampedSelection(
                NSRange(location: 3, length: 4),
                utf16Count: 12
            ),
            NSRange(location: 3, length: 4)
        )
        XCTAssertEqual(
            ToasttyComposerTextView.clampedSelection(
                NSRange(location: 9, length: 5),
                utf16Count: 10
            ),
            NSRange(location: 9, length: 1)
        )
        XCTAssertEqual(
            ToasttyComposerTextView.clampedSelection(
                NSRange(location: 9, length: 0),
                utf16Count: 0
            ),
            NSRange(location: 0, length: 0)
        )
    }

    func testRevealSelectionScrollsOverflowingCaretIntoVisibleBounds() {
        let (window, textView) = makeOverflowingTextView()
        XCTAssertTrue(textView.becomeFirstResponder())
        textView.selectedRange = NSRange(location: textView.text.utf16.count, length: 0)

        textView.requestSelectionVisibility()
        textView.layoutIfNeeded()

        let selectionEnd = textView.selectedTextRange?.end
        let caret = selectionEnd.map { textView.caretRect(for: $0) } ?? .null
        XCTAssertGreaterThan(textView.contentOffset.y, 0)
        XCTAssertLessThanOrEqual(
            caret.maxY,
            textView.contentOffset.y + textView.bounds.height + 1
        )
        window.isHidden = true
    }

    func testRevealSelectionDoesNotFightNonemptySelection() {
        let (window, textView) = makeOverflowingTextView()
        XCTAssertTrue(textView.becomeFirstResponder())
        textView.selectedRange = NSRange(location: 0, length: textView.text.utf16.count)
        textView.setContentOffset(.zero, animated: false)

        textView.revealSelection()

        XCTAssertEqual(textView.contentOffset, .zero)
        window.isHidden = true
    }

    func testAccessibilityValueUsesPlaceholderOnlyForEmptyDraft() {
        let textView = ToasttyComposerUIKitTextView()
        textView.placeholder = "Message Codex…"

        XCTAssertEqual(textView.accessibilityValue, "Message Codex…")

        textView.text = "Draft"
        textView.textDidChange()

        XCTAssertEqual(textView.accessibilityValue, "Draft")
    }

    private func makeOverflowingTextView() -> (UIWindow, ToasttyComposerUIKitTextView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 180, height: 300))
        let viewController = UIViewController()
        window.rootViewController = viewController

        let textView = ToasttyComposerUIKitTextView()
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = true
        textView.frame = CGRect(x: 0, y: 0, width: 180, height: 80)
        textView.text = (1 ... 20).map { "Composer line \($0)" }.joined(separator: "\n")
        viewController.view.addSubview(textView)
        window.makeKeyAndVisible()
        textView.layoutIfNeeded()
        return (window, textView)
    }
}
