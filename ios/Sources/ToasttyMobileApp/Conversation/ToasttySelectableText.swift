import SwiftUI
import UIKit

/// UIKit supplies range selection on every supported iOS version. Keep each
/// existing Markdown block's layout, with the transcript owning scrolling.
@MainActor
struct ToasttySelectableText: UIViewRepresentable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.openURL) private var openURL

    let text: AttributedString
    var textStyle: UIFont.TextStyle = .body
    var weight: UIFont.Weight?
    var monospaced = false
    var textColor: Color = ToasttyDesignTokens.primaryText
    var lineSpacing: CGFloat = 6
    var alignment: NSTextAlignment = .natural

    init(_ text: AttributedString, textStyle: UIFont.TextStyle = .body,
         weight: UIFont.Weight? = nil, monospaced: Bool = false,
         textColor: Color = ToasttyDesignTokens.primaryText,
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
        view.tintColor = UIColor(ToasttyDesignTokens.amber)
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
        view.invalidateIntrinsicContentSize()
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
        let boldText: Bool

        func attributedText() -> NSAttributedString {
            let traits = UITraitCollection(traitsFrom: [
                UITraitCollection(preferredContentSizeCategory: contentSizeCategory),
                UITraitCollection(legibilityWeight: boldText ? .bold : .regular),
            ])
            let preferred = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traits)
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
                    .foregroundColor: UIColor(run.foregroundColor ?? (run.link == nil ? textColor : ToasttyDesignTokens.amberText)),
                    .paragraphStyle: paragraph,
                ]
                if let color = run.backgroundColor { attributes[.backgroundColor] = UIColor(color) }
                if let link = run.link { attributes[.link] = link }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                result.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
            }
            return result
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        fileprivate var input: RenderingInput?
        var renderedText = NSAttributedString(string: "")
        var idealWidth: CGFloat?
        var measuredSizes: [CGFloat: CGSize] = [:]
        var openURL: OpenURLAction?

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content,
                  ToasttyPreviewURLPolicy.localFileReference(url) != nil else { return defaultAction }
            return UIAction(title: defaultAction.title, image: defaultAction.image) { [weak self] _ in
                self?.openURL?(url)
            }
        }

        func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem,
                      defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            guard case .link(let url) = textItem.content,
                  ToasttyPreviewURLPolicy.localFileReference(url) != nil else { return .init(menu: defaultMenu) }
            // File references must open the conversation preview from a link's
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
    override func copy(_ sender: Any?) {
        guard let range = selectedTextRange,
              let selection = text(in: range), !selection.isEmpty else { return }
        // Transcript colors belong to Toastty. Pasting elsewhere must not carry
        // its dark-theme rich text or inline-code backgrounds.
        UIPasteboard.general.string = selection
    }
}
