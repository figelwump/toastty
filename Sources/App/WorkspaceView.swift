import CoreState
import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
    @ObservedObject private var ghosttyHostStyleStore = GhosttyHostStyleStore.shared

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

            auxToggle(title: "Diff", systemImage: "text.alignleft", kind: .diff, identifier: "topbar.toggle.diff")
            auxToggle(title: "Markdown", systemImage: "doc.text", kind: .markdown, identifier: "topbar.toggle.markdown")
            focusedPanelToggle(identifier: "topbar.toggle.focused-panel")

            topBarButton(title: "Split H", icon: {
                SplitHorizontalIconView(color: ToastyTheme.mutedTextStrong)
            }, active: false) {
                split(orientation: .horizontal)
            }
            .disabled(isFocusedPanelModeActive)
            .accessibilityIdentifier("workspace.split.horizontal")

            topBarButton(title: "Split V", icon: {
                SplitVerticalIconView(color: ToastyTheme.mutedTextStrong)
            }, active: false) {
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
            focusedPanelModeActive: workspace.focusedPanelModeActive,
            unfocusedSplitStyle: ghosttyHostStyleStore.unfocusedSplitStyle
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func auxToggle(title: String, systemImage: String, kind: PanelKind, identifier: String) -> some View {
        let isOn = store.selectedWorkspace?.auxPanelVisibility.contains(kind) ?? false
        topBarButton(title: title, systemImage: systemImage, active: isOn) {
            guard let workspaceID = store.selectedWorkspace?.id else { return }
            store.send(.toggleAuxPanel(workspaceID: workspaceID, kind: kind))
        }
        .disabled(isFocusedPanelModeActive)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private func focusedPanelToggle(identifier: String) -> some View {
        let isOn = isFocusedPanelModeActive
        topBarButton(title: isOn ? "Restore Layout" : "Focus Panel", icon: {
            FocusIconView(color: isOn ? ToastyTheme.accent : ToastyTheme.mutedTextStrong)
        }, active: isOn) {
            guard let workspaceID = store.selectedWorkspace?.id else { return }
            store.send(.toggleFocusedPanelMode(workspaceID: workspaceID))
        }
        .accessibilityIdentifier(identifier)
    }

    private var isFocusedPanelModeActive: Bool {
        store.selectedWorkspace?.focusedPanelModeActive ?? false
    }

    private func topBarButton(
        title: String,
        systemImage: String? = nil,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(active ? ToastyTheme.accent : ToastyTheme.mutedTextStrong)
                }
                Text(title)
                    .font(ToastyTheme.fontSubtext)
                    .foregroundStyle(active ? ToastyTheme.primaryText : ToastyTheme.mutedTextStrong)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(active ? ToastyTheme.elevatedBackground : Color.clear)
        .overlay(
            Rectangle()
                .stroke(active ? ToastyTheme.subtleBorder : Color.clear, lineWidth: 1)
        )
    }

    /// Top bar button variant that accepts a custom icon view (e.g. Canvas-based icons).
    private func topBarButton<Icon: View>(
        title: String,
        @ViewBuilder icon: () -> Icon,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                icon()
                Text(title)
                    .font(ToastyTheme.fontSubtext)
                    .foregroundStyle(active ? ToastyTheme.primaryText : ToastyTheme.mutedTextStrong)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(active ? ToastyTheme.elevatedBackground : Color.clear)
        .overlay(
            Rectangle()
                .stroke(active ? ToastyTheme.subtleBorder : Color.clear, lineWidth: 1)
        )
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
    let unfocusedSplitStyle: GhosttyUnfocusedSplitStyle

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
                        unfocusedSplitStyle: unfocusedSplitStyle,
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

                Group {
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
                                focusedPanelModeActive: focusedPanelModeActive,
                                unfocusedSplitStyle: unfocusedSplitStyle
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
                                focusedPanelModeActive: focusedPanelModeActive,
                                unfocusedSplitStyle: unfocusedSplitStyle
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
                                focusedPanelModeActive: focusedPanelModeActive,
                                unfocusedSplitStyle: unfocusedSplitStyle
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
                                focusedPanelModeActive: focusedPanelModeActive,
                                unfocusedSplitStyle: unfocusedSplitStyle
                            )
                            .frame(width: geometry.size.width, height: secondHeight)
                            .opacity(showSecond ? 1 : 0)
                            .allowsHitTesting(showSecond)
                        }
                        .clipped()
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: effectiveRatio)
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
    let unfocusedSplitStyle: GhosttyUnfocusedSplitStyle
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
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(isFocused ? ToastyTheme.accent : ToastyTheme.hairline)
                        .frame(height: isFocused ? 2 : 1)
                }

            switch panelState {
            case .terminal(let terminalState):
                TerminalPanelHostView(
                    panelID: panelID,
                    terminalState: terminalState,
                    focused: isFocused,
                    globalFontPoints: globalFontPoints,
                    runtimeRegistry: terminalRuntimeRegistry
                )
                .overlay {
                    if focusedPanelID != nil, !isFocused, unfocusedSplitStyle.fillOverlayOpacity > 0 {
                        Rectangle()
                            .fill(unfocusedSplitStyle.fillColor.color)
                            .opacity(unfocusedSplitStyle.fillOverlayOpacity)
                            .allowsHitTesting(false)
                    }
                }
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

// MARK: - Top Bar Icons

/// Viewfinder bracket corners with center dot — Focus/Zoom toggle icon.
/// Matches the 11×11 stroke-based icon language used across the top nav bar.
struct FocusIconView: View {
    let color: Color

    var body: some View {
        Canvas { context, _ in
            // Four corner brackets
            var brackets = Path()
            // Top-left
            brackets.move(to: CGPoint(x: 1.5, y: 3.5))
            brackets.addLine(to: CGPoint(x: 1.5, y: 1.5))
            brackets.addLine(to: CGPoint(x: 3.5, y: 1.5))
            // Top-right
            brackets.move(to: CGPoint(x: 7.5, y: 1.5))
            brackets.addLine(to: CGPoint(x: 9.5, y: 1.5))
            brackets.addLine(to: CGPoint(x: 9.5, y: 3.5))
            // Bottom-right
            brackets.move(to: CGPoint(x: 9.5, y: 7.5))
            brackets.addLine(to: CGPoint(x: 9.5, y: 9.5))
            brackets.addLine(to: CGPoint(x: 7.5, y: 9.5))
            // Bottom-left
            brackets.move(to: CGPoint(x: 3.5, y: 9.5))
            brackets.addLine(to: CGPoint(x: 1.5, y: 9.5))
            brackets.addLine(to: CGPoint(x: 1.5, y: 7.5))

            context.stroke(
                brackets,
                with: .color(color),
                style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
            )

            // Center dot
            let dot = Path(ellipseIn: CGRect(x: 5.5 - 1.2, y: 5.5 - 1.2, width: 2.4, height: 2.4))
            context.fill(dot, with: .color(color))
        }
        .frame(width: 11, height: 11)
    }
}

/// Two side-by-side rounded rectangles — Split Horizontal icon.
struct SplitHorizontalIconView: View {
    let color: Color

    var body: some View {
        Canvas { context, _ in
            let left = Path(roundedRect: CGRect(x: 1.5, y: 1.5, width: 3.2, height: 8), cornerRadius: 0.8)
            let right = Path(roundedRect: CGRect(x: 6.3, y: 1.5, width: 3.2, height: 8), cornerRadius: 0.8)
            let style = StrokeStyle(lineWidth: 1.1)
            context.stroke(left, with: .color(color), style: style)
            context.stroke(right, with: .color(color), style: style)
        }
        .frame(width: 11, height: 11)
    }
}

/// Two stacked rounded rectangles — Split Vertical icon.
struct SplitVerticalIconView: View {
    let color: Color

    var body: some View {
        Canvas { context, _ in
            let top = Path(roundedRect: CGRect(x: 1.5, y: 1.5, width: 8, height: 3.2), cornerRadius: 0.8)
            let bottom = Path(roundedRect: CGRect(x: 1.5, y: 6.3, width: 8, height: 3.2), cornerRadius: 0.8)
            let style = StrokeStyle(lineWidth: 1.1)
            context.stroke(top, with: .color(color), style: style)
            context.stroke(bottom, with: .color(color), style: style)
        }
        .frame(width: 11, height: 11)
    }
}
