import AppKit
import CoreState
import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
    @ObservedObject private var ghosttyHostStyleStore = GhosttyHostStyleStore.shared
    @State private var focusedUnreadClearTask: Task<Void, Never>?
    @State private var appIsActive = NSApplication.shared.isActive

    private static let focusedUnreadClearDelayNanoseconds: UInt64 = 300_000_000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            Rectangle()
                .fill(ToastyTheme.hairline)
                .frame(height: 1)

            if let window = store.selectedWindow {
                workspaceStack(for: window)
            } else {
                EmptyStateView()
            }
        }
        .background(ToastyTheme.surfaceBackground)
        .onAppear {
            appIsActive = NSApplication.shared.isActive
            scheduleFocusedUnreadPanelClearIfNeeded()
        }
        .onChange(of: selectedWorkspaceUnreadSignature) { _, _ in
            scheduleFocusedUnreadPanelClearIfNeeded()
        }
        .onDisappear {
            focusedUnreadClearTask?.cancel()
            focusedUnreadClearTask = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appIsActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            appIsActive = false
        }
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            Text(store.selectedWorkspace?.title ?? "")
                .font(ToastyTheme.fontTitle)
                .foregroundStyle(ToastyTheme.primaryText)
                .accessibilityIdentifier("topbar.workspace.title")

            Spacer()

            focusedPanelToggle(identifier: "topbar.toggle.focused-panel")

            topBarFlashButton(title: "Split H", icon: { highlighted in
                SplitHorizontalIconView(color: highlighted ? ToastyTheme.accent : ToastyTheme.inactiveText)
            }) {
                split(orientation: .horizontal)
            }
            .disabled(isFocusedPanelModeActive)
            .accessibilityIdentifier("workspace.split.horizontal")

            topBarFlashButton(title: "Split V", icon: { highlighted in
                SplitVerticalIconView(color: highlighted ? ToastyTheme.accent : ToastyTheme.inactiveText)
            }) {
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
        terminalRuntimeRegistry.splitFocusedPane(workspaceID: workspaceID, orientation: orientation)
    }

    private func workspaceStack(for window: WindowState) -> some View {
        let missingWorkspaceIDs = window.workspaceIDs.filter { store.state.workspacesByID[$0] == nil }
        assert(
            missingWorkspaceIDs.isEmpty,
            "Selected window references workspace(s) missing from state map: \(missingWorkspaceIDs)"
        )

        return ZStack {
            ForEach(window.workspaceIDs, id: \.self) { workspaceID in
                if let workspace = store.state.workspacesByID[workspaceID] {
                    let isSelected = window.selectedWorkspaceID == workspaceID
                    workspaceContent(for: workspace)
                        // Keep non-selected workspaces mounted so background terminal
                        // surfaces can continue emitting runtime actions (for example
                        // desktop notifications and command-finished updates).
                        .opacity(isSelected ? 1 : 0)
                        .allowsHitTesting(isSelected)
                        .accessibilityHidden(!isSelected)
                        .zIndex(isSelected ? 1 : 0)
                }
            }
        }
    }

    @ViewBuilder
    private func workspaceContent(for workspace: WorkspaceState) -> some View {
        let terminalShortcutNumbersByPanelID = workspace.terminalShortcutNumbersByPanelID(
            limit: TerminalShortcutConfig.maxShortcutCount
        )
        PaneNodeView(
            node: workspace.paneTree,
            workspace: workspace,
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            globalFontPoints: store.state.globalTerminalFontPoints,
            focusedPanelID: workspace.focusedPanelID,
            focusedPanelModeActive: workspace.focusedPanelModeActive,
            appIsActive: appIsActive,
            unfocusedSplitStyle: ghosttyHostStyleStore.unfocusedSplitStyle,
            terminalShortcutNumbersByPanelID: terminalShortcutNumbersByPanelID
        )
        .id(workspace.id)
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
            FocusIconView(color: isOn ? ToastyTheme.accent : ToastyTheme.inactiveText)
        }, active: isOn) {
            guard let workspaceID = store.selectedWorkspace?.id else { return }
            store.send(.toggleFocusedPanelMode(workspaceID: workspaceID))
        }
        .accessibilityIdentifier(identifier)
    }

    private var isFocusedPanelModeActive: Bool {
        store.selectedWorkspace?.focusedPanelModeActive ?? false
    }

    private var selectedWorkspaceUnreadSignature: SelectedWorkspaceUnreadSignature? {
        guard let workspace = store.selectedWorkspace else { return nil }
        return SelectedWorkspaceUnreadSignature(
            workspaceID: workspace.id,
            focusedPanelID: workspace.focusedPanelID,
            unreadPanelIDs: workspace.unreadPanelIDs
        )
    }

    private func scheduleFocusedUnreadPanelClearIfNeeded() {
        focusedUnreadClearTask?.cancel()
        focusedUnreadClearTask = nil

        guard let workspace = store.selectedWorkspace,
              let focusedPanelID = workspace.focusedPanelID,
              workspace.unreadPanelIDs.contains(focusedPanelID) else {
            return
        }

        let workspaceID = workspace.id
        focusedUnreadClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.focusedUnreadClearDelayNanoseconds)
            guard Task.isCancelled == false else { return }
            guard let currentWorkspace = store.selectedWorkspace,
                  currentWorkspace.id == workspaceID,
                  currentWorkspace.focusedPanelID == focusedPanelID,
                  currentWorkspace.unreadPanelIDs.contains(focusedPanelID) else {
                return
            }
            _ = store.send(.markPanelNotificationsRead(workspaceID: workspaceID, panelID: focusedPanelID))
        }
    }

    private func topBarButton(
        title: String,
        systemImage: String? = nil,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        styledTopBarButton(active: active, action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(active ? ToastyTheme.accent : ToastyTheme.inactiveText)
                }
                Text(title)
                    .font(ToastyTheme.fontSubtext)
                    .foregroundStyle(active ? ToastyTheme.primaryText : ToastyTheme.inactiveText)
            }
        }
    }

    /// Top bar button variant that accepts a custom icon view (e.g. Canvas-based icons).
    private func topBarButton<Icon: View>(
        title: String,
        @ViewBuilder icon: () -> Icon,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        styledTopBarButton(active: active, action: action) {
            HStack(spacing: 4) {
                icon()
                Text(title)
                    .font(ToastyTheme.fontSubtext)
                    .foregroundStyle(active ? ToastyTheme.primaryText : ToastyTheme.inactiveText)
            }
        }
    }

    private func styledTopBarButton<Label: View>(
        active: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
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

    /// Top bar button for momentary actions (e.g. split). Briefly flashes the "active"
    /// styling (accent icon, light text, elevated background) while pressed, then fades back.
    /// This intentionally bypasses `styledTopBarButton` and uses `TopBarFlashButtonStyle`.
    private func topBarFlashButton<Icon: View>(
        title: String,
        @ViewBuilder icon: @escaping (_ isHighlighted: Bool) -> Icon,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            // Placeholder label — TopBarFlashButtonStyle renders the actual content.
            Text(title)
        }
        .buttonStyle(TopBarFlashButtonStyle(title: title, icon: icon))
    }
}

private struct SelectedWorkspaceUnreadSignature: Equatable {
    let workspaceID: UUID
    let focusedPanelID: UUID?
    let unreadPanelIDs: Set<UUID>
}

private struct PaneNodeView: View {
    let node: PaneNode
    let workspace: WorkspaceState
    @ObservedObject var store: AppStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
    let globalFontPoints: Double
    let focusedPanelID: UUID?
    let focusedPanelModeActive: Bool
    let appIsActive: Bool
    let unfocusedSplitStyle: GhosttyUnfocusedSplitStyle
    let terminalShortcutNumbersByPanelID: [UUID: Int]

    var body: some View {
        switch node {
        case .leaf(_, let panelID):
            Group {
                if let panelState = workspace.panels[panelID] {
                    PanelCardView(
                        workspaceID: workspace.id,
                        panelID: panelID,
                        panelState: panelState,
                        focusedPanelID: workspace.focusedPanelID,
                        hasUnreadNotification: workspace.unreadPanelIDs.contains(panelID),
                        shortcutNumber: terminalShortcutNumbersByPanelID[panelID],
                        globalFontPoints: globalFontPoints,
                        appIsActive: appIsActive,
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
                let focusBranchVisibility = focusModeBranchVisibility(first: first, second: second)

                Group {
                    if orientation == .horizontal {
                        let availableWidth = max(geometry.size.width, 0)
                        let collapseRatioThreshold = collapseRatioThreshold(
                            availableDimension: availableWidth,
                            minimumVisibleDimension: Self.minimumAnimatedBranchDimension
                        )
                        let isCollapsed = effectiveRatio <= collapseRatioThreshold
                            || effectiveRatio >= (1 - collapseRatioThreshold)
                        let showFirst = focusBranchVisibility.showFirst || !isCollapsed
                        let showSecond = focusBranchVisibility.showSecond || !isCollapsed
                        let bothBranchesVisible = showFirst && showSecond
                        let dividerThickness: CGFloat = bothBranchesVisible ? 1 : 0
                        let adjustedAvailableWidth = max(geometry.size.width - dividerThickness, 0)
                        let firstWidth = adjustedAvailableWidth * effectiveRatio
                        let secondWidth = max(adjustedAvailableWidth - firstWidth, 0)
                        let showDivider = dividerThickness > 0 && showFirst && showSecond
                        let displayFirstWidth: CGFloat = showFirst ? (showSecond ? firstWidth : adjustedAvailableWidth) : 0
                        let displaySecondWidth: CGFloat = showSecond ? (showFirst ? secondWidth : adjustedAvailableWidth) : 0

                        HStack(spacing: 0) {
                            if showFirst {
                                PaneNodeView(
                                    node: first,
                                    workspace: workspace,
                                    store: store,
                                    terminalRuntimeRegistry: terminalRuntimeRegistry,
                                    globalFontPoints: globalFontPoints,
                                    focusedPanelID: focusedPanelID,
                                    focusedPanelModeActive: focusedPanelModeActive,
                                    appIsActive: appIsActive,
                                    unfocusedSplitStyle: unfocusedSplitStyle,
                                    terminalShortcutNumbersByPanelID: terminalShortcutNumbersByPanelID
                                )
                                .frame(width: displayFirstWidth, height: geometry.size.height)
                            }

                            if showDivider {
                                Rectangle()
                                    .fill(ToastyTheme.paneDivider)
                                    .frame(width: dividerThickness, height: geometry.size.height)
                            }

                            if showSecond {
                                PaneNodeView(
                                    node: second,
                                    workspace: workspace,
                                    store: store,
                                    terminalRuntimeRegistry: terminalRuntimeRegistry,
                                    globalFontPoints: globalFontPoints,
                                    focusedPanelID: focusedPanelID,
                                    focusedPanelModeActive: focusedPanelModeActive,
                                    appIsActive: appIsActive,
                                    unfocusedSplitStyle: unfocusedSplitStyle,
                                    terminalShortcutNumbersByPanelID: terminalShortcutNumbersByPanelID
                                )
                                .frame(width: displaySecondWidth, height: geometry.size.height)
                            }
                        }
                        .clipped()
                    } else {
                        let availableHeight = max(geometry.size.height, 0)
                        let collapseRatioThreshold = collapseRatioThreshold(
                            availableDimension: availableHeight,
                            minimumVisibleDimension: Self.minimumAnimatedBranchDimension
                        )
                        let isCollapsed = effectiveRatio <= collapseRatioThreshold
                            || effectiveRatio >= (1 - collapseRatioThreshold)
                        let showFirst = focusBranchVisibility.showFirst || !isCollapsed
                        let showSecond = focusBranchVisibility.showSecond || !isCollapsed
                        let bothBranchesVisible = showFirst && showSecond
                        let dividerThickness: CGFloat = bothBranchesVisible ? 1 : 0
                        let adjustedAvailableHeight = max(geometry.size.height - dividerThickness, 0)
                        let firstHeight = adjustedAvailableHeight * effectiveRatio
                        let secondHeight = max(adjustedAvailableHeight - firstHeight, 0)
                        let showDivider = dividerThickness > 0 && showFirst && showSecond
                        let displayFirstHeight: CGFloat = showFirst ? (showSecond ? firstHeight : adjustedAvailableHeight) : 0
                        let displaySecondHeight: CGFloat = showSecond ? (showFirst ? secondHeight : adjustedAvailableHeight) : 0

                        VStack(spacing: 0) {
                            if showFirst {
                                PaneNodeView(
                                    node: first,
                                    workspace: workspace,
                                    store: store,
                                    terminalRuntimeRegistry: terminalRuntimeRegistry,
                                    globalFontPoints: globalFontPoints,
                                    focusedPanelID: focusedPanelID,
                                    focusedPanelModeActive: focusedPanelModeActive,
                                    appIsActive: appIsActive,
                                    unfocusedSplitStyle: unfocusedSplitStyle,
                                    terminalShortcutNumbersByPanelID: terminalShortcutNumbersByPanelID
                                )
                                .frame(width: geometry.size.width, height: displayFirstHeight)
                            }

                            if showDivider {
                                Rectangle()
                                    .fill(ToastyTheme.paneDivider)
                                    .frame(width: geometry.size.width, height: dividerThickness)
                            }

                            if showSecond {
                                PaneNodeView(
                                    node: second,
                                    workspace: workspace,
                                    store: store,
                                    terminalRuntimeRegistry: terminalRuntimeRegistry,
                                    globalFontPoints: globalFontPoints,
                                    focusedPanelID: focusedPanelID,
                                    focusedPanelModeActive: focusedPanelModeActive,
                                    appIsActive: appIsActive,
                                    unfocusedSplitStyle: unfocusedSplitStyle,
                                    terminalShortcutNumbersByPanelID: terminalShortcutNumbersByPanelID
                                )
                                .frame(width: geometry.size.width, height: displaySecondHeight)
                            }
                        }
                        .clipped()
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: baseRatio)
                .animation(.easeInOut(duration: 0.2), value: focusedPanelModeActive)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static let minimumAnimatedBranchDimension: CGFloat = 64

    private func collapseRatioThreshold(
        availableDimension: CGFloat,
        minimumVisibleDimension: CGFloat
    ) -> Double {
        guard availableDimension > 0 else {
            return 0.0001
        }
        return min(max(Double(minimumVisibleDimension / availableDimension), 0.0001), 0.5)
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

    private func focusModeBranchVisibility(first: PaneNode, second: PaneNode) -> (showFirst: Bool, showSecond: Bool) {
        guard focusedPanelModeActive, let focusedPanelID else {
            return (true, true)
        }
        let firstContainsFocused = first.leafContaining(panelID: focusedPanelID) != nil
        let secondContainsFocused = second.leafContaining(panelID: focusedPanelID) != nil
        if firstContainsFocused == secondContainsFocused {
            return (true, true)
        }
        return (firstContainsFocused, secondContainsFocused)
    }
}

private struct PanelCardView: View {
    let workspaceID: UUID
    let panelID: UUID
    let panelState: PanelState
    let focusedPanelID: UUID?
    let hasUnreadNotification: Bool
    let shortcutNumber: Int?
    let globalFontPoints: Double
    let appIsActive: Bool
    let unfocusedSplitStyle: GhosttyUnfocusedSplitStyle
    @ObservedObject var store: AppStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry

    private var isFocused: Bool {
        focusedPanelID == panelID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if hasUnreadNotification {
                    Circle()
                        .fill(ToastyTheme.badgeBlue)
                        .frame(width: 7, height: 7)
                        .shadow(color: ToastyTheme.badgeBlue.opacity(0.5), radius: 3, x: 0, y: 0)
                }

                Text(panelLabel)
                    .font(panelTitleFont)
                    .foregroundStyle(panelTitleTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                if let shortcutLabel {
                    shortcutBadge(shortcutLabel)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(ToastyTheme.elevatedBackground)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(panelHeaderDividerColor)
                    .frame(height: 1)
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
                .id(panelID)
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
            return terminal.displayPanelLabel
        case .diff:
            return "Diff Panel"
        case .markdown:
            return "Markdown Panel"
        case .scratchpad:
            return "Scratchpad Panel"
        }
    }

    private var shortcutLabel: String? {
        guard case .terminal = panelState else { return nil }
        guard let shortcutNumber else { return nil }
        return TerminalShortcutConfig.shortcutLabel(for: shortcutNumber)
    }

    private var panelTitleFont: Font {
        guard case .terminal = panelState else {
            return ToastyTheme.fontMonoHeader
        }
        return ToastyTheme.fontMonoTerminalPaneTitle
    }

    private var panelTitleTextColor: Color {
        guard case .terminal = panelState else {
            return ToastyTheme.primaryText
        }
        return appIsActive ? ToastyTheme.primaryText : ToastyTheme.primaryText.opacity(0.68)
    }

    private var panelHeaderDividerColor: Color {
        guard isFocused else {
            return ToastyTheme.hairline
        }
        guard case .terminal = panelState else {
            return ToastyTheme.accent
        }
        return appIsActive ? ToastyTheme.accent : ToastyTheme.accent.opacity(0.5)
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

    private func shortcutBadge(_ label: String) -> some View {
        Text(label)
            .font(ToastyTheme.fontShortcutBadge)
            .foregroundStyle(ToastyTheme.shortcutBadgeText)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(ToastyTheme.hairline, in: RoundedRectangle(cornerRadius: 3))
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

// MARK: - Flash Button Style

/// Custom ButtonStyle for momentary top bar actions. Shows the "active" pill styling
/// (accent icon, primary text, elevated background + border) while pressed, with a
/// smooth fade-out on release.
private struct TopBarFlashButtonStyle<Icon: View>: ButtonStyle {
    let title: String
    @ViewBuilder let icon: (_ isHighlighted: Bool) -> Icon

    func makeBody(configuration: Configuration) -> some View {
        let highlighted = configuration.isPressed
        HStack(spacing: 4) {
            icon(highlighted)
            Text(title)
                .font(ToastyTheme.fontSubtext)
                .foregroundStyle(highlighted ? ToastyTheme.primaryText : ToastyTheme.inactiveText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(highlighted ? ToastyTheme.elevatedBackground : Color.clear)
        .overlay(
            Rectangle()
                .stroke(highlighted ? ToastyTheme.subtleBorder : Color.clear, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.15), value: highlighted)
    }
}
