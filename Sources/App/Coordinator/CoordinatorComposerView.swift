import AppKit
import ConversationUI
import CoreState
import PhotosUI
import SwiftUI

/// While the coordinator's turn runs: what Send does with the text.
struct CoordinatorComposerDelivery: Equatable {
    /// Send types the text into the running turn. Otherwise the text waits
    /// in the queue for the turn's end.
    var steers: Bool
    /// The running turn can take a steer now.
    var canSteer: Bool
}

/// The composer for a message to the coordinator: the coordinator's message
/// that it replies to, a row of attached files,
/// a ＋ menu that attaches files or photos, a text field that grows with its
/// text, and one button that sends, or stops the running turn. While a turn
/// runs, a chip beside the button says whether Send steers the turn or
/// queues the message.
///
/// It knows nothing about the chat around it, so another window can host
/// it: the host gives the text, the files, the state and the actions.
struct CoordinatorComposerView: View {
    @Binding var text: String
    /// The files attached to the message.
    @ObservedObject var attachments: DraftAttachments
    /// The coordinator's message that this message replies to.
    var reply: CoordinatorReplyTarget?
    /// ✕ on the reply, or Escape in an empty field.
    var onCancelReply: () -> Void = {}
    var placeholder = "Message the coordinator…"
    /// A turn runs that Stop can end.
    let canStop: Bool
    /// False while the message is being sent with its files.
    var isEditable = true
    /// While a turn runs, how Send delivers the text. `nil` hides the chip.
    var delivery: CoordinatorComposerDelivery?
    /// Counts up each time the text field should take the keyboard.
    let focusRequestID: Int
    /// The size of the text in the field.
    var fontSize = CoordinatorComposerTextEditor.defaultFontSize
    let onSend: () -> Void
    /// Command-Return: the text waits for the turn's end, whatever the chip
    /// shows.
    var onQueue: () -> Void = {}
    /// The user chose Queue (`true`) or Steer on the chip.
    var onChooseQueue: (Bool) -> Void = { _ in }
    let onStop: () -> Void
    /// ＋ › Files…: opens the open panel.
    var onChooseFiles: () -> Void = {}
    /// Takes files dropped on the text field. Required: without it,
    /// AppKit would type a dropped file's path into the text.
    let dropTarget: AttachmentDropTarget
    /// Tells the host which text view is the composer's, so the host can
    /// give it the keyboard.
    var onTextView: (NSTextView?) -> Void = { _ in }

    @State private var isPhotosPickerPresented = false
    @State private var photoSelection: [PhotosPickerItem] = []

    /// Text or a file to send.
    private var hasMessage: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || attachments.attachments.isEmpty == false
    }

    /// A file that is still being copied holds the message back.
    private var canSend: Bool {
        hasMessage && isEditable && attachments.pendingCount == 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reply {
                replyBar(reply)
            }
            if attachments.isEmpty == false {
                tray
            }
            // The buttons are as tall as one line of the field, so they line
            // up with the field's last line at every text size.
            HStack(alignment: .bottom, spacing: 6) {
                attachMenu
                    .frame(height: rowHeight)

                CoordinatorComposerTextEditor(
                    text: $text,
                    placeholder: placeholder,
                    isEditable: isEditable,
                    focusRequestID: focusRequestID,
                    fontSize: fontSize,
                    onSubmit: { if canSend { onSend() } },
                    onQueue: { if canSend { onQueue() } },
                    onCancel: {
                        guard reply != nil, text.isEmpty, isEditable else { return false }
                        onCancelReply()
                        return true
                    },
                    onPasteAttachments: { attachments.pasteAttachments(from: $0) },
                    canPasteAttachments: { attachments.canPasteAttachments(from: $0) },
                    dropTarget: dropTarget,
                    onTextView: onTextView
                )

                HStack(spacing: 6) {
                    // Stop while a turn runs and the field is empty. With text
                    // or a file in the field the button sends, with the chip
                    // beside it.
                    if canStop, hasMessage == false {
                        button(systemImage: "stop.fill", label: "Stop", identifier: "coordinator.chat.stop", action: onStop)
                            .help("Stop the coordinator's turn")
                    } else {
                        if let delivery {
                            deliveryChip(delivery)
                        }
                        button(
                            systemImage: "arrow.up",
                            label: Self.sendLabel(delivery),
                            identifier: "coordinator.chat.send",
                            action: onSend
                        )
                        .disabled(canSend == false)
                        .help(Self.sendHelp(delivery))
                    }
                }
                .frame(height: rowHeight)
            }
            .padding(.vertical, 2)
        }
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(ToastyTheme.elevatedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    attachments.isDropTargeted ? ToastyTheme.accent : ToastyTheme.hairline,
                    lineWidth: attachments.isDropTargeted ? 1.5 : 1
                )
        }
        .photosPicker(
            isPresented: $isPhotosPickerPresented,
            selection: $photoSelection,
            maxSelectionCount: max(1, TaskRecord.maximumAttachmentCount - attachments.attachments.count - attachments.pendingCount),
            matching: .images
        )
        .onChange(of: photoSelection) { _, items in
            guard items.isEmpty == false else { return }
            attachments.attachPhotos(items)
            photoSelection = []
        }
    }

    static let trayHeight: CGFloat = 74

    /// The height of the field with one line of text.
    private var rowHeight: CGFloat {
        CoordinatorComposerTextEditor.singleLineHeight(fontSize: fontSize)
    }

    /// The coordinator's message that this message replies to: who and
    /// when, the start of the message on two lines, and ✕.
    private func replyBar(_ reply: CoordinatorReplyTarget) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text(reply.time.map { "Replying to the coordinator · \($0)" } ?? "Replying to the coordinator")
                } icon: {
                    Image(systemName: "arrowshape.turn.up.left")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ToastyTheme.primaryText)
                Text(ToasttyMessageQuote.excerpt(of: reply.text))
                    .font(.system(size: 11))
                    .foregroundStyle(ToastyTheme.inactiveText)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("coordinator.chat.reply.excerpt")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onCancelReply) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(ToastyTheme.subtleText)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isEditable == false)
            .help("Do not reply to this message (Escape in an empty field)")
            .accessibilityLabel("Remove reply")
            .accessibilityIdentifier("coordinator.chat.reply.remove")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(ToastyTheme.accent.opacity(0.08))
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(ToastyTheme.accent)
                .frame(width: 3)
                .padding(.vertical, 2)
        }
        .padding(.horizontal, 2)
        .padding(.top, 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coordinator.chat.reply")
    }

    /// The attached files, in a row that scrolls sideways once it is full,
    /// with a spinner while a file is being copied in.
    private var tray: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments.attachments) { attachment in
                        AttachmentChip(attachment: attachment, accessibilityIdentifier: "coordinator.chat.attachment") {
                            attachments.remove(id: attachment.id)
                        }
                        .disabled(isEditable == false)
                    }
                    if attachments.pendingCount > 0 {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, 4)
                            .accessibilityLabel("Copying a file")
                            .accessibilityIdentifier("coordinator.chat.attachment.copying")
                    }
                    Color.clear.frame(width: 1, height: 1).id(Self.trayEndID)
                }
                .padding(.vertical, 1)
                .padding(.leading, 2)
            }
            .frame(height: Self.trayHeight)
            // Keeps the newest file in view once the files fill the row.
            .onChange(of: attachments.attachments.count + attachments.pendingCount) {
                scroller.scrollTo(Self.trayEndID, anchor: .trailing)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coordinator.chat.attachments")
    }

    private static let trayEndID = "end"

    /// ＋: attach files with the open panel, or photos from Photos.
    private var attachMenu: some View {
        Menu {
            Button("Files…", action: onChooseFiles)
                .accessibilityIdentifier("coordinator.chat.attach.files")
            Button("Photos…") { isPhotosPickerPresented = true }
                .accessibilityIdentifier("coordinator.chat.attach.photos")
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ToastyTheme.subtleText)
                .frame(width: CoordinatorComposerTextEditor.buttonSize, height: CoordinatorComposerTextEditor.buttonSize)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isEditable == false || attachments.canAttachMore == false)
        .help("Attach files or photos. You can also paste or drop them here.")
        .accessibilityLabel("Attach")
        .accessibilityIdentifier("coordinator.chat.attach")
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
                .frame(width: CoordinatorComposerTextEditor.buttonSize, height: CoordinatorComposerTextEditor.buttonSize)
                .background(Circle().fill(ToastyTheme.accent))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(canSend || canStop ? 1 : 0.35)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    /// Steer is the default and looks plain. Queue takes the accent, also
    /// when the turn cannot take a steer: the color marks a send that does
    /// not go into the running turn.
    private func deliveryChip(_ delivery: CoordinatorComposerDelivery) -> some View {
        let queues = delivery.steers == false
        return Menu {
            Button("Steer") { onChooseQueue(false) }
                .disabled(delivery.canSteer == false)
            Button("Queue") { onChooseQueue(true) }
        } label: {
            HStack(spacing: 4) {
                Text(queues ? "Queue" : "Steer")
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(queues ? ToastyTheme.accent : ToastyTheme.inactiveText)
            .padding(.horizontal, 9)
            .frame(height: CoordinatorComposerTextEditor.buttonSize)
            .background(Capsule().fill(queues ? ToastyTheme.accent.opacity(0.16) : Color.clear))
            .overlay {
                Capsule().strokeBorder(queues ? ToastyTheme.accent.opacity(0.45) : ToastyTheme.subtleBorder, lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help(Self.chipHelp(delivery))
        .accessibilityLabel(queues ? "Queue selected" : "Steer selected")
        .accessibilityIdentifier("coordinator.chat.delivery")
    }

    static func sendLabel(_ delivery: CoordinatorComposerDelivery?) -> String {
        guard let delivery else { return "Send" }
        return delivery.steers ? "Steer" : "Queue"
    }

    static func sendHelp(_ delivery: CoordinatorComposerDelivery?) -> String {
        guard let delivery else { return "Send (Return). Shift-Return starts a new line." }
        return delivery.steers
            ? "Steer: add to the running turn (Return). Command-Return queues. Shift-Return starts a new line."
            : "Queue: send after this turn (Return). Shift-Return starts a new line."
    }

    static func chipHelp(_ delivery: CoordinatorComposerDelivery) -> String {
        if delivery.canSteer == false {
            return "The running turn cannot take a steer now, so the message waits for the turn's end."
        }
        return "Steer adds the message to the running turn. Queue sends it after this turn."
    }
}

/// The composer's text field. An `NSTextView`, so Return can send while
/// Shift-Return starts a new line, and an input method keeps its own Return.
struct CoordinatorComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var isEditable = true
    let focusRequestID: Int
    let fontSize: CGFloat
    let onSubmit: () -> Void
    /// Command-Return.
    var onQueue: () -> Void = {}
    /// Escape. Returns true when it took the key.
    var onCancel: () -> Bool = { false }
    /// Returns true when it took the pasteboard as attachments.
    let onPasteAttachments: (NSPasteboard) -> Bool
    let canPasteAttachments: (NSPasteboard) -> Bool
    let dropTarget: AttachmentDropTarget
    let onTextView: (NSTextView?) -> Void

    static let defaultFontSize: CGFloat = 13
    static let lineSpacing: CGFloat = 3
    /// The field grows with its text up to this height, then scrolls.
    static let maximumHeight: CGFloat = 180
    /// The width and height of the buttons beside the field.
    static let buttonSize: CGFloat = 24
    /// The space above and below the text, at least.
    static let minimumVerticalInset: CGFloat = 2

    /// The height of one line of text, as the field lays it out.
    static func lineHeight(fontSize: CGFloat) -> CGFloat {
        NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: fontSize))
    }

    /// The field's height with one line: at least the buttons' height, with
    /// the line in the middle.
    static func singleLineHeight(fontSize: CGFloat) -> CGFloat {
        ceil(max(buttonSize, lineHeight(fontSize: fontSize) + 2 * minimumVerticalInset))
    }

    /// The space above and below the text. It puts one line in the middle
    /// of the field, and the last line in the middle of the buttons beside it.
    static func verticalInset(fontSize: CGFloat) -> CGFloat {
        (singleLineHeight(fontSize: fontSize) - lineHeight(fontSize: fontSize)) / 2
    }

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
        textView.textColor = NSColor(ToastyTheme.primaryText)
        textView.insertionPointColor = NSColor(ToastyTheme.accent)
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
        // Takes files and images as well as text.
        textView.updateDragTypeRegistration()
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
        let lineHeight = Self.lineHeight(fontSize: fontSize)
        // An empty copy measures one line in the default font, which can be
        // taller than a line at a small text size.
        let textHeight = storage.length == 0 ? lineHeight : max(layoutManager.usedRect(for: container).height, lineHeight)
        let used = textHeight + Self.verticalInset(fontSize: fontSize) * 2
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
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        if textView.font?.pointSize != fontSize {
            textView.font = .systemFont(ofSize: fontSize)
        }
        let inset = NSSize(width: 0, height: Self.verticalInset(fontSize: fontSize))
        if textView.textContainerInset != inset {
            textView.textContainerInset = inset
        }
        textView.onSubmit = onSubmit
        textView.onQueue = onQueue
        textView.onCancel = onCancel
        textView.onPasteAttachments = onPasteAttachments
        textView.canPasteAttachments = canPasteAttachments
        textView.dropTarget = dropTarget
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

final class CoordinatorComposerTextView: AttachmentTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }
    var onSubmit: () -> Void = {}
    var onQueue: () -> Void = {}
    var onCancel: () -> Bool = { false }

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
        // Return sends, and with Command it queues. With Shift or Option it
        // starts a new line. While an input method composes, Return belongs
        // to it.
        if Self.isReturn(event), hasMarkedText() == false {
            let keys = modifiers.subtracting([.numericPad, .function])
            if keys.isEmpty {
                onSubmit()
                return
            }
            if keys == .command {
                onQueue()
                return
            }
            if modifiers.contains(.shift) || modifiers.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
                return
            }
        }
        super.keyDown(with: event)
    }

    /// Escape. While an input method composes, Escape belongs to it.
    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() == false, onCancel() { return }
        super.cancelOperation(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, placeholder.isEmpty == false else { return }
        let origin = NSPoint(
            x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerInset.height
        )
        (placeholder as NSString).draw(at: origin, withAttributes: [
            .font: font ?? .systemFont(ofSize: CoordinatorComposerTextEditor.defaultFontSize),
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
