import SwiftUI
import UIKit

@MainActor
struct ToasttyComposerTextView: UIViewRepresentable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let text: String
    let onTextChange: (String, UInt64) -> Void
    var editRevision: UInt64 = 0
    var replacement: ToasttyComposerReplacement? = nil
    var onReplacementCompleted: (ToasttyComposerReplacementResult) -> Void = { _ in }
    @Binding var isFocused: Bool

    let placeholder: String
    let isEnabled: Bool
    let accessibilityLabel: String
    let accessibilityHint: String
    var maximumVisibleLines: Int = 5

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
        // Let SwiftUI grow the composer before UIKit starts moving its internal
        // viewport. Scrolling is enabled only after a capped height has settled.
        textView.isScrollEnabled = false
        textView.contentInsetAdjustmentBehavior = .never
        textView.alwaysBounceVertical = false
        textView.showsVerticalScrollIndicator = false
        textView.keyboardDismissMode = .none
        textView.autocapitalizationType = .sentences
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.text = text
        textView.selectedRange = NSRange(location: text.utf16.count, length: 0)
        textView.onCompositionEnded = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.applyPendingReplacement(to: textView)
        }
        textView.textDidChange()
        synchronize(textView)
        #if DEBUG
        textView.traceTyping(.created)
        #endif
        return textView
    }

    func updateUIView(
        _ textView: ToasttyComposerUIKitTextView,
        context: Context
    ) {
        context.coordinator.parent = self
        synchronize(textView)
        #if DEBUG
        textView.traceTyping(.synchronized, editRevision: context.coordinator.traceEditRevision)
        #endif

        context.coordinator.receiveReplacement(replacement, in: textView)

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
        guard let width = proposal.width,
              width.isFinite,
              width > 0 else {
            return nil
        }
        _ = dynamicTypeSize
        let lineHeight = Self.lineFragmentHeight(of: textView)
        let naturalHeight = Self.naturalHeight(of: textView, width: width)
        let height = Self.clampedHeight(
            naturalHeight: naturalHeight,
            lineHeight: lineHeight,
            maximumVisibleLines: maximumVisibleLines
        )
        textView.updateLayoutMeasurement(
            width: width,
            naturalHeight: naturalHeight,
            fittedHeight: height,
            maximumHeight: Self.maximumHeight(lineHeight: lineHeight, maximumVisibleLines: maximumVisibleLines)
        )
        return CGSize(width: width, height: height)
    }

    static func dismantleUIView(
        _ textView: ToasttyComposerUIKitTextView,
        coordinator: Coordinator
    ) {
        #if DEBUG
        textView.traceTyping(.dismantled)
        #endif
        coordinator.isActive = false
        textView.onCompositionEnded = nil
        textView.delegate = nil
        if textView.isFirstResponder {
            textView.resignFirstResponder()
        }
    }

    static func clampedHeight(
        naturalHeight: CGFloat,
        lineHeight: CGFloat,
        maximumVisibleLines: Int = 5
    ) -> CGFloat {
        min(
            max(ceil(naturalHeight), ceil(lineHeight)),
            maximumHeight(lineHeight: lineHeight, maximumVisibleLines: maximumVisibleLines)
        )
    }

    static func maximumHeight(lineHeight: CGFloat, maximumVisibleLines: Int = 5) -> CGFloat {
        ceil(lineHeight * CGFloat(max(1, maximumVisibleLines)))
    }

    static func lineFragmentHeight(of textView: UITextView) -> CGFloat {
        let font = textView.font ?? UIFont.preferredFont(forTextStyle: .body)
        let layoutManager = textView.layoutManager
        layoutManager.ensureLayout(for: textView.textContainer)
        guard layoutManager.numberOfGlyphs > 0 else { return font.lineHeight }
        return layoutManager.lineFragmentUsedRect(
            forGlyphAt: 0,
            effectiveRange: nil
        ).height
    }

    static func naturalHeight(
        of textView: UITextView,
        width: CGFloat
    ) -> CGFloat {
        let fittingHeight = textView.sizeThatFits(CGSize(
            width: width,
            height: .greatestFiniteMagnitude
        )).height
        guard textView.isScrollEnabled,
              abs(textView.bounds.width - width) <= 0.5 else {
            return fittingHeight
        }
        let layoutManager = textView.layoutManager
        layoutManager.ensureLayout(for: textView.textContainer)
        let textKitHeight = layoutManager.usedRect(for: textView.textContainer).height
            + textView.textContainerInset.top
            + textView.textContainerInset.bottom
        return max(fittingHeight, textKitHeight)
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
        var lastReplacementRevision: UInt64 = 0
        var isActive = true
        private var pendingReplacement: ToasttyComposerReplacement?
        private var isReplacingText = false
        private var editRevision: UInt64
        #if DEBUG
        fileprivate var traceEditRevision: UInt64 { editRevision }
        #endif
        private var lastNativeText: String

        func receiveReplacement(_ replacement: ToasttyComposerReplacement?, in textView: ToasttyComposerUIKitTextView) {
            guard let replacement else {
                pendingReplacement = nil
                return
            }
            if replacement.revision > lastReplacementRevision {
                lastReplacementRevision = replacement.revision
                pendingReplacement = replacement
                #if DEBUG
                if textView.typingTrace != nil {
                    textView.traceTyping(.replacementReceived, replacementLength: replacement.text.utf16.count,
                                         editRevision: editRevision, replacementRevision: replacement.revision,
                                         expectedEditRevision: replacement.expectedEditRevision)
                }
                #endif
            }
            applyPendingReplacement(to: textView)
        }

        func applyPendingReplacement(to textView: ToasttyComposerUIKitTextView) {
            #if DEBUG
            if textView.typingTrace != nil, let replacement = pendingReplacement, textView.markedTextRange != nil {
                textView.traceTyping(.replacementDeferred, editRevision: editRevision, replacementRevision: replacement.revision,
                                         expectedEditRevision: replacement.expectedEditRevision)
            }
            #endif
            guard isActive, !isReplacingText, textView.markedTextRange == nil,
                  let replacement = pendingReplacement else { return }
            // Selection callbacks can precede textViewDidChange. Account for
            // the actual native text before deciding whether this request won.
            recordNativeEdit(in: textView)
            pendingReplacement = nil
            // A clear followed by restoration can coalesce into one render.
            guard !(textView.text ?? "").utf16.elementsEqual(replacement.text.utf16) else {
                #if DEBUG
                textView.traceTyping(.replacementUnchanged, editRevision: editRevision, replacementRevision: replacement.revision,
                                         expectedEditRevision: replacement.expectedEditRevision)
                #endif
                reportCompletion(replacement, in: textView, rejected: false)
                return
            }
            guard editRevision == replacement.expectedEditRevision else {
                #if DEBUG
                textView.traceTyping(.replacementRejected, editRevision: editRevision, replacementRevision: replacement.revision,
                                         expectedEditRevision: replacement.expectedEditRevision)
                #endif
                reportCompletion(replacement, in: textView, rejected: true)
                return
            }
            isReplacingText = true
            textView.text = replacement.text
            lastNativeText = replacement.text
            textView.selectedRange = NSRange(location: replacement.text.utf16.count, length: 0)
            isReplacingText = false
            #if DEBUG
            textView.traceTyping(.replacementApplied, editRevision: editRevision, replacementRevision: replacement.revision,
                                         expectedEditRevision: replacement.expectedEditRevision)
            #endif
            reportCompletion(replacement, in: textView, rejected: false)
            textView.textDidChange()
            textView.requestSelectionVisibility()
        }

        func reportCompletion(_ replacement: ToasttyComposerReplacement, in textView: ToasttyComposerUIKitTextView, rejected: Bool) {
            // updateUIView cannot synchronously mutate SwiftUI state. On a
            // completion, publish the latest native text when the callback runs.
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView, self.isActive,
                      self.lastReplacementRevision == replacement.revision else { return }
                self.recordNativeEdit(in: textView)
                self.parent.onReplacementCompleted(ToasttyComposerReplacementResult(
                    revision: replacement.revision, nativeText: textView.text ?? "",
                    nativeEditRevision: self.editRevision, wasApplied: !rejected
                ))
            }
        }

        init(parent: ToasttyComposerTextView) {
            self.parent = parent
            self.editRevision = parent.editRevision
            self.lastNativeText = parent.text
        }

        private func recordNativeEdit(in textView: UITextView) {
            let text = textView.text ?? ""
            if !text.utf16.elementsEqual(lastNativeText.utf16) {
                editRevision += 1
                lastNativeText = text
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            #if DEBUG
            (textView as? ToasttyComposerUIKitTextView)?.traceTyping(.focusBegan, editRevision: editRevision)
            #endif
            if parent.isFocused == false {
                parent.isFocused = true
            }
            (textView as? ToasttyComposerUIKitTextView)?.requestSelectionVisibility()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            #if DEBUG
            (textView as? ToasttyComposerUIKitTextView)?.traceTyping(.focusEnded, editRevision: editRevision)
            #endif
            if parent.isFocused {
                parent.isFocused = false
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isReplacingText, let textView = textView as? ToasttyComposerUIKitTextView else { return }
            textView.textDidChange()
            recordNativeEdit(in: textView)
            #if DEBUG
            textView.traceTyping(.textChanged, editRevision: editRevision)
            #endif
            applyPendingReplacement(to: textView)
            parent.onTextChange(textView.text ?? "", editRevision)
            guard textView.markedTextRange == nil else { return }
            textView.requestSelectionVisibility()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            #if DEBUG
            (textView as? ToasttyComposerUIKitTextView)?.traceTyping(.selectionChanged, editRevision: editRevision)
            #endif
            guard let textView = textView as? ToasttyComposerUIKitTextView,
                  textView.markedTextRange == nil else {
                return
            }
            applyPendingReplacement(to: textView)
            textView.requestSelectionVisibility()
        }
    }
}

@MainActor
final class ToasttyComposerUIKitTextView: UITextView {
    private struct LayoutMeasurement {
        let width: CGFloat
        let naturalHeight: CGFloat
        let fittedHeight: CGFloat
        let maximumHeight: CGFloat
    }

    private static let layoutTolerance: CGFloat = 0.5

    private let placeholderLabel = UILabel()
    private var shouldRevealSelection = false
    private var deferredSelectionRevealScheduled = false
    private var lastLayoutSize = CGSize.zero
    private var layoutMeasurement: LayoutMeasurement?

    var onCompositionEnded: (() -> Void)?

    #if DEBUG
    let typingTrace: ToasttyComposerTrace?
    let typingTraceInstanceID: UInt64

    private func configureTypingTraceScreenshotObserver() {
        guard typingTrace != nil else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(typingTraceScreenshot),
            name: UIApplication.userDidTakeScreenshotNotification, object: nil
        )
    }

    @objc private func typingTraceScreenshot() {
        guard window != nil, UIApplication.shared.applicationState == .active else { return }
        traceTyping(.screenshot)
    }
    #endif

    override func unmarkText() {
        super.unmarkText()
        #if DEBUG
        traceTyping(.unmarkTextCalled)
        #endif
        onCompositionEnded?()
    }

    var placeholder = "" {
        didSet {
            placeholderLabel.text = placeholder
            updateAccessibilityValue()
        }
    }

    #if DEBUG
    init(typingTrace: ToasttyComposerTrace? = .shared) {
        self.typingTrace = typingTrace
        typingTraceInstanceID = typingTrace?.newComposerID() ?? 0
        super.init(frame: .zero, textContainer: nil)
        configurePlaceholder()
        configureTypingTraceScreenshotObserver()
    }
    #else
    init() {
        super.init(frame: .zero, textContainer: nil)
        configurePlaceholder()
    }
    #endif

    private func configurePlaceholder() {
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
        #if DEBUG
        defer { traceTyping(.laidOut) }
        #endif
        placeholderLabel.frame = bounds

        let didChangeSize = bounds.size != lastLayoutSize
        lastLayoutSize = bounds.size
        let didEnableScrolling = updateInternalScrolling()

        guard isScrollEnabled else {
            shouldRevealSelection = false
            normalizeNonOverflowOffset()
            return
        }
        shouldRevealSelection = shouldRevealSelection || didChangeSize
        if didEnableScrolling {
            // TextKit updates wrapped-line geometry after scrolling is enabled.
            // Reveal from the following layout pass so the caret rect and
            // content size both describe the scrollable viewport.
            scheduleSelectionRevealAfterLayout()
            return
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
        guard shouldRevealSelection == false else { return }
        shouldRevealSelection = true
        setNeedsLayout()
    }

    func updateLayoutMeasurement(
        width: CGFloat,
        naturalHeight: CGFloat,
        fittedHeight: CGFloat,
        maximumHeight: CGFloat
    ) {
        layoutMeasurement = LayoutMeasurement(
            width: width,
            naturalHeight: naturalHeight,
            fittedHeight: fittedHeight,
            maximumHeight: maximumHeight
        )
        #if DEBUG
        if typingTrace != nil {
            traceTyping(.measured, measurement: .init(
                width: width, naturalHeight: naturalHeight, fittedHeight: fittedHeight, maximumHeight: maximumHeight
            ))
        }
        #endif
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
        #if DEBUG
        traceTyping(.selectionRevealed, requestedOffsetY: offsetY)
        #endif
    }

    private func updateInternalScrolling() -> Bool {
        guard let layoutMeasurement,
              abs(bounds.width - layoutMeasurement.width) <= Self.layoutTolerance else {
            return false
        }
        let shouldScroll: Bool
        let hasSettledFittedHeight = abs(
            bounds.height - layoutMeasurement.fittedHeight
        ) <= Self.layoutTolerance
        let isHeightCapped = abs(
            layoutMeasurement.fittedHeight - layoutMeasurement.maximumHeight
        ) <= Self.layoutTolerance
        let hasOverflow = layoutMeasurement.naturalHeight
            > layoutMeasurement.fittedHeight + Self.layoutTolerance
        shouldScroll = hasSettledFittedHeight && isHeightCapped && hasOverflow

        guard isScrollEnabled != shouldScroll else { return false }
        isScrollEnabled = shouldScroll
        #if DEBUG
        traceTyping(.scrollingChanged)
        #endif
        return shouldScroll
    }

    private func scheduleSelectionRevealAfterLayout() {
        guard deferredSelectionRevealScheduled == false else { return }
        deferredSelectionRevealScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deferredSelectionRevealScheduled = false
            guard self.isScrollEnabled, self.markedTextRange == nil else { return }
            self.shouldRevealSelection = true
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
    }

    private func normalizeNonOverflowOffset() {
        let minimumOffset = -adjustedContentInset.top
        guard abs(contentOffset.y - minimumOffset) > Self.layoutTolerance else { return }
        setContentOffset(
            CGPoint(x: contentOffset.x, y: minimumOffset),
            animated: false
        )
        #if DEBUG
        traceTyping(.offsetNormalized, requestedOffsetY: minimumOffset)
        #endif
    }
}

