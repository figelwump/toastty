import AppKit
import SwiftUI

/// Comment composer shown in a popover anchored to an annotation mark.
/// Enter saves, Shift+Enter inserts a newline, Escape cancels.
struct BrowserAnnotationCommentEditorView: View {
    let sequenceNumber: Int
    let saveButtonTitle: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    let onDelete: (() -> Void)?
    let onTextChange: ((String) -> Void)?

    @State private var text: String

    init(
        sequenceNumber: Int,
        initialComment: String = "",
        saveButtonTitle: String,
        onSave: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        onDelete: (() -> Void)? = nil,
        onTextChange: ((String) -> Void)? = nil
    ) {
        self.sequenceNumber = sequenceNumber
        self.saveButtonTitle = saveButtonTitle
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete
        self.onTextChange = onTextChange
        _text = State(initialValue: initialComment)
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                BrowserAnnotationNumberBadge(number: sequenceNumber)
                Text("Add comment")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ToastyTheme.primaryText)
            }

            ZStack(alignment: .topLeading) {
                BrowserAnnotationCommentTextView(
                    text: $text,
                    onSubmit: saveIfPossible,
                    onCancel: onCancel
                )
                .frame(height: 58)

                if text.isEmpty {
                    Text("What should the agent change here?")
                        .font(.system(size: 12))
                        .foregroundStyle(ToastyTheme.mutedText)
                        .padding(.top, 5)
                        .padding(.leading, 7)
                        .allowsHitTesting(false)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ToastyTheme.surfaceBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(ToastyTheme.subtleBorder, lineWidth: 1)
            }

            HStack(spacing: 8) {
                Text("↩ Save   ⇧↩ Newline   esc Cancel")
                    .font(.system(size: 9.5))
                    .foregroundStyle(ToastyTheme.mutedText)

                Spacer(minLength: 12)

                if let onDelete {
                    Button("Delete", action: onDelete)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ToastyTheme.sessionErrorText)
                }

                Button(action: saveIfPossible) {
                    Text(saveButtonTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ToastyTheme.accentDark)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(
                                trimmedText.isEmpty
                                    ? ToastyTheme.accent.opacity(0.4)
                                    : ToastyTheme.accent
                            )
                        )
                }
                .buttonStyle(.plain)
                .disabled(trimmedText.isEmpty)
            }
        }
        .padding(11)
        .frame(width: 262)
        .onChange(of: text) { _, newValue in
            onTextChange?(newValue)
        }
    }

    private func saveIfPossible() {
        let comment = trimmedText
        guard comment.isEmpty == false else { return }
        onSave(comment)
    }
}

/// Read-only comment view shown when clicking an existing annotation mark.
struct BrowserAnnotationCommentDetailView: View {
    let sequenceNumber: Int
    let comment: String
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                BrowserAnnotationNumberBadge(number: sequenceNumber)
                Text("Annotation")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ToastyTheme.primaryText)
            }

            Text(comment)
                .font(.system(size: 12))
                .foregroundStyle(ToastyTheme.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Spacer(minLength: 12)

                Button("Delete", action: onDelete)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ToastyTheme.sessionErrorText)

                Button(action: onEdit) {
                    Text("Edit")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ToastyTheme.primaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(ToastyTheme.elevatedBackground))
                        .overlay {
                            Capsule().stroke(ToastyTheme.subtleBorder, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(11)
        .frame(width: 262)
    }
}

struct BrowserAnnotationNumberBadge: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color(nsColor: BrowserAnnotationMarkStyle.markColor)))
            .overlay {
                Circle().stroke(.white, lineWidth: 1.5)
            }
    }
}

/// Multiline comment field with field-editor-style key handling.
private struct BrowserAnnotationCommentTextView: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = InitialFocusTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = NSColor(ToastyTheme.primaryText)
        textView.insertionPointColor = NSColor(ToastyTheme.accent)
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 3, height: 5)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.verticalScrollElasticity = .none
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else {
            return
        }
        textView.string = text
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BrowserAnnotationCommentTextView

        init(_ parent: BrowserAnnotationCommentTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(
            _ textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                let isShiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                guard isShiftHeld == false else {
                    return false
                }
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

private final class InitialFocusTextView: NSTextView {
    private var hasRequestedInitialFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard hasRequestedInitialFocus == false, let window else { return }
        hasRequestedInitialFocus = true
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.makeFirstResponder(self)
        }
    }
}
