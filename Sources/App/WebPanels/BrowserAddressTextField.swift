import AppKit
import SwiftUI

final class BrowserChromeTextField: NSTextField, NSTextViewDelegate {}

struct BrowserAddressTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusRequestID: UUID?
    let accessibilityID: String
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onEditingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onSubmit: onSubmit,
            onCancel: onCancel,
            onEditingChanged: onEditingChanged
        )
    }

    func makeNSView(context: Context) -> BrowserChromeTextField {
        let textField = BrowserChromeTextField(string: text)
        textField.delegate = context.coordinator
        configure(textField)
        return textField
    }

    func updateNSView(_ textField: BrowserChromeTextField, context: Context) {
        context.coordinator.update(
            text: $text,
            onSubmit: onSubmit,
            onCancel: onCancel,
            onEditingChanged: onEditingChanged
        )

        configure(textField)
        context.coordinator.synchronizeDisplayedText(with: text, in: textField)
        context.coordinator.requestFocusIfNeeded(
            requestID: focusRequestID,
            in: textField
        )
    }

    static func dismantleNSView(_ textField: BrowserChromeTextField, coordinator: Coordinator) {
        coordinator.resetFocusState()
    }

    private func configure(_ textField: BrowserChromeTextField) {
        textField.placeholderString = placeholder
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 12, weight: .medium)
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
        private var onEditingChanged: (Bool) -> Void
        private var lastHandledFocusRequestID: UUID?
        private var pendingFocusRequestID: UUID?

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void,
            onEditingChanged: @escaping (Bool) -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
            self.onEditingChanged = onEditingChanged
        }

        func update(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void,
            onEditingChanged: @escaping (Bool) -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
            self.onEditingChanged = onEditingChanged
        }

        func requestFocusIfNeeded(requestID: UUID?, in textField: NSTextField) {
            guard let requestID,
                  lastHandledFocusRequestID != requestID else {
                return
            }

            pendingFocusRequestID = requestID
            attemptFocusAndSelection(
                in: textField,
                requestID: requestID,
                remainingAttempts: 12
            )
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

        func controlTextDidBeginEditing(_ notification: Notification) {
            _ = notification
            onEditingChanged(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            _ = notification
            onEditingChanged(false)
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
