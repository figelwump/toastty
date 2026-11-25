@testable import ConversationUI
import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain
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

    func testTaskChipFollowsAgentActivityFromTheSessionList() async throws {
        let id = UUID()
        let url = CoordinatorTaskLink.url(taskID: id)
        let source = "See \(CoordinatorTaskLink.markdown(taskID: id, title: "Check the build"))."
        let runID = RemoteProjectionRunID()
        func message(showsActivity: Bool, dynamicTypeSize: DynamicTypeSize = .large) throws -> AnyView {
            let task = RemoteTaskSummary(
                id: id, title: "Check the build", group: .running, showsAgentActivity: showsActivity,
                statusLine: "Merging…", stageTitle: "Running", stageReason: "Merging…", activityAt: Date()
            )
            let snapshot = RemoteSessionListSnapshot(
                projectionRunID: runID, conversations: [], generatedAt: Date(),
                tasks: RemoteTaskBoard(tasks: [task], running: [RemoteTaskBoardEntry(taskID: id)])
            )
            let bytes = try ConversationEventCoding.makeEncoder().encode(RemoteGatewayStreamMessage.sessionList(snapshot))
            let decoded = try GatewayCompatibilityDecoder().decodeStreamMessage(bytes)
            let tasks: RemoteTaskBoard? = if case .sessionList(let snapshot) = decoded { snapshot.tasks } else { nil }
            let board = try MobileTaskBoard(XCTUnwrap(tasks))
            return AnyView(ToasttyMarkdownText(text: source)
                .environment(\.conversationLinkPresenter, ToasttyTaskLinkChips(board: board).presenter)
                .dynamicTypeSize(dynamicTypeSize)
                .frame(width: 280))
        }
        func spinners(in textView: UITextView) -> [ToasttyLayerAnimationUIView] {
            textView.subviews.compactMap { $0 as? ToasttyLayerAnimationUIView }
        }
        let (window, host) = try await host(message(showsActivity: false))
        defer { window.isHidden = true; window.rootViewController = nil }
        let textView = try XCTUnwrap(findTextView(in: host.view) as? ToasttyTranscriptTextView)
        let quietBounds = textView.bounds
        let quietText = textView.text
        XCTAssertTrue(spinners(in: textView).isEmpty)
        XCTAssertTrue(textView.becomeFirstResponder())
        let selection = (textView.text as NSString).range(of: "See")
        textView.selectedRange = selection

        host.rootView = try message(showsActivity: true)
        await settleLayout()
        XCTAssertTrue(findTextView(in: host.view) === textView)
        XCTAssertEqual(textView.bounds, quietBounds)
        XCTAssertEqual(textView.text, quietText)
        XCTAssertEqual(textView.selectedRange, selection)
        let dotIndex = (textView.attributedText.string as NSString).range(of: "●").location
        XCTAssertEqual(textView.attributedText.attribute(.link, at: dotIndex, effectiveRange: nil) as? URL, url)
        let spinner = try XCTUnwrap(spinners(in: textView).first)
        XCTAssertTrue(textView.bounds.contains(spinner.frame))
        XCTAssertEqual(spinner.playingAnimationKeys, [[ToasttyLayerAnimationView.Animation.Property.rotation.rawValue]])

        textView.animatesChipSpinners = false
        textView.layoutIfNeeded()
        XCTAssertEqual(spinners(in: textView).first?.playingAnimationKeys, [[]])

        host.rootView = try message(showsActivity: false)
        await settleLayout()
        XCTAssertTrue(spinners(in: textView).isEmpty)
        XCTAssertEqual(textView.bounds, quietBounds)
        XCTAssertEqual(textView.text, quietText)
        XCTAssertEqual(textView.selectedRange, selection)

        host.rootView = try message(showsActivity: true, dynamicTypeSize: .accessibility5)
        await settleLayout()
        XCTAssertGreaterThan(textView.bounds.height, quietBounds.height)
        let wrappedSpinner = try XCTUnwrap(spinners(in: textView).first)
        XCTAssertTrue(textView.bounds.contains(wrappedSpinner.frame))
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
