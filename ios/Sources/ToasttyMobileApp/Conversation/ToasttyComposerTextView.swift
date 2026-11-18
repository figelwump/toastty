import ConversationUI
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
    /// The coordinator chat's @ mentions: the list's state. `nil` in a
    /// task's session, whose field edits plain text.
    var mentionPicker: ToasttyMentionPicker? = nil
    /// The tasks that can be mentioned.
    var mentionCandidates: [CoordinatorMentionCandidate] = []

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
        configureMentions(textView)
        textView.setDraft(text)
        textView.selectedRange = NSRange(location: textView.textStorage.length, length: 0)
        textView.onCompositionEnded = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.applyPendingReplacement(to: textView)
        }
        textView.onMentionEdit = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.publishNativeEdit(of: textView)
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
        configureMentions(textView)
        synchronize(textView)
        #if DEBUG
        textView.traceTyping(.synchronized, editRevision: context.coordinator.traceEditRevision)
        #endif

        context.coordinator.receiveReplacement(replacement, in: textView)
        context.coordinator.scheduleFocusSync(for: textView)
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
        textView.onMentionEdit = nil
        textView.delegate = nil
        // The list belongs to this field. It closes after this update, which
        // must not change what the list shows.
        if let picker = coordinator.parent.mentionPicker {
            DispatchQueue.main.async { picker.close() }
        }
        if textView.isFirstResponder {
            textView.resignFirstResponder()
        }
    }

    fileprivate static func setTakesText(_ takesText: Bool, on textView: ToasttyComposerUIKitTextView) {
        textView.isEditable = takesText
        textView.isSelectable = takesText
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

    /// Hands the field the tasks it can mention. None of these is observed,
    /// so setting them inside a SwiftUI update changes nothing on screen.
    private func configureMentions(_ textView: ToasttyComposerUIKitTextView) {
        textView.mentionPicker = mentionPicker
        guard let mentionPicker else { return }
        textView.mentionCandidates = mentionCandidates
        mentionPicker.candidates = mentionCandidates
        mentionPicker.textView = textView
    }

    private func synchronize(_ textView: ToasttyComposerUIKitTextView) {
        textView.placeholder = placeholder
        // A text view that stops taking text gives up the keyboard at once:
        // a responder change, which inside this SwiftUI update can spin in
        // the AttributeGraph cycle that `scheduleFocusSync` avoids. The field
        // that has the keyboard keeps taking text here; the focus sync drops
        // the keyboard after the update and then locks the field.
        Self.setTakesText(isEnabled || textView.isFirstResponder, on: textView)
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
        private var isFocusSyncScheduled = false
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
            guard !textView.draftText.utf16.elementsEqual(replacement.text.utf16) else {
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
            textView.setDraft(replacement.text)
            lastNativeText = replacement.text
            textView.selectedRange = NSRange(location: textView.textStorage.length, length: 0)
            isReplacingText = false
            #if DEBUG
            textView.traceTyping(.replacementApplied, editRevision: editRevision, replacementRevision: replacement.revision,
                                         expectedEditRevision: replacement.expectedEditRevision)
            #endif
            reportCompletion(replacement, in: textView, rejected: false)
            textView.textDidChange()
            textView.requestSelectionVisibility()
            // This can run inside a SwiftUI update: the list follows the new
            // text after it.
            scheduleMentionPickerUpdate(for: textView)
        }

        /// Moves the keyboard focus to match `isFocused` once the current
        /// SwiftUI update has finished. A responder change asks the hosting
        /// view whether it can take the focus, and SwiftUI answers with a
        /// nested view-graph update; inside `updateUIView` that update can
        /// depend on this view's own update and spin in an AttributeGraph
        /// cycle, which froze the app on Send in a task's session.
        func scheduleFocusSync(for textView: ToasttyComposerUIKitTextView) {
            guard needsFocusChange(textView), isFocusSyncScheduled == false else { return }
            isFocusSyncScheduled = true
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self else { return }
                self.isFocusSyncScheduled = false
                guard self.isActive, let textView else { return }
                self.syncFocus(of: textView)
            }
        }

        private func needsFocusChange(_ textView: ToasttyComposerUIKitTextView) -> Bool {
            parent.isFocused && parent.isEnabled ? !textView.isFirstResponder : textView.isFirstResponder
        }

        private func syncFocus(of textView: ToasttyComposerUIKitTextView) {
            // The latest state wins: a focus change and its reversal in one
            // update cycle leave the keyboard as it is.
            guard needsFocusChange(textView) else { return }
            if textView.isFirstResponder {
                textView.resignFirstResponder()
                ToasttyComposerTextView.setTakesText(parent.isEnabled || textView.isFirstResponder, on: textView)
            } else if textView.becomeFirstResponder() {
                textView.requestSelectionVisibility()
            }
        }

        func reportCompletion(_ replacement: ToasttyComposerReplacement, in textView: ToasttyComposerUIKitTextView, rejected: Bool) {
            // updateUIView cannot synchronously mutate SwiftUI state. On a
            // completion, publish the latest native text when the callback runs.
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView, self.isActive,
                      self.lastReplacementRevision == replacement.revision else { return }
                self.recordNativeEdit(in: textView)
                self.parent.onReplacementCompleted(ToasttyComposerReplacementResult(
                    revision: replacement.revision, nativeText: textView.draftText,
                    nativeEditRevision: self.editRevision, wasApplied: !rejected
                ))
            }
        }

        init(parent: ToasttyComposerTextView) {
            self.parent = parent
            self.editRevision = parent.editRevision
            self.lastNativeText = parent.text
        }

        /// The draft's text: a mention counts as its task's link.
        private func recordNativeEdit(in textView: ToasttyComposerUIKitTextView) {
            let text = textView.draftText
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
            guard let textView = textView as? ToasttyComposerUIKitTextView else { return }
            textView.requestSelectionVisibility()
            updateMentionPicker(for: textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            #if DEBUG
            (textView as? ToasttyComposerUIKitTextView)?.traceTyping(.focusEnded, editRevision: editRevision)
            #endif
            if parent.isFocused {
                parent.isFocused = false
            }
            // The list closes with the keyboard, after this callback, unless
            // the field took the keyboard back.
            if let picker = parent.mentionPicker {
                DispatchQueue.main.async { [weak textView] in
                    guard textView?.isFirstResponder != true else { return }
                    picker.close()
                }
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isReplacingText, let textView = textView as? ToasttyComposerUIKitTextView else { return }
            // A mention's insertion publishes once its word is marked.
            guard textView.isInsertingMention == false else { return }
            textView.normalizeMentions()
            publishNativeEdit(of: textView)
        }

        /// Publishes the field's text as the draft after an edit: the
        /// user's, through the text view's callbacks, or the field's own, a
        /// mention put in or a paste with mentions. Never inside a SwiftUI
        /// update.
        func publishNativeEdit(of textView: ToasttyComposerUIKitTextView) {
            guard isActive, !isReplacingText else { return }
            textView.textDidChange()
            recordNativeEdit(in: textView)
            #if DEBUG
            textView.traceTyping(.textChanged, editRevision: editRevision)
            #endif
            applyPendingReplacement(to: textView)
            parent.onTextChange(textView.draftText, editRevision)
            updateMentionPicker(for: textView)
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
            if !isReplacingText {
                textView.keepSelectionOutOfMentions()
            }
            applyPendingReplacement(to: textView)
            textView.requestSelectionVisibility()
            updateMentionPicker(for: textView)
        }

        /// The list follows the text and the caret. Only from the text
        /// view's own callbacks, while it has the keyboard: a replacement
        /// that runs inside a SwiftUI update schedules it instead.
        private func updateMentionPicker(for textView: ToasttyComposerUIKitTextView) {
            guard let picker = parent.mentionPicker, isActive, !isReplacingText,
                  textView.isInsertingMention == false, textView.isFirstResponder else { return }
            picker.update(text: textView.mentionTriggerText, selection: textView.selectedRange)
        }

        private func scheduleMentionPickerUpdate(for textView: ToasttyComposerUIKitTextView) {
            guard let picker = parent.mentionPicker else { return }
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, self.isActive, let textView, textView.isFirstResponder else {
                    picker.close()
                    return
                }
                self.updateMentionPicker(for: textView)
            }
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
        if text.isEmpty {
            accessibilityValue = placeholder
        } else if ToasttyComposerMentionText.containsMention(textStorage) {
            // VoiceOver reads a mention as "mention, <title>".
            accessibilityValue = ToasttyComposerMentionText.spoken(textStorage)
        } else {
            accessibilityValue = text
        }
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

    // MARK: - Mentions

    /// The coordinator chat's list of tasks to mention. `nil` in a task's
    /// session: the field then edits plain text, as before.
    weak var mentionPicker: ToasttyMentionPicker?
    var mentionCandidates: [CoordinatorMentionCandidate] = [] {
        didSet {
            if oldValue != mentionCandidates { mentionCandidatesByIDCache = nil }
        }
    }
    private var mentionCandidatesByIDCache: [UUID: CoordinatorMentionCandidate]?
    /// Publishes the draft after an edit that the field made itself.
    var onMentionEdit: (() -> Void)?
    /// While the field puts in a mention's text: its word is not marked yet,
    /// so the edit is published once it is.
    private(set) var isInsertingMention = false
    private var isAdjustingSelection = false
    private var lastSelection = NSRange(location: 0, length: 0)
    /// The color of text that is not a mention. `textColor` can read back a
    /// mention's color when the text starts with one.
    var plainTextColor = UIColor(ToasttyDesignTokens.primaryText)

    var mentionsEnabled: Bool { mentionPicker != nil }

    /// The text as the draft holds it: each mention as its task's link.
    var draftText: String {
        guard ToasttyComposerMentionText.containsMention(textStorage) else { return text ?? "" }
        return ToasttyComposerMentionText.serialized(textStorage)
    }

    /// The text that the `@` rule reads, with each mention as one object.
    var mentionTriggerText: NSString {
        ToasttyComposerMentionText.triggerText(textStorage)
    }

    /// The attributes of text that is not a mention.
    var plainTextAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font ?? UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: plainTextColor,
        ]
    }

    private var mentionCandidatesByID: [UUID: CoordinatorMentionCandidate] {
        if let mentionCandidatesByIDCache { return mentionCandidatesByIDCache }
        let byID = Dictionary(mentionCandidates.map { ($0.taskID, $0) }, uniquingKeysWith: { first, _ in first })
        mentionCandidatesByIDCache = byID
        return byID
    }

    /// Shows the draft. In the coordinator's chat, a link to a task that can
    /// be mentioned shows as that task's mention.
    func setDraft(_ draft: String) {
        guard mentionsEnabled else {
            text = draft
            return
        }
        let attributes = plainTextAttributes
        attributedText = ToasttyComposerMentionText.attributed(
            draft, candidates: mentionCandidatesByID, attributes: attributes
        ) ?? NSAttributedString(string: draft, attributes: attributes)
        typingAttributes = attributes
    }

    /// The mention's word that holds the character at `index`.
    func mentionRange(at index: Int) -> NSRange? {
        guard index >= 0, index < textStorage.length else { return nil }
        var range = NSRange(location: NSNotFound, length: 0)
        let value = textStorage.attribute(
            .toasttyMention, at: index, longestEffectiveRange: &range,
            in: NSRange(location: 0, length: textStorage.length)
        )
        return value is ToasttyMentionToken ? range : nil
    }

    /// Puts the task's mention in place of the `@` and the search before
    /// the caret, then a space unless one follows, with the caret after
    /// them. The text goes in through the field's own editing, so Undo
    /// takes it out.
    func insertMention(_ candidate: CoordinatorMentionCandidate) {
        guard mentionsEnabled, isEditable else { return }
        if markedTextRange != nil { unmarkText() }
        let selection = selectedRange
        guard selection.length == 0,
              let match = CoordinatorMentionTrigger.match(in: mentionTriggerText, caret: selection.location) else { return }
        let token = ToasttyMentionToken(candidate: candidate)
        let word = NSRange(location: 0, length: (token.text as NSString).length)
        insert(
            token.text,
            mentions: [(range: word, token: token)],
            replacing: NSRange(location: match.anchor, length: selection.location - match.anchor),
            spaceAfter: true
        )
    }

    /// The paperclip's Mention a Task: types `@` at the caret, with a space
    /// before it when the caret follows a word or a mention, so that the
    /// list opens.
    func beginMention() {
        guard mentionsEnabled, isEditable else { return }
        if isFirstResponder == false { _ = becomeFirstResponder() }
        if markedTextRange != nil { unmarkText() }
        let location = selectedRange.location
        let text = mentionTriggerText
        var needsSpace = false
        if location > 0, location <= text.length {
            let previous = text.character(at: location - 1)
            needsSpace = previous == CoordinatorMentionTrigger.objectReplacementCharacter
                || CoordinatorMentionTrigger.startsAMention(after: previous) == false
        }
        insertText(needsSpace ? " @" : "@")
    }

    /// One Delete takes out a whole mention. It replaces the mention's
    /// range with nothing: a selected word that the system deletes takes the
    /// space before it too (smart delete). The replacement reaches the text
    /// view's change callback, which publishes the draft, and Undo puts the
    /// mention back.
    override func deleteBackward() {
        let selection = selectedRange
        if markedTextRange == nil, selection.length == 0, selection.location > 0,
           let mention = mentionRange(at: selection.location - 1),
           let start = position(from: beginningOfDocument, offset: mention.location),
           let end = position(from: start, offset: mention.length),
           let range = textRange(from: start, to: end) {
            replace(range, withText: "")
            return
        }
        super.deleteBackward()
    }

    /// The caret does not stop inside a mention, and a selection takes a
    /// mention whole. A caret that steps one character into a mention, as an
    /// arrow key moves it, goes on to its other side; any other move, such as
    /// a tap, goes to the nearer side. Text typed next to a mention is plain
    /// text.
    func keepSelectionOutOfMentions() {
        guard mentionsEnabled, isAdjustingSelection == false, markedTextRange == nil else { return }
        let selection = selectedRange
        var adjusted = selection
        if selection.length == 0 {
            if let mention = mentionRange(at: selection.location), mention.location < selection.location {
                let end = NSMaxRange(mention)
                let string = textStorage.string as NSString
                let firstStep = NSMaxRange(string.rangeOfComposedCharacterSequence(at: mention.location))
                let lastStep = string.rangeOfComposedCharacterSequence(at: end - 1).location
                if lastSelection.length == 0, lastSelection.location == mention.location, selection.location == firstStep {
                    adjusted.location = end
                } else if lastSelection.length == 0, lastSelection.location == end, selection.location == lastStep {
                    adjusted.location = mention.location
                } else {
                    adjusted.location = selection.location - mention.location <= end - selection.location
                        ? mention.location : end
                }
            }
        } else if selection.location != NSNotFound {
            var lower = selection.location
            var upper = NSMaxRange(selection)
            if let mention = mentionRange(at: lower), mention.location < lower { lower = mention.location }
            if upper > 0, let mention = mentionRange(at: upper - 1), NSMaxRange(mention) > upper { upper = NSMaxRange(mention) }
            adjusted = NSRange(location: lower, length: upper - lower)
        }
        if adjusted != selection {
            setSelectionQuietly(adjusted)
        } else {
            lastSelection = selection
        }
        if typingAttributes[.toasttyMention] != nil {
            typingAttributes = plainTextAttributes
        }
    }

    /// A mention whose word an edit changed, such as autocorrect across
    /// it, becomes plain text. Text typed against a mention's word loses the
    /// mention's look. Runs in the text view's own change callback.
    func normalizeMentions() {
        guard markedTextRange == nil else { return }
        let mentions = ToasttyComposerMentionText.mentions(in: textStorage)
        guard mentions.isEmpty == false else { return }
        let string = textStorage.string as NSString
        var plain: [NSRange] = []
        for (range, token) in mentions {
            let word = string.substring(with: range)
            guard word != token.text else { continue }
            let wordLength = (token.text as NSString).length
            if word.hasPrefix(token.text) {
                plain.append(NSRange(location: range.location + wordLength, length: range.length - wordLength))
            } else if word.hasSuffix(token.text) {
                plain.append(NSRange(location: range.location, length: range.length - wordLength))
            } else {
                plain.append(range)
            }
        }
        guard plain.isEmpty == false else { return }
        textStorage.beginEditing()
        for range in plain {
            textStorage.removeAttribute(.toasttyMention, range: range)
            textStorage.removeAttribute(.backgroundColor, range: range)
            textStorage.addAttribute(.foregroundColor, value: plainTextColor, range: range)
        }
        textStorage.endEditing()
    }

    /// Copy and Cut of text with a mention give the task's link, as the
    /// message does.
    override func copy(_ sender: Any?) {
        guard let link = serializedSelectionWithMention() else { return super.copy(sender) }
        UIPasteboard.general.string = link
    }

    override func cut(_ sender: Any?) {
        guard isEditable, let link = serializedSelectionWithMention(), let range = selectedTextRange else {
            return super.cut(sender)
        }
        UIPasteboard.general.string = link
        // Like any replacement, this reaches the change callback, which
        // publishes the draft.
        replace(range, withText: "")
    }

    /// A paste with a link to a task that can be mentioned puts in its
    /// mention. Other text pastes as before.
    override func paste(_ sender: Any?) {
        guard mentionsEnabled, isEditable, let string = UIPasteboard.general.string,
              let attributed = ToasttyComposerMentionText.attributed(
                  string, candidates: mentionCandidatesByID, attributes: plainTextAttributes
              ) else {
            return super.paste(sender)
        }
        if markedTextRange != nil { unmarkText() }
        insert(
            attributed.string,
            mentions: ToasttyComposerMentionText.mentions(in: attributed),
            replacing: selectedRange,
            spaceAfter: false
        )
    }

    private func serializedSelectionWithMention() -> String? {
        let selection = selectedRange
        guard selection.location != NSNotFound, selection.length > 0, NSMaxRange(selection) <= textStorage.length
        else { return nil }
        let part = textStorage.attributedSubstring(from: selection)
        guard ToasttyComposerMentionText.containsMention(part) else { return nil }
        return ToasttyComposerMentionText.serialized(part)
    }

    /// Replaces `range` with `string` through the field's own editing, then
    /// marks the mentions' words (`mentions` are ranges in `string`) and
    /// publishes the draft once.
    private func insert(
        _ string: String,
        mentions: [(range: NSRange, token: ToasttyMentionToken)],
        replacing range: NSRange,
        spaceAfter: Bool
    ) {
        guard range.location != NSNotFound, NSMaxRange(range) <= textStorage.length else { return }
        var inserted = string
        var caretOffset = 0
        if spaceAfter {
            let after = NSMaxRange(range)
            if after < textStorage.length, (textStorage.string as NSString).character(at: after) == 0x20 {
                caretOffset = 1
            } else {
                inserted += " "
            }
        }
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end) else { return }
        isInsertingMention = true
        replace(textRange, withText: inserted)
        isInsertingMention = false
        let insertedRange = NSRange(location: range.location, length: (inserted as NSString).length)
        // Mark the words only when the field took the text as given.
        if NSMaxRange(insertedRange) <= textStorage.length,
           (textStorage.string as NSString).substring(with: insertedRange) == inserted {
            let attributes = plainTextAttributes
            textStorage.beginEditing()
            for mention in mentions {
                textStorage.setAttributes(
                    ToasttyComposerMentionText.mentionAttributes(mention.token, over: attributes),
                    range: NSRange(location: range.location + mention.range.location, length: mention.range.length)
                )
            }
            textStorage.endEditing()
        }
        setSelectionQuietly(NSRange(
            location: min(NSMaxRange(insertedRange) + caretOffset, textStorage.length), length: 0
        ))
        typingAttributes = plainTextAttributes
        onMentionEdit?()
    }

    /// Moves the selection without the mention rules acting on the move.
    private func setSelectionQuietly(_ range: NSRange) {
        isAdjustingSelection = true
        selectedRange = range
        isAdjustingSelection = false
        lastSelection = range
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

