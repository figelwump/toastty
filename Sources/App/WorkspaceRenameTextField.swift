import AppKit
import SwiftUI

// Shared AppKit-backed inline rename field used for workspace and tab titles.
struct WorkspaceRenameTextField: NSViewRepresentable {
    @Binding var text: String
    let itemID: UUID
    let placeholder: String
    let font: NSFont
    let accessibilityID: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onSubmit: onSubmit,
            onCancel: onCancel
        )
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField(string: text)
        textField.delegate = context.coordinator
        configure(textField)
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.update(
            text: $text,
            onSubmit: onSubmit,
            onCancel: onCancel
        )

        configure(textField)
        context.coordinator.synchronizeDisplayedText(with: text, in: textField)
        context.coordinator.requestInitialSelection(
            for: itemID,
            in: textField
        )
    }

    static func dismantleNSView(_ textField: NSTextField, coordinator: Coordinator) {
        coordinator.resetSelectionState()
    }

    private func configure(_ textField: NSTextField) {
        textField.placeholderString = placeholder
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = font
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
        private var onSubmit: () -> Void
        private var onCancel: () -> Void
        private var selectionScheduledForItemID: UUID?
        private var pendingSelectionRequestID: UUID?

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func update(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func requestInitialSelection(for itemID: UUID, in textField: NSTextField) {
            guard selectionScheduledForItemID != itemID else { return }

            selectionScheduledForItemID = itemID
            let requestID = UUID()
            pendingSelectionRequestID = requestID
            attemptFocusAndSelection(in: textField, requestID: requestID, remainingAttempts: 12)
        }

        func resetSelectionState() {
            selectionScheduledForItemID = nil
            pendingSelectionRequestID = nil
        }

        @discardableResult
        func focusAndSelectAll(in textField: NSTextField) -> Bool {
            guard let window = textField.window else { return false }

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

        func synchronizeDisplayedText(with text: String, in textField: NSTextField) {
            guard isEditing(textField) == false,
                  textField.stringValue != text else { return }

            textField.stringValue = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text.wrappedValue = textField.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
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
            guard pendingSelectionRequestID == requestID else { return }

            if focusAndSelectAll(in: textField) {
                pendingSelectionRequestID = nil
                return
            }

            guard remainingAttempts > 0 else {
                pendingSelectionRequestID = nil
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

        func isEditing(_ textField: NSTextField) -> Bool {
            guard let window = textField.window else { return false }
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
