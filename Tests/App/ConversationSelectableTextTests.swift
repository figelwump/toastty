import AppKit
import Combine
import ConversationUI
import SwiftUI
import XCTest

/// Hosts the public renderer. These tests run in the remote AppTests host;
/// they do not launch or drive an installed Toastty instance.
@MainActor
final class ConversationSelectableTextTests: XCTestCase {
    func testWidthProbesAndResizeKeepVisibleTextWrappedAtItsActualWidth() throws {
        let model = TextModel(text: String(repeating: "alpha beta gamma delta epsilon ", count: 25))
        let harness = Harness(model: model, width: 320)
        defer { harness.close() }
        let textView = try harness.textView()
        try assertLayoutFits(textView, width: 320)
        let narrowHeight = textView.bounds.height

        // The layout probes the ideal width between two identical constrained
        // proposals. A cached answer must not leave the ideal width on screen.
        model.probeRevision += 1
        harness.settle()
        try assertLayoutFits(textView, width: 320)
        XCTAssertEqual(textView.bounds.height, narrowHeight, accuracy: 1)

        harness.resize(width: 640)
        try assertLayoutFits(textView, width: 640)
        XCTAssertLessThan(textView.bounds.height, narrowHeight)
        harness.resize(width: 320)
        model.probeRevision += 1
        harness.settle()
        try assertLayoutFits(textView, width: 320)
        XCTAssertEqual(textView.bounds.height, narrowHeight, accuracy: 1)

        for width in [CGFloat(320.4), CGFloat(319.6)] {
            harness.resize(width: width)
            try assertLayoutFits(textView, width: width)
        }

        harness.resize(width: 320)
        try assertLayoutFits(textView, width: 320)
        let beforeAppendHeight = textView.bounds.height
        model.text += String(repeating: "additional streamed words ", count: 8)
        harness.settle()
        try assertLayoutFits(textView, width: 320)
        XCTAssertGreaterThan(textView.bounds.height, beforeAppendHeight)
        let appendedHeight = textView.bounds.height

        model.text = String(repeating: "Replacement content uses a new prefix. ", count: 9)
        harness.settle()
        try assertLayoutFits(textView, width: 320)
        XCTAssertLessThan(textView.bounds.height, appendedHeight)
    }

    func testCenteredTextHasFiniteIdealSizeAndWraps() throws {
        let model = TextModel(text: String(repeating: "centered words ", count: 20))
        let harness = Harness(model: model, width: 280, alignment: .center)
        defer { harness.close() }
        let textView = try harness.textView()
        let ideal = harness.controller.sizeThatFits(in: CGSize(width: 1_000_000, height: 800))
        XCTAssertTrue(ideal.width.isFinite)
        XCTAssertGreaterThan(ideal.width, 100)
        XCTAssertLessThan(ideal.width, 10_000)
        model.probeRevision += 1
        harness.settle()
        try assertLayoutFits(textView, width: 280)
        XCTAssertGreaterThan(textView.bounds.height, 30)
    }

    func testSelectionSurvivesStreamingAppendAndCopyUsesPlainText() throws {
        let model = TextModel(text: "alpha 👋 中文 e\u{301} beta gamma")
        let harness = Harness(model: model, width: 320)
        defer { harness.close() }
        let textView = try harness.textView()
        let selection = (model.text as NSString).range(of: "beta")
        textView.setSelectedRange(selection)

        model.text += " and more streamed text"
        harness.settle()
        XCTAssertEqual(textView.string, model.text)
        XCTAssertEqual(textView.selectedRange(), selection)
        textView.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "beta")
        XCTAssertFalse(NSPasteboard.general.types?.contains(.rtf) ?? true)

        model.text = "An unrelated replacement"
        harness.settle()
        XCTAssertEqual(textView.string, model.text)
        XCTAssertEqual(textView.selectedRange().length, 0)
    }

    func testNativeApplicationLinksCallTheHostOpenURLAction() throws {
        let urls = try ["toastty://task/task-1", "toastty://session/session-1"].map {
            try XCTUnwrap(URL(string: $0))
        }
        var text = AttributedString("Task")
        text.link = urls[0]
        var session = AttributedString("Session")
        session.link = urls[1]
        text.append(AttributedString(" "))
        text.append(session)
        var opened: [URL] = []
        let harness = Harness(view: ConversationSelectableText(text).environment(\.openURL, OpenURLAction { url in
            opened.append(url)
            return .handled
        }), width: 320)
        defer { harness.close() }
        let textView = try harness.textView()
        let rendered = try XCTUnwrap(textView.textStorage)
        XCTAssertEqual(rendered.attribute(.link, at: 0, effectiveRange: nil) as? URL, urls[0])
        XCTAssertEqual(rendered.attribute(.link, at: 5, effectiveRange: nil) as? URL, urls[1])

        // This is NSTextView's public link activation entry point. AppKit also
        // uses it for mouse tracking; it must reach the injected SwiftUI action.
        textView.clicked(onLink: urls[0], at: 0)
        textView.clicked(onLink: urls[1], at: 5)
        XCTAssertEqual(opened, urls)
    }

    private func assertLayoutFits(_ textView: NSTextView, width: CGFloat,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let container = try XCTUnwrap(textView.textContainer, file: file, line: line)
        let layout = try XCTUnwrap(textView.layoutManager, file: file, line: line)
        XCTAssertGreaterThan(textView.bounds.width, 100, file: file, line: line)
        XCTAssertLessThanOrEqual(textView.bounds.width, width + 1, file: file, line: line)
        XCTAssertEqual(textView.bounds.width, width, accuracy: 1,
                       "Long text must use the proposed width before its wrapped height is checked",
                       file: file, line: line)
        XCTAssertEqual(container.containerSize.width, textView.bounds.width, accuracy: 1, file: file, line: line)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        XCTAssertLessThanOrEqual(used.width, textView.bounds.width + 1, file: file, line: line)
        XCTAssertLessThanOrEqual(ceil(used.height), textView.bounds.height + 1, file: file, line: line)
        XCTAssertEqual(ceil(used.height), textView.bounds.height, accuracy: 1,
                       "The frame must fit the live nonempty body text without extra blank height",
                       file: file, line: line)
    }

    @MainActor
    private final class TextModel: ObservableObject {
        @Published var text: String
        @Published var probeRevision = 0
        init(text: String) { self.text = text }
    }

    private struct TextHarnessView: View {
        @ObservedObject var model: TextModel
        let alignment: ConversationTextAlignment

        var body: some View {
            WidthProbeLayout(revision: model.probeRevision) {
                ConversationSelectableText(AttributedString(model.text), alignment: alignment)
            }
        }
    }

    /// A real SwiftUI layout can ask for an ideal width between two proposals
    /// of the visible width. Exercise that sequence without changing the frame.
    private struct WidthProbeLayout: Layout {
        let revision: Int

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let child = subviews.first else { return .zero }
            let constrained = ProposedViewSize(width: proposal.width, height: nil)
            _ = child.sizeThatFits(constrained)
            _ = child.sizeThatFits(.unspecified)
            return child.sizeThatFits(constrained)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                                  proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }

    @MainActor
    private final class Harness {
        let controller: NSHostingController<AnyView>
        let window: NSWindow

        convenience init(model: TextModel, width: CGFloat, alignment: ConversationTextAlignment = .natural) {
            self.init(view: TextHarnessView(model: model, alignment: alignment), width: width)
        }

        init(view: some View, width: CGFloat) {
            controller = NSHostingController(rootView: AnyView(view))
            controller.sizingOptions = []
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            // Give the offscreen host a placed root before asking SwiftUI to
            // lay out its children. A controller's fitting-size query alone
            // does not attach or size that view in this borderless window.
            controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 800)
            controller.view.autoresizingMask = [.width, .height]
            window.contentView = controller.view
            settle()
            assertRootGeometry(maximumWidth: width)
        }

        func resize(width: CGFloat) {
            window.setContentSize(NSSize(width: width, height: 800))
            settle()
            assertRootGeometry(maximumWidth: width)
        }

        private func assertRootGeometry(maximumWidth: CGFloat,
                                        file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(window.contentView === controller.view, file: file, line: line)
            XCTAssertTrue(controller.view.window === window, file: file, line: line)
            let bounds = controller.view.bounds
            XCTAssertTrue(bounds.width.isFinite, file: file, line: line)
            XCTAssertTrue(bounds.height.isFinite, file: file, line: line)
            XCTAssertGreaterThan(bounds.width, 0, file: file, line: line)
            XCTAssertGreaterThan(bounds.height, 0, file: file, line: line)
            // The host may adopt short content's ideal size. Only the long
            // wrapping scenarios require the exact proposed width.
            XCTAssertLessThanOrEqual(bounds.width, maximumWidth + 1, file: file, line: line)
        }

        func settle() {
            let deadline = Date().addingTimeInterval(0.15)
            while Date() < deadline {
                controller.view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.03)))
            }
            controller.view.layoutSubtreeIfNeeded()
        }

        func textView() throws -> NSTextView {
            func find(in view: NSView) -> NSTextView? {
                if let text = view as? NSTextView { return text }
                return view.subviews.lazy.compactMap { find(in: $0) }.first
            }
            return try XCTUnwrap(find(in: controller.view))
        }

        func close() { window.close() }
    }
}
