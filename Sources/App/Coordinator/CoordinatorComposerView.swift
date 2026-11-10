import AppKit
import SwiftUI

/// The composer for a message to the coordinator: a text field that grows
/// with its text, and one button that sends, or stops the running turn.
///
/// It knows nothing about the chat around it, so another window can host
/// it: the host gives the text, the state and the actions.
struct CoordinatorComposerView: View {
    @Binding var text: String
    var placeholder = "Message the coordinator…"
    /// A turn runs that Stop can end.
    let canStop: Bool
    /// Counts up each time the text field should take the keyboard.
    let focusRequestID: Int
    let onSend: () -> Void
    let onStop: () -> Void
    /// Tells the host which text view is the composer's, so the host can
    /// give it the keyboard.
    var onTextView: (NSTextView?) -> Void = { _ in }

    private var canSend: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            CoordinatorComposerTextEditor(
                text: $text,
                placeholder: placeholder,
                focusRequestID: focusRequestID,
                onSubmit: { if canSend { onSend() } },
                onTextView: onTextView
            )
            .padding(.vertical, 4)

            // Stop while a turn runs and the field is empty. With text in
            // the field the button sends: the message then waits its turn.
            if canStop, canSend == false {
                button(systemImage: "stop.fill", label: "Stop", identifier: "coordinator.chat.stop", action: onStop)
                    .help("Stop the coordinator's turn")
            } else {
                button(systemImage: "arrow.up", label: "Send", identifier: "coordinator.chat.send", action: onSend)
                    .disabled(canSend == false)
                    .help("Send (Return). Shift-Return starts a new line.")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(ToastyTheme.elevatedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(ToastyTheme.hairline, lineWidth: 1)
        }
    }

    private func button(
        systemImage: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(ToastyTheme.accentDark)
                .frame(width: 24, height: 24)
                .background(Circle().fill(ToastyTheme.accent))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(canSend || canStop ? 1 : 0.35)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// The composer's text field. An `NSTextView`, so Return can send while
/// Shift-Return starts a new line, and an input method keeps its own Return.
struct CoordinatorComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusRequestID: Int
    let onSubmit: () -> Void
    let onTextView: (NSTextView?) -> Void

    static let fontSize: CGFloat = 13
    static let lineSpacing: CGFloat = 3
    /// The field grows with its text up to this height, then scrolls.
    static let maximumHeight: CGFloat = 180

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CoordinatorComposerTextView()
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
        textView.setAccessibilityIdentifier("coordinator.chat.composer")
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        context.coordinator.textView = textView
        // Only a later request gives the field the keyboard. A composer
        // that is made while its workspace is hidden must not take it.
        context.coordinator.lastFocusRequestID = focusRequestID
        configure(textView)
        onTextView(textView)
        return scrollView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let textView = context.coordinator.textView else {
            return nil
        }
        // Measured on a copy, as the quick entry editor does: SwiftUI may
        // propose sizes it then discards.
        let storage = NSTextStorage(attributedString: textView.attributedString())
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = textView.textContainer?.lineFragmentPadding ?? 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        let lineHeight = ceil(NSFont.systemFont(ofSize: Self.fontSize).boundingRectForFont.height)
        let used = max(layoutManager.usedRect(for: container).height, lineHeight) + textView.textContainerInset.height * 2
        return CGSize(width: width, height: min(ceil(used), Self.maximumHeight))
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.text = $text
        configure(textView)
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
        }
        if context.coordinator.lastFocusRequestID != focusRequestID {
            context.coordinator.lastFocusRequestID = focusRequestID
            // Leave the SwiftUI update before changing AppKit focus.
            DispatchQueue.main.async {
                textView.requestFocus()
            }
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.textView?.delegate = nil
    }

    private func configure(_ textView: CoordinatorComposerTextView) {
        textView.placeholder = placeholder
        textView.onSubmit = onSubmit
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: CoordinatorComposerTextView?
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

final class CoordinatorComposerTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }
    var onSubmit: () -> Void = {}

    private var hasPendingFocusRequest = false

    /// SwiftUI can update the field before it is in a window. The request
    /// waits for that, and is not tried again after it was refused.
    func requestFocus() {
        hasPendingFocusRequest = true
        applyPendingFocus()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard hasPendingFocusRequest, window != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.applyPendingFocus() }
    }

    private func applyPendingFocus() {
        guard hasPendingFocusRequest, let window else { return }
        hasPendingFocusRequest = false
        window.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Return sends. With Shift or Option it starts a new line. While an
        // input method composes, Return belongs to it.
        if Self.isReturn(event), hasMarkedText() == false {
            if modifiers.subtracting([.numericPad, .function]).isEmpty {
                onSubmit()
                return
            }
            if modifiers.contains(.shift) || modifiers.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
                return
            }
        }
        super.keyDown(with: event)
    }

    // The message is plain text, whatever the pasteboard carries.
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, placeholder.isEmpty == false else { return }
        let origin = NSPoint(
            x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerInset.height
        )
        (placeholder as NSString).draw(at: origin, withAttributes: [
            .font: font ?? .systemFont(ofSize: CoordinatorComposerTextEditor.fontSize),
            .foregroundColor: NSColor(ToastyTheme.inactiveText).withAlphaComponent(0.6),
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
