#if canImport(UIKit)
import RemoteProtocol
import SwiftUI
import UIKit

/// UIKit supplies range selection on every supported iOS version. Keep each
/// existing Markdown block's layout, with the transcript owning scrolling.
@MainActor
struct ToasttySelectableText: UIViewRepresentable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.conversationTextScale) private var textScale
    @Environment(\.openURL) private var openURL

    let text: AttributedString
    var textStyle: UIFont.TextStyle = .body
    var weight: UIFont.Weight?
    var monospaced = false
    var textColor: Color = ConversationDesignTokens.primaryText
    var lineSpacing: CGFloat = 6
    var alignment: NSTextAlignment = .natural

    init(_ text: AttributedString, textStyle: UIFont.TextStyle = .body,
         weight: UIFont.Weight? = nil, monospaced: Bool = false,
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

    func makeUIView(context: Context) -> ToasttyTranscriptTextView {
        let view = ToasttyTranscriptTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.contentInsetAdjustmentBehavior = .never
        view.adjustsFontForContentSizeCategory = false
        view.tintColor = UIColor(ConversationDesignTokens.amber)
        // Each run already has its link color. UIKit's default overrides it.
        view.linkTextAttributes = [:]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: ToasttyTranscriptTextView, context: Context) {
        context.coordinator.openURL = openURL
        let input = RenderingInput(
            text: text, textStyle: textStyle, weight: weight, monospaced: monospaced,
            textColor: textColor, lineSpacing: lineSpacing, alignment: alignment,
            contentSizeCategory: UIContentSizeCategory(dynamicTypeSize),
            textScale: textScale,
            boldText: legibilityWeight == .bold
        )
        guard context.coordinator.input != input else { return }
        context.coordinator.input = input
        context.coordinator.measuredSizes.removeAll(keepingCapacity: true)
        context.coordinator.idealWidth = nil
        let rendered = input.attributedText()
        // UIKit may substitute fonts in its storage. Compare our own rendered
        // strings so emoji and fallback fonts do not turn appends into resets.
        let previous = context.coordinator.renderedText
        context.coordinator.renderedText = rendered
        // Append only if the existing rendered prefix is unchanged. A Markdown
        // reparse can change earlier characters or formatting as tokens arrive.
        if previous.length > 0, rendered.length > previous.length,
           rendered.attributedSubstring(from: NSRange(location: 0, length: previous.length)).isEqual(to: previous) {
            view.textStorage.append(rendered.attributedSubstring(from: NSRange(
                location: previous.length, length: rendered.length - previous.length
            )))
        } else if !rendered.isEqual(to: previous) {
            view.attributedText = rendered
            view.selectedRange = NSRange(location: 0, length: 0)
        }
        // Room for a chip's outline above the first line and below the last.
        let chipRoom = ToasttyTranscriptTextView.chipRoom(in: rendered)
        if view.textContainerInset != chipRoom { view.textContainerInset = chipRoom }
        view.invalidateIntrinsicContentSize()
        view.setNeedsLayout()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ToasttyTranscriptTextView, context: Context) -> CGSize? {
        if let width = proposal.width, width <= 0 { return .zero }
        let text = context.coordinator.renderedText
        // An unbounded proposal asks for the ideal width. Never give an infinite
        // width to UITextView, including inside a horizontal table scroll view.
        let ideal: CGFloat
        if let cached = context.coordinator.idealWidth {
            ideal = cached
        } else {
            // Leave one point for TextKit's fractional glyph layout, so short
            // bubbles do not wrap their last character at the measured edge.
            ideal = ceil(text.boundingRect(
                with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
            ).width) + 1
            context.coordinator.idealWidth = ideal
        }
        let width = max(1, min(proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal, max(1, ideal)))
        if let cached = context.coordinator.measuredSizes[width] { return cached }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let size = CGSize(width: width, height: ceil(fitted.height))
        context.coordinator.measuredSizes[width] = size
        return size
    }

    static func dismantleUIView(_ view: ToasttyTranscriptTextView, coordinator: Coordinator) {
        view.delegate = nil
        if view.isFirstResponder { view.resignFirstResponder() }
    }

    fileprivate struct RenderingInput: Equatable {
        let text: AttributedString
        let textStyle: UIFont.TextStyle
        let weight: UIFont.Weight?
        let monospaced: Bool
        let textColor: Color
        let lineSpacing: CGFloat
        let alignment: NSTextAlignment
        let contentSizeCategory: UIContentSizeCategory
        let textScale: CGFloat
        let boldText: Bool

        func attributedText() -> NSAttributedString {
            let traits = UITraitCollection(traitsFrom: [
                UITraitCollection(preferredContentSizeCategory: contentSizeCategory),
                UITraitCollection(legibilityWeight: boldText ? .bold : .regular),
            ])
            let style = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traits)
            let preferred = textScale == 1 ? style : style.withSize(style.pointSize * textScale)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = lineSpacing
            paragraph.alignment = alignment
            let result = NSMutableAttributedString(string: "")
            for run in text.runs {
                let intent = run.inlinePresentationIntent ?? []
                let code = monospaced || intent.contains(.code)
                var runWeight = intent.contains(.stronglyEmphasized) ? UIFont.Weight.bold : weight
                if boldText, let explicitWeight = runWeight {
                    runWeight = explicitWeight >= .bold ? .heavy : .bold
                }
                var font = code
                    ? UIFont.monospacedSystemFont(ofSize: preferred.pointSize, weight: runWeight ?? (boldText ? .semibold : .regular))
                    : runWeight.map { UIFont.systemFont(ofSize: preferred.pointSize, weight: $0) } ?? preferred
                if intent.contains(.emphasized),
                   let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
                    font = UIFont(descriptor: descriptor, size: font.pointSize)
                }
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: UIColor(run.foregroundColor ?? (run.link == nil ? textColor : ConversationDesignTokens.amberText)),
                    .paragraphStyle: paragraph,
                ]
                if let color = run.backgroundColor { attributes[.backgroundColor] = UIColor(color) }
                if let link = run.link { attributes[.link] = link }
                var characters = String(text[run.range].characters)
                // A chip's dot stays a dot here: this view draws no spinner.
                // The chip's link names it, so two chips side by side keep
                // two outlines.
                if run[ConversationChipAttribute.self] != nil {
                    attributes[.toasttyChip] = run.link ?? true
                    characters = Self.unbreakable(characters)
                }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                result.append(NSAttributedString(string: characters, attributes: attributes))
            }
            return result
        }

        /// No line break inside a chip, such as after a hyphen in its title:
        /// a word joiner follows each character. TextKit 2 has no hook that
        /// refuses a break, as the Mac's layout manager does. A chip wider
        /// than the line still wraps, because TextKit then breaks by
        /// character.
        static func unbreakable(_ characters: String) -> String {
            characters.map(String.init).joined(separator: wordJoiner)
        }
    }

    /// Zero width, with no line break on either side.
    nonisolated static let wordJoiner = "\u{2060}"

    final class Coordinator: NSObject, UITextViewDelegate {
        fileprivate var input: RenderingInput?
        var renderedText = NSAttributedString(string: "")
        var idealWidth: CGFloat?
        var measuredSizes: [CGFloat: CGSize] = [:]
        var openURL: OpenURLAction?

        /// File references open the conversation's preview, and a task chip
        /// opens its task, through the host's `openURL`. UIKit's default
        /// would hand them to the system.
        static func hostOpensLink(_ url: URL) -> Bool {
            RemotePreviewLinkReference.localFileReference(url) != nil || CoordinatorTaskLink.isToasttyURL(url)
        }

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content, Self.hostOpensLink(url) else { return defaultAction }
            return UIAction(title: defaultAction.title, image: defaultAction.image) { [weak self] _ in
                self?.openURL?(url)
            }
        }

        func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem,
                      defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            guard case .link(let url) = textItem.content, Self.hostOpensLink(url) else { return .init(menu: defaultMenu) }
            // These links must open through the host from a link's
            // long-press menu too, rather than going directly to UIApplication.
            let open = UIAction(title: "Open", image: UIImage(systemName: "arrow.up.right")) { [weak self] _ in
                self?.openURL?(url)
            }
            let copy = UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.url = url
            }
            return .init(preview: nil, menu: UIMenu(children: [open, copy]))
        }
    }
}

@MainActor
final class ToasttyTranscriptTextView: UITextView {
    /// The outline of each chip, behind the text.
    private let chipOutlines: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.white.withAlphaComponent(0.08).cgColor
        layer.strokeColor = UIColor.white.withAlphaComponent(0.22).cgColor
        layer.lineWidth = 1
        return layer
    }()

    override func layoutSubviews() {
        super.layoutSubviews()
        if chipOutlines.superlayer == nil { layer.insertSublayer(chipOutlines, at: 0) }
        chipOutlines.frame = bounds
        chipOutlines.path = chipOutlinePath()
    }

    override func copy(_ sender: Any?) {
        guard let range = selectedTextRange,
              let selection = text(in: range), !selection.isEmpty else { return }
        // Transcript colors belong to Toastty. Pasting elsewhere must not carry
        // its dark-theme rich text or inline-code backgrounds. A chip keeps
        // its words together with no-break spaces; a copy gets plain spaces.
        UIPasteboard.general.string = selection
            .replacingOccurrences(of: ToasttySelectableText.wordJoiner, with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// The outline is four points taller than a line of the chip's text and
    /// centers on its capitals, as on the Mac. This is how far it reaches
    /// above the first line and below the last, in whole points; zero when
    /// the text has no chip.
    static func chipRoom(in text: NSAttributedString) -> UIEdgeInsets {
        var font: UIFont?
        text.enumerateAttribute(.toasttyChip, in: NSRange(location: 0, length: text.length)) { value, range, stop in
            guard value != nil else { return }
            font = text.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont
            stop.pointee = true
        }
        guard let font else { return .zero }
        let middle = font.ascender - font.capHeight / 2
        let half = chipOutlineHeight(font) / 2
        return UIEdgeInsets(top: ceil(max(0, half - middle)), left: 0,
                            bottom: ceil(max(0, middle + half - font.lineHeight)), right: 0)
    }

    private static func chipOutlineHeight(_ font: UIFont) -> CGFloat {
        font.lineHeight + 4
    }

    /// One rounded rect for each line a chip is on, around that line's part
    /// of the chip, drawn half a point inside so the stroke stays whole.
    private func chipOutlinePath() -> CGPath? {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return nil }
        let storage = textStorage
        let path = CGMutablePath()
        let inset = textContainerInset
        storage.enumerateAttribute(.toasttyChip, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil,
                  let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont,
                  let start = content.location(content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { return }
            layout.ensureLayout(for: textRange)
            let height = Self.chipOutlineHeight(font)
            layout.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, frame, baseline, _ in
                guard frame.width > 0 else { return true }
                let middle = frame.minY + baseline - font.capHeight / 2
                let outline = CGRect(x: inset.left + frame.minX, y: inset.top + middle - height / 2,
                                     width: frame.width, height: height).insetBy(dx: 0.5, dy: 0.5)
                path.addRoundedRect(in: outline, cornerWidth: outline.height / 2, cornerHeight: outline.height / 2)
                return true
            }
        }
        return path.isEmpty ? nil : path
    }
}

extension NSAttributedString.Key {
    /// Marks the characters of a chip. See `ConversationChipAttribute`.
    static let toasttyChip = NSAttributedString.Key("toastty.conversationChip")
}
#endif
