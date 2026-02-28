import CoreState
import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            Divider()

            if let workspace = store.selectedWorkspace {
                workspaceContent(for: workspace)
            } else {
                ContentUnavailableView("No workspace selected", systemImage: "rectangle.slash")
            }
        }
    }

    private var topBar: some View {
        HStack {
            Text(store.selectedWorkspace?.title ?? "")
                .font(.title3)
                .fontWeight(.semibold)
                .accessibilityIdentifier("topbar.workspace.title")

            Spacer()

            auxToggle(title: "Diff", kind: .diff, identifier: "topbar.toggle.diff")
            auxToggle(title: "Markdown", kind: .markdown, identifier: "topbar.toggle.markdown")
            focusedPanelToggle(identifier: "topbar.toggle.focused-panel")

            Button("Split Horizontal") {
                split(orientation: .horizontal)
            }
            .disabled(isFocusedPanelModeActive)
            .accessibilityIdentifier("workspace.split.horizontal")
            Button("Split Vertical") {
                split(orientation: .vertical)
            }
            .disabled(isFocusedPanelModeActive)
            .accessibilityIdentifier("workspace.split.vertical")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityIdentifier("topbar.container")
    }

    private func split(orientation: SplitOrientation) {
        guard let workspaceID = store.selectedWorkspace?.id else { return }
        store.send(.splitFocusedPane(workspaceID: workspaceID, orientation: orientation))
    }

    @ViewBuilder
    private func workspaceContent(for workspace: WorkspaceState) -> some View {
        if workspace.focusedPanelModeActive,
           let panelID = workspace.focusedPanelID,
           let panelState = workspace.panels[panelID] {
            PanelCardView(
                workspaceID: workspace.id,
                panelID: panelID,
                panelState: panelState,
                focusedPanelID: panelID,
                globalFontPoints: store.state.globalTerminalFontPoints,
                store: store,
                terminalRuntimeRegistry: terminalRuntimeRegistry
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            PaneNodeView(
                node: workspace.paneTree,
                workspace: workspace,
                store: store,
                terminalRuntimeRegistry: terminalRuntimeRegistry,
                globalFontPoints: store.state.globalTerminalFontPoints
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func auxToggle(title: String, kind: PanelKind, identifier: String) -> some View {
        let isOn = store.selectedWorkspace?.auxPanelVisibility.contains(kind) ?? false
        Button(title) {
            guard let workspaceID = store.selectedWorkspace?.id else { return }
            store.send(.toggleAuxPanel(workspaceID: workspaceID, kind: kind))
        }
        .buttonStyle(.bordered)
        .tint(isOn ? .accentColor : .gray)
        .disabled(isFocusedPanelModeActive)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private func focusedPanelToggle(identifier: String) -> some View {
        let isOn = isFocusedPanelModeActive
        Button(isOn ? "Restore Layout" : "Focus Panel") {
            guard let workspaceID = store.selectedWorkspace?.id else { return }
            store.send(.toggleFocusedPanelMode(workspaceID: workspaceID))
        }
        .buttonStyle(.bordered)
        .tint(isOn ? .accentColor : .gray)
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .accessibilityIdentifier(identifier)
    }

    private var isFocusedPanelModeActive: Bool {
        store.selectedWorkspace?.focusedPanelModeActive ?? false
    }
}

private struct PaneNodeView: View {
    let node: PaneNode
    let workspace: WorkspaceState
    @ObservedObject var store: AppStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
    let globalFontPoints: Double

    var body: some View {
        switch node {
        case .leaf(_, let tabPanelIDs, let selectedIndex):
            let selectedPanelID = paneSelectedPanelID(tabPanelIDs: tabPanelIDs, selectedIndex: selectedIndex)

            Group {
                if let panelID = selectedPanelID,
                   let panelState = workspace.panels[panelID] {
                    PanelCardView(
                        workspaceID: workspace.id,
                        panelID: panelID,
                        panelState: panelState,
                        focusedPanelID: workspace.focusedPanelID,
                        globalFontPoints: globalFontPoints,
                        store: store,
                        terminalRuntimeRegistry: terminalRuntimeRegistry
                    )
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        case .split(_, let orientation, _, let first, let second):
            if orientation == .horizontal {
                HStack(spacing: 0) {
                    PaneNodeView(
                        node: first,
                        workspace: workspace,
                        store: store,
                        terminalRuntimeRegistry: terminalRuntimeRegistry,
                        globalFontPoints: globalFontPoints
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Rectangle()
                        .fill(Color.gray.opacity(0.35))
                        .frame(width: 1)

                    PaneNodeView(
                        node: second,
                        workspace: workspace,
                        store: store,
                        terminalRuntimeRegistry: terminalRuntimeRegistry,
                        globalFontPoints: globalFontPoints
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    PaneNodeView(
                        node: first,
                        workspace: workspace,
                        store: store,
                        terminalRuntimeRegistry: terminalRuntimeRegistry,
                        globalFontPoints: globalFontPoints
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Rectangle()
                        .fill(Color.gray.opacity(0.35))
                        .frame(height: 1)

                    PaneNodeView(
                        node: second,
                        workspace: workspace,
                        store: store,
                        terminalRuntimeRegistry: terminalRuntimeRegistry,
                        globalFontPoints: globalFontPoints
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func paneSelectedPanelID(tabPanelIDs: [UUID], selectedIndex: Int) -> UUID? {
        if tabPanelIDs.indices.contains(selectedIndex) {
            return tabPanelIDs[selectedIndex]
        }
        if tabPanelIDs.isEmpty {
            return nil
        }
        assertionFailure("PaneNodeView received an out-of-range selected index.")
        return tabPanelIDs.first
    }
}

private struct PanelCardView: View {
    let workspaceID: UUID
    let panelID: UUID
    let panelState: PanelState
    let focusedPanelID: UUID?
    let globalFontPoints: Double
    @ObservedObject var store: AppStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry

    private var isFocused: Bool {
        focusedPanelID == panelID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(panelLabel)
                .font(.body.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.gray.opacity(0.14))

            switch panelState {
            case .terminal(let terminalState):
                TerminalPanelHostView(
                    panelID: panelID,
                    terminalState: terminalState,
                    focused: isFocused,
                    globalFontPoints: globalFontPoints,
                    runtimeRegistry: terminalRuntimeRegistry
                )
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )

            case .diff:
                auxPanelPlaceholder(title: "Diff Panel")
            case .markdown:
                auxPanelPlaceholder(title: "Markdown Panel")
            case .scratchpad:
                auxPanelPlaceholder(title: "Scratchpad Panel")
            }
        }
        .background(Color.gray.opacity(0.06))
        .overlay(
            Rectangle()
                .strokeBorder(isFocused ? Color.accentColor : Color.gray.opacity(0.28), lineWidth: isFocused ? 1.5 : 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            store.send(.focusPanel(workspaceID: workspaceID, panelID: panelID))
        }
    }

    private var panelLabel: String {
        switch panelState {
        case .terminal(let terminal):
            return "\(terminal.title) · \(terminal.shell)"
        case .diff:
            return "Diff Panel"
        case .markdown:
            return "Markdown Panel"
        case .scratchpad:
            return "Scratchpad Panel"
        }
    }

    @ViewBuilder
    private func auxPanelPlaceholder(title: String) -> some View {
        Text(title)
            .font(.body.monospaced())
            .foregroundStyle(.secondary)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .leading
            )
    }
}
