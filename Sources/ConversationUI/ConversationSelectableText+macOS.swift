#if canImport(AppKit)
import AppKit
import SwiftUI

/// The AppKit leaf uses the same parsed blocks and inline attributes as iOS.
/// NSTextView supplies native range selection without adding a scroll view.
@MainActor
struct ConversationNativeSelectableText: NSViewRepresentable {
    @Environment(\.openURL) private var openURL
    @Environment(\.legibilityWeight) private var legibilityWeight

    let text: AttributedString
    var textStyle: NSFont.TextStyle = .body
    var weight: NSFont.Weight?
    var monospaced = false
    var textColor: Color = ConversationTheme.toastty.primaryText
    var lineSpacing: CGFloat = 6
    var alignment: NSTextAlignment = .natural
    var theme: ConversationTheme = .toastty

    init(_ text: AttributedString, textStyle: NSFont.TextStyle = .body,
         weight: NSFont.Weight? = nil, monospaced: Bool = false,
         textColor: Color = ConversationTheme.toastty.primaryText,
         lineSpacing: CGFloat = 6, alignment: NSTextAlignment = .natural,
         theme: ConversationTheme = .toastty) {
        self.text = text
        self.textStyle = textStyle
        self.weight = weight
        self.monospaced = monospaced
        self.textColor = textColor
        self.lineSpacing = lineSpacing
        self.alignment = alignment
        self.theme = theme
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ConversationTranscriptTextView {
        let view = ConversationTranscriptTextView(usingTextLayoutManager: false)
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
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ConversationTranscriptTextView, context: Context) {
        context.coordinator.openURL = openURL
        let rendered = attributedText()
        let previous = context.coordinator.renderedText
        guard !rendered.isEqual(to: previous) else { return }
        context.coordinator.renderedText = rendered
        context.coordinator.sizingTextStorage.setAttributedString(rendered)
        context.coordinator.measuredSizes.removeAll(keepingCapacity: true)
        context.coordinator.idealWidth = nil
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

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ConversationTranscriptTextView,
                      context: Context) -> CGSize? {
        if let width = proposal.width, width <= 0 { return .zero }
        let ideal: CGFloat
        if let cached = context.coordinator.idealWidth {
            ideal = cached
        } else {
            // Alignment affects the live container's line origins, not the
            // content's ideal width. A finite, natural-alignment copy avoids
            // precision loss for centered/trailing text in unbounded probes.
            let sizingText = NSMutableAttributedString(attributedString: context.coordinator.renderedText)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .natural
            sizingText.addAttribute(.paragraphStyle, value: paragraph,
                                    range: NSRange(location: 0, length: sizingText.length))
            ideal = ceil(sizingText.boundingRect(
                with: CGSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).width) + 1
            context.coordinator.idealWidth = ideal
        }
        let width = max(1, min(proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal, max(1, ideal)))
        if let cached = context.coordinator.measuredSizes[width] { return cached }
        // The live container follows the already-placed text view. Measure
        // proposals in a separate TextKit stack so a previous frame cannot
        // supply the height for a new width or change visible text layout.
        let container = context.coordinator.sizingTextContainer
        let layout = context.coordinator.sizingLayoutManager
        container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let size = CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
        context.coordinator.measuredSizes[width] = size
        return size
    }

    static func dismantleNSView(_ view: ConversationTranscriptTextView, coordinator: Coordinator) {
        view.delegate = nil
    }

    private func attributedText() -> NSAttributedString {
        let preferred = NSFont.preferredFont(forTextStyle: textStyle)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = alignment
        let result = NSMutableAttributedString(string: "")
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            let code = monospaced || intent.contains(.code)
            let boldText = legibilityWeight == .bold
            var runWeight = intent.contains(.stronglyEmphasized) ? NSFont.Weight.bold : weight
            if boldText, let explicitWeight = runWeight {
                runWeight = explicitWeight >= .bold ? .heavy : .bold
            }
            var font = code
                ? NSFont.monospacedSystemFont(ofSize: preferred.pointSize, weight: runWeight ?? (boldText ? .semibold : .regular))
                : runWeight.map { NSFont.systemFont(ofSize: preferred.pointSize, weight: $0) } ?? preferred
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(run.foregroundColor ?? (run.link == nil ? textColor : theme.amberText)),
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
        let sizingTextContainer = NSTextContainer(size: CGSize(width: 1, height: CGFloat.greatestFiniteMagnitude))

        override init() {
            super.init()
            sizingTextContainer.lineFragmentPadding = 0
            sizingTextContainer.widthTracksTextView = false
            sizingTextContainer.heightTracksTextView = false
            sizingLayoutManager.addTextContainer(sizingTextContainer)
            sizingTextStorage.addLayoutManager(sizingLayoutManager)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            openURL?(url)
            return true
        }
    }
}

@MainActor
final class ConversationTranscriptTextView: NSTextView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainer?.containerSize = CGSize(width: newSize.width,
                                             height: CGFloat.greatestFiniteMagnitude)
    }

    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((string as NSString).substring(with: range), forType: .string)
    }
}

extension ConversationTextStyle {
    var native: NSFont.TextStyle {
        switch self {
        case .body: .body
        case .headline: .headline
        case .subheadline: .subheadline
        }
    }
}

extension ConversationTextWeight {
    var native: NSFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
    }
}

extension ConversationTextAlignment {
    var native: NSTextAlignment {
        switch self {
        case .natural: .natural
        case .left: .left
        case .center: .center
        case .right: .right
        }
    }
}
#endif
