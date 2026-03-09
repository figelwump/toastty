import AppKit
import CoreState
import SwiftUI

struct WorkspaceView: View {
    let windowID: UUID
    @ObservedObject var store: AppStore
    let terminalRuntimeContext: TerminalWindowRuntimeContext?
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

            if let window = store.window(id: windowID) {
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
            Text(selectedWorkspace?.title ?? "")
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
        guard let workspaceID = selectedWorkspace?.id else { return }
        terminalRuntimeContext?.splitFocusedSlot(workspaceID: workspaceID, orientation: orientation)
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
                    let isSelected = store.selectedWorkspaceID(in: windowID) == workspaceID
                    workspaceContent(for: workspace, isSelected: isSelected)
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
    private func workspaceContent(for workspace: WorkspaceState, isSelected: Bool) -> some View {
        let terminalShortcutNumbersByPanelID = workspace.terminalShortcutNumbersByPanelID(
            limit: TerminalShortcutConfig.maxShortcutCount
        )
        let renderedLayout = workspace.renderedLayout
        GeometryReader { geometry in
            let projection = renderedLayout.projectLayout(
                in: LayoutFrame(
                    minX: 0,
                    minY: 0,
                    width: geometry.size.width,
                    height: geometry.size.height
                ),
                dividerThickness: 1
            )
            ZStack(alignment: .topLeading) {
                ForEach(projection.slots) { placement in
                    SlotPlacementView(
                        placement: placement,
                        workspace: workspace,
                        isWorkspaceSelected: isSelected,
                        store: store,
                        terminalRuntimeContext: terminalRuntimeContext,
                        globalFontPoints: store.state.globalTerminalFontPoints,
                        appIsActive: appIsActive,
                        unfocusedSplitStyle: ghosttyHostStyleStore.unfocusedSplitStyle,
                        terminalShortcutNumbersByPanelID: terminalShortcutNumbersByPanelID
                    )
                }

                ForEach(projection.dividers) { placement in
                    Rectangle()
                        .fill(ToastyTheme.slotDivider)
                        .frame(
                            width: CGFloat(placement.frame.width),
                            height: CGFloat(placement.frame.height)
                        )
                        .offset(
                            x: CGFloat(placement.frame.minX),
                            y: CGFloat(placement.frame.minY)
                        )
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        // Keep the workspace subtree mounted across focused-layout toggles so
        // terminal hosts preserve their runtime state instead of remounting.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func auxToggle(title: String, systemImage: String, kind: PanelKind, identifier: String) -> some View {
        let isOn = selectedWorkspace?.auxPanelVisibility.contains(kind) ?? false
        topBarButton(title: title, systemImage: systemImage, active: isOn) {
            guard let workspaceID = selectedWorkspace?.id else { return }
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
            guard let workspaceID = selectedWorkspace?.id else { return }
            store.send(.toggleFocusedPanelMode(workspaceID: workspaceID))
        }
        .accessibilityIdentifier(identifier)
    }

    private var isFocusedPanelModeActive: Bool {
        selectedWorkspace?.focusedPanelModeActive ?? false
    }

    private var selectedWorkspaceUnreadSignature: SelectedWorkspaceUnreadSignature? {
        guard let workspace = selectedWorkspace else { return nil }
        return SelectedWorkspaceUnreadSignature(
            workspaceID: workspace.id,
            focusedPanelID: workspace.focusedPanelID,
            unreadPanelIDs: workspace.unreadPanelIDs
        )
    }

    private func scheduleFocusedUnreadPanelClearIfNeeded() {
        focusedUnreadClearTask?.cancel()
        focusedUnreadClearTask = nil

        guard let workspace = selectedWorkspace,
              let focusedPanelID = workspace.focusedPanelID,
              workspace.unreadPanelIDs.contains(focusedPanelID) else {
            return
        }

        let workspaceID = workspace.id
        focusedUnreadClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.focusedUnreadClearDelayNanoseconds)
            guard Task.isCancelled == false else { return }
            guard let currentWorkspace = store.selectedWorkspace(in: windowID),
                  currentWorkspace.id == workspaceID,
                  currentWorkspace.focusedPanelID == focusedPanelID,
                  currentWorkspace.unreadPanelIDs.contains(focusedPanelID) else {
                return
            }
            _ = store.send(.markPanelNotificationsRead(workspaceID: workspaceID, panelID: focusedPanelID))
        }
    }

    private var selectedWorkspace: WorkspaceState? {
        store.selectedWorkspace(in: windowID)
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

private struct SlotPlacementView: View {
    let placement: LayoutSlotPlacement
    let workspace: WorkspaceState
    let isWorkspaceSelected: Bool
    @ObservedObject var store: AppStore
    let terminalRuntimeContext: TerminalWindowRuntimeContext?
    let globalFontPoints: Double
    let appIsActive: Bool
    let unfocusedSplitStyle: GhosttyUnfocusedSplitStyle
    let terminalShortcutNumbersByPanelID: [UUID: Int]

    var body: some View {
        Group {
            if let panelState = workspace.panels[placement.panelID] {
                PanelCardView(
                    workspaceID: workspace.id,
                    panelID: placement.panelID,
                    panelState: panelState,
                    isWorkspaceSelected: isWorkspaceSelected,
                    focusedPanelID: workspace.focusedPanelID,
                    hasUnreadNotification: workspace.unreadPanelIDs.contains(placement.panelID),
                    shortcutNumber: terminalShortcutNumbersByPanelID[placement.panelID],
                    globalFontPoints: globalFontPoints,
                    appIsActive: appIsActive,
                    unfocusedSplitStyle: unfocusedSplitStyle,
                    store: store,
                    terminalRuntimeContext: terminalRuntimeContext
                )
            } else {
                Color.clear
            }
        }
        // Slot containers stay keyed by stable slot identity so topology changes
        // do not remount the panel host for an existing slot.
        .id(placement.slotID)
        .frame(
            width: CGFloat(placement.frame.width),
            height: CGFloat(placement.frame.height),
            alignment: .topLeading
        )
        .offset(
            x: CGFloat(placement.frame.minX),
            y: CGFloat(placement.frame.minY)
        )
    }
}

private struct PanelCardView: View {
    let workspaceID: UUID
    let panelID: UUID
    let panelState: PanelState
    let isWorkspaceSelected: Bool
    let focusedPanelID: UUID?
    let hasUnreadNotification: Bool
    let shortcutNumber: Int?
    let globalFontPoints: Double
    let appIsActive: Bool
    let unfocusedSplitStyle: GhosttyUnfocusedSplitStyle
    @ObservedObject var store: AppStore
    let terminalRuntimeContext: TerminalWindowRuntimeContext?

    private var isFocused: Bool {
        // Only the selected workspace may present a focused terminal host.
        // Hidden-but-mounted workspaces still render for background runtime
        // updates, but they must not retain keyboard focus or route shortcuts.
        isWorkspaceSelected && focusedPanelID == panelID
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
                if let terminalRuntimeContext {
                TerminalPanelHostView(
                    workspaceID: workspaceID,
                    panelID: panelID,
                    terminalState: terminalState,
                    focused: isFocused,
                    globalFontPoints: globalFontPoints,
                    runtimeContext: terminalRuntimeContext
                )
                .overlay {
                    if isWorkspaceSelected,
                       focusedPanelID != nil,
                       !isFocused,
                       unfocusedSplitStyle.fillOverlayOpacity > 0 {
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
                } else {
                    Color.clear
                }

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
        return ToastyTheme.fontMonoTerminalSlotTitle
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
