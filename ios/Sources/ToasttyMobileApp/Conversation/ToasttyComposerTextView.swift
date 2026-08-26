import SwiftUI
import UIKit

@MainActor
struct ToasttyComposerTextView: UIViewRepresentable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Binding var text: String
    @Binding var isFocused: Bool

    let placeholder: String
    let isEnabled: Bool
    let accessibilityLabel: String
    let accessibilityHint: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ToasttyComposerUIKitTextView {
        let textView = ToasttyComposerUIKitTextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = UIColor(ToasttyDesignTokens.primaryText)
        textView.tintColor = UIColor(ToasttyDesignTokens.amber)
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = true
        textView.contentInsetAdjustmentBehavior = .never
        textView.alwaysBounceVertical = false
        textView.showsVerticalScrollIndicator = false
        textView.keyboardDismissMode = .none
        textView.autocapitalizationType = .sentences
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        synchronize(textView)
        return textView
    }

    func updateUIView(
        _ textView: ToasttyComposerUIKitTextView,
        context: Context
    ) {
        context.coordinator.parent = self
        synchronize(textView)

        if textView.text != text, textView.markedTextRange == nil {
            let selection = textView.selectedRange
            textView.text = text
            textView.selectedRange = Self.clampedSelection(
                selection,
                utf16Count: text.utf16.count
            )
            textView.textDidChange()
            textView.requestSelectionVisibility()
        }

        if isFocused, isEnabled {
            if textView.isFirstResponder == false {
                textView.becomeFirstResponder()
                textView.requestSelectionVisibility()
            }
        } else if textView.isFirstResponder {
            textView.resignFirstResponder()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView textView: ToasttyComposerUIKitTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        _ = dynamicTypeSize
        let lineHeight = textView.font?.lineHeight
            ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
        let naturalHeight = textView.sizeThatFits(CGSize(
            width: width,
            height: .greatestFiniteMagnitude
        )).height
        let height = Self.clampedHeight(
            naturalHeight: naturalHeight,
            lineHeight: lineHeight
        )
        return CGSize(width: width, height: height)
    }

    static func dismantleUIView(
        _ textView: ToasttyComposerUIKitTextView,
        coordinator: Coordinator
    ) {
        textView.delegate = nil
        if textView.isFirstResponder {
            textView.resignFirstResponder()
        }
    }

    static func clampedHeight(naturalHeight: CGFloat, lineHeight: CGFloat) -> CGFloat {
        min(max(ceil(naturalHeight), ceil(lineHeight)), ceil(lineHeight * 5))
    }

    static func clampedSelection(_ selection: NSRange, utf16Count: Int) -> NSRange {
        let location = min(selection.location, utf16Count)
        return NSRange(
            location: location,
            length: min(selection.length, utf16Count - location)
        )
    }

    private func synchronize(_ textView: ToasttyComposerUIKitTextView) {
        textView.placeholder = placeholder
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.accessibilityLabel = accessibilityLabel
        textView.accessibilityHint = accessibilityHint
        textView.accessibilityIdentifier = "toastty-mobile-composer-input"
        textView.updateAccessibilityValue()
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ToasttyComposerTextView

        init(parent: ToasttyComposerTextView) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if parent.isFocused == false {
                parent.isFocused = true
            }
            (textView as? ToasttyComposerUIKitTextView)?.requestSelectionVisibility()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused {
                parent.isFocused = false
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let textView = textView as? ToasttyComposerUIKitTextView else { return }
            textView.textDidChange()
            if parent.text != textView.text {
                parent.text = textView.text
            }
            guard textView.markedTextRange == nil else { return }
            textView.requestSelectionVisibility()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard let textView = textView as? ToasttyComposerUIKitTextView,
                  textView.markedTextRange == nil else {
                return
            }
            textView.requestSelectionVisibility()
        }
    }
}

@MainActor
final class ToasttyComposerUIKitTextView: UITextView {
    private let placeholderLabel = UILabel()
    private var shouldRevealSelection = false
    private var lastLayoutSize = CGSize.zero

    var placeholder = "" {
        didSet {
            placeholderLabel.text = placeholder
            updateAccessibilityValue()
        }
    }

    init() {
        super.init(frame: .zero, textContainer: nil)
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = UIColor(ToasttyDesignTokens.mutedText)
        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.isAccessibilityElement = false
        addSubview(placeholderLabel)
        textDidChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholderLabel.frame = bounds

        if bounds.size != lastLayoutSize {
            lastLayoutSize = bounds.size
            shouldRevealSelection = true
        }
        guard shouldRevealSelection, markedTextRange == nil else { return }
        shouldRevealSelection = false
        revealSelection()
    }

    func textDidChange() {
        placeholderLabel.isHidden = text.isEmpty == false
        updateAccessibilityValue()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func updateAccessibilityValue() {
        accessibilityValue = text.isEmpty ? placeholder : text
    }

    func requestSelectionVisibility() {
        shouldRevealSelection = true
        setNeedsLayout()
    }

    func revealSelection() {
        guard isFirstResponder,
              let selection = selectedTextRange,
              selection.isEmpty,
              isTracking == false,
              isDragging == false,
              isDecelerating == false else {
            return
        }

        let caret = caretRect(for: selection.end)
        guard caret.isNull == false,
              caret.isInfinite == false,
              caret.minY.isFinite,
              caret.maxY.isFinite else {
            return
        }
        let padding: CGFloat = 2
        let insets = adjustedContentInset
        let minimumOffset = -insets.top
        let maximumOffset = max(
            minimumOffset,
            max(contentSize.height, caret.maxY + padding)
                - bounds.height
                + insets.bottom
        )
        let visibleMinimumY = contentOffset.y + insets.top
        let visibleMaximumY = contentOffset.y + bounds.height - insets.bottom
        let requestedOffset: CGFloat

        if caret.maxY + padding > visibleMaximumY {
            requestedOffset = contentOffset.y + caret.maxY + padding - visibleMaximumY
        } else if caret.minY - padding < visibleMinimumY {
            requestedOffset = contentOffset.y + caret.minY - padding - visibleMinimumY
        } else {
            return
        }

        let offsetY = min(max(requestedOffset, minimumOffset), maximumOffset)
        setContentOffset(CGPoint(x: contentOffset.x, y: offsetY), animated: false)
    }
}
