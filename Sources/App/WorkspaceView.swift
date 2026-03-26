import AppKit
import CoreState
import SwiftUI

struct WorkspaceView: View {
    enum WorkspaceTabTrailingAccessory: Equatable {
        case closeButton
        case badge(String)
        case empty
    }

    let windowID: UUID
    @ObservedObject var store: AppStore
    @ObservedObject var agentCatalogStore: AgentCatalogStore
    @ObservedObject var terminalProfileStore: TerminalProfileStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore
    let profileShortcutRegistry: ProfileShortcutRegistry
    let agentLaunchService: AgentLaunchService
    let openAgentProfilesConfiguration: () -> Void
    let terminalRuntimeContext: TerminalWindowRuntimeContext?
    let sidebarVisible: Bool
    @ObservedObject private var ghosttyHostStyleStore = GhosttyHostStyleStore.shared
    @State private var focusedUnreadClearTask: Task<Void, Never>?
    @State private var appIsActive = NSApplication.shared.isActive
    @State private var hoveredTabID: UUID?
    @State private var hoveredTabCloseButtonID: UUID?
    @State private var renamingTabID: UUID?
    @State private var renameDraftTitle = ""

    private static let focusedUnreadClearDelayNanoseconds: UInt64 = 300_000_000

    nonisolated static func workspaceTabTrailingAccessory(
        index: Int,
        isHovered: Bool
    ) -> WorkspaceTabTrailingAccessory {
        if isHovered {
            return .closeButton
        }

        guard let shortcutLabel = DisplayShortcutConfig.workspaceTabSelectionShortcutLabel(for: index + 1) else {
            return .empty
        }
        return .badge(shortcutLabel)
    }

    private var agentTopBarModel: WorkspaceAgentTopBarModel {
        WorkspaceAgentTopBarModel(
            catalog: agentCatalogStore.catalog,
            profileShortcutRegistry: profileShortcutRegistry
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            Rectangle()
                .fill(ToastyTheme.hairline)
                .frame(height: 1)

            if let workspace = selectedWorkspace,
               workspace.tabIDs.count > 1 {
                workspaceTabBar(for: workspace)
                Rectangle()
                    .fill(ToastyTheme.hairline)
                    .frame(height: 1)
            }

            if let window = store.window(id: windowID) {
                workspaceStack(for: window)
            } else {
                EmptyStateView(onCreateWorkspace: createWorkspaceAction)
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
        .onChange(of: store.state.workspacesByID) { _, _ in
            pruneTransientTabRenameState()
        }
        .onChange(of: store.pendingRenameWorkspaceTabRequest) { _, _ in
            consumePendingWorkspaceTabRenameRequestIfNeeded()
        }
        .onChange(of: selectedWorkspace?.id) { _, _ in
            pruneTransientTabRenameState()
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
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("topbar.workspace.title")

            Spacer(minLength: 12)

            if agentTopBarModel.showsAddAgentsButton {
                topBarFlashTextButton(title: WorkspaceAgentTopBarModel.addAgentsTitle) {
                    openAgentProfilesConfiguration()
                }
                .accessibilityIdentifier("topbar.agent.add")
            } else {
                ForEach(agentTopBarModel.actions) { action in
                    topBarFlashTextButton(title: action.title) {
                        launchAgent(profileID: action.profileID)
                    }
                    .disabled(canLaunchAgent(profileID: action.profileID) == false)
                    .help(action.helpText)
                    .accessibilityIdentifier("topbar.agent.\(action.profileID)")
                }
            }

            focusedPanelToggle(identifier: "topbar.toggle.focused-panel")

            topBarFlashButton(title: "Split H", icon: { highlighted in
                SplitHorizontalIconView(color: highlighted ? ToastyTheme.accent : ToastyTheme.inactiveText)
            }) {
                split(orientation: .horizontal)
            }
            .disabled(isFocusedPanelModeActive)
            .help(ToasttyKeyboardShortcuts.splitHorizontal.helpText("Split Horizontally"))
            .accessibilityIdentifier("workspace.split.horizontal")

            topBarFlashButton(title: "Split V", icon: { highlighted in
                SplitVerticalIconView(color: highlighted ? ToastyTheme.accent : ToastyTheme.inactiveText)
            }) {
                split(orientation: .vertical)
            }
            .disabled(isFocusedPanelModeActive)
            .help(ToasttyKeyboardShortcuts.splitVertical.helpText("Split Vertically"))
            .accessibilityIdentifier("workspace.split.vertical")
        }
        .padding(.leading, sidebarVisible ? 12 : ToastyTheme.topBarLeadingPaddingWithoutSidebar)
        .padding(.trailing, 12)
        .padding(.top, ToastyTheme.topBarContentTopPadding)
        .frame(height: ToastyTheme.topBarHeight)
        .background(ToastyTheme.chromeBackground)
        .accessibilityIdentifier("topbar.container")
    }

    private func workspaceTabBar(for workspace: WorkspaceState) -> some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(workspace.orderedTabs.enumerated()), id: \.element.id) { index, tab in
                        workspaceTabRow(
                            workspaceID: workspace.id,
                            tab: tab,
                            index: index,
                            isSelected: workspace.resolvedSelectedTabID == tab.id
                        )
                    }
                }
                .padding(
                    .leading,
                    sidebarVisible
                        ? ToastyTheme.workspaceTabLeadingPaddingWithSidebar
                        : ToastyTheme.topBarLeadingPaddingWithoutSidebar
                )
                .padding(.vertical, 4)
            }

            Button(action: createTabInSelectedWorkspace) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ToastyTheme.inactiveText)
                    .frame(width: 20, height: 20)
                    .background(ToastyTheme.elevatedBackground, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(ToastyTheme.subtleBorder, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
            .disabled(selectedWorkspace == nil)
            .help(ToasttyKeyboardShortcuts.newTab.helpText("New Tab"))
            .accessibilityIdentifier("workspace.tabs.new")
        }
        .frame(height: ToastyTheme.workspaceTabBarHeight)
        .background(ToastyTheme.chromeBackground)
        .accessibilityIdentifier("workspace.tabs.container")
    }

    private func split(orientation: SplitOrientation) {
        guard let workspaceID = selectedWorkspace?.id else { return }
        terminalRuntimeContext?.splitFocusedSlot(workspaceID: workspaceID, orientation: orientation)
    }

    private func canLaunchAgent(profileID: String) -> Bool {
        agentLaunchService.canLaunchAgent(
            profileID: profileID,
            workspaceID: selectedWorkspace?.id
        )
    }

    private func launchAgent(profileID: String) {
        AgentLaunchUI.launch(
            profileID: profileID,
            workspaceID: selectedWorkspace?.id,
            agentLaunchService: agentLaunchService
        )
    }

    private var createWorkspaceAction: (() -> Void)? {
        guard store.canCreateWorkspaceFromCommand(preferredWindowID: windowID) else { return nil }
        return {
            _ = store.createWorkspaceFromCommand(preferredWindowID: windowID)
        }
    }

    private func createTabInSelectedWorkspace() {
        cancelTabRename()
        _ = store.createWorkspaceTabFromCommand(preferredWindowID: windowID)
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
        ZStack {
            ForEach(workspace.orderedTabs) { tab in
                let isSelectedTab = workspace.resolvedSelectedTabID == tab.id
                workspaceTabContent(
                    workspace: workspace,
                    tab: tab,
                    isWorkspaceSelected: isSelected,
                    isTabSelected: isSelectedTab
                )
                .opacity(isSelectedTab ? 1 : 0)
                .allowsHitTesting(isSelected && isSelectedTab)
                .accessibilityHidden(!(isSelected && isSelectedTab))
                .zIndex(isSelectedTab ? 1 : 0)
            }
        }
        // Keep the workspace subtree mounted across focused-layout toggles so
        // terminal hosts preserve their runtime state instead of remounting.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func workspaceTabContent(
        workspace: WorkspaceState,
        tab: WorkspaceTabState,
        isWorkspaceSelected: Bool,
        isTabSelected: Bool
    ) -> some View {
        let terminalShortcutNumbersByPanelID = terminalShortcutNumbersByPanelID(
            for: tab,
            isSelectedTab: isWorkspaceSelected && isTabSelected
        )
        let panelSessionStatusesByPanelID: [UUID: WorkspaceSessionStatus] = Dictionary(
            uniqueKeysWithValues: tab.panels.keys.compactMap { panelID in
                guard let status = sessionRuntimeStore.panelStatus(for: panelID) else {
                    return nil
                }
                return (panelID, status)
            }
        )
        let renderedLayout = WorkspaceSplitTree(root: tab.layoutTree).renderedLayout(
            workspaceID: workspace.id,
            focusedPanelModeActive: tab.focusedPanelModeActive,
            focusedPanelID: tab.focusedPanelID
        )

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
                        workspaceID: workspace.id,
                        tab: tab,
                        isWorkspaceSelected: isWorkspaceSelected,
                        isTabSelected: isTabSelected,
                        store: store,
                        terminalProfileStore: terminalProfileStore,
                        terminalRuntimeRegistry: terminalRuntimeRegistry,
                        terminalRuntimeContext: terminalRuntimeContext,
                        windowFontPoints: store.state.effectiveTerminalFontPoints(for: windowID),
                        appIsActive: appIsActive,
                        unfocusedSplitStyle: ghosttyHostStyleStore.unfocusedSplitStyle,
                        terminalShortcutNumbersByPanelID: terminalShortcutNumbersByPanelID,
                        panelSessionStatusesByPanelID: panelSessionStatusesByPanelID
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
        .help(
            ToasttyKeyboardShortcuts.toggleFocusedPanel.helpText(
                isOn ? "Restore Layout" : "Focus Panel"
            )
        )
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

    private func terminalShortcutNumbersByPanelID(
        for tab: WorkspaceTabState,
        isSelectedTab: Bool
    ) -> [UUID: Int] {
        guard isSelectedTab else { return [:] }
        let terminalPanelIDs = tab.layoutTree.allSlotInfos.compactMap { slot -> UUID? in
            guard case .terminal = tab.panels[slot.panelID] else {
                return nil
            }
            return slot.panelID
        }

        return Dictionary(
            uniqueKeysWithValues: terminalPanelIDs
                .prefix(DisplayShortcutConfig.maxPanelFocusShortcutCount)
                .enumerated()
                .map { offset, panelID in
                    (panelID, offset + 1)
                }
        )
    }

    private func workspaceTabRow(
        workspaceID: UUID,
        tab: WorkspaceTabState,
        index: Int,
        isSelected: Bool
    ) -> some View {
        let hasUnread = tab.unreadPanelIDs.isEmpty == false
        let isRenaming = renamingTabID == tab.id
        let isHovered = isRenaming == false && hoveredTabID == tab.id
        let colors = resolveTabColors(
            isSelected: isSelected,
            isHovered: isHovered,
            hasUnread: hasUnread,
            appIsActive: appIsActive
        )

        return ZStack(alignment: .trailing) {
            if isRenaming {
                workspaceTabRenameRow(
                    workspaceID: workspaceID,
                    tab: tab,
                    colors: colors,
                    hasUnread: hasUnread
                )
            } else {
                Button {
                    if renamingTabID != nil {
                        cancelTabRename()
                    }
                    _ = store.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: tab.id))
                } label: {
                    workspaceTabChrome(colors: colors) {
                        HStack(spacing: 5) {
                            workspaceTabTitleContent(
                                tab: tab,
                                textColor: colors.text,
                                hasUnread: hasUnread
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)

                            workspaceTabTrailingContent(
                                index: index,
                                isSelected: isSelected,
                                isHovered: isHovered
                            )
                            .frame(width: ToastyTheme.workspaceTabTrailingSlotWidth, alignment: .trailing)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.displayTitle)
                .help(tab.displayTitle)
                .accessibilityIdentifier("workspace.tab.\(tab.id.uuidString)")
                .animation(.easeInOut(duration: 0.15), value: isSelected)
                .animation(.easeOut(duration: 0.1), value: isHovered)
            }

            if isHovered {
                workspaceTabCloseButton(workspaceID: workspaceID, tab: tab)
                    .padding(.trailing, 10)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            workspaceTabContextMenu(workspaceID: workspaceID, tab: tab)
        }
        .onHover { hovering in
            guard isRenaming == false else { return }
            if hovering {
                hoveredTabID = tab.id
            } else if hoveredTabID == tab.id {
                hoveredTabID = nil
                if hoveredTabCloseButtonID == tab.id {
                    hoveredTabCloseButtonID = nil
                }
            }
        }
    }

    @ViewBuilder
    private func workspaceTabTitleContent(
        tab: WorkspaceTabState,
        textColor: Color,
        hasUnread: Bool
    ) -> some View {
        HStack(spacing: 5) {
            if hasUnread {
                Circle()
                    .fill(ToastyTheme.workspaceTabUnreadDot)
                    .frame(
                        width: ToastyTheme.workspaceTabUnreadDotDiameter,
                        height: ToastyTheme.workspaceTabUnreadDotDiameter
                    )
            }

            Text(tab.displayTitle)
                .font(ToastyTheme.fontWorkspaceTab)
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func workspaceTabRenameRow(
        workspaceID: UUID,
        tab: WorkspaceTabState,
        colors: (background: Color, border: Color, text: Color),
        hasUnread: Bool
    ) -> some View {
        workspaceTabChrome(colors: colors) {
            HStack(spacing: 5) {
                if hasUnread {
                    Circle()
                        .fill(ToastyTheme.workspaceTabUnreadDot)
                        .frame(
                            width: ToastyTheme.workspaceTabUnreadDotDiameter,
                            height: ToastyTheme.workspaceTabUnreadDotDiameter
                        )
                }

                WorkspaceRenameTextField(
                    text: $renameDraftTitle,
                    itemID: tab.id,
                    placeholder: "Tab name",
                    font: .monospacedSystemFont(ofSize: 11, weight: .medium),
                    accessibilityID: renameTextFieldAccessibilityID(for: tab.id),
                    onSubmit: {
                        commitTabRename(workspaceID: workspaceID, tabID: tab.id)
                    },
                    onCancel: {
                        cancelTabRenameAndRestoreFocus()
                    }
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                Color.clear
                    .frame(width: ToastyTheme.workspaceTabTrailingSlotWidth, height: 16)
            }
        }
        .accessibilityIdentifier("workspace.tab.rename.container.\(tab.id.uuidString)")
    }

    private func workspaceTabChrome<Content: View>(
        colors: (background: Color, border: Color, text: Color),
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, 10)
            .frame(width: ToastyTheme.workspaceTabWidth, height: ToastyTheme.workspaceTabHeight)
            .background(
                colors.background,
                in: RoundedRectangle(cornerRadius: ToastyTheme.workspaceTabCornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ToastyTheme.workspaceTabCornerRadius)
                    .stroke(colors.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
    }

    private func resolveTabColors(
        isSelected: Bool,
        isHovered: Bool,
        hasUnread: Bool,
        appIsActive: Bool
    ) -> (background: Color, border: Color, text: Color) {
        if isSelected {
            return (
                ToastyTheme.workspaceTabSelectedBackground,
                ToastyTheme.workspaceTabSelectedBorderColor(appIsActive: appIsActive),
                ToastyTheme.primaryText
            )
        }

        if isHovered {
            return (
                ToastyTheme.workspaceTabHoverBackground,
                ToastyTheme.workspaceTabHoverBorder,
                ToastyTheme.workspaceTabHoverText
            )
        }

        if hasUnread {
            return (
                ToastyTheme.workspaceTabUnreadBackground,
                ToastyTheme.workspaceTabUnreadBorder,
                ToastyTheme.workspaceTabUnreadText
            )
        }

        return (
            ToastyTheme.workspaceTabUnselectedBackground,
            ToastyTheme.workspaceTabUnselectedBorder,
            ToastyTheme.workspaceTabUnselectedText
        )
    }

    @ViewBuilder
    private func workspaceTabTrailingContent(
        index: Int,
        isSelected: Bool,
        isHovered: Bool
    ) -> some View {
        switch Self.workspaceTabTrailingAccessory(index: index, isHovered: isHovered) {
        case .closeButton:
            Color.clear.frame(height: 16)
        case .badge(let shortcutLabel):
            Text(shortcutLabel)
                .font(ToastyTheme.fontWorkspaceTabBadge)
                .foregroundStyle(
                    isSelected
                        ? ToastyTheme.workspaceTabBadgeSelectedText
                        : ToastyTheme.workspaceTabBadgeUnselectedText
                )
                .transition(.opacity)
        case .empty:
            EmptyView()
        }
    }

    private func workspaceTabCloseButton(
        workspaceID: UUID,
        tab: WorkspaceTabState
    ) -> some View {
        Button {
            closeWorkspaceTab(workspaceID: workspaceID, tabID: tab.id)
        } label: {
            Text("×")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(
                    hoveredTabCloseButtonID == tab.id
                        ? ToastyTheme.workspaceTabCloseButtonHover
                        : ToastyTheme.workspaceTabCloseButton
                )
                .frame(width: 16, height: 16)
                .background(
                    ToastyTheme.workspaceTabCloseBackground,
                    in: RoundedRectangle(cornerRadius: 4)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close \(tab.displayTitle)")
        .onHover { hovering in
            if hovering {
                hoveredTabCloseButtonID = tab.id
            } else if hoveredTabCloseButtonID == tab.id {
                hoveredTabCloseButtonID = nil
            }
        }
        .help("Close \(tab.displayTitle)")
        .accessibilityIdentifier("workspace.tab.close.\(tab.id.uuidString)")
        .transition(.opacity)
        .contextMenu {
            workspaceTabContextMenu(workspaceID: workspaceID, tab: tab)
        }
    }

    @ViewBuilder
    private func workspaceTabContextMenu(workspaceID: UUID, tab: WorkspaceTabState) -> some View {
        Button(ToasttyKeyboardShortcuts.renameTab.menuTitle("Rename Tab")) {
            beginTabRename(tab)
        }

        if tab.customTitle != nil {
            Button("Reset Tab Title") {
                resetWorkspaceTabTitle(workspaceID: workspaceID, tabID: tab.id)
            }
        }

        Button("Close Tab", role: .destructive) {
            closeWorkspaceTab(workspaceID: workspaceID, tabID: tab.id)
        }
    }

    private func beginTabRename(_ tab: WorkspaceTabState) {
        clearTabHoverState(for: tab.id)
        renamingTabID = tab.id
        renameDraftTitle = tab.displayTitle
    }

    private func commitTabRename(workspaceID: UUID, tabID: UUID) {
        guard let workspace = store.state.workspacesByID[workspaceID],
              let tab = workspace.tab(id: tabID) else {
            cancelTabRenameAndRestoreFocus()
            return
        }

        let trimmedTitle = renameDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.isEmpty == false else {
            renameDraftTitle = tab.displayTitle
            cancelTabRenameAndRestoreFocus()
            return
        }

        _ = store.send(.setWorkspaceTabCustomTitle(workspaceID: workspaceID, tabID: tabID, title: trimmedTitle))
        cancelTabRenameAndRestoreFocus()
    }

    private func resetWorkspaceTabTitle(workspaceID: UUID, tabID: UUID) {
        _ = store.send(.setWorkspaceTabCustomTitle(workspaceID: workspaceID, tabID: tabID, title: nil))
        if renamingTabID == tabID {
            cancelTabRenameAndRestoreFocus()
        }
    }

    private func closeWorkspaceTab(workspaceID: UUID, tabID: UUID) {
        clearTabHoverState(for: tabID)
        if renamingTabID == tabID {
            cancelTabRename()
        }
        _ = store.send(.closeWorkspaceTab(workspaceID: workspaceID, tabID: tabID))
    }

    private func cancelTabRename() {
        renamingTabID = nil
        renameDraftTitle = ""
    }

    private func cancelTabRenameAndRestoreFocus() {
        cancelTabRename()
        scheduleWorkspaceSlotFocusRestore()
    }

    private func scheduleWorkspaceSlotFocusRestore() {
        guard let workspaceID = selectedWorkspace?.id else { return }
        terminalRuntimeContext?.scheduleWorkspaceFocusRestore(
            workspaceID: workspaceID,
            avoidStealingKeyboardFocus: false
        )
    }

    private func pruneTransientTabRenameState() {
        guard let renamingTabID else { return }
        guard let workspace = selectedWorkspace,
              workspace.tabIDs.count > 1,
              workspace.tabsByID[renamingTabID] != nil else {
            cancelTabRename()
            return
        }
    }

    private func clearTabHoverState(for tabID: UUID) {
        if hoveredTabID == tabID {
            hoveredTabID = nil
        }
        if hoveredTabCloseButtonID == tabID {
            hoveredTabCloseButtonID = nil
        }
    }

    private func consumePendingWorkspaceTabRenameRequestIfNeeded() {
        guard let request = store.consumePendingWorkspaceTabRenameRequest(windowID: windowID),
              let workspace = selectedWorkspace,
              workspace.id == request.workspaceID,
              workspace.orderedTabs.count > 1,
              let tab = workspace.tab(id: request.tabID) else {
            return
        }

        beginTabRename(tab)
    }

    private func renameTextFieldAccessibilityID(for tabID: UUID) -> String {
        "workspace.tab.rename.\(tabID.uuidString)"
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

    private func topBarFlashTextButton(
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(TopBarFlashTextButtonStyle())
    }
}

struct WorkspaceAgentTopBarModel: Equatable {
    static let addAgentsTitle = "Add Agents…"

    struct Action: Equatable, Identifiable {
        let profileID: String
        let title: String
        let helpText: String

        var id: String { profileID }
    }

    let actions: [Action]

    var showsAddAgentsButton: Bool {
        actions.isEmpty
    }

    init(
        catalog: AgentCatalog,
        profileShortcutRegistry: ProfileShortcutRegistry
    ) {
        actions = catalog.profiles.map { profile in
            let helpTextBase = "Run \(profile.displayName)"
            let helpText = profileShortcutRegistry.chord(
                for: .agentProfileLaunch(profileID: profile.id)
            ).map { "\(helpTextBase) (\($0.symbolLabel))" } ?? helpTextBase

            return Action(
                profileID: profile.id,
                title: profile.displayName,
                helpText: helpText
            )
        }
    }
}

private struct SelectedWorkspaceUnreadSignature: Equatable {
    let workspaceID: UUID
    let focusedPanelID: UUID?
    let unreadPanelIDs: Set<UUID>
}

private struct SlotPlacementView: View {
    let placement: LayoutSlotPlacement
    let workspaceID: UUID
    let tab: WorkspaceTabState
    let isWorkspaceSelected: Bool
    let isTabSelected: Bool
    @ObservedObject var store: AppStore
    @ObservedObject var terminalProfileStore: TerminalProfileStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
    let terminalRuntimeContext: TerminalWindowRuntimeContext?
    let windowFontPoints: Double
    let appIsActive: Bool
    let unfocusedSplitStyle: GhosttyUnfocusedSplitStyle
    let terminalShortcutNumbersByPanelID: [UUID: Int]
    let panelSessionStatusesByPanelID: [UUID: WorkspaceSessionStatus]

    var body: some View {
        Group {
            if let panelState = tab.panels[placement.panelID] {
                PanelCardView(
                    workspaceID: workspaceID,
                    panelID: placement.panelID,
                    panelState: panelState,
                    isWorkspaceSelected: isWorkspaceSelected,
                    isTabSelected: isTabSelected,
                    focusedPanelID: tab.focusedPanelID,
                    hasUnreadNotification: tab.unreadPanelIDs.contains(placement.panelID),
                    panelSessionStatus: panelSessionStatusesByPanelID[placement.panelID],
                    terminalDisplayTitleOverride: terminalRuntimeRegistry.panelDisplayTitleOverride(for: placement.panelID),
                    shortcutNumber: terminalShortcutNumbersByPanelID[placement.panelID],
                    windowFontPoints: windowFontPoints,
                    appIsActive: appIsActive,
                    unfocusedSplitStyle: unfocusedSplitStyle,
                    store: store,
                    terminalProfileStore: terminalProfileStore,
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
    let isTabSelected: Bool
    let focusedPanelID: UUID?
    let hasUnreadNotification: Bool
    let panelSessionStatus: WorkspaceSessionStatus?
    let terminalDisplayTitleOverride: String?
    let shortcutNumber: Int?
    let windowFontPoints: Double
    let appIsActive: Bool
    let unfocusedSplitStyle: GhosttyUnfocusedSplitStyle
    @ObservedObject var store: AppStore
    @ObservedObject var terminalProfileStore: TerminalProfileStore
    let terminalRuntimeContext: TerminalWindowRuntimeContext?

    private var isFocused: Bool {
        // Only the selected workspace may present a focused terminal host.
        // Hidden-but-mounted workspaces still render for background runtime
        // updates, but they must not retain keyboard focus or route shortcuts.
        isWorkspaceSelected && isTabSelected && focusedPanelID == panelID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                let indicatorState = panelHeaderIndicatorState
                if indicatorState != .hidden {
                    SessionStatusIndicator(state: indicatorState, size: 8, lineWidth: 1.4)
                }

                if let terminalProfileBadge {
                    profileBadge(terminalProfileBadge)
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
            .background(panelHeaderBackgroundColor)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(panelHeaderDividerColor)
                    .frame(height: panelHeaderDividerHeight)
            }

            switch panelState {
            case .terminal(let terminalState):
                if let terminalRuntimeContext {
                TerminalPanelHostView(
                    workspaceID: workspaceID,
                    panelID: panelID,
                    terminalState: terminalState,
                    focused: isFocused,
                    windowFontPoints: windowFontPoints,
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
            if let panelSessionStatus, panelSessionStatus.isActive {
                return panelSessionStatus.agent.displayName
            }
            return terminalDisplayTitleOverride ?? terminal.displayPanelLabel
        case .diff:
            return "Diff Panel"
        case .markdown:
            return "Markdown Panel"
        case .scratchpad:
            return "Scratchpad Panel"
        }
    }

    private var terminalProfileBadge: TerminalProfileBadge? {
        guard case .terminal(let terminalState) = panelState,
              let profileBinding = terminalState.profileBinding else {
            return nil
        }

        if let profile = terminalProfileStore.catalog.profile(id: profileBinding.profileID) {
            return TerminalProfileBadge(label: profile.badgeLabel, isAvailable: true)
        }

        return TerminalProfileBadge(
            label: profileBinding.profileID,
            isAvailable: false
        )
    }

    private var shortcutLabel: String? {
        guard case .terminal = panelState else { return nil }
        guard let shortcutNumber else { return nil }
        return DisplayShortcutConfig.panelFocusShortcutLabel(for: shortcutNumber)
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
        guard let terminalHeaderAppearance else {
            guard isFocused else {
                return ToastyTheme.hairline
            }
            return ToastyTheme.accent
        }

        return ToastyTheme.panelHeaderDividerColor(
            for: terminalHeaderAppearance.treatment,
            appIsActive: appIsActive
        )
    }

    private var panelHeaderBackgroundColor: Color {
        guard let terminalHeaderAppearance else {
            return ToastyTheme.elevatedBackground
        }

        return ToastyTheme.panelHeaderBackgroundColor(
            for: terminalHeaderAppearance.treatment,
            appIsActive: appIsActive
        )
    }

    private var panelHeaderDividerHeight: CGFloat {
        guard let terminalHeaderAppearance else {
            return 1
        }
        return CGFloat(terminalHeaderAppearance.dividerHeight)
    }

    private var panelHeaderIndicatorState: SessionStatusIndicatorState {
        terminalHeaderAppearance?.indicatorState ?? .hidden
    }

    private var terminalHeaderAppearance: PanelHeaderAppearance? {
        guard case .terminal = panelState else {
            return nil
        }

        return PanelHeaderAppearance.resolve(
            isFocused: isFocused,
            hasUnreadNotification: hasUnreadNotification,
            sessionStatusKind: panelSessionStatus?.status.kind
        )
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

    private func profileBadge(_ badge: TerminalProfileBadge) -> some View {
        Text(badge.label)
            .font(ToastyTheme.fontTerminalProfileBadge)
            .foregroundStyle(
                badge.isAvailable
                    ? ToastyTheme.terminalProfileBadgeText
                    : ToastyTheme.terminalProfileBadgeMissingText
            )
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                badge.isAvailable
                    ? ToastyTheme.terminalProfileBadgeBackground
                    : ToastyTheme.terminalProfileBadgeMissingBackground,
                in: Capsule()
            )
    }
}

private struct TerminalProfileBadge {
    let label: String
    let isAvailable: Bool
}

// MARK: - Top Bar Icons

/// Sidebar panel icon — rectangle with left panel section.
/// When `sidebarVisible` is true the left panel is filled to indicate the sidebar is shown.
struct SidebarToggleIconView: View {
    let color: Color
    let sidebarVisible: Bool

    var body: some View {
        Canvas { context, _ in
            // Outer rectangle
            let rect = Path(roundedRect: CGRect(x: 1, y: 1, width: 12, height: 12), cornerRadius: 1.5)
            context.stroke(rect, with: .color(color), style: StrokeStyle(lineWidth: 1.2))

            // Vertical divider separating sidebar panel from main area
            var divider = Path()
            divider.move(to: CGPoint(x: 5.2, y: 1))
            divider.addLine(to: CGPoint(x: 5.2, y: 13))
            context.stroke(divider, with: .color(color), style: StrokeStyle(lineWidth: 1.2))

            // Fill the left panel area when sidebar is visible
            if sidebarVisible {
                let fill = Path(CGRect(x: 1.7, y: 1.7, width: 3.5, height: 10.6))
                context.fill(fill, with: .color(color.opacity(0.3)))
            }
        }
        .frame(width: 14, height: 14)
    }
}

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

private struct TopBarFlashTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let highlighted = configuration.isPressed
        configuration.label
            .font(ToastyTheme.fontSubtext)
            .foregroundStyle(highlighted ? ToastyTheme.primaryText : ToastyTheme.inactiveText)
            .lineLimit(1)
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
