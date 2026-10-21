import AppKit
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
    let onCancel: () -> Void
    /// Returns true when it took the pasteboard as attachments.
    let onPasteAttachments: (NSPasteboard) -> Bool
    let dropTarget: QuickEntryDropTarget

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
        textView.registerForDraggedTypes(QuickEntryModel.droppableTypes)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        context.coordinator.textView = textView
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
            // The panel may not be key yet on the first pass.
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    private func configure(_ textView: QuickEntryNSTextView) {
        textView.placeholder = placeholder
        textView.isEditable = isEditable
        textView.onSubmit = onSubmit
        textView.onCancel = onCancel
        textView.onPasteAttachments = onPasteAttachments
        textView.dropTarget = dropTarget
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: QuickEntryNSTextView?
        var lastFocusRequestID: Int?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

final class QuickEntryNSTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onPasteAttachments: (NSPasteboard) -> Bool = { _ in false }
    weak var dropTarget: QuickEntryDropTarget?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if Self.isReturn(event), modifiers.contains(.command), hasMarkedText() == false {
            onSubmit()
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

    // Files and images attach; anything else pastes as plain text. Do not
    // narrow readablePasteboardTypes to get plain text: pasteAsPlainText(_:)
    // then inserts nothing.
    override func paste(_ sender: Any?) {
        if onPasteAttachments(.general) {
            return
        }
        pasteAsPlainText(sender)
    }

    // Files and images dropped on the text attach, as they do anywhere else
    // on the panel; dropped text and links still go into the text.

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if let dropTarget, dropTarget.dropEntered(sender.draggingPasteboard) {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if QuickEntryDropTarget.carriesAttachments(sender.draggingPasteboard) {
            return .copy
        }
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropTarget?.dropExited()
        super.draggingExited(sender)
    }

    // NSTextView agrees to a drop only for types it reads as text, so a
    // promised file or image data would end here, before
    // performDragOperation(_:), and attach nothing.
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if QuickEntryDropTarget.carriesAttachments(sender.draggingPasteboard) {
            return true
        }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let dropTarget, QuickEntryDropTarget.carriesAttachments(sender.draggingPasteboard) {
            return dropTarget.performDrop(sender.draggingPasteboard)
        }
        dropTarget?.dropExited()
        return super.performDragOperation(sender)
    }

    // A drag can end without an exit or a drop, for example when it is
    // cancelled over the panel; the highlight must not stay on.
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dropTarget?.dropExited()
        super.draggingEnded(sender)
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
