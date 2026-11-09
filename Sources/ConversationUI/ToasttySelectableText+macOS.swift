#if canImport(AppKit) && !canImport(UIKit)
import AppKit
import SwiftUI

/// The AppKit counterpart of the UIKit text view: `NSTextView` supplies range
/// selection for the same attributed runs, and the transcript owns scrolling.
@MainActor
struct ToasttySelectableText: NSViewRepresentable {
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.openURL) private var openURL

    let text: AttributedString
    var textStyle: NSFont.TextStyle = .body
    var weight: NSFont.Weight?
    var monospaced = false
    var textColor: Color = ConversationDesignTokens.primaryText
    var lineSpacing: CGFloat = 6
    var alignment: NSTextAlignment = .natural

    init(_ text: AttributedString, textStyle: NSFont.TextStyle = .body,
         weight: NSFont.Weight? = nil, monospaced: Bool = false,
         textColor: Color = ConversationDesignTokens.primaryText,
         lineSpacing: CGFloat = 6, alignment: NSTextAlignment = .natural) {
        self.text = text
        self.textStyle = textStyle
        self.weight = weight
        self.monospaced = monospaced
        self.textColor = textColor
        self.lineSpacing = lineSpacing
        self.alignment = alignment
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ToasttyTranscriptTextView {
        // TextKit 1, so the separate sizing stack below measures the same
        // layout that the view draws.
        let view = ToasttyTranscriptTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        // Each run already has its link color. AppKit's default overrides it.
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ToasttyTranscriptTextView, context: Context) {
        context.coordinator.openURL = openURL
        let rendered = attributedText()
        let previous = context.coordinator.renderedText
        guard !rendered.isEqual(to: previous) else { return }
        context.coordinator.renderedText = rendered
        context.coordinator.sizingTextStorage.setAttributedString(rendered)
        context.coordinator.measuredSizes.removeAll(keepingCapacity: true)
        context.coordinator.idealWidth = nil
        // Append only if the existing rendered prefix is unchanged, as on iOS.
        if previous.length > 0, rendered.length > previous.length,
           rendered.attributedSubstring(from: NSRange(location: 0, length: previous.length)).isEqual(to: previous) {
            let selection = view.selectedRanges
            view.textStorage?.append(rendered.attributedSubstring(from: NSRange(
                location: previous.length, length: rendered.length - previous.length
            )))
            view.selectedRanges = selection
        } else {
            view.textStorage?.setAttributedString(rendered)
            view.setSelectedRange(NSRange(location: 0, length: 0))
        }
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ToasttyTranscriptTextView,
                      context: Context) -> CGSize? {
        if let width = proposal.width, width <= 0 { return .zero }
        let ideal: CGFloat
        if let cached = context.coordinator.idealWidth {
            ideal = cached
        } else {
            // Alignment moves line origins, not the content's ideal width. A
            // natural-alignment copy keeps centered and trailing text from
            // reporting the whole probe width.
            let sizingText = NSMutableAttributedString(attributedString: context.coordinator.renderedText)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = lineSpacing
            paragraph.alignment = .natural
            sizingText.addAttribute(.paragraphStyle, value: paragraph,
                                    range: NSRange(location: 0, length: sizingText.length))
            // Leave one point for TextKit's fractional glyph layout, so short
            // bubbles do not wrap their last character at the measured edge.
            ideal = ceil(sizingText.boundingRect(
                with: CGSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).width) + 1
            context.coordinator.idealWidth = ideal
        }
        let width = max(1, min(proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal, max(1, ideal)))
        if let cached = context.coordinator.measuredSizes[width] { return cached }
        // The live container follows the placed text view. Measure proposals
        // in a separate TextKit stack, so an earlier frame cannot supply the
        // height for a new width.
        let container = context.coordinator.sizingTextContainer
        let layout = context.coordinator.sizingLayoutManager
        container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let size = CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
        context.coordinator.measuredSizes[width] = size
        return size
    }

    static func dismantleNSView(_ view: ToasttyTranscriptTextView, coordinator: Coordinator) {
        view.delegate = nil
    }

    private func attributedText() -> NSAttributedString {
        let boldText = legibilityWeight == .bold
        let preferred = NSFont.preferredFont(forTextStyle: textStyle)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = alignment
        let result = NSMutableAttributedString(string: "")
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            let code = monospaced || intent.contains(.code)
            var runWeight = intent.contains(.stronglyEmphasized) ? NSFont.Weight.bold : weight
            if boldText, let explicitWeight = runWeight {
                runWeight = explicitWeight.rawValue >= NSFont.Weight.bold.rawValue ? .heavy : .bold
            }
            var font = code
                ? NSFont.monospacedSystemFont(ofSize: preferred.pointSize, weight: runWeight ?? (boldText ? .semibold : .regular))
                : runWeight.map { NSFont.systemFont(ofSize: preferred.pointSize, weight: $0) } ?? preferred
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(run.foregroundColor ?? (run.link == nil ? textColor : ConversationDesignTokens.amberText)),
                .paragraphStyle: paragraph,
            ]
            if let color = run.backgroundColor { attributes[.backgroundColor] = NSColor(color) }
            if let link = run.link { attributes[.link] = link }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        return result
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var renderedText = NSAttributedString(string: "")
        var idealWidth: CGFloat?
        var measuredSizes: [CGFloat: CGSize] = [:]
        var openURL: OpenURLAction?
        let sizingTextStorage = NSTextStorage(string: "")
        let sizingLayoutManager = NSLayoutManager()
        let sizingTextContainer = NSTextContainer(
            size: CGSize(width: 1, height: CGFloat.greatestFiniteMagnitude)
        )

        override init() {
            super.init()
            sizingTextContainer.lineFragmentPadding = 0
            sizingTextContainer.widthTracksTextView = false
            sizingTextContainer.heightTracksTextView = false
            sizingLayoutManager.addTextContainer(sizingTextContainer)
            sizingTextStorage.addLayoutManager(sizingLayoutManager)
        }

        /// Every link goes to the host's `openURL`, which decides between a
        /// file preview and the system browser.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            openURL?(url)
            return true
        }
    }
}

@MainActor
final class ToasttyTranscriptTextView: NSTextView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainer?.containerSize = CGSize(width: newSize.width,
                                             height: CGFloat.greatestFiniteMagnitude)
    }

    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        // Transcript colors belong to Toastty. Pasting elsewhere must not carry
        // its dark-theme rich text or inline-code backgrounds.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((string as NSString).substring(with: range), forType: .string)
    }
}
#endif
