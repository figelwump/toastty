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
        PaneNodeView(
            node: workspace.paneTree,
            workspace: workspace,
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            globalFontPoints: store.state.globalTerminalFontPoints,
            focusedPanelID: workspace.focusedPanelID,
            focusedPanelModeActive: workspace.focusedPanelModeActive
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
    let focusedPanelID: UUID?
    let focusedPanelModeActive: Bool

    var body: some View {
        switch node {
        case .leaf(_, let tabPanelIDs, let selectedIndex):
            let selectedPanelID = paneSelectedPanelID(
                tabPanelIDs: tabPanelIDs,
                selectedIndex: selectedIndex
            )

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
                let baseRatio = min(max(ratio, 0.1), 0.9)
                let effectiveRatio = effectiveSplitRatio(baseRatio: baseRatio, first: first, second: second)
                let isCollapsed = effectiveRatio <= 0.0001 || effectiveRatio >= 0.9999
                let dividerThickness: CGFloat = isCollapsed ? 0 : 1

                if orientation == .horizontal {
                    let availableWidth = max(geometry.size.width - dividerThickness, 0)
                    let firstWidth = availableWidth * effectiveRatio
                    let secondWidth = max(availableWidth - firstWidth, 0)
                    let showFirst = isCollapsed ? effectiveRatio >= 0.5 : true
                    let showSecond = isCollapsed ? effectiveRatio < 0.5 : true

                    HStack(spacing: 0) {
                        PaneNodeView(
                            node: first,
                            workspace: workspace,
                            store: store,
                            terminalRuntimeRegistry: terminalRuntimeRegistry,
                            globalFontPoints: globalFontPoints,
                            focusedPanelID: focusedPanelID,
                            focusedPanelModeActive: focusedPanelModeActive
                        )
                        .frame(width: firstWidth, height: geometry.size.height)
                        .opacity(showFirst ? 1 : 0)
                        .allowsHitTesting(showFirst)

                        if dividerThickness > 0 {
                            Rectangle()
                                .fill(ToastyTheme.paneDivider)
                                .frame(width: dividerThickness, height: geometry.size.height)
                        }

                        PaneNodeView(
                            node: second,
                            workspace: workspace,
                            store: store,
                            terminalRuntimeRegistry: terminalRuntimeRegistry,
                            globalFontPoints: globalFontPoints,
                            focusedPanelID: focusedPanelID,
                            focusedPanelModeActive: focusedPanelModeActive
                        )
                        .frame(width: secondWidth, height: geometry.size.height)
                        .opacity(showSecond ? 1 : 0)
                        .allowsHitTesting(showSecond)
                    }
                    .clipped()
                } else {
                    let availableHeight = max(geometry.size.height - dividerThickness, 0)
                    let firstHeight = availableHeight * effectiveRatio
                    let secondHeight = max(availableHeight - firstHeight, 0)
                    let showFirst = isCollapsed ? effectiveRatio >= 0.5 : true
                    let showSecond = isCollapsed ? effectiveRatio < 0.5 : true

                    VStack(spacing: 0) {
                        PaneNodeView(
                            node: first,
                            workspace: workspace,
                            store: store,
                            terminalRuntimeRegistry: terminalRuntimeRegistry,
                            globalFontPoints: globalFontPoints,
                            focusedPanelID: focusedPanelID,
                            focusedPanelModeActive: focusedPanelModeActive
                        )
                        .frame(width: geometry.size.width, height: firstHeight)
                        .opacity(showFirst ? 1 : 0)
                        .allowsHitTesting(showFirst)

                        if dividerThickness > 0 {
                            Rectangle()
                                .fill(ToastyTheme.paneDivider)
                                .frame(width: geometry.size.width, height: dividerThickness)
                        }

                        PaneNodeView(
                            node: second,
                            workspace: workspace,
                            store: store,
                            terminalRuntimeRegistry: terminalRuntimeRegistry,
                            globalFontPoints: globalFontPoints,
                            focusedPanelID: focusedPanelID,
                            focusedPanelModeActive: focusedPanelModeActive
                        )
                        .frame(width: geometry.size.width, height: secondHeight)
                        .opacity(showSecond ? 1 : 0)
                        .allowsHitTesting(showSecond)
                    }
                    .clipped()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func effectiveSplitRatio(baseRatio: Double, first: PaneNode, second: PaneNode) -> Double {
        guard focusedPanelModeActive, let focusedPanelID else {
            return baseRatio
        }
        let firstContainsFocused = first.leafContaining(panelID: focusedPanelID) != nil
        let secondContainsFocused = second.leafContaining(panelID: focusedPanelID) != nil

        if firstContainsFocused && secondContainsFocused {
            assertionFailure("Focused panel unexpectedly appears in both split branches.")
            return baseRatio
        }

        if firstContainsFocused && !secondContainsFocused {
            return 1
        }
        if secondContainsFocused && !firstContainsFocused {
            return 0
        }
        return baseRatio
    }

    private func paneSelectedPanelID(tabPanelIDs: [UUID], selectedIndex: Int) -> UUID? {
        if focusedPanelModeActive,
           let focusedPanelID,
           tabPanelIDs.contains(focusedPanelID) {
            return focusedPanelID
        }
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
            Rectangle()
                .fill(isFocused ? ToastyTheme.accent : ToastyTheme.hairline)
                .frame(height: isFocused ? 2 : 1)

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
                .strokeBorder(ToastyTheme.hairline, lineWidth: 1)
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
