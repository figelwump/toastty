import CoreState
import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            Rectangle()
                .fill(ToastyTheme.hairline)
                .frame(height: 1)

            if let workspace = store.selectedWorkspace {
                workspaceContent(for: workspace)
            } else {
                ContentUnavailableView("No workspace selected", systemImage: "rectangle.slash")
            }
        }
        .background(ToastyTheme.surfaceBackground)
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            Text(store.selectedWorkspace?.title ?? "")
                .font(ToastyTheme.fontTitle)
                .foregroundStyle(ToastyTheme.primaryText)
                .accessibilityIdentifier("topbar.workspace.title")

            Spacer()

            auxToggle(title: "Diff", kind: .diff, identifier: "topbar.toggle.diff")
            auxToggle(title: "Markdown", kind: .markdown, identifier: "topbar.toggle.markdown")
            focusedPanelToggle(identifier: "topbar.toggle.focused-panel")

            topBarButton(title: "Split Horizontal", active: false) {
                split(orientation: .horizontal)
            }
            .disabled(isFocusedPanelModeActive)
            .accessibilityIdentifier("workspace.split.horizontal")

            topBarButton(title: "Split Vertical", active: false) {
                split(orientation: .vertical)
            }
            .disabled(isFocusedPanelModeActive)
            .accessibilityIdentifier("workspace.split.vertical")
        }
        .padding(.horizontal, 12)
        .frame(height: ToastyTheme.topBarHeight)
        .background(ToastyTheme.chromeBackground)
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
        topBarButton(title: title, active: isOn) {
            guard let workspaceID = store.selectedWorkspace?.id else { return }
            store.send(.toggleAuxPanel(workspaceID: workspaceID, kind: kind))
        }
        .disabled(isFocusedPanelModeActive)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private func focusedPanelToggle(identifier: String) -> some View {
        let isOn = isFocusedPanelModeActive
        topBarButton(title: isOn ? "Restore Layout" : "Focus Panel", active: isOn) {
            guard let workspaceID = store.selectedWorkspace?.id else { return }
            store.send(.toggleFocusedPanelMode(workspaceID: workspaceID))
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .accessibilityIdentifier(identifier)
    }

    private var isFocusedPanelModeActive: Bool {
        store.selectedWorkspace?.focusedPanelModeActive ?? false
    }

    private func topBarButton(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(ToastyTheme.fontSubtext)
            .foregroundStyle(active ? ToastyTheme.accent : ToastyTheme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(active ? ToastyTheme.accent.opacity(0.16) : ToastyTheme.elevatedBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(active ? ToastyTheme.accent : ToastyTheme.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
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

        case .split(_, let orientation, let ratio, let first, let second):
            GeometryReader { geometry in
                let dividerThickness: CGFloat = 1
                let clampedRatio = min(max(ratio, 0.1), 0.9)

                if orientation == .horizontal {
                    let availableWidth = max(geometry.size.width - dividerThickness, 0)
                    let firstWidth = availableWidth * clampedRatio
                    let secondWidth = max(availableWidth - firstWidth, 0)

                    HStack(spacing: 0) {
                        PaneNodeView(
                            node: first,
                            workspace: workspace,
                            store: store,
                            terminalRuntimeRegistry: terminalRuntimeRegistry,
                            globalFontPoints: globalFontPoints
                        )
                        .frame(width: firstWidth, height: geometry.size.height)

                        Rectangle()
                            .fill(ToastyTheme.paneDivider)
                            .frame(width: dividerThickness, height: geometry.size.height)

                        PaneNodeView(
                            node: second,
                            workspace: workspace,
                            store: store,
                            terminalRuntimeRegistry: terminalRuntimeRegistry,
                            globalFontPoints: globalFontPoints
                        )
                        .frame(width: secondWidth, height: geometry.size.height)
                    }
                } else {
                    let availableHeight = max(geometry.size.height - dividerThickness, 0)
                    let firstHeight = availableHeight * clampedRatio
                    let secondHeight = max(availableHeight - firstHeight, 0)

                    VStack(spacing: 0) {
                        PaneNodeView(
                            node: first,
                            workspace: workspace,
                            store: store,
                            terminalRuntimeRegistry: terminalRuntimeRegistry,
                            globalFontPoints: globalFontPoints
                        )
                        .frame(width: geometry.size.width, height: firstHeight)

                        Rectangle()
                            .fill(ToastyTheme.paneDivider)
                            .frame(width: geometry.size.width, height: dividerThickness)

                        PaneNodeView(
                            node: second,
                            workspace: workspace,
                            store: store,
                            terminalRuntimeRegistry: terminalRuntimeRegistry,
                            globalFontPoints: globalFontPoints
                        )
                        .frame(width: geometry.size.width, height: secondHeight)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .font(ToastyTheme.fontMonoHeader)
                .foregroundStyle(ToastyTheme.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(ToastyTheme.elevatedBackground)

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
        .background(ToastyTheme.surfaceBackground)
        .overlay(
            Rectangle()
                .strokeBorder(isFocused ? ToastyTheme.accent : ToastyTheme.hairline, lineWidth: isFocused ? 1.5 : 1)
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
            .font(ToastyTheme.fontMonoHeader)
            .foregroundStyle(ToastyTheme.mutedText)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .leading
            )
    }
}
