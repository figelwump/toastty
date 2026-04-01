import SwiftUI

struct TerminalPanelHeaderSearchBar: View {
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
    let panelID: UUID
    let isActivePanel: Bool
    let layout: PanelHeaderSearchLayout

    @State private var draftNeedle = ""
    @FocusState private var isFieldFocused: Bool

    private var searchState: TerminalSearchState? {
        terminalRuntimeRegistry.searchState(for: panelID)
    }

    private var registryOwnsSearchFieldFocus: Bool {
        terminalRuntimeRegistry.isSearchFieldFocused(panelID: panelID)
    }

    var body: some View {
        Group {
            if let searchState, searchState.isPresented {
                HStack(spacing: PanelHeaderSearchLayout.searchControlsSpacing) {
                    TextField("Search", text: searchBinding)
                        .textFieldStyle(.plain)
                        .font(ToastyTheme.fontBody)
                        .foregroundStyle(ToastyTheme.primaryText)
                        .padding(.leading, 8)
                        .padding(.trailing, layout.showsMatchLabel ? 36 : 8)
                        .frame(
                            width: layout.fieldWidth,
                            height: PanelHeaderSearchLayout.searchFieldHeight
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(ToastyTheme.surfaceBackground.opacity(0.96))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
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
                            if layout.showsMatchLabel,
                               let matchLabel = matchLabel(for: searchState) {
                                Text(matchLabel)
                                    .font(ToastyTheme.fontWorkspaceTabBadge)
                                    .foregroundStyle(ToastyTheme.inactiveText)
                                    .monospacedDigit()
                                    .padding(.trailing, 7)
                            }
                        }
                        .accessibilityIdentifier("panel.header.search.field.\(panelID.uuidString)")

                    HStack(spacing: PanelHeaderSearchLayout.searchButtonSpacing) {
                        searchButton(
                            systemImage: "chevron.up",
                            accessibilityIdentifier: "panel.header.search.previous.\(panelID.uuidString)",
                            action: { _ = terminalRuntimeRegistry.findPrevious(panelID: panelID) }
                        )

                        searchButton(
                            systemImage: "chevron.down",
                            accessibilityIdentifier: "panel.header.search.next.\(panelID.uuidString)",
                            action: { _ = terminalRuntimeRegistry.findNext(panelID: panelID) }
                        )

                        searchButton(
                            systemImage: "xmark",
                            accessibilityIdentifier: "panel.header.search.close.\(panelID.uuidString)",
                            action: closeSearch
                        )
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .fixedSize(horizontal: true, vertical: false)
                .onAppear {
                    syncDraft(with: searchState)
                    guard isActivePanel else {
                        return
                    }
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
                    guard isActivePanel else {
                        return
                    }
                    requestFieldFocus()
                }
                .onChange(of: registryOwnsSearchFieldFocus) { _, ownsFocus in
                    guard ownsFocus == false, isFieldFocused else {
                        return
                    }
                    isFieldFocused = false
                }
                .onChange(of: isActivePanel) { _, isActive in
                    guard isActive == false, isFieldFocused else {
                        return
                    }
                    // Keep the search UI visible in inactive tabs, but return
                    // keyboard focus to whichever panel the user just activated.
                    isFieldFocused = false
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
    private func searchButton(
        systemImage: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ToastyTheme.primaryText)
                .frame(
                    width: PanelHeaderSearchLayout.searchButtonSize,
                    height: PanelHeaderSearchLayout.searchButtonSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
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
