import SwiftUI
import UIKit
import XCTest
@testable import ToasttyMobileApp

@MainActor
final class ToasttyComposerTypingTests: XCTestCase {
    func testComputedStateBindingPreservesCaretAcrossGrowingLines() async throws {
        let prefix = "Here’s another thought taking a step back here what if we used open claw for the coordinator. And the idea is "
        for width: CGFloat in [281, 290, 310] {
            let host = UIHostingController(rootView: ComposerStateTypingHarness(width: width))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            host.view.layoutIfNeeded()
            await settleLayout()
            let textView = try XCTUnwrap(findComposer(in: host.view))
            textView.autocorrectionType = .no
            textView.inlinePredictionType = .no
            XCTAssertTrue(textView.becomeFirstResponder())
            textView.insertText(prefix)
            await settleLayout()
            let initialHeight = textView.bounds.height
            var expected = prefix
            for character in "that this would keep the words in order " {
                textView.insertText(String(character))
                expected.append(character)
                XCTAssertEqual(textView.selectedRange, NSRange(location: expected.utf16.count, length: 0),
                               "Immediately after \(character), width \(width)")
                await settleLayout()
                XCTAssertEqual(textView.text, expected)
                XCTAssertEqual(textView.selectedRange, NSRange(location: expected.utf16.count, length: 0),
                               "After layout for \(character), width \(width)")
            }
            XCTAssertGreaterThan(textView.bounds.height, initialHeight)
        }
    }

    func testIncrementalTypingPreservesInsertionPointAcrossSoftWrapsAndBindingEchoes() async throws {
        let (window, model, textView) = try await makeComposer()
        defer { window.isHidden = true; window.rootViewController = nil }
        let draft = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu "
        var expected = ""
        let initialHeight = textView.bounds.height
        for character in draft {
            textView.insertText(String(character))
            expected.append(character)
            XCTAssertEqual(textView.selectedRange, NSRange(location: expected.utf16.count, length: 0), "Immediately after inserting \(expected)")
            await settleLayout()
            XCTAssertEqual(model.text, expected)
            XCTAssertEqual(textView.text, expected)
            XCTAssertEqual(textView.selectedRange, NSRange(location: expected.utf16.count, length: 0), "After binding/layout echo for \(expected)")
        }
        XCTAssertGreaterThan(textView.bounds.height, initialHeight)
    }

    func testIntentionalMiddleInsertionAndSelectionSurviveBindingUpdates() async throws {
        let (window, model, textView) = try await makeComposer()
        defer { window.isHidden = true; window.rootViewController = nil }
        textView.insertText("alpha beta gamma delta epsilon zeta eta theta")
        await settleLayout()
        textView.selectedRange = NSRange(location: 6, length: 4)
        textView.insertText("middle")
        await settleLayout()
        XCTAssertEqual(textView.text, "alpha middle gamma delta epsilon zeta eta theta")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 12, length: 0))
        model.revision += 1
        await settleLayout()
        XCTAssertEqual(textView.selectedRange, NSRange(location: 12, length: 0))
        textView.insertText(" edit")
        await settleLayout()
        XCTAssertEqual(model.text, "alpha middle edit gamma delta epsilon zeta eta theta")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 17, length: 0))
    }

    func testMarkedTextSurvivesUnrelatedBindingEcho() async throws {
        let (window, model, textView) = try await makeComposer()
        defer { window.isHidden = true; window.rootViewController = nil }
        textView.insertText("alpha beta gamma delta ")
        textView.setMarkedText("composition", selectedRange: NSRange(location: 11, length: 0))
        let expected = textView.text
        let selection = textView.selectedRange
        model.revision += 1
        await settleLayout()
        XCTAssertNotNil(textView.markedTextRange)
        XCTAssertEqual(textView.text, expected)
        XCTAssertEqual(textView.selectedRange, selection)
        textView.unmarkText()
        textView.insertText(" done")
        await settleLayout()
        XCTAssertEqual(model.text, expected! + " done")
    }

    func testPredictionReplacementThatCreatesFirstSoftWrapKeepsFollowingTypingAtEnd() async throws {
        let (window, model, textView) = try await makeComposer()
        defer { window.isHidden = true; window.rootViewController = nil }
        let typo = "wrod"
        let replacement = "extraordinary"
        let font = try XCTUnwrap(textView.font)
        let width = textView.bounds.width
        let prefix = try XCTUnwrap((1...10).map { String(repeating: "word ", count: $0) }.first {
            (($0 + typo) as NSString).size(withAttributes: [.font: font]).width < width - 4
                && (($0 + replacement) as NSString).size(withAttributes: [.font: font]).width > width + 4
        })
        textView.insertText(prefix)
        textView.setMarkedText(typo, selectedRange: NSRange(location: typo.utf16.count, length: 0))
        model.revision += 1
        await settleLayout()
        let originalCaret = textView.caretRect(for: try XCTUnwrap(textView.selectedTextRange).end)
        let firstLineCaret = textView.caretRect(for: textView.beginningOfDocument)
        XCTAssertEqual(originalCaret.minY, firstLineCaret.minY, accuracy: 1)

        // Model acceptance of a longer prediction using the same UITextInput
        // replacement boundary, rather than assigning UITextView.text.
        textView.replace(try XCTUnwrap(textView.markedTextRange), withText: replacement)
        textView.unmarkText()
        model.revision += 1
        await settleLayout()
        let expected = prefix + replacement
        XCTAssertEqual(textView.text, expected)
        XCTAssertEqual(textView.selectedRange, NSRange(location: expected.utf16.count, length: 0))
        let wrappedCaret = textView.caretRect(for: try XCTUnwrap(textView.selectedTextRange).end)
        XCTAssertGreaterThan(wrappedCaret.minY, originalCaret.minY)
        for suffix in [" keeps", " the cursor", " at the end"] {
            textView.insertText(suffix)
            await settleLayout()
        }
        XCTAssertEqual(model.text, expected + " keeps the cursor at the end")
        XCTAssertEqual(textView.selectedRange, NSRange(location: model.text.utf16.count, length: 0))
    }

    func testStaleBindingEchoDuringWrapKeepsCaretAtEnd() async throws {
        let prefix = "Here’s another thought taking a step back here what if we used open claw for the coordinator. And the idea is "
        let model = ComposerStalePublishModel()
        let host = UIHostingController(rootView: ComposerStalePublishHarness(model: model, width: 281))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 360, height: 640)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<40 where findComposer(in: host.view) == nil {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            await settleLayout()
        }
        let textView = try XCTUnwrap(findComposer(in: host.view))
        XCTAssertTrue(textView.becomeFirstResponder())
        await settleLayout()
        textView.insertText(prefix)
        await settleLayout()
        model.holdPublished = true
        textView.insertText("h")
        XCTAssertEqual(textView.text, prefix + "h")
        XCTAssertEqual(model.published, prefix)
        model.poke += 1
        await settleLayout()
        model.holdPublished = false
        model.published = prefix + "h"
        model.poke += 1
        await settleLayout()
        XCTAssertEqual(textView.text, prefix + "h")
        XCTAssertEqual(
            textView.selectedRange,
            NSRange(location: (prefix + "h").utf16.count, length: 0),
            "A stale SwiftUI echo during wrap must keep the caret at the end"
        )
    }

    func testStaleEmptyDraftDoesNotMoveCaretBeforeFirstCharacter() async throws {
        try await assertStaleEchoPreservesEdit(initial: "") { $0.insertText("h") }
    }

    func testStaleDraftDoesNotRestoreDeletedCharacter() async throws {
        try await assertStaleEchoPreservesEdit(initial: "that") { $0.deleteBackward() }
    }

    func testStaleDraftBeforeKeyboardReplacementPreservesTextAndCaret() async throws {
        try await assertStaleEchoPreservesEdit(initial: "teh") { textView in
            textView.selectedRange = NSRange(location: 0, length: 3)
            textView.insertText("the ")
        }
    }

    private func assertStaleEchoPreservesEdit(
        initial: String,
        edit: (ToasttyComposerUIKitTextView) -> Void
    ) async throws {
        let model = ComposerStalePublishModel()
        let host = UIHostingController(rootView: ComposerStalePublishHarness(model: model, width: 281))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 360, height: 640)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<40 where findComposer(in: host.view) == nil {
            host.view.layoutIfNeeded()
            await settleLayout()
        }
        let textView = try XCTUnwrap(findComposer(in: host.view))
        XCTAssertTrue(textView.becomeFirstResponder())
        textView.insertText(initial)
        await settleLayout()
        model.holdPublished = true
        edit(textView)
        let expectedText = try XCTUnwrap(textView.text)
        let expectedSelection = textView.selectedRange
        model.poke += 1
        await settleLayout()
        XCTAssertEqual(textView.text, expectedText, "An old rendered draft must not undo a native edit")
        XCTAssertEqual(textView.selectedRange, expectedSelection)
        model.holdPublished = false
        model.published = expectedText
        model.poke += 1
        await settleLayout()
        XCTAssertEqual(textView.selectedRange, expectedSelection, "The current draft must not leave a stale insertion point")
        textView.insertText("!")
        await settleLayout()
        XCTAssertEqual(model.published, expectedText + "!")
    }

    func testTextDidChangeNotificationRerenderDuringWrap() async throws {
        let prefix = "Here’s another thought taking a step back here what if we used open claw for the coordinator. And the idea is "
        let (window, model, textView) = try await makeComposer(width: 281)
        defer { window.isHidden = true; window.rootViewController = nil }
        textView.insertText(prefix)
        await settleLayout()
        let token = NotificationCenter.default.addObserver(
            forName: UITextView.textDidChangeNotification,
            object: textView,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                model.revision += 1
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        textView.insertText("h")
        await settleLayout()
        textView.insertText("a")
        await settleLayout()
        textView.insertText("t")
        await settleLayout()
        XCTAssertEqual(textView.text, prefix + "hat")
        XCTAssertEqual(
            textView.selectedRange,
            NSRange(location: (prefix + "hat").utf16.count, length: 0)
        )
    }

    func testExplicitClearAndRestoreApplyOnceAndPlaceCaretAtEnd() async throws {
        let (window, model, textView) = try await makeComposer()
        defer { window.isHidden = true; window.rootViewController = nil }
        textView.insertText("send this")
        await settleLayout()
        model.replace(with: "")
        await settleLayout()
        XCTAssertEqual(textView.text, "")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 0))
        model.replace(with: "restored 👩🏽‍💻 draft")
        await settleLayout()
        XCTAssertEqual(textView.text, model.text)
        XCTAssertEqual(textView.selectedRange.location, model.text.utf16.count)
        textView.insertText("!")
        model.revision += 1
        await settleLayout()
        XCTAssertEqual(textView.text, "restored 👩🏽‍💻 draft!")
        XCTAssertEqual(model.text, textView.text)
        XCTAssertTrue(textView.isFirstResponder)
    }

    func testClearPreservesNativeEditMadeBeforeRequestRenders() async throws {
        let (window, model, textView) = try await makeComposer()
        defer { window.isHidden = true; window.rootViewController = nil }
        textView.insertText("sent")
        await settleLayout()
        model.replace(with: "")
        textView.insertText(" newer")
        await settleLayout()
        XCTAssertEqual(textView.text, "sent newer")
        XCTAssertEqual(model.text, textView.text)
        XCTAssertEqual(model.rejectedRevision, 1)
        XCTAssertEqual(textView.selectedRange.location, "sent newer".utf16.count)
    }

    func testReplacementWaitsForCompositionToEndWithoutAnotherRender() async throws {
        let (window, model, textView) = try await makeComposer()
        defer { window.isHidden = true; window.rootViewController = nil }
        textView.setMarkedText("draft", selectedRange: NSRange(location: 5, length: 0))
        await settleLayout()
        model.replace(with: "")
        await settleLayout()
        XCTAssertNotNil(textView.markedTextRange)
        XCTAssertEqual(textView.text, "draft")
        // UIKit may publish a final composition callback before unmarking.
        textView.delegate?.textViewDidChange?(textView)
        XCTAssertEqual(model.text, "draft")
        textView.unmarkText()
        await settleLayout()
        XCTAssertNil(textView.markedTextRange)
        XCTAssertEqual(textView.text, "")
        XCTAssertEqual(model.text, "")
    }

    func testNewerCompositionEditRejectsDeferredReplacement() async throws {
        let (window, model, textView) = try await makeComposer()
        defer { window.isHidden = true; window.rootViewController = nil }
        textView.setMarkedText("draft", selectedRange: NSRange(location: 5, length: 0))
        await settleLayout()
        model.replace(with: "")
        await settleLayout()
        textView.setMarkedText("draft continued", selectedRange: NSRange(location: 15, length: 0))
        textView.unmarkText()
        await settleLayout()
        XCTAssertEqual(textView.text, "draft continued")
        XCTAssertEqual(model.text, textView.text)
        XCTAssertEqual(model.rejectedRevision, 1)
    }

    func testCoalescedClearAndRestorePreservesSelection() async throws {
        let (window, model, textView) = try await makeComposer()
        defer { window.isHidden = true; window.rootViewController = nil }
        textView.insertText("restore me")
        textView.selectedRange = NSRange(location: 3, length: 2)
        await settleLayout()
        model.replace(with: "")
        model.replace(with: "restore me")
        await settleLayout()
        XCTAssertEqual(textView.text, "restore me")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 3, length: 2))
        XCTAssertNil(model.rejectedRevision)
    }

    func testCoalescedClearAndDifferentRecoveryAppliesWithoutNativeEdit() async throws {
        let (window, model, textView) = try await makeComposer()
        defer { window.isHidden = true; window.rootViewController = nil }
        textView.insertText("newly sent")
        await settleLayout()
        model.replace(with: "")
        model.replace(with: "older rejected attachment draft")
        await settleLayout()
        XCTAssertEqual(textView.text, "older rejected attachment draft")
        XCTAssertEqual(model.text, textView.text)
        XCTAssertEqual(textView.selectedRange.location, model.text.utf16.count)
        XCTAssertNil(model.rejectedRevision)
    }

    func testClearPreservesEditEvenWhenTextReturnsToOriginalValue() async throws {
        let (window, model, textView) = try await makeComposer()
        defer { window.isHidden = true; window.rootViewController = nil }
        textView.insertText("sent")
        await settleLayout()
        model.replace(with: "")
        textView.insertText("!")
        textView.deleteBackward()
        await settleLayout()
        XCTAssertEqual(textView.text, "sent")
        XCTAssertEqual(model.text, "sent")
        XCTAssertEqual(model.rejectedRevision, 1)
    }

    func testRemountPreservesNewerDraftAndRejectsUnconsumedClear() async throws {
        let (window, model, oldTextView) = try await makeComposer()
        defer { window.isHidden = true; window.rootViewController = nil }
        oldTextView.insertText("sent")
        await settleLayout()
        model.replace(with: "")
        oldTextView.insertText(" newer")
        model.editorID = UUID()
        await settleLayout()
        let textView = try XCTUnwrap(findComposer(in: try XCTUnwrap(window.rootViewController).view))
        XCTAssertFalse(textView === oldTextView)
        XCTAssertEqual(textView.text, "sent newer")
        XCTAssertEqual(model.text, textView.text)
        XCTAssertEqual(model.rejectedRevision, 1)
    }

    private func makeComposer() async throws -> (UIWindow, ComposerTypingModel, ToasttyComposerUIKitTextView) {
        try await makeComposer(width: 180)
    }

    private func makeComposer(width: CGFloat) async throws -> (UIWindow, ComposerTypingModel, ToasttyComposerUIKitTextView) {
        let model = ComposerTypingModel()
        let host = UIHostingController(rootView: ComposerTypingHarness(model: model, width: width))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: max(320, width + 40), height: 500)
        window.rootViewController = host
        window.makeKeyAndVisible()
        for _ in 0..<40 where findComposer(in: host.view) == nil {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            await settleLayout()
        }
        let textView = try XCTUnwrap(findComposer(in: host.view))
        XCTAssertTrue(textView.becomeFirstResponder())
        await settleLayout()
        return (window, model, textView)
    }

    private func findComposer(in view: UIView) -> ToasttyComposerUIKitTextView? {
        if let textView = view as? ToasttyComposerUIKitTextView { return textView }
        return view.subviews.lazy.compactMap { self.findComposer(in: $0) }.first
    }

    private func settleLayout() async {
        try? await Task.sleep(for: .milliseconds(30))
    }
}

@MainActor
private final class ComposerTypingModel: ObservableObject {
    @Published var text = ""
    @Published var focused = false
    var editRevision: UInt64 = 0
    @Published var revision = 0
    @Published var editorID = UUID()
    @Published var replacement: ToasttyComposerReplacement?
    var rejectedRevision: UInt64?

    func replace(with text: String) {
        replacement = ToasttyComposerReplacement(
            revision: (replacement?.revision ?? 0) + 1, expectedEditRevision: editRevision, text: text
        )
        self.text = text
    }
}

private struct ComposerTypingHarness: View {
    @ObservedObject var model: ComposerTypingModel
    var width: CGFloat = 180
    var body: some View {
        VStack {
            Text("Revision \(model.revision)")
            ToasttyComposerTextView(text: model.text, onTextChange: { text, revision in model.text = text; model.editRevision = revision },
                editRevision: model.editRevision,
                replacement: model.replacement,
                onReplacementCompleted: { result in
                    guard model.replacement?.revision == result.revision else { return }
                    model.text = result.nativeText
                    model.editRevision = result.nativeEditRevision
                    if !result.wasApplied { model.rejectedRevision = result.revision }
                }, isFocused: $model.focused,
                placeholder: "Message", isEnabled: true, accessibilityLabel: "Message", accessibilityHint: "")
                .id(model.editorID)
                .frame(width: width)
        }
    }
}

@MainActor
private final class ComposerStalePublishModel: ObservableObject {
    @Published var published = ""
    @Published var focused = false
    @Published var poke = 0
    var holdPublished = false
}

private struct ComposerStalePublishHarness: View {
    @ObservedObject var model: ComposerStalePublishModel
    let width: CGFloat
    var body: some View {
        VStack {
            Text("poke \(model.poke)")
            ToasttyComposerTextView(
                text: model.published,
                onTextChange: { newValue, _ in
                    if model.holdPublished { return }
                    model.published = newValue
                },
                isFocused: $model.focused,
                placeholder: "Message", isEnabled: true, accessibilityLabel: "Message", accessibilityHint: ""
            )
            .frame(width: width)
        }
    }
}

private struct ComposerStateTypingHarness: View {
    let width: CGFloat
    @State private var drafts = ToasttyComposerDraftState()
    @State private var focused = false
    private let conversationID = UUID()

    var body: some View {
        ToasttyComposerTextView(
            text: drafts.draft(for: conversationID),
            onTextChange: { drafts.updateDraft($0, for: conversationID, editRevision: $1) },
            editRevision: drafts.editRevisions[conversationID, default: 0],
            replacement: drafts.replacements[conversationID],
            onReplacementCompleted: { drafts.completeReplacement($0, for: conversationID) },
            isFocused: $focused,
            placeholder: "Message", isEnabled: true, accessibilityLabel: "Message", accessibilityHint: ""
        )
        .frame(width: width)
    }
}
