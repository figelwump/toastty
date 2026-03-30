import SwiftUI

struct TerminalSearchOverlay: View {
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
    let panelID: UUID

    @State private var draftNeedle = ""
    @FocusState private var isFieldFocused: Bool

    private var searchState: TerminalSearchState? {
        terminalRuntimeRegistry.searchState(for: panelID)
    }

    var body: some View {
        Group {
            if let searchState, searchState.isPresented {
                HStack(spacing: 8) {
                    TextField("Search Scrollback", text: searchBinding)
                        .textFieldStyle(.plain)
                        .font(ToastyTheme.fontBody)
                        .foregroundStyle(ToastyTheme.primaryText)
                        .frame(width: 220)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(ToastyTheme.surfaceBackground.opacity(0.96))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(ToastyTheme.subtleBorder, lineWidth: 1)
                        }
                        .focused($isFieldFocused)
                        .onSubmit {
                            _ = terminalRuntimeRegistry.findNext(panelID: panelID)
                        }
#if canImport(AppKit)
                        .onExitCommand {
                            closeSearch()
                        }
#endif
                        .overlay(alignment: .trailing) {
                            if let matchLabel = matchLabel(for: searchState) {
                                Text(matchLabel)
                                    .font(ToastyTheme.fontWorkspaceTabBadge)
                                    .foregroundStyle(ToastyTheme.inactiveText)
                                    .monospacedDigit()
                                    .padding(.trailing, 10)
                            }
                        }

                    overlayButton(
                        systemImage: "chevron.up",
                        action: { _ = terminalRuntimeRegistry.findPrevious(panelID: panelID) }
                    )

                    overlayButton(
                        systemImage: "chevron.down",
                        action: { _ = terminalRuntimeRegistry.findNext(panelID: panelID) }
                    )

                    overlayButton(
                        systemImage: "xmark",
                        action: closeSearch
                    )
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(ToastyTheme.elevatedBackground.opacity(0.98))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(ToastyTheme.subtleBorder, lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.22), radius: 10, y: 3)
                .onAppear {
                    syncDraft(with: searchState)
                    requestFieldFocus()
                }
                .onDisappear {
                    terminalRuntimeRegistry.setSearchFieldFocused(false, panelID: panelID)
                }
                .onChange(of: searchState.needle) { _, nextNeedle in
                    guard draftNeedle != nextNeedle else {
                        return
                    }
                    draftNeedle = nextNeedle
                }
                .onChange(of: searchState.focusRequestID) { _, _ in
                    syncDraft(with: terminalRuntimeRegistry.searchState(for: panelID))
                    requestFieldFocus()
                }
                .onChange(of: isFieldFocused) { _, focused in
                    terminalRuntimeRegistry.setSearchFieldFocused(focused, panelID: panelID)
                }
            }
        }
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { draftNeedle },
            set: { nextValue in
                draftNeedle = nextValue
                terminalRuntimeRegistry.updateSearchNeedle(nextValue, panelID: panelID)
            }
        )
    }

    @ViewBuilder
    private func overlayButton(
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .foregroundStyle(ToastyTheme.primaryText)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(ToastyTheme.chromeBackground)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(ToastyTheme.hairline, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private func matchLabel(for searchState: TerminalSearchState) -> String? {
        if let selected = searchState.selected {
            return "\(selected + 1)/\(searchState.total.map(String.init) ?? "?")"
        }
        if let total = searchState.total {
            return "-/\(total)"
        }
        return nil
    }

    private func syncDraft(with searchState: TerminalSearchState?) {
        draftNeedle = searchState?.needle ?? ""
    }

    private func requestFieldFocus() {
        DispatchQueue.main.async {
            isFieldFocused = true
        }
    }

    private func closeSearch() {
        _ = terminalRuntimeRegistry.endSearch(panelID: panelID)
        terminalRuntimeRegistry.restoreTerminalFocusAfterSearch(panelID: panelID)
    }
}
