import AppKit
import Combine
import CoreState
import SwiftUI

/// The task text field. An `NSTextView`, so the panel can handle Esc,
/// ⌘↩ and pasted images itself: SwiftUI's `TextEditor` turns Esc into
/// word completion and pastes only text.
struct QuickEntryTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isEditable: Bool
    let focusRequestID: Int
    let onSubmit: () -> Void
    /// ⌥⌘↩: create the task directly.
    var onCreateTask: () -> Void = {}
    let onCancel: () -> Void
    /// Returns true when it took the pasteboard as attachments.
    let onPasteAttachments: (NSPasteboard) -> Bool
    let dropTarget: AttachmentDropTarget
    /// Words that dictation finished. They go in at the caret.
    var dictatedWords: PassthroughSubject<String, Never>?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = QuickEntryNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: Self.fontSize)
        textView.textColor = NSColor(ToastyTheme.primaryText)
        textView.insertionPointColor = NSColor(ToastyTheme.accent)
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = Self.lineSpacing
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes[.paragraphStyle] = paragraph
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityIdentifier("quick-entry.text")
        textView.string = text
        textView.registerForDraggedTypes(DraftAttachments.droppableTypes)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.dictatedWords = dictatedWords?.sink { [weak textView] words in
            textView?.insertDictated(words)
        }
        configure(textView)
        return scrollView
    }

    /// The design's 15.5 pt text at 1.5 line height.
    static let fontSize: CGFloat = 15.5
    static let lineSpacing: CGFloat = 4.5
    /// The text area grows with the text between these heights, then scrolls.
    static let minimumHeight: CGFloat = 66
    static let maximumHeight: CGFloat = 260

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let textView = context.coordinator.textView else {
            return nil
        }
        // Measured on a copy: SwiftUI may propose sizes it then discards, and
        // the text on screen must keep wrapping at its real width.
        let storage = NSTextStorage(attributedString: textView.attributedString())
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = textView.textContainer?.lineFragmentPadding ?? 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2
        return CGSize(width: width, height: min(max(used, Self.minimumHeight), Self.maximumHeight))
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.text = $text
        configure(textView)
        if textView.string != text {
            textView.string = text
        }
        if context.coordinator.lastFocusRequestID != focusRequestID {
            context.coordinator.lastFocusRequestID = focusRequestID
            // Leave the SwiftUI update before changing AppKit focus.
            DispatchQueue.main.async {
                textView.requestFocus()
            }
        }
    }

    private func configure(_ textView: QuickEntryNSTextView) {
        textView.placeholder = placeholder
        textView.isEditable = isEditable
        textView.onSubmit = onSubmit
        textView.onCreateTask = onCreateTask
        textView.onCancel = onCancel
        textView.onPasteAttachments = onPasteAttachments
        textView.dropTarget = dropTarget
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: QuickEntryNSTextView?
        var lastFocusRequestID: Int?
        var dictatedWords: AnyCancellable?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

final class QuickEntryNSTextView: AttachmentTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }
    var onSubmit: () -> Void = {}
    var onCreateTask: () -> Void = {}
    var onCancel: () -> Void = {}

    private var hasPendingFocusRequest = false

    /// SwiftUI can update the editor before it attaches to the panel.
    /// Keep that request until AppKit can assign its first responder.
    func requestFocus() {
        hasPendingFocusRequest = true
        applyPendingFocus()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard hasPendingFocusRequest, window != nil else { return }
        // Attachment can happen inside SwiftUI layout too.
        DispatchQueue.main.async { [weak self] in self?.applyPendingFocus() }
    }

    private func applyPendingFocus() {
        guard hasPendingFocusRequest, let window else { return }
        // A request waits only for attachment. Do not retry a refused
        // request on a later attachment, after the user moves focus.
        hasPendingFocusRequest = false
        guard isEditable else { return }
        if window.makeFirstResponder(self) == false {
            ToasttyLog.debug("Could not focus the quick entry editor", category: .tasks, metadata: [
                "window_number": String(window.windowNumber),
                "is_key_window": String(window.isKeyWindow),
            ])
        }
    }

    /// Puts dictated words at the caret, or in place of the selection,
    /// with the spaces they need next to the text around them.
    func insertDictated(_ words: String) {
        guard isEditable else { return }
        let selection = selectedRange()
        guard let range = Range(selection, in: string) else { return }
        let insertion = QuickEntryDictation.insertion(
            of: words,
            before: string[..<range.lowerBound].last,
            after: string[range.upperBound...].first
        )
        guard insertion.isEmpty == false else { return }
        insertText(insertion, replacementRange: selection)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if Self.isReturn(event), modifiers.contains(.command), hasMarkedText() == false {
            if modifiers.contains(.option) {
                onCreateTask()
            } else {
                onSubmit()
            }
            return
        }
        // Handled here as well as in cancelOperation(_:), because a key
        // binding can turn Esc into word completion instead.
        if event.keyCode == 53, modifiers.isEmpty, hasMarkedText() == false {
            onCancel()
            return
        }
        super.keyDown(with: event)
    }

    /// Esc: AppKit sends this through the key bindings. While an input
    /// method is composing, Esc belongs to it.
    override func cancelOperation(_ sender: Any?) {
        guard hasMarkedText() == false else {
            super.cancelOperation(sender)
            return
        }
        onCancel()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, placeholder.isEmpty == false else { return }
        let origin = NSPoint(
            x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerInset.height
        )
        (placeholder as NSString).draw(at: origin, withAttributes: [
            .font: font ?? .systemFont(ofSize: 14),
            .foregroundColor: NSColor(QuickEntryView.mutedText),
        ])
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    static func isReturn(_ event: NSEvent) -> Bool {
        event.keyCode == 36 || event.keyCode == 76
    }
}
