import AppKit
import SwiftUI

final class PaletteTextField: NSTextField {}

struct PaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusRequestID: UUID
    let accessibilityID: String
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown,
            onSubmit: onSubmit,
            onCancel: onCancel
        )
    }

    func makeNSView(context: Context) -> PaletteTextField {
        let textField = PaletteTextField(string: text)
        textField.delegate = context.coordinator
        configure(textField)
        return textField
    }

    func updateNSView(_ textField: PaletteTextField, context: Context) {
        context.coordinator.update(
            text: $text,
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown,
            onSubmit: onSubmit,
            onCancel: onCancel
        )

        configure(textField)
        context.coordinator.synchronizeDisplayedText(with: text, in: textField)
        context.coordinator.requestFocusIfNeeded(requestID: focusRequestID, in: textField)
    }

    static func dismantleNSView(_ textField: PaletteTextField, coordinator: Coordinator) {
        coordinator.resetFocusState()
        _ = textField
    }

    private func configure(_ textField: PaletteTextField) {
        textField.placeholderString = placeholder
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 15, weight: .medium)
        textField.textColor = NSColor(ToastyTheme.primaryText)
        textField.maximumNumberOfLines = 1
        textField.lineBreakMode = .byTruncatingTail
        textField.setAccessibilityIdentifier(accessibilityID)
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var text: Binding<String>
        private var onMoveUp: () -> Void
        private var onMoveDown: () -> Void
        private var onSubmit: () -> Void
        private var onCancel: () -> Void
        private var lastHandledFocusRequestID: UUID?
        private var pendingFocusRequestID: UUID?

        init(
            text: Binding<String>,
            onMoveUp: @escaping () -> Void,
            onMoveDown: @escaping () -> Void,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.text = text
            self.onMoveUp = onMoveUp
            self.onMoveDown = onMoveDown
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func update(
            text: Binding<String>,
            onMoveUp: @escaping () -> Void,
            onMoveDown: @escaping () -> Void,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.text = text
            self.onMoveUp = onMoveUp
            self.onMoveDown = onMoveDown
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func requestFocusIfNeeded(requestID: UUID, in textField: NSTextField) {
            guard lastHandledFocusRequestID != requestID else {
                return
            }

            pendingFocusRequestID = requestID
            attemptFocusAndSelection(in: textField, requestID: requestID, remainingAttempts: 12)
        }

        func resetFocusState() {
            lastHandledFocusRequestID = nil
            pendingFocusRequestID = nil
        }

        func synchronizeDisplayedText(with text: String, in textField: NSTextField) {
            guard isEditing(textField) == false,
                  textField.stringValue != text else {
                return
            }

            textField.stringValue = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text.wrappedValue = textField.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            _ = control
            _ = textView

            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
                return true
            case #selector(NSResponder.moveUp(_:)):
                onMoveUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                onMoveDown()
                return true
            default:
                return false
            }
        }

        private func attemptFocusAndSelection(
            in textField: NSTextField,
            requestID: UUID,
            remainingAttempts: Int
        ) {
            guard pendingFocusRequestID == requestID else { return }

            if focusAndSelectAll(in: textField) {
                pendingFocusRequestID = nil
                lastHandledFocusRequestID = requestID
                return
            }

            guard remainingAttempts > 0 else {
                pendingFocusRequestID = nil
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self, weak textField] in
                guard let self, let textField else { return }
                self.attemptFocusAndSelection(
                    in: textField,
                    requestID: requestID,
                    remainingAttempts: remainingAttempts - 1
                )
            }
        }

        @discardableResult
        private func focusAndSelectAll(in textField: NSTextField) -> Bool {
            guard let window = textField.window else {
                return false
            }

            if let editor = currentEditor(in: window, for: textField) {
                editor.selectAll(nil)
                return true
            }

            guard window.makeFirstResponder(textField),
                  let editor = currentEditor(in: window, for: textField) else {
                return false
            }

            editor.selectAll(nil)
            return true
        }

        private func isEditing(_ textField: NSTextField) -> Bool {
            guard let window = textField.window else {
                return false
            }
            return currentEditor(in: window, for: textField) != nil
        }

        private func currentEditor(in window: NSWindow, for textField: NSTextField) -> NSTextView? {
            guard let editor = window.firstResponder as? NSTextView,
                  editor.delegate as? NSTextField === textField else {
                return nil
            }
            return editor
        }
    }
}
