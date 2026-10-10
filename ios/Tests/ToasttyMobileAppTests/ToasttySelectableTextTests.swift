import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import ToasttyMobileApp

@MainActor
final class ToasttySelectableTextTests: XCTestCase {
    func testMarkdownKeepsInlineFormattingAndLinkDestinationsInSelectableText() async throws {
        let source = "Normal **bold** *italic* `value` and [file](docs/mobile-preview.md:12)."
        let content = try XCTUnwrap(ToasttyMarkdownText.blocks(source).first).content
        let (window, host) = try await host(ToasttySelectableText(content).frame(width: 280))
        defer { window.isHidden = true; window.rootViewController = nil }
        let textView = try XCTUnwrap(findTextView(in: host.view))
        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertFalse(textView.isScrollEnabled)
        let text = try XCTUnwrap(textView.attributedText)
        let bold = try XCTUnwrap(text.attribute(.font, at: (text.string as NSString).range(of: "bold").location, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.traitBold))
        let italic = try XCTUnwrap(text.attribute(.font, at: (text.string as NSString).range(of: "italic").location, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(italic.fontDescriptor.symbolicTraits.contains(.traitItalic))
        let codeIndex = (text.string as NSString).range(of: "value").location
        let code = try XCTUnwrap(text.attribute(.font, at: codeIndex, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(code.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        XCTAssertNotNil(text.attribute(.backgroundColor, at: codeIndex, effectiveRange: nil))
        XCTAssertEqual(text.attribute(.link, at: (text.string as NSString).range(of: "file").location, effectiveRange: nil) as? URL,
                       URL(string: "docs/mobile-preview.md:12"))
    }

    func testSelectionSurvivesStreamAppendAndClearsWhenContentIsReplaced() async throws {
        let model = SelectionHarnessModel()
        let (window, host) = try await host(SelectionHarness(model: model))
        defer { window.isHidden = true; window.rootViewController = nil }
        let textView = try XCTUnwrap(findTextView(in: host.view))
        XCTAssertTrue(textView.becomeFirstResponder())
        let selection = (model.text as NSString).range(of: "beta")
        textView.selectedRange = selection
        model.text += " and more streamed text"
        await settleLayout()
        XCTAssertEqual(textView.text, model.text)
        XCTAssertEqual(textView.selectedRange, selection)
        XCTAssertEqual((textView.text as NSString).substring(with: textView.selectedRange), "beta")
        textView.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "beta")
        XCTAssertTrue(UIPasteboard.general.types.allSatisfy { UTType($0)?.conforms(to: .plainText) == true },
                      "Copy must not export dark-theme rich text")
        model.text = "An unrelated replacement"
        await settleLayout()
        XCTAssertEqual(textView.text, model.text)
        XCTAssertEqual(textView.selectedRange.length, 0)
    }

    func testTextWrapsWithoutClippingAndFollowsDynamicType() async throws {
        let content = AttributedString(String(repeating: "alpha beta gamma delta ", count: 10))
        let (window, host) = try await host(ToasttySelectableText(content).frame(width: 200))
        defer { window.isHidden = true; window.rootViewController = nil }
        let textView = try XCTUnwrap(findTextView(in: host.view))
        let height = textView.bounds.height
        let pointSize = try XCTUnwrap(textView.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont).pointSize
        XCTAssertEqual(textView.bounds.width, 200, accuracy: 1)
        XCTAssertGreaterThan(height, pointSize * 2)
        XCTAssertGreaterThanOrEqual(height + 1, textView.sizeThatFits(CGSize(width: 200, height: CGFloat.greatestFiniteMagnitude)).height)
        host.rootView = AnyView(ToasttySelectableText(content).frame(width: 200).dynamicTypeSize(.accessibility5))
        await settleLayout()
        let enlarged = try XCTUnwrap(findTextView(in: host.view))
        let enlargedFont = try XCTUnwrap(enlarged.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertGreaterThan(enlargedFont.pointSize, pointSize)
        XCTAssertGreaterThan(enlarged.bounds.height, height)
    }

    private func host(_ view: some View) async throws -> (UIWindow, UIHostingController<AnyView>) {
        let host = UIHostingController(rootView: AnyView(view))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        await settleLayout()
        return (window, host)
    }

    private func findTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView { return textView }
        return view.subviews.lazy.compactMap { self.findTextView(in: $0) }.first
    }

    private func settleLayout() async {
        try? await Task.sleep(for: .milliseconds(100))
    }
}

@MainActor
@Observable
private final class SelectionHarnessModel {
    var text = "alpha 👋 中文 e\u{301} beta gamma"
}

private struct SelectionHarness: View {
    let model: SelectionHarnessModel

    var body: some View {
        ToasttySelectableText(AttributedString(model.text)).frame(width: 280)
    }
}
