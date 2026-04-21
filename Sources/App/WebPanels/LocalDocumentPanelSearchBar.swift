import AppKit
import SwiftUI

final class LocalDocumentSearchTextField: NSSearchField, NSTextViewDelegate {}

struct LocalDocumentPanelHeaderSearchBar: View {
    let panelID: UUID
    @ObservedObject var runtime: LocalDocumentPanelRuntime
    let isActivePanel: Bool
    let activatePanel: () -> Void

    @State private var draftQuery = ""

    private var searchState: LocalDocumentSearchState? {
        runtime.searchState()
    }

    var body: some View {
        Group {
            if let searchState, searchState.isPresented {
                GeometryReader { geometry in
                    let chrome = PanelHeaderSearchLayout.resolveSearchChrome(
                        availableWidth: geometry.size.width
                    )

                    HStack(spacing: PanelHeaderSearchLayout.searchControlsSpacing) {
                        LocalDocumentSearchField(
                            text: searchBinding,
                            placeholder: "Search",
                            focusRequestID: isActivePanel ? searchState.focusRequestID : nil,
                            accessibilityID: "local-document.search.field.\(panelID.uuidString)",
                            onSubmit: {
                                activatePanel()
                                _ = runtime.findNext()
                            },
                            onCancel: closeSearch,
                            onEditingChanged: handleSearchEditingChanged
                        )
                        .frame(
                            width: chrome.fieldWidth,
                            height: PanelHeaderSearchLayout.searchFieldHeight
                        )
                        .overlay(alignment: .trailing) {
                            if chrome.showsMatchLabel,
                               searchState.query.isEmpty == false,
                               searchState.lastMatchFound == false {
                                Text("No Match")
                                    .font(ToastyTheme.fontWorkspaceTabBadge)
                                    .foregroundStyle(ToastyTheme.inactiveText)
                                    .padding(.trailing, 7)
                            }
                        }

                        HStack(spacing: PanelHeaderSearchLayout.searchButtonSpacing) {
                            if chrome.showsNavigationButtons {
                                searchButton(
                                    systemImage: "chevron.up",
                                    helpText: ToasttyKeyboardShortcuts.findPrevious.helpText("Find Previous"),
                                    accessibilityIdentifier: "local-document.search.previous.\(panelID.uuidString)",
                                    isDisabled: searchState.query.isEmpty
                                ) {
                                    activatePanel()
                                    _ = runtime.findPrevious()
                                }

                                searchButton(
                                    systemImage: "chevron.down",
                                    helpText: ToasttyKeyboardShortcuts.findNext.helpText("Find Next"),
                                    accessibilityIdentifier: "local-document.search.next.\(panelID.uuidString)",
                                    isDisabled: searchState.query.isEmpty
                                ) {
                                    activatePanel()
                                    _ = runtime.findNext()
                                }
                            }

                            searchButton(
                                systemImage: "xmark",
                                helpText: "Hide Find",
                                accessibilityIdentifier: "local-document.search.close.\(panelID.uuidString)",
                                isDisabled: false,
                                action: closeSearch
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(
                    minWidth: PanelHeaderSearchLayout.minimumSearchBarWidth,
                    idealWidth: PanelHeaderSearchLayout.maximumSearchBarWidth,
                    maxWidth: PanelHeaderSearchLayout.maximumSearchBarWidth,
                    minHeight: PanelHeaderSearchLayout.searchFieldHeight,
                    idealHeight: PanelHeaderSearchLayout.searchFieldHeight,
                    maxHeight: PanelHeaderSearchLayout.searchFieldHeight,
                    alignment: .trailing
                )
                .onAppear {
                    syncDraft(with: searchState)
                }
                .onDisappear {
                    runtime.setSearchFieldFocused(false)
                }
                .onChange(of: searchState.query) { _, nextQuery in
                    guard draftQuery != nextQuery else {
                        return
                    }
                    draftQuery = nextQuery
                }
                .onChange(of: searchState.focusRequestID) { _, _ in
                    syncDraft(with: runtime.searchState())
                }
                .onChange(of: isActivePanel) { _, isActive in
                    guard isActive == false else {
                        return
                    }
                    runtime.setSearchFieldFocused(false)
                }
            }
        }
    }

    @ViewBuilder
    private func searchButton(
        systemImage: String,
        helpText: String,
        accessibilityIdentifier: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isDisabled ? ToastyTheme.inactiveText : ToastyTheme.primaryText)
                .frame(
                    width: PanelHeaderSearchLayout.searchButtonSize,
                    height: PanelHeaderSearchLayout.searchButtonSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(helpText)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func handleSearchEditingChanged(_ isEditing: Bool) {
        if isEditing, isActivePanel == false {
            activatePanel()
        }
        runtime.setSearchFieldFocused(isEditing)
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { draftQuery },
            set: { nextValue in
                draftQuery = nextValue
                runtime.updateSearchQuery(nextValue)
            }
        )
    }

    private func syncDraft(with searchState: LocalDocumentSearchState) {
        draftQuery = searchState.query
    }

    private func syncDraft(with searchState: LocalDocumentSearchState?) {
        draftQuery = searchState?.query ?? ""
    }

    private func closeSearch() {
        activatePanel()
        _ = runtime.endSearch()
        _ = runtime.focusWebView()
    }
}

struct LocalDocumentSearchField: NSViewRepresentable {
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

    func makeNSView(context: Context) -> LocalDocumentSearchTextField {
        let textField = LocalDocumentSearchTextField(string: text)
        textField.delegate = context.coordinator
        configure(textField)
        return textField
    }

    func updateNSView(_ textField: LocalDocumentSearchTextField, context: Context) {
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

    static func dismantleNSView(_ textField: LocalDocumentSearchTextField, coordinator: Coordinator) {
        coordinator.resetFocusState()
        _ = textField
    }

    private func configure(_ textField: LocalDocumentSearchTextField) {
        textField.placeholderString = placeholder
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 12, weight: .medium)
        textField.maximumRecents = 0
        textField.recentsAutosaveName = nil
        textField.setAccessibilityIdentifier(accessibilityID)
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
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
            _ = control
            _ = textView

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
