import SwiftUI
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
        XCTAssertEqual(
            ToasttyComposerTextView.maximumHeight(lineHeight: 20.4),
            102
        )
        XCTAssertEqual(
            ToasttyComposerTextView.clampedHeight(
                naturalHeight: 103,
                lineHeight: 20.4
            ),
            102
        )
    }

    func testTwoLineAttachmentCapScrollsLongAccessibilityDraftAndShrinksAfterClear() {
        let (window, textView) = makeTextView()
        textView.font = .preferredFont(
            forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        )
        textView.text = "1\n2\n3\n4\n5\n6"
        textView.textDidChange()
        fitTextViewToContent(textView, maximumVisibleLines: 2)
        let lineHeight = ToasttyComposerTextView.lineFragmentHeight(of: textView)
        XCTAssertEqual(textView.bounds.height, ceil(lineHeight * 2), accuracy: 0.001)
        XCTAssertTrue(textView.isScrollEnabled)

        textView.text = ""
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.textDidChange()
        fitTextViewToContent(textView, maximumVisibleLines: 2)
        XCTAssertEqual(textView.bounds.height, ceil(textView.font!.lineHeight), accuracy: 0.001)
        XCTAssertFalse(textView.isScrollEnabled)
        XCTAssertEqual(textView.contentOffset.y, 0, accuracy: 0.001)
        window.isHidden = true
    }

    func testBackspacingOverflowingAccessibilityDraftClearsBinding() async {
        let (window, textView) = makeTextView()
        defer { window.isHidden = true }
        var draft = ""
        let composer = ToasttyComposerTextView(
            text: Binding(get: { draft }, set: { draft = $0 }),
            isFocused: .constant(true),
            placeholder: "Message Codex…",
            isEnabled: true,
            accessibilityLabel: "Message Codex",
            accessibilityHint: "",
            maximumVisibleLines: 2
        )
        let coordinator = composer.makeCoordinator()
        textView.delegate = coordinator
        textView.font = .preferredFont(
            forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        )
        XCTAssertTrue(textView.becomeFirstResponder())
        let longDraft = "Review these files\n3\n4\n5\n6\nFOX7"
        textView.insertText(longDraft)
        XCTAssertEqual(draft, longDraft)
        fitTextViewToContent(textView, maximumVisibleLines: 2)
        let deferredReveal = expectation(description: "overflow caret layout")
        DispatchQueue.main.async { deferredReveal.fulfill() }
        await fulfillment(of: [deferredReveal])
        textView.requestSelectionVisibility()
        textView.layoutIfNeeded()
        XCTAssertTrue(textView.isScrollEnabled)
        XCTAssertGreaterThan(textView.contentOffset.y, 0)

        for _ in longDraft {
            textView.deleteBackward()
        }

        XCTAssertEqual(textView.text, "")
        XCTAssertEqual(draft, "")
        XCTAssertTrue(textView.isFirstResponder)
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
        XCTAssertTrue(textView.isScrollEnabled)
        XCTAssertGreaterThan(textView.contentOffset.y, 0)
        XCTAssertLessThanOrEqual(
            caret.maxY,
            textView.contentOffset.y + textView.bounds.height + 1
        )
        window.isHidden = true
    }

    func testLineGrowthKeepsNonOverflowingViewportStable() {
        let (window, textView) = makeTextView()
        XCTAssertTrue(textView.becomeFirstResponder())

        for lineCount in 1 ... 5 {
            textView.text = (1 ... lineCount)
                .map(String.init)
                .joined(separator: "\n")
            textView.selectedRange = NSRange(
                location: textView.text.utf16.count,
                length: 0
            )
            textView.textDidChange()
            fitTextViewToContent(textView)
            textView.setContentOffset(CGPoint(x: 0, y: 12), animated: false)
            textView.requestSelectionVisibility()
            textView.layoutIfNeeded()

            XCTAssertFalse(textView.isScrollEnabled, "line count: \(lineCount)")
            XCTAssertEqual(textView.contentOffset.y, 0, accuracy: 0.001)
        }

        window.isHidden = true
    }

    func testFiveLineCapUsesLaidOutTextKitFragmentHeight() {
        let (window, textView) = makeTextView()
        textView.text = "1"
        textView.textDidChange()
        fitTextViewToContent(textView)
        let lineFragmentHeight = ToasttyComposerTextView.lineFragmentHeight(of: textView)

        textView.text = "1\n2\n3\n4\n5"
        textView.textDidChange()
        fitTextViewToContent(textView)

        XCTAssertEqual(
            textView.bounds.height,
            lineFragmentHeight * 5,
            accuracy: 0.001
        )
        XCTAssertFalse(textView.isScrollEnabled)
        window.isHidden = true
    }

    func testRepeatedOverflowLayoutsKeepCaretOffsetStable() {
        let (window, textView) = makeOverflowingTextView()
        XCTAssertTrue(textView.becomeFirstResponder())
        textView.selectedRange = NSRange(location: textView.text.utf16.count, length: 0)
        textView.requestSelectionVisibility()
        textView.layoutIfNeeded()
        let settledOffset = textView.contentOffset.y

        for _ in 0 ..< 5 {
            textView.requestSelectionVisibility()
            textView.requestSelectionVisibility()
            textView.setNeedsLayout()
            textView.layoutIfNeeded()
            XCTAssertEqual(textView.contentOffset.y, settledOffset, accuracy: 0.001)
        }

        window.isHidden = true
    }

    func testSoftWrappedOverflowRevealsCaretAfterEnablingScrolling() async {
        let (window, textView) = makeTextView()
        XCTAssertTrue(textView.becomeFirstResponder())
        textView.text = "alpha beta gamma delta"
        textView.selectedRange = NSRange(location: textView.text.utf16.count, length: 0)
        textView.textDidChange()
        fitTextViewToContent(textView)
        XCTAssertFalse(textView.isScrollEnabled)

        textView.text += String(repeating: "epsilon zeta eta theta ", count: 20)
            + " ZEBRA888"
        textView.selectedRange = NSRange(location: textView.text.utf16.count, length: 0)
        textView.textDidChange()
        textView.requestSelectionVisibility()
        fitTextViewToContent(textView)
        let deferredReveal = expectation(description: "deferred caret reveal")
        DispatchQueue.main.async {
            deferredReveal.fulfill()
        }
        await fulfillment(of: [deferredReveal])

        let selectionEnd = textView.selectedTextRange?.end
        let caret = selectionEnd.map { textView.caretRect(for: $0) } ?? .null
        XCTAssertTrue(textView.isScrollEnabled)
        XCTAssertGreaterThan(textView.contentOffset.y, 0)
        XCTAssertLessThanOrEqual(
            caret.maxY,
            textView.contentOffset.y + textView.bounds.height + 1
        )

        textView.setContentOffset(.zero, animated: false)
        textView.text += String(repeating: " incremental wrapped tail", count: 4)
        textView.selectedRange = NSRange(
            location: textView.text.utf16.count,
            length: 0
        )
        textView.textDidChange()
        textView.requestSelectionVisibility()
        fitTextViewToContent(textView)
        let postChangeReveal = expectation(description: "post-change caret reveal")
        DispatchQueue.main.async {
            postChangeReveal.fulfill()
        }
        await fulfillment(of: [postChangeReveal])

        let updatedSelectionEnd = textView.selectedTextRange?.end
        let updatedCaret = updatedSelectionEnd.map { textView.caretRect(for: $0) } ?? .null
        XCTAssertTrue(textView.isScrollEnabled)
        XCTAssertGreaterThan(textView.contentOffset.y, 0)
        XCTAssertLessThanOrEqual(
            updatedCaret.maxY,
            textView.contentOffset.y + textView.bounds.height + 1
        )
        window.isHidden = true
    }

    func testScrollingNaturalHeightUsesFullTextKitContent() {
        let (window, textView) = makeOverflowingTextView()

        XCTAssertTrue(textView.isScrollEnabled)
        XCTAssertGreaterThan(
            ToasttyComposerTextView.naturalHeight(
                of: textView,
                width: textView.bounds.width
            ),
            textView.bounds.height
        )
        window.isHidden = true
    }

    func testMeasurementForAnotherWidthDoesNotDisableSettledOverflow() {
        let (window, textView) = makeOverflowingTextView()
        XCTAssertTrue(textView.isScrollEnabled)

        textView.updateLayoutMeasurement(
            width: textView.bounds.width * 2,
            naturalHeight: 22,
            fittedHeight: 22,
            maximumHeight: textView.bounds.height
        )
        textView.setNeedsLayout()
        textView.layoutIfNeeded()

        XCTAssertTrue(textView.isScrollEnabled)
        window.isHidden = true
    }

    func testCappedFractionalOverflowUsesLayoutTolerance() {
        let (window, textView) = makeTextView()
        let maximumHeight = ToasttyComposerTextView.maximumHeight(
            lineHeight: ToasttyComposerTextView.lineFragmentHeight(of: textView)
        )
        textView.frame.size.height = maximumHeight

        textView.updateLayoutMeasurement(
            width: textView.bounds.width,
            naturalHeight: maximumHeight + 0.25,
            fittedHeight: maximumHeight,
            maximumHeight: maximumHeight
        )
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        XCTAssertFalse(textView.isScrollEnabled)

        textView.updateLayoutMeasurement(
            width: textView.bounds.width,
            naturalHeight: maximumHeight + 0.75,
            fittedHeight: maximumHeight,
            maximumHeight: maximumHeight
        )
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
        XCTAssertTrue(textView.isScrollEnabled)
        window.isHidden = true
    }

    func testProgrammaticClearLeavesGrowingViewportAtTop() {
        let (window, textView) = makeOverflowingTextView()
        XCTAssertTrue(textView.becomeFirstResponder())
        textView.selectedRange = NSRange(location: textView.text.utf16.count, length: 0)
        textView.requestSelectionVisibility()
        textView.layoutIfNeeded()
        XCTAssertGreaterThan(textView.contentOffset.y, 0)

        textView.text = ""
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.textDidChange()
        fitTextViewToContent(textView)

        XCTAssertFalse(textView.isScrollEnabled)
        XCTAssertEqual(textView.contentOffset.y, 0, accuracy: 0.001)
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
        let (window, textView) = makeTextView()
        textView.text = (1 ... 20).map { "Composer line \($0)" }.joined(separator: "\n")
        textView.textDidChange()
        fitTextViewToContent(textView)
        return (window, textView)
    }

    private func makeTextView() -> (UIWindow, ToasttyComposerUIKitTextView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 180, height: 300))
        let viewController = UIViewController()
        window.rootViewController = viewController

        let textView = ToasttyComposerUIKitTextView()
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.frame = CGRect(x: 0, y: 0, width: 180, height: 20)
        viewController.view.addSubview(textView)
        window.makeKeyAndVisible()
        textView.layoutIfNeeded()
        return (window, textView)
    }

    private func fitTextViewToContent(_ textView: ToasttyComposerUIKitTextView, maximumVisibleLines: Int = 5) {
        let lineHeight = ToasttyComposerTextView.lineFragmentHeight(of: textView)
        let naturalHeight = ToasttyComposerTextView.naturalHeight(
            of: textView,
            width: textView.bounds.width
        )
        let fittedHeight = ToasttyComposerTextView.clampedHeight(
            naturalHeight: naturalHeight,
            lineHeight: lineHeight,
            maximumVisibleLines: maximumVisibleLines
        )
        textView.updateLayoutMeasurement(
            width: textView.bounds.width,
            naturalHeight: naturalHeight,
            fittedHeight: fittedHeight,
            maximumHeight: ToasttyComposerTextView.maximumHeight(lineHeight: lineHeight, maximumVisibleLines: maximumVisibleLines)
        )
        textView.frame.size.height = fittedHeight
        textView.setNeedsLayout()
        textView.layoutIfNeeded()
    }
}
