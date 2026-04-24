import AppKit
import CoreState
import SwiftUI

struct WorkspaceView: View {
    struct FocusedUnreadClearCandidate: Equatable {
        let workspaceID: UUID
        let panelID: UUID
    }

    enum WorkspaceTabTrailingAccessory: Equatable {
        case closeButton
        case badge(String)
        case empty
    }

    enum WorkspaceTabFocusIndicatorStyle: Equatable {
        case fullLabel
        case iconOnly
    }

    enum PanelHeaderTrailingAccessory: Equatable {
        case closeButton
        case badge(String)
        case empty
    }

    struct FocusModePresentationState: Equatable {
        let workspaceID: UUID
        let tabID: UUID
        let focusedPanelModeActive: Bool
        let effectiveRootNodeID: UUID?
    }

    struct TransientUnfocusHighlightRequest: Equatable {
        let workspaceID: UUID
        let tabID: UUID
        let rootNodeID: UUID
    }

    struct WorkspaceTabChromeSpec {
        let background: Color
        let text: Color
        let accentColor: Color?
        let borderColor: Color?
    }

    struct WorkspaceTabDragState: Equatable {
        let tabID: UUID
        let sourceIndex: Int
        let startPointerX: CGFloat
        var translationWidth: CGFloat
        var targetIndex: Int
    }

    private struct WorkspaceTabShape: Shape {
        func path(in rect: CGRect) -> Path {
            let radius = min(ToastyTheme.workspaceTabCornerRadius, rect.width / 2, rect.height)
            var path = Path()

            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + radius, y: rect.minY),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                control: CGPoint(x: rect.maxX, y: rect.minY)
            )
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()

            return path
        }
    }

    let windowID: UUID
    @ObservedObject var store: AppStore
    @ObservedObject var agentCatalogStore: AgentCatalogStore
    @ObservedObject var terminalProfileStore: TerminalProfileStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
    @ObservedObject var webPanelRuntimeRegistry: WebPanelRuntimeRegistry
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore
    let profileShortcutRegistry: ProfileShortcutRegistry
    let focusedPanelCommandController: FocusedPanelCommandController
    let agentLaunchService: AgentLaunchService
    let showAgentGetStartedFlow: () -> Void
    let toggleCommandPalette: @MainActor (UUID) -> Void
    let terminalRuntimeContext: TerminalWindowRuntimeContext?
    let sidebarVisible: Bool
    @ObservedObject private var ghosttyHostStyleStore = GhosttyHostStyleStore.shared
    @State private var focusedUnreadClearTask: Task<Void, Never>?
    @State private var appIsActive = NSApplication.shared.isActive
    @State private var hoveredTabID: UUID?
    @State private var hoveredTabCloseButtonID: UUID?
    @State private var renamingTabID: UUID?
    @State private var activeTabDrag: WorkspaceTabDragState?
    @State private var measuredWorkspaceTabFramesByID: [UUID: CGRect] = [:]
    @State private var renameDraftTitle = ""
    @State private var pendingWorkspaceTabClose: PendingWorkspaceTabClose?
    @State private var flashingPanelID: UUID?
    @State private var flashingPanelOverlayOpacity = 0.0
    @State private var activePanelFlashRequestID: UUID?
    @State private var lastHandledPanelFlashRequestID: UUID?
    @State private var panelFlashClearWorkItem: DispatchWorkItem?
    @State private var panelFlashResetWorkItem: DispatchWorkItem?
    @State private var transientUnfocusHighlight: TransientUnfocusHighlightRequest?
    @State private var transientUnfocusHighlightOpacity = 0.0
    @State private var transientUnfocusHighlightFadeWorkItem: DispatchWorkItem?
    @State private var transientUnfocusHighlightResetWorkItem: DispatchWorkItem?

    private static let focusedUnreadClearDelayNanoseconds: UInt64 = 300_000_000
    private static let workspaceTitleToTabsSpacing: CGFloat = 18
    private static let workspaceTabsToControlsSpacing: CGFloat = 12
    private static let workspaceTabStripSpacing: CGFloat = -1.5
    private static let workspaceTabAccessorySpacing: CGFloat = 10
    private static let workspaceNewTabButtonSize: CGFloat = 20
    private nonisolated static let workspaceTabDragActivationDistance: CGFloat = 4

    nonisolated static func resolvedWorkspaceTitleWidth(
        preferredWidth: CGFloat,
        availableWidth: CGFloat,
        trailingWidth: CGFloat,
        tabCount: Int,
        titleSpacing: CGFloat = 18,
        trailingSpacing: CGFloat = 12,
        tabSpacing: CGFloat = 0,
        tabAccessoryWidth: CGFloat = 0,
        tabAccessorySpacing: CGFloat = 0,
        titleMaxWidth: CGFloat = 260
    ) -> CGFloat {
        let cappedPreferredWidth = min(preferredWidth, titleMaxWidth)
        guard availableWidth.isFinite else { return cappedPreferredWidth }

        let minimumTabsWidth = workspaceTabMinimumTotalWidth(
            tabCount: tabCount,
            spacing: tabSpacing,
            trailingAccessoryWidth: tabAccessoryWidth,
            trailingAccessorySpacing: tabAccessorySpacing
        )

        guard minimumTabsWidth > 0 else {
            return max(0, min(cappedPreferredWidth, availableWidth - trailingWidth - trailingSpacing))
        }
        let availableTitleWidth = availableWidth - trailingWidth - titleSpacing - trailingSpacing - minimumTabsWidth
        return max(0, min(cappedPreferredWidth, availableTitleWidth))
    }

    nonisolated static func workspaceHeaderTitleOriginY(
        boundsHeight: CGFloat,
        titleHeight: CGFloat
    ) -> CGFloat {
        let resolvedTitleHeight = min(boundsHeight, titleHeight)
        let hiddenSidebarOriginY = ToastyTheme.hiddenSidebarTitleCenterY - (resolvedTitleHeight / 2)
        return min(max(0, hiddenSidebarOriginY), max(0, boundsHeight - resolvedTitleHeight))
    }

    nonisolated static func workspaceUnreadSummaryText(unreadPanelCount: Int) -> String? {
        guard unreadPanelCount > 0 else { return nil }
        return unreadPanelCount == 1 ? "1 unread" : "\(unreadPanelCount) unreads"
    }

    nonisolated static func workspaceHeaderTitleColumnPreferredWidth(
        titleWidth: CGFloat,
        unreadSummaryWidth: CGFloat
    ) -> CGFloat {
        max(titleWidth, unreadSummaryWidth)
    }

    nonisolated static func workspaceHeaderUnreadSummaryOriginY(
        titleOriginY: CGFloat,
        titleHeight: CGFloat,
        spacing: CGFloat
    ) -> CGFloat {
        titleOriginY + titleHeight + spacing
    }

    nonisolated static func focusedUnreadClearCandidate(
        workspace: WorkspaceState?,
        appIsActive: Bool
    ) -> FocusedUnreadClearCandidate? {
        guard appIsActive,
              let workspace,
              let focusedPanelID = workspace.focusedPanelID,
              workspace.unreadPanelIDs.contains(focusedPanelID) else {
            return nil
        }

        return FocusedUnreadClearCandidate(
            workspaceID: workspace.id,
            panelID: focusedPanelID
        )
    }

    nonisolated static func shouldClearFocusedUnread(
        currentWorkspace: WorkspaceState?,
        candidate: FocusedUnreadClearCandidate,
        appIsActive: Bool
    ) -> Bool {
        guard appIsActive,
              let currentWorkspace,
              currentWorkspace.id == candidate.workspaceID,
              currentWorkspace.focusedPanelID == candidate.panelID else {
            return false
        }

        return currentWorkspace.unreadPanelIDs.contains(candidate.panelID)
    }

    private static let panelFlashPeakDuration: Double = 0.18
    private static let panelFlashSettleDuration: Double = 0.28
    private static let transientUnfocusHighlightHoldDuration: Double = 1.0
    private static let transientUnfocusHighlightFadeDuration: Double = 0.3
    // Once tabs compress near their minimum width, keep the focus badge
    // single-line by switching to the icon-only variant.
    private static let workspaceTabCompactFocusIndicatorThreshold: CGFloat = 120

    nonisolated static func workspaceTabTrailingAccessory(
        index: Int,
        isHovered: Bool,
        showsCloseAffordance: Bool
    ) -> WorkspaceTabTrailingAccessory {
        if isHovered && showsCloseAffordance {
            return .closeButton
        }

        guard let shortcutLabel = DisplayShortcutConfig.workspaceTabSelectionShortcutLabel(for: index + 1) else {
            return .empty
        }
        return .badge(shortcutLabel)
    }

    nonisolated static func workspaceTabManagementAffordancesEnabled(tabCount: Int) -> Bool {
        tabCount > 0
    }

    nonisolated static func workspaceTabInstallsContextMenu(tabCount: Int) -> Bool {
        tabCount > 0
    }

    nonisolated static func workspaceTabFocusIndicatorStyle(tabWidth: CGFloat) -> WorkspaceTabFocusIndicatorStyle {
        guard tabWidth.isFinite, tabWidth > 0 else { return .fullLabel }
        return tabWidth <= Self.workspaceTabCompactFocusIndicatorThreshold ? .iconOnly : .fullLabel
    }

    nonisolated static func workspaceTabReorderTargetIndex(
        orderedTabIDs: [UUID],
        measuredFramesByID: [UUID: CGRect],
        draggedTabID: UUID,
        pointerX: CGFloat
    ) -> Int? {
        guard pointerX.isFinite else { return nil }

        let measuredFrames = orderedTabIDs.compactMap { tabID -> CGRect? in
            guard tabID != draggedTabID else { return nil }
            return measuredFramesByID[tabID]
        }
        guard measuredFrames.count == max(orderedTabIDs.count - 1, 0) else { return nil }
        guard measuredFrames.isEmpty == false else { return 0 }

        for (index, frame) in measuredFrames.enumerated() {
            if pointerX < frame.midX {
                return index
            }
        }
        return measuredFrames.count
    }

    nonisolated static func workspaceTabInsertionIndicatorX(
        orderedTabIDs: [UUID],
        measuredFramesByID: [UUID: CGRect],
        draggedTabID: UUID,
        targetIndex: Int
    ) -> CGFloat? {
        let measuredFrames = orderedTabIDs.compactMap { tabID -> CGRect? in
            guard tabID != draggedTabID else { return nil }
            return measuredFramesByID[tabID]
        }
        guard measuredFrames.count == max(orderedTabIDs.count - 1, 0) else { return nil }
        guard measuredFrames.isEmpty == false else { return nil }
        guard targetIndex >= 0, targetIndex <= measuredFrames.count else { return nil }

        if targetIndex == 0 {
            return measuredFrames[0].minX
        }
        if targetIndex == measuredFrames.count {
            return measuredFrames[measuredFrames.count - 1].maxX
        }
        return measuredFrames[targetIndex].minX
    }

    nonisolated static func panelHeaderTrailingAccessory(
        shortcutLabel: String?,
        isHovered: Bool
    ) -> PanelHeaderTrailingAccessory {
        if isHovered {
            return .closeButton
        }

        guard let shortcutLabel else {
            return .empty
        }
        return .badge(shortcutLabel)
    }

    nonisolated static func browserTitleIconPanelID(for tab: WorkspaceTabState) -> UUID? {
        guard tab.customTitle == nil,
              let panelID = tab.resolvedFocusedPanelID,
              case .web(let webState)? = tab.panels[panelID],
              webState.definition == .browser else {
            return nil
        }

        return panelID
    }

    nonisolated static func workspaceTabMinimumTotalWidth(
        tabCount: Int,
        spacing: CGFloat = 0,
        trailingAccessoryWidth: CGFloat = 0,
        trailingAccessorySpacing: CGFloat = 0
    ) -> CGFloat {
        workspaceTabTotalWidth(
            tabCount: tabCount,
            tabWidth: ToastyTheme.workspaceTabMinimumWidth,
            spacing: spacing
        ) + workspaceTabTrailingAccessoryTotalWidth(
            tabCount: tabCount,
            accessoryWidth: trailingAccessoryWidth,
            accessorySpacing: trailingAccessorySpacing
        )
    }

    nonisolated static func workspaceTabIdealTotalWidth(
        tabCount: Int,
        spacing: CGFloat = 0,
        trailingAccessoryWidth: CGFloat = 0,
        trailingAccessorySpacing: CGFloat = 0
    ) -> CGFloat {
        workspaceTabTotalWidth(
            tabCount: tabCount,
            tabWidth: ToastyTheme.workspaceTabWidth,
            spacing: spacing
        ) + workspaceTabTrailingAccessoryTotalWidth(
            tabCount: tabCount,
            accessoryWidth: trailingAccessoryWidth,
            accessorySpacing: trailingAccessorySpacing
        )
    }

    nonisolated static func resolvedWorkspaceTabWidth(
        availableWidth: CGFloat,
        tabCount: Int,
        spacing: CGFloat = 0,
        trailingAccessoryWidth: CGFloat = 0,
        trailingAccessorySpacing: CGFloat = 0
    ) -> CGFloat {
        guard tabCount > 0 else { return ToastyTheme.workspaceTabWidth }

        let spacingWidth = CGFloat(max(tabCount - 1, 0)) * spacing
        let accessoryWidth = workspaceTabTrailingAccessoryTotalWidth(
            tabCount: tabCount,
            accessoryWidth: trailingAccessoryWidth,
            accessorySpacing: trailingAccessorySpacing
        )
        let availableTabWidth = max(0, availableWidth - spacingWidth - accessoryWidth)
        let fittedWidth = floor(availableTabWidth / CGFloat(tabCount))
        return min(
            ToastyTheme.workspaceTabWidth,
            max(ToastyTheme.workspaceTabMinimumWidth, fittedWidth)
        )
    }

    nonisolated private static func workspaceTabTotalWidth(
        tabCount: Int,
        tabWidth: CGFloat,
        spacing: CGFloat
    ) -> CGFloat {
        guard tabCount > 0 else { return 0 }
        return CGFloat(tabCount) * tabWidth + CGFloat(max(tabCount - 1, 0)) * spacing
    }

    nonisolated private static func workspaceTabTrailingAccessoryTotalWidth(
        tabCount: Int,
        accessoryWidth: CGFloat,
        accessorySpacing: CGFloat
    ) -> CGFloat {
        guard accessoryWidth > 0 else { return 0 }
        guard tabCount > 0 else { return accessoryWidth }
        return accessorySpacing + accessoryWidth
    }

    nonisolated static func workspaceTabChromeSpec(
        isSelected: Bool,
        isHovered: Bool,
        isRenaming: Bool,
        appIsActive: Bool
    ) -> WorkspaceTabChromeSpec {
        if isRenaming {
            if isSelected {
                return WorkspaceTabChromeSpec(
                    background: ToastyTheme.workspaceTabSelectedBackground,
                    text: ToastyTheme.primaryText,
                    accentColor: ToastyTheme.workspaceTabSelectedAccentColor(appIsActive: appIsActive),
                    borderColor: nil
                )
            }

            return WorkspaceTabChromeSpec(
                background: ToastyTheme.workspaceTabHoverBackground,
                text: ToastyTheme.primaryText,
                accentColor: nil,
                borderColor: ToastyTheme.subtleBorder
            )
        }

        if isSelected {
            return WorkspaceTabChromeSpec(
                background: ToastyTheme.workspaceTabSelectedBackground,
                text: ToastyTheme.primaryText,
                accentColor: ToastyTheme.workspaceTabSelectedAccentColor(appIsActive: appIsActive),
                borderColor: nil
            )
        }

        if isHovered {
            return WorkspaceTabChromeSpec(
                background: ToastyTheme.workspaceTabHoverBackground,
                text: ToastyTheme.workspaceTabHoverText,
                accentColor: nil,
                borderColor: ToastyTheme.subtleBorder
            )
        }

        return WorkspaceTabChromeSpec(
            // Keep unselected tabs visually matching the chrome while still
            // painting opaque pixels so overlapped borders can be occluded.
            background: ToastyTheme.chromeBackground,
            text: ToastyTheme.workspaceTabUnselectedText,
            accentColor: nil,
            borderColor: ToastyTheme.subtleBorder
        )
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

            if let window = store.window(id: windowID) {
                workspaceStack(for: window)
            } else {
                EmptyStateView(onCreateWorkspace: createWorkspaceAction)
            }
        }
        .background(ToastyTheme.surfaceBackground)
        .alert(
            "Close this tab?",
            isPresented: pendingWorkspaceTabCloseBinding,
            presenting: pendingWorkspaceTabClose
        ) { closeTarget in
            if closeTarget.assessment.allowsDestructiveConfirmation {
                Button("Cancel", role: .cancel) {
                    pendingWorkspaceTabClose = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Close Tab") {
                    confirmWorkspaceTabClose(closeTarget)
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("OK") {
                    pendingWorkspaceTabClose = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        } message: { closeTarget in
            Text(closeTarget.assessment.confirmationMessage)
        }
        .onAppear {
            appIsActive = NSApplication.shared.isActive
            scheduleFocusedUnreadPanelClearIfNeeded()
            handlePendingPanelFlashRequest()
            handlePendingBrowserLocationFocusRequest()
        }
        .onChange(of: selectedWorkspaceUnreadSignature) { _, _ in
            scheduleFocusedUnreadPanelClearIfNeeded()
        }
        .onChange(of: store.state.workspacesByID) { _, _ in
            pruneTransientTabRenameState()
            pruneTransientTabDragState()
            prunePendingWorkspaceTabCloseState()
            pruneTransientPanelFlashState()
            pruneTransientUnfocusHighlightState()
        }
        .onChange(of: store.pendingRenameWorkspaceTabRequest) { _, _ in
            consumePendingWorkspaceTabRenameRequestIfNeeded()
        }
        .onChange(of: store.pendingPanelFlashRequest) { _, _ in
            handlePendingPanelFlashRequest()
        }
        .onChange(of: store.pendingBrowserLocationFocusRequest) { _, _ in
            handlePendingBrowserLocationFocusRequest()
        }
        .onChange(of: selectedWorkspaceFocusModePresentationState) { oldValue, newValue in
            handleFocusModePresentationChange(from: oldValue, to: newValue)
        }
        .onChange(of: selectedWorkspace?.id) { _, _ in
            pruneTransientTabRenameState()
            pruneTransientTabDragState()
            prunePendingWorkspaceTabCloseState()
            pruneTransientPanelFlashState()
            pruneTransientUnfocusHighlightState()
            handlePendingBrowserLocationFocusRequest()
        }
        .onChange(of: selectedWorkspace?.focusedPanelID) { _, _ in
            handlePendingBrowserLocationFocusRequest()
        }
        .onDisappear {
            cancelWorkspaceTabDrag()
            cancelFocusedUnreadClearTask()
            panelFlashClearWorkItem?.cancel()
            panelFlashResetWorkItem?.cancel()
            panelFlashClearWorkItem = nil
            panelFlashResetWorkItem = nil
            clearTransientUnfocusHighlight()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appIsActive = true
            scheduleFocusedUnreadPanelClearIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            appIsActive = false
            cancelWorkspaceTabDrag()
            cancelFocusedUnreadClearTask()
            hoveredTabID = nil
            hoveredTabCloseButtonID = nil
        }
    }

    private var topBar: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(ToastyTheme.hairline)
                .frame(height: 1)

            Group {
                if let workspace = selectedWorkspace {
                    WorkspaceHeaderLayout(
                        tabCount: workspace.tabIDs.count,
                        titleSpacing: Self.workspaceTitleToTabsSpacing,
                        trailingSpacing: Self.workspaceTabsToControlsSpacing,
                        tabSpacing: Self.workspaceTabStripSpacing,
                        tabAccessoryWidth: Self.workspaceNewTabButtonSize,
                        tabAccessorySpacing: Self.workspaceTabAccessorySpacing
                    ) {
                        workspaceTitleLabel
                        workspaceUnreadSummaryLabel(for: workspace)
                        workspaceHeaderTabStrip(for: workspace)
                        topBarTrailingControls
                            .fixedSize(horizontal: true, vertical: true)
                    }
                } else {
                    HStack(alignment: .center, spacing: Self.workspaceTabsToControlsSpacing) {
                        workspaceTitleLabel
                        Spacer(minLength: 0)
                        topBarTrailingControls
                            .fixedSize(horizontal: true, vertical: true)
                    }
                }
            }
            .padding(.leading, sidebarVisible ? 12 : ToastyTheme.topBarLeadingPaddingWithoutSidebar)
            .padding(.trailing, 12)
            .padding(.top, ToastyTheme.topBarContentTopPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: ToastyTheme.topBarHeight)
        .background(ToastyTheme.chromeBackground)
        .accessibilityIdentifier("topbar.container")
    }

    private var workspaceTitleLabel: some View {
        Text(selectedWorkspace?.title ?? "")
            .font(ToastyTheme.fontTitle)
            .foregroundStyle(ToastyTheme.primaryText)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityIdentifier("topbar.workspace.title")
    }

    @ViewBuilder
    private func workspaceUnreadSummaryLabel(for workspace: WorkspaceState) -> some View {
        if let summary = Self.workspaceUnreadSummaryText(unreadPanelCount: workspace.unreadPanelCount) {
            Text(summary)
                .font(ToastyTheme.fontWorkspaceSubtitle)
                .foregroundStyle(ToastyTheme.inactiveWorkspaceSubtitleText)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("topbar.workspace.unreads")
        } else {
            // Preserve the explicit unread-summary layout slot without
            // changing width or height when the label is hidden.
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    private var topBarTrailingControls: some View {
        HStack(spacing: 0) {
            if agentTopBarModel.showsAddAgentsButton {
                topBarFlashTextButton(title: WorkspaceAgentTopBarModel.addAgentsTitle) {
                    showAgentGetStartedFlow()
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

            topBarFlashButton(icon: { highlighted in
                CommandPaletteIconView(color: highlighted ? ToastyTheme.accent : ToastyTheme.inactiveText)
            }) {
                toggleCommandPalette(windowID)
            }
            .help(ToasttyKeyboardShortcuts.commandPalette.helpText("Open Command Palette"))
            .accessibilityLabel("Open Command Palette")
            .accessibilityIdentifier("topbar.command-palette")

            focusedPanelToggle(identifier: "topbar.toggle.focused-panel")

            topBarFlashButton(icon: { highlighted in
                SplitHorizontalIconView(color: highlighted ? ToastyTheme.accent : ToastyTheme.inactiveText)
            }) {
                split(orientation: .horizontal)
            }
            .disabled(isFocusedPanelModeActive)
            .help(ToasttyKeyboardShortcuts.splitHorizontal.helpText("Split Horizontally"))
            .accessibilityIdentifier("workspace.split.horizontal")

            topBarFlashButton(icon: { highlighted in
                SplitVerticalIconView(color: highlighted ? ToastyTheme.accent : ToastyTheme.inactiveText)
            }) {
                split(orientation: .vertical)
            }
            .disabled(isFocusedPanelModeActive)
            .help(ToasttyKeyboardShortcuts.splitVertical.helpText("Split Vertically"))
            .accessibilityIdentifier("workspace.split.vertical")
        }
    }

    private func workspaceHeaderTabStrip(for workspace: WorkspaceState) -> some View {
        let allowsManagementAffordances = Self.workspaceTabManagementAffordancesEnabled(tabCount: workspace.tabIDs.count)
        let installsContextMenu = Self.workspaceTabInstallsContextMenu(tabCount: workspace.tabIDs.count)
        let insertionIndicatorX = activeTabDrag.flatMap { dragState -> CGFloat? in
            guard dragState.targetIndex != dragState.sourceIndex else { return nil }
            return Self.workspaceTabInsertionIndicatorX(
                orderedTabIDs: workspace.tabIDs,
                measuredFramesByID: measuredWorkspaceTabFramesByID,
                draggedTabID: dragState.tabID,
                targetIndex: dragState.targetIndex
            )
        }

        return NonWindowDraggableRegion {
            WorkspaceTabStripLayout(
                spacing: Self.workspaceTabStripSpacing,
                accessorySpacing: Self.workspaceTabAccessorySpacing
            ) {
                ForEach(Array(workspace.orderedTabs.enumerated()), id: \.element.id) { index, tab in
                    let isSelected = workspace.resolvedSelectedTabID == tab.id
                    let isDragged = activeTabDrag?.tabID == tab.id
                    workspaceTabRow(
                        workspaceID: workspace.id,
                        orderedTabIDs: workspace.tabIDs,
                        tab: tab,
                        index: index,
                        isSelected: isSelected,
                        allowsManagementAffordances: allowsManagementAffordances,
                        installsContextMenu: installsContextMenu
                    )
                    .zIndex(
                        isDragged
                            ? Double(workspace.orderedTabs.count + 1)
                            : isSelected ? Double(workspace.orderedTabs.count) : Double(index)
                    )
                }

                newTabButton
            }
            .frame(height: ToastyTheme.workspaceTabHeight, alignment: .bottom)
            .coordinateSpace(name: WorkspaceTabStripCoordinateSpace.name)
            .onPreferenceChange(WorkspaceTabFramePreferenceKey.self) { measuredWorkspaceTabFramesByID = $0 }
            .overlay(alignment: .topLeading) {
                if let insertionIndicatorX {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(ToastyTheme.accent)
                        .frame(width: 2, height: ToastyTheme.workspaceTabHeight - 4)
                        .offset(x: insertionIndicatorX - 1, y: 2)
                        .allowsHitTesting(false)
                }
            }
            .clipped()
            .animation(.easeInOut(duration: 0.18), value: workspace.orderedTabs.map(\.id))
            .accessibilityIdentifier("workspace.tabs.container")
        }
    }

    private var newTabButton: some View {
        Button(action: createTabInSelectedWorkspace) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ToastyTheme.inactiveText)
                .frame(width: Self.workspaceNewTabButtonSize, height: Self.workspaceNewTabButtonSize)
                .background(ToastyTheme.elevatedBackground, in: RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(ToastyTheme.subtleBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(selectedWorkspace == nil)
        .help(ToasttyKeyboardShortcuts.newTab.helpText("New Tab"))
        .accessibilityIdentifier("workspace.tabs.new")
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
            focusedPanelID: tab.focusedPanelID,
            focusModeRootNodeID: tab.focusModeRootNodeID
        )

        GeometryReader { geometry in
            let viewportFrame = LayoutFrame(
                minX: 0,
                minY: 0,
                width: geometry.size.width,
                height: geometry.size.height
            )
            let projection = renderedLayout.projectLayout(
                in: viewportFrame,
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
                        webPanelRuntimeRegistry: webPanelRuntimeRegistry,
                        focusedPanelCommandController: focusedPanelCommandController,
                        terminalRuntimeContext: terminalRuntimeContext,
                        windowFontPoints: store.state.effectiveTerminalFontPoints(for: windowID),
                        windowMarkdownTextScale: store.state.effectiveMarkdownTextScale(for: windowID),
                        appIsActive: appIsActive,
                        unfocusedSplitStyle: ghosttyHostStyleStore.unfocusedSplitStyle,
                        terminalShortcutNumbersByPanelID: terminalShortcutNumbersByPanelID,
                        panelSessionStatusesByPanelID: panelSessionStatusesByPanelID,
                        panelFlashOverlayOpacity: flashingPanelID == placement.panelID ? flashingPanelOverlayOpacity : 0
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
            .overlay(alignment: .topLeading) {
                if isWorkspaceSelected,
                   isTabSelected,
                   tab.focusedPanelModeActive {
                    FocusModeViewportChrome()
                        .allowsHitTesting(false)
                } else if isWorkspaceSelected,
                          isTabSelected,
                          let frame = transientUnfocusHighlightFrame(
                              workspaceID: workspace.id,
                              tabID: tab.id,
                              layoutTree: tab.layoutTree,
                              projection: projection
                          ) {
                    FocusModeViewportChrome(fillOpacity: 0.04)
                        .opacity(transientUnfocusHighlightOpacity)
                        .frame(
                            width: CGFloat(frame.width),
                            height: CGFloat(frame.height)
                        )
                        .offset(
                            x: CGFloat(frame.minX),
                            y: CGFloat(frame.minY)
                        )
                        .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private func focusedPanelToggle(identifier: String) -> some View {
        let isOn = isFocusedPanelModeActive
        styledTopBarButton(active: isOn) {
            guard let workspaceID = selectedWorkspace?.id else { return }
            _ = terminalRuntimeRegistry.toggleFocusedPanelMode(workspaceID: workspaceID)
        } label: {
            HStack(spacing: 5) {
                FocusIconView(color: isOn ? ToastyTheme.focusModeAccent : ToastyTheme.inactiveText)
                if let title = Self.focusedPanelToggleTitle(isActive: isOn) {
                    Text(title)
                        .font(ToastyTheme.fontSubtext)
                        .foregroundStyle(ToastyTheme.focusModeAccent)
                }
            }
        }
        .help(
            ToasttyKeyboardShortcuts.toggleFocusedPanel.helpText(
                isOn ? "Unfocus Panel" : "Focus Panel"
            )
        )
        .accessibilityLabel(isOn ? "Unfocus Panel" : "Focus Panel")
        .accessibilityIdentifier(identifier)
    }

    static func focusedPanelToggleTitle(isActive: Bool) -> String? {
        isActive ? "Unfocus" : nil
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

    private var selectedWorkspaceFocusModePresentationState: FocusModePresentationState? {
        guard let workspace = selectedWorkspace,
              let tab = workspace.selectedTab else {
            return nil
        }

        let effectiveRootNodeID: UUID? = if tab.focusedPanelModeActive {
            WorkspaceSplitTree(root: tab.layoutTree).effectiveFocusModeRootNodeID(
                preferredRootNodeID: tab.focusModeRootNodeID,
                focusedPanelID: tab.focusedPanelID
            )
        } else {
            nil
        }

        return FocusModePresentationState(
            workspaceID: workspace.id,
            tabID: tab.id,
            focusedPanelModeActive: tab.focusedPanelModeActive,
            effectiveRootNodeID: effectiveRootNodeID
        )
    }

    private func scheduleFocusedUnreadPanelClearIfNeeded() {
        cancelFocusedUnreadClearTask()

        guard let clearCandidate = Self.focusedUnreadClearCandidate(
            workspace: selectedWorkspace,
            appIsActive: NSApplication.shared.isActive
        ) else {
            return
        }

        focusedUnreadClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.focusedUnreadClearDelayNanoseconds)
            guard Task.isCancelled == false else { return }
            guard Self.shouldClearFocusedUnread(
                currentWorkspace: store.selectedWorkspace(in: windowID),
                candidate: clearCandidate,
                appIsActive: NSApplication.shared.isActive
            ) else {
                return
            }
            _ = store.send(
                .markPanelNotificationsRead(
                    workspaceID: clearCandidate.workspaceID,
                    panelID: clearCandidate.panelID
                )
            )
        }
    }

    private func cancelFocusedUnreadClearTask() {
        focusedUnreadClearTask?.cancel()
        focusedUnreadClearTask = nil
    }

    @MainActor
    private func handlePendingPanelFlashRequest() {
        guard let request = store.pendingPanelFlashRequest,
              request.windowID == windowID,
              lastHandledPanelFlashRequestID != request.requestID else {
            return
        }

        lastHandledPanelFlashRequestID = request.requestID
        DispatchQueue.main.async {
            guard let request = store.consumePendingPanelFlashRequest(
                windowID: windowID,
                requestID: request.requestID
            ) else {
                return
            }
            flashPanel(request.panelID, requestID: request.requestID)
        }
    }

    @MainActor
    private func handlePendingBrowserLocationFocusRequest() {
        guard let request = store.pendingBrowserLocationFocusRequest,
              request.windowID == windowID,
              let workspace = selectedWorkspace,
              workspace.id == request.workspaceID,
              workspace.focusedPanelID == request.panelID,
              case .web(let webState)? = workspace.panelState(for: request.panelID),
              webState.definition == .browser else {
            return
        }

        guard let consumedRequest = store.consumePendingBrowserLocationFocusRequest(windowID: windowID) else {
            return
        }

        webPanelRuntimeRegistry
            .browserRuntime(for: consumedRequest.panelID)
            .requestLocationFieldFocus()
    }

    @MainActor
    private func flashPanel(_ panelID: UUID, requestID: UUID) {
        activePanelFlashRequestID = requestID
        panelFlashClearWorkItem?.cancel()
        panelFlashResetWorkItem?.cancel()
        panelFlashClearWorkItem = nil
        panelFlashResetWorkItem = nil
        flashingPanelID = panelID
        flashingPanelOverlayOpacity = 0

        withAnimation(.easeOut(duration: 0.08)) {
            flashingPanelOverlayOpacity = 1
        }

        let clearWorkItem = DispatchWorkItem { [requestID] in
            guard activePanelFlashRequestID == requestID else { return }
            panelFlashClearWorkItem = nil
            withAnimation(.easeOut(duration: Self.panelFlashSettleDuration)) {
                flashingPanelOverlayOpacity = 0
            }
        }
        panelFlashClearWorkItem = clearWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.panelFlashPeakDuration,
            execute: clearWorkItem
        )

        let resetWorkItem = DispatchWorkItem { [requestID] in
            guard activePanelFlashRequestID == requestID else { return }
            activePanelFlashRequestID = nil
            flashingPanelID = nil
            flashingPanelOverlayOpacity = 0
            panelFlashResetWorkItem = nil
        }
        panelFlashResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.panelFlashPeakDuration + Self.panelFlashSettleDuration,
            execute: resetWorkItem
        )
    }

    private func pruneTransientPanelFlashState() {
        guard let flashingPanelID else { return }
        if store.state.workspaceSelection(containingPanelID: flashingPanelID)?.windowID == windowID {
            return
        }

        activePanelFlashRequestID = nil
        self.flashingPanelID = nil
        flashingPanelOverlayOpacity = 0
        panelFlashClearWorkItem?.cancel()
        panelFlashResetWorkItem?.cancel()
        panelFlashClearWorkItem = nil
        panelFlashResetWorkItem = nil
    }

    private func handleFocusModePresentationChange(
        from previous: FocusModePresentationState?,
        to current: FocusModePresentationState?
    ) {
        guard let request = Self.transientUnfocusHighlightRequest(from: previous, to: current) else {
            if Self.shouldClearTransientUnfocusHighlight(from: previous, to: current) {
                clearTransientUnfocusHighlight()
            }
            return
        }

        showTransientUnfocusHighlight(request)
    }

    private func showTransientUnfocusHighlight(_ request: TransientUnfocusHighlightRequest) {
        transientUnfocusHighlightFadeWorkItem?.cancel()
        transientUnfocusHighlightResetWorkItem?.cancel()
        transientUnfocusHighlightFadeWorkItem = nil
        transientUnfocusHighlightResetWorkItem = nil

        // Leave one brief visual breadcrumb after unfocus so the restored subtree
        // is easy to locate in the full layout.
        transientUnfocusHighlight = request
        transientUnfocusHighlightOpacity = 1

        let fadeWorkItem = DispatchWorkItem {
            transientUnfocusHighlightFadeWorkItem = nil
            withAnimation(.easeOut(duration: Self.transientUnfocusHighlightFadeDuration)) {
                transientUnfocusHighlightOpacity = 0
            }
        }
        transientUnfocusHighlightFadeWorkItem = fadeWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.transientUnfocusHighlightHoldDuration,
            execute: fadeWorkItem
        )

        let resetWorkItem = DispatchWorkItem {
            transientUnfocusHighlightResetWorkItem = nil
            transientUnfocusHighlight = nil
            transientUnfocusHighlightOpacity = 0
        }
        transientUnfocusHighlightResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.transientUnfocusHighlightHoldDuration + Self.transientUnfocusHighlightFadeDuration,
            execute: resetWorkItem
        )
    }

    private func clearTransientUnfocusHighlight() {
        transientUnfocusHighlight = nil
        transientUnfocusHighlightOpacity = 0
        transientUnfocusHighlightFadeWorkItem?.cancel()
        transientUnfocusHighlightResetWorkItem?.cancel()
        transientUnfocusHighlightFadeWorkItem = nil
        transientUnfocusHighlightResetWorkItem = nil
    }

    private func pruneTransientUnfocusHighlightState() {
        guard let transientUnfocusHighlight else { return }
        guard let workspace = selectedWorkspace,
              workspace.id == transientUnfocusHighlight.workspaceID,
              let tab = workspace.tab(id: transientUnfocusHighlight.tabID),
              tab.layoutTree.findSubtree(nodeID: transientUnfocusHighlight.rootNodeID) != nil else {
            clearTransientUnfocusHighlight()
            return
        }
    }

    private func transientUnfocusHighlightFrame(
        workspaceID: UUID,
        tabID: UUID,
        layoutTree: LayoutNode,
        projection: LayoutProjection
    ) -> LayoutFrame? {
        guard let transientUnfocusHighlight,
              transientUnfocusHighlight.workspaceID == workspaceID,
              transientUnfocusHighlight.tabID == tabID else {
            return nil
        }

        return Self.focusModeHighlightFrame(
            rootNodeID: transientUnfocusHighlight.rootNodeID,
            layoutTree: layoutTree,
            projection: projection
        )
    }

    nonisolated static func transientUnfocusHighlightRequest(
        from previous: FocusModePresentationState?,
        to current: FocusModePresentationState?
    ) -> TransientUnfocusHighlightRequest? {
        guard let previous,
              previous.focusedPanelModeActive,
              let rootNodeID = previous.effectiveRootNodeID,
              let current,
              current.focusedPanelModeActive == false,
              previous.workspaceID == current.workspaceID,
              previous.tabID == current.tabID else {
            return nil
        }

        return TransientUnfocusHighlightRequest(
            workspaceID: previous.workspaceID,
            tabID: previous.tabID,
            rootNodeID: rootNodeID
        )
    }

    nonisolated static func shouldClearTransientUnfocusHighlight(
        from previous: FocusModePresentationState?,
        to current: FocusModePresentationState?
    ) -> Bool {
        if current?.focusedPanelModeActive == true {
            return true
        }

        return previous?.workspaceID != current?.workspaceID || previous?.tabID != current?.tabID
    }

    nonisolated static func focusModeHighlightFrame(
        rootNodeID: UUID,
        layoutTree: LayoutNode,
        projection: LayoutProjection
    ) -> LayoutFrame? {
        guard let subtree = layoutTree.findSubtree(nodeID: rootNodeID) else {
            return nil
        }

        let slotIDs = Set(subtree.allSlotInfos.map(\.slotID))
        guard let firstFrame = projection.slots.first(where: { slotIDs.contains($0.slotID) })?.frame else {
            return nil
        }

        return projection.slots.reduce(firstFrame) { partialFrame, slot in
            guard slotIDs.contains(slot.slotID) else {
                return partialFrame
            }
            return union(partialFrame, slot.frame)
        }
    }

    nonisolated private static func union(_ lhs: LayoutFrame, _ rhs: LayoutFrame) -> LayoutFrame {
        let minX = min(lhs.minX, rhs.minX)
        let minY = min(lhs.minY, rhs.minY)
        let maxX = max(lhs.maxX, rhs.maxX)
        let maxY = max(lhs.maxY, rhs.maxY)
        return LayoutFrame(
            minX: minX,
            minY: minY,
            width: maxX - minX,
            height: maxY - minY
        )
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

    @ViewBuilder
    private func workspaceTabRow(
        workspaceID: UUID,
        orderedTabIDs: [UUID],
        tab: WorkspaceTabState,
        index: Int,
        isSelected: Bool,
        allowsManagementAffordances: Bool,
        installsContextMenu: Bool
    ) -> some View {
        let hasUnread = tab.unreadPanelIDs.isEmpty == false
        let isAnyTabDragActive = activeTabDrag != nil
        let isDraggedTab = activeTabDrag?.tabID == tab.id
        let isRenaming = renamingTabID == tab.id
        let isHovered = appIsActive && isRenaming == false && isAnyTabDragActive == false && hoveredTabID == tab.id
        let showsManagementAffordances = allowsManagementAffordances && isAnyTabDragActive == false
        let chromeSpec = Self.workspaceTabChromeSpec(
            isSelected: isSelected,
            isHovered: isHovered,
            isRenaming: isRenaming,
            appIsActive: appIsActive
        )

        let row = ZStack(alignment: .trailing) {
            if isRenaming {
                workspaceTabRenameRow(
                    workspaceID: workspaceID,
                    tab: tab,
                    chromeSpec: chromeSpec,
                    hasUnread: hasUnread
                )
            } else {
                workspaceTabChrome(chromeSpec: chromeSpec) {
                    GeometryReader { geometry in
                        let focusIndicatorStyle = Self.workspaceTabFocusIndicatorStyle(
                            tabWidth: geometry.size.width
                        )
                        HStack(spacing: 5) {
                            workspaceTabTitleContent(
                                tab: tab,
                                textColor: chromeSpec.text,
                                hasUnread: hasUnread,
                                focusIndicatorStyle: focusIndicatorStyle
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)

                            workspaceTabTrailingContent(
                                index: index,
                                isSelected: isSelected,
                                isHovered: isHovered,
                                showsCloseAffordance: showsManagementAffordances
                            )
                            .frame(width: ToastyTheme.workspaceTabTrailingSlotWidth, alignment: .trailing)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }
                .contentShape(Rectangle())
                .overlay {
                    PointerInteractionRegion(
                        name: "workspace-tab",
                        metadata: [
                            "workspaceID": workspaceID.uuidString,
                            "tabID": tab.id.uuidString,
                            "sourceIndex": "\(index)",
                        ],
                        onBegan: { _ in
                            beginWorkspaceTabInteraction(tabID: tab.id)
                        },
                        onChanged: { value in
                            updateWorkspaceTabDrag(
                                workspaceID: workspaceID,
                                orderedTabIDs: orderedTabIDs,
                                tabID: tab.id,
                                sourceIndex: index,
                                value: value
                            )
                        },
                        onEnded: { value in
                            finishWorkspaceTabInteraction(
                                workspaceID: workspaceID,
                                tabID: tab.id,
                                value: value
                            )
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(tab.displayTitle)
                .accessibilityAction {
                    selectWorkspaceTab(workspaceID: workspaceID, tabID: tab.id)
                }
                .help(tab.displayTitle)
                .accessibilityIdentifier("workspace.tab.\(tab.id.uuidString)")
                .animation(.easeOut(duration: 0.1), value: isHovered)
            }

            if isHovered && showsManagementAffordances {
                workspaceTabCloseButton(workspaceID: workspaceID, tab: tab)
                    .padding(.trailing, 10)
            }
        }
        .contentShape(Rectangle())
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

        let measuredRow = row
            .background(workspaceTabFrameMeasurement(tabID: tab.id))
            .offset(x: isDraggedTab ? activeTabDrag?.translationWidth ?? 0 : 0)
            .shadow(
                color: isDraggedTab ? ToastyTheme.accent.opacity(0.18) : .clear,
                radius: isDraggedTab ? 8 : 0,
                y: isDraggedTab ? 3 : 0
            )

        let interactiveRow = measuredRow

        if installsContextMenu {
            interactiveRow.contextMenu {
                if isAnyTabDragActive == false {
                    workspaceTabContextMenu(workspaceID: workspaceID, tab: tab)
                }
            }
        } else {
            interactiveRow
        }
    }

    @ViewBuilder
    private func workspaceTabTitleContent(
        tab: WorkspaceTabState,
        textColor: Color,
        hasUnread: Bool,
        focusIndicatorStyle: WorkspaceTabFocusIndicatorStyle
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

            if let browserPanelID = Self.browserTitleIconPanelID(for: tab) {
                BrowserTitleIconView(
                    image: webPanelRuntimeRegistry.browserRuntime(for: browserPanelID).faviconImage,
                    fallbackSymbolName: "globe",
                    tintColor: textColor,
                    size: 12
                )
            }

            Text(tab.displayTitle)
                .font(ToastyTheme.fontWorkspaceTab)
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.tail)

            if tab.focusedPanelModeActive {
                workspaceTabFocusIndicator(style: focusIndicatorStyle)
            }
        }
    }

    @ViewBuilder
    private func workspaceTabFocusIndicator(style: WorkspaceTabFocusIndicatorStyle) -> some View {
        switch style {
        case .fullLabel:
            Text("Focused")
                .font(ToastyTheme.fontWorkspaceSessionChip)
                .foregroundStyle(ToastyTheme.focusModeAccent)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    ToastyTheme.focusModeAccent.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 4)
                )
                .fixedSize(horizontal: true, vertical: true)
        case .iconOnly:
            FocusIconView(color: ToastyTheme.focusModeAccent)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    ToastyTheme.focusModeAccent.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 4)
                )
                .fixedSize(horizontal: true, vertical: true)
        }
    }

    private func workspaceTabRenameRow(
        workspaceID: UUID,
        tab: WorkspaceTabState,
        chromeSpec: WorkspaceTabChromeSpec,
        hasUnread: Bool
    ) -> some View {
        workspaceTabChrome(chromeSpec: chromeSpec) {
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
        chromeSpec: WorkspaceTabChromeSpec,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: ToastyTheme.workspaceTabHeight, maxHeight: ToastyTheme.workspaceTabHeight)
            .background(
                chromeSpec.background,
                in: WorkspaceTabShape()
            )
            .overlay(alignment: .top) {
                if let accentColor = chromeSpec.accentColor {
                    Rectangle()
                        .fill(accentColor)
                        .frame(height: ToastyTheme.workspaceTabAccentLineHeight)
                        .clipShape(WorkspaceTabShape())
                }
            }
            .overlay {
                if let borderColor = chromeSpec.borderColor {
                    WorkspaceTabShape()
                        .stroke(borderColor, lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func workspaceTabTrailingContent(
        index: Int,
        isSelected: Bool,
        isHovered: Bool,
        showsCloseAffordance: Bool
    ) -> some View {
        switch Self.workspaceTabTrailingAccessory(
            index: index,
            isHovered: isHovered,
            showsCloseAffordance: showsCloseAffordance
        ) {
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
        guard let workspace = store.state.workspacesByID[workspaceID],
              let tab = workspace.tab(id: tabID) else {
            pendingWorkspaceTabClose = nil
            return
        }

        let closeAssessment = WorkspaceTabCloseConfirmation.assess(
            tab: tab,
            shouldBypassConfirmation: shouldBypassInteractiveConfirmation
        ) { panelID in
            terminalRuntimeRegistry.terminalCloseConfirmationAssessment(panelID: panelID)
        } localDocumentCloseConfirmationState: { panelID in
            webPanelRuntimeRegistry.localDocumentCloseConfirmationState(panelID: panelID)
        }

        guard closeAssessment.requiresConfirmation else {
            pendingWorkspaceTabClose = nil
            _ = store.send(.closeWorkspaceTab(workspaceID: workspaceID, tabID: tabID))
            return
        }

        pendingWorkspaceTabClose = PendingWorkspaceTabClose(
            workspaceID: workspaceID,
            tabID: tabID,
            assessment: closeAssessment
        )
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
              workspace.tabsByID[renamingTabID] != nil else {
            cancelTabRename()
            return
        }
    }

    private func prunePendingWorkspaceTabCloseState() {
        guard let pendingWorkspaceTabClose else { return }
        guard let workspace = store.state.workspacesByID[pendingWorkspaceTabClose.workspaceID],
              workspace.tab(id: pendingWorkspaceTabClose.tabID) != nil else {
            self.pendingWorkspaceTabClose = nil
            return
        }
    }

    private var pendingWorkspaceTabCloseBinding: Binding<Bool> {
        Binding(
            get: { pendingWorkspaceTabClose != nil },
            set: { isPresented in
                if !isPresented {
                    pendingWorkspaceTabClose = nil
                }
            }
        )
    }

    private var shouldBypassInteractiveConfirmation: Bool {
        let processInfo = ProcessInfo.processInfo
        return AutomationConfig.shouldBypassInteractiveConfirmation(
            arguments: processInfo.arguments,
            environment: processInfo.environment
        )
    }

    private func confirmWorkspaceTabClose(_ closeTarget: PendingWorkspaceTabClose) {
        pendingWorkspaceTabClose = nil
        _ = store.send(.closeWorkspaceTab(workspaceID: closeTarget.workspaceID, tabID: closeTarget.tabID))
    }

    private func clearTabHoverState(for tabID: UUID) {
        if hoveredTabID == tabID {
            hoveredTabID = nil
        }
        if hoveredTabCloseButtonID == tabID {
            hoveredTabCloseButtonID = nil
        }
    }

    private func workspaceTabFrameMeasurement(tabID: UUID) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: WorkspaceTabFramePreferenceKey.self,
                value: [
                    tabID: geometry.frame(in: .named(WorkspaceTabStripCoordinateSpace.name))
                ]
            )
        }
    }

    nonisolated static func workspaceTabDragActivationExceeded(translation: CGSize) -> Bool {
        abs(translation.width) >= workspaceTabDragActivationDistance
    }

    nonisolated static func pointerMovementWithinTapTolerance(translation: CGSize) -> Bool {
        let distanceSquared = (translation.width * translation.width) + (translation.height * translation.height)
        return distanceSquared < (workspaceTabDragActivationDistance * workspaceTabDragActivationDistance)
    }

    private func updateWorkspaceTabDrag(
        workspaceID: UUID,
        orderedTabIDs: [UUID],
        tabID: UUID,
        sourceIndex: Int,
        value: PointerInteractionValue
    ) {
        let baseMetadata = workspaceTabDragLogMetadata(
            workspaceID: workspaceID,
            tabID: tabID,
            sourceIndex: sourceIndex,
            value: value
        )
        if renamingTabID != nil {
            ToasttyLog.info(
                "workspace tab drag ignored",
                category: .input,
                metadata: baseMetadata.merging(["reason": "renaming-tab"], uniquingKeysWith: { _, new in new })
            )
            return
        }
        if workspaceID != selectedWorkspace?.id {
            ToasttyLog.info(
                "workspace tab drag ignored",
                category: .input,
                metadata: baseMetadata.merging(["reason": "inactive-workspace"], uniquingKeysWith: { _, new in new })
            )
            return
        }
        guard Self.workspaceTabDragActivationExceeded(translation: value.translation) else {
            ToasttyLog.info(
                "workspace tab drag below activation threshold",
                category: .input,
                metadata: baseMetadata
            )
            return
        }

        clearTabHoverState(for: tabID)

        var dragState = activeTabDrag
        if dragState?.tabID != tabID {
            let startPointerX = (measuredWorkspaceTabFramesByID[tabID]?.minX ?? 0) + value.startLocation.x
            dragState = WorkspaceTabDragState(
                tabID: tabID,
                sourceIndex: sourceIndex,
                startPointerX: startPointerX,
                translationWidth: value.translation.width,
                targetIndex: sourceIndex
            )
            ToasttyLog.info(
                "workspace tab drag activated",
                category: .input,
                metadata: baseMetadata.merging(
                    [
                        "startPointerX": "\(startPointerX)",
                        "orderedTabCount": "\(orderedTabIDs.count)",
                    ],
                    uniquingKeysWith: { _, new in new }
                )
            )
        } else {
            dragState?.translationWidth = value.translation.width
        }

        let pointerX = (dragState?.startPointerX ?? value.location.x) + value.translation.width
        let targetIndex = Self.workspaceTabReorderTargetIndex(
            orderedTabIDs: orderedTabIDs,
            measuredFramesByID: measuredWorkspaceTabFramesByID,
            draggedTabID: tabID,
            pointerX: pointerX
        ) ?? sourceIndex
        let previousTargetIndex = dragState?.targetIndex
        dragState?.targetIndex = targetIndex
        activeTabDrag = dragState
        if previousTargetIndex != targetIndex {
            ToasttyLog.info(
                "workspace tab drag target changed",
                category: .input,
                metadata: baseMetadata.merging(
                    [
                        "pointerX": "\(pointerX)",
                        "targetIndex": "\(targetIndex)",
                        "previousTargetIndex": previousTargetIndex.map(String.init) ?? "nil",
                    ],
                    uniquingKeysWith: { _, new in new }
                )
            )
        }
    }

    private func finishWorkspaceTabInteraction(
        workspaceID: UUID,
        tabID: UUID,
        value: PointerInteractionValue
    ) {
        if activeTabDrag?.tabID == tabID {
            ToasttyLog.info(
                "workspace tab drag finishing",
                category: .input,
                metadata: workspaceTabDragLogMetadata(workspaceID: workspaceID, tabID: tabID, sourceIndex: nil, value: value)
            )
            finishWorkspaceTabDrag(workspaceID: workspaceID)
            return
        }

        guard activeTabDrag == nil else { return }
        guard Self.pointerMovementWithinTapTolerance(translation: value.translation) else { return }
        ToasttyLog.info(
            "workspace tab pointer ended as tap",
            category: .input,
            metadata: workspaceTabDragLogMetadata(workspaceID: workspaceID, tabID: tabID, sourceIndex: nil, value: value)
        )
        selectWorkspaceTab(workspaceID: workspaceID, tabID: tabID)
    }

    private func finishWorkspaceTabDrag(workspaceID: UUID) {
        guard let activeTabDrag else { return }
        cancelWorkspaceTabDrag()

        guard activeTabDrag.targetIndex != activeTabDrag.sourceIndex else {
            ToasttyLog.info(
                "workspace tab drag finished without reorder",
                category: .input,
                metadata: [
                    "workspaceID": workspaceID.uuidString,
                    "tabID": activeTabDrag.tabID.uuidString,
                    "sourceIndex": "\(activeTabDrag.sourceIndex)",
                    "targetIndex": "\(activeTabDrag.targetIndex)",
                    "translationWidth": "\(activeTabDrag.translationWidth)",
                ]
            )
            return
        }
        ToasttyLog.info(
            "workspace tab drag committing reorder",
            category: .input,
            metadata: [
                "workspaceID": workspaceID.uuidString,
                "tabID": activeTabDrag.tabID.uuidString,
                "sourceIndex": "\(activeTabDrag.sourceIndex)",
                "targetIndex": "\(activeTabDrag.targetIndex)",
                "translationWidth": "\(activeTabDrag.translationWidth)",
            ]
        )
        _ = store.send(
            .moveWorkspaceTab(
                workspaceID: workspaceID,
                fromIndex: activeTabDrag.sourceIndex,
                toIndex: activeTabDrag.targetIndex
            )
        )
    }

    private func selectWorkspaceTab(workspaceID: UUID, tabID: UUID) {
        if renamingTabID != nil {
            cancelTabRename()
        }
        _ = store.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: tabID))
    }

    private func beginWorkspaceTabInteraction(tabID: UUID) {
        guard let activeTabDrag else { return }
        ToasttyLog.info(
            "workspace tab stale drag cancelled on new pointer sequence",
            category: .input,
            metadata: [
                "newTabID": tabID.uuidString,
                "activeTabID": activeTabDrag.tabID.uuidString,
                "sourceIndex": "\(activeTabDrag.sourceIndex)",
                "targetIndex": "\(activeTabDrag.targetIndex)",
                "translationWidth": "\(activeTabDrag.translationWidth)",
            ]
        )
        cancelWorkspaceTabDrag()
    }

    private func cancelWorkspaceTabDrag() {
        activeTabDrag = nil
    }

    private func workspaceTabDragLogMetadata(
        workspaceID: UUID,
        tabID: UUID,
        sourceIndex: Int?,
        value: PointerInteractionValue
    ) -> [String: String] {
        var metadata: [String: String] = [
            "workspaceID": workspaceID.uuidString,
            "tabID": tabID.uuidString,
            "startLocation": DraggableInteractionLog.pointDescription(value.startLocation),
            "location": DraggableInteractionLog.pointDescription(value.location),
            "translation": DraggableInteractionLog.sizeDescription(value.translation),
        ]
        if let sourceIndex {
            metadata["sourceIndex"] = "\(sourceIndex)"
        }
        if let activeTabDrag {
            metadata["activeTabID"] = activeTabDrag.tabID.uuidString
            metadata["activeSourceIndex"] = "\(activeTabDrag.sourceIndex)"
            metadata["activeTargetIndex"] = "\(activeTabDrag.targetIndex)"
            metadata["activeTranslationWidth"] = "\(activeTabDrag.translationWidth)"
        }
        if let measuredFrame = measuredWorkspaceTabFramesByID[tabID] {
            metadata["measuredFrame"] = DraggableInteractionLog.rectDescription(measuredFrame)
        }
        return metadata
    }

    private func pruneTransientTabDragState() {
        guard let workspace = selectedWorkspace else {
            measuredWorkspaceTabFramesByID = [:]
            cancelWorkspaceTabDrag()
            return
        }

        measuredWorkspaceTabFramesByID = measuredWorkspaceTabFramesByID.filter { workspace.tabsByID[$0.key] != nil }
        if let activeTabDrag,
           workspace.tabsByID[activeTabDrag.tabID] == nil {
            cancelWorkspaceTabDrag()
        }
    }

    private func consumePendingWorkspaceTabRenameRequestIfNeeded() {
        guard let request = store.consumePendingWorkspaceTabRenameRequest(windowID: windowID),
              let workspace = selectedWorkspace,
              workspace.id == request.workspaceID,
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

    private func styledTopBarButton<Label: View>(
        active: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            TopBarButtonChrome(highlighted: active) {
                label()
            }
        }
        .buttonStyle(.plain)
    }

    /// Top bar button for momentary actions (e.g. split). Briefly flashes the "active"
    /// styling (accent icon, light text, elevated background) while pressed, then fades back.
    /// This intentionally bypasses `styledTopBarButton` and uses `TopBarFlashButtonStyle`.
    private func topBarFlashButton<Icon: View>(
        @ViewBuilder icon: @escaping (_ isHighlighted: Bool) -> Icon,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            // Placeholder label — TopBarFlashButtonStyle renders the actual content.
            Color.clear.frame(width: 0, height: 0)
        }
        .buttonStyle(TopBarFlashButtonStyle(icon: icon))
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

private struct BrowserTitleIconView: View {
    let image: NSImage?
    let fallbackSymbolName: String
    let tintColor: Color
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: fallbackSymbolName)
                    .font(.system(size: size - 2, weight: .medium))
                    .foregroundStyle(tintColor.opacity(0.82))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

private struct PendingWorkspaceTabClose: Identifiable {
    let workspaceID: UUID
    let tabID: UUID
    let assessment: WorkspaceTabCloseConfirmationAssessment

    var id: UUID { tabID }
}

private struct FocusModeViewportChrome: View {
    let fillOpacity: Double

    init(fillOpacity: Double = 0.03) {
        self.fillOpacity = fillOpacity
    }

    /// Approximate macOS window corner geometry so the glow hugs the
    /// rounded window frame instead of fighting the system mask.
    private static let windowCornerRadius: CGFloat = 10

    var body: some View {
        let color = ToastyTheme.focusModeAccent
        let shape = RoundedRectangle(cornerRadius: Self.windowCornerRadius, style: .continuous)
        shape
            .fill(color.opacity(fillOpacity))
            .overlay {
                // Soft inner glow — blurred stroke clipped to bounds
                shape
                    .stroke(color.opacity(0.5), lineWidth: 5)
                    .blur(radius: 4)
            }
            .overlay {
                // Crisp thin edge on top of the glow
                shape
                    .strokeBorder(color.opacity(0.6), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

private struct WorkspaceHeaderLayout: Layout {
    // Subview order: title, unread summary slot, tab strip, trailing controls.
    let tabCount: Int
    let titleSpacing: CGFloat
    let trailingSpacing: CGFloat
    let tabSpacing: CGFloat
    let tabAccessoryWidth: CGFloat
    let tabAccessorySpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        guard subviews.count == 4 else {
            assertionFailure("WorkspaceHeaderLayout expected title, unread summary, tabs, and trailing controls")
            return .zero
        }

        let titleSize = subviews[0].sizeThatFits(.unspecified)
        let unreadSummarySize = subviews[1].sizeThatFits(.unspecified)
        let tabsSize = subviews[2].sizeThatFits(
            ProposedViewSize(width: nil, height: ToastyTheme.workspaceTabHeight)
        )
        // Keep the trailing top-bar controls measured inside the visible bar.
        // Plain buttons in the hidden titlebar region can otherwise report a
        // taller hit target than the visible chrome, which leaks active fills
        // above the intended button bounds.
        let trailingSize = subviews[3].sizeThatFits(
            ProposedViewSize(width: nil, height: ToastyTheme.topBarHeight)
        )
        let titleColumnWidth = min(
            WorkspaceView.workspaceHeaderTitleColumnPreferredWidth(
                titleWidth: titleSize.width,
                unreadSummaryWidth: unreadSummarySize.width
            ),
            ToastyTheme.workspaceTitleMaxWidth
        )
        let titleColumnHeight = titleSize.height +
            (unreadSummarySize.height > 0 ? ToastyTheme.topBarUnreadSummaryTopSpacing : 0) +
            unreadSummarySize.height
        let width = if let proposedWidth = proposal.width, proposedWidth.isFinite {
            proposedWidth
        } else {
            titleColumnWidth +
                titleSpacing + tabsSize.width + trailingSpacing + trailingSize.width
        }

        return CGSize(
            width: width,
            height: max(ToastyTheme.topBarHeight, titleColumnHeight, trailingSize.height, ToastyTheme.workspaceTabHeight)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        guard subviews.count == 4 else {
            assertionFailure("WorkspaceHeaderLayout expected title, unread summary, tabs, and trailing controls")
            return
        }

        let titleSize = subviews[0].sizeThatFits(.unspecified)
        let unreadSummarySize = subviews[1].sizeThatFits(.unspecified)
        let trailingSize = subviews[3].sizeThatFits(
            ProposedViewSize(width: nil, height: bounds.height)
        )
        let trailingX = max(bounds.minX, bounds.maxX - trailingSize.width)
        let titleColumnPreferredWidth = WorkspaceView.workspaceHeaderTitleColumnPreferredWidth(
            titleWidth: titleSize.width,
            unreadSummaryWidth: unreadSummarySize.width
        )
        let titleColumnWidth = WorkspaceView.resolvedWorkspaceTitleWidth(
            preferredWidth: titleColumnPreferredWidth,
            availableWidth: bounds.width,
            trailingWidth: trailingSize.width,
            tabCount: tabCount,
            titleSpacing: titleSpacing,
            trailingSpacing: trailingSpacing,
            tabSpacing: tabSpacing,
            tabAccessoryWidth: tabAccessoryWidth,
            tabAccessorySpacing: tabAccessorySpacing,
            titleMaxWidth: ToastyTheme.workspaceTitleMaxWidth
        )
        let titleHeight = min(bounds.height, titleSize.height)
        let titleY = bounds.minY + WorkspaceView.workspaceHeaderTitleOriginY(
            boundsHeight: bounds.height,
            titleHeight: titleHeight
        )

        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: titleY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: titleColumnWidth, height: titleHeight)
        )

        let unreadSummaryY = WorkspaceView.workspaceHeaderUnreadSummaryOriginY(
            titleOriginY: titleY,
            titleHeight: titleHeight,
            spacing: ToastyTheme.topBarUnreadSummaryTopSpacing
        )
        let unreadSummaryHeight = min(
            unreadSummarySize.height,
            max(0, bounds.maxY - unreadSummaryY)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: unreadSummaryY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: titleColumnWidth, height: unreadSummaryHeight)
        )

        let tabsX = bounds.minX + titleColumnWidth + titleSpacing
        let tabsMaxX = max(tabsX, trailingX - trailingSpacing)
        let tabsWidth = max(0, tabsMaxX - tabsX)

        subviews[2].place(
            at: CGPoint(x: tabsX, y: bounds.maxY),
            anchor: .bottomLeading,
            proposal: ProposedViewSize(width: tabsWidth, height: ToastyTheme.workspaceTabHeight)
        )

        let trailingHeight = min(bounds.height, trailingSize.height)
        let trailingY = bounds.minY + ((bounds.height - trailingHeight) / 2)

        subviews[3].place(
            at: CGPoint(x: trailingX, y: trailingY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: trailingSize.width, height: trailingHeight)
        )
    }
}

private struct WorkspaceTabStripLayout: Layout {
    let spacing: CGFloat
    let accessorySpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }

        let height = ToastyTheme.workspaceTabHeight
        let tabCount = max(subviews.count - 1, 0)
        let accessoryWidth = subviews.last?.sizeThatFits(.unspecified).width ?? 0
        let idealWidth = WorkspaceView.workspaceTabIdealTotalWidth(
            tabCount: tabCount,
            spacing: spacing,
            trailingAccessoryWidth: accessoryWidth,
            trailingAccessorySpacing: accessorySpacing
        )
        let minimumWidth = WorkspaceView.workspaceTabMinimumTotalWidth(
            tabCount: tabCount,
            spacing: spacing,
            trailingAccessoryWidth: accessoryWidth,
            trailingAccessorySpacing: accessorySpacing
        )

        guard let proposedWidth = proposal.width, proposedWidth.isFinite else {
            return CGSize(width: idealWidth, height: height)
        }

        return CGSize(width: max(proposedWidth, minimumWidth), height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        guard !subviews.isEmpty else { return }

        let tabCount = max(subviews.count - 1, 0)
        let accessorySubview = subviews.last
        let accessorySize = accessorySubview?.sizeThatFits(.unspecified) ?? .zero
        let tabWidth = WorkspaceView.resolvedWorkspaceTabWidth(
            availableWidth: bounds.width,
            tabCount: tabCount,
            spacing: spacing,
            trailingAccessoryWidth: accessorySize.width,
            trailingAccessorySpacing: accessorySpacing
        )
        var nextX = bounds.minX

        for subview in subviews.dropLast() {
            subview.place(
                at: CGPoint(x: nextX, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: tabWidth, height: bounds.height)
            )
            nextX += tabWidth + spacing
        }

        guard let accessorySubview else { return }

        let accessoryX = nextX + (tabCount > 0 ? accessorySpacing : 0)
        let accessoryY = bounds.minY + ((bounds.height - accessorySize.height) / 2)

        accessorySubview.place(
            at: CGPoint(x: accessoryX, y: accessoryY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: accessorySize.width, height: accessorySize.height)
        )
    }
}

private enum WorkspaceTabStripCoordinateSpace {
    static let name = "workspace-tabs.strip"
}

private struct WorkspaceTabFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct WorkspaceAgentTopBarModel: Equatable {
    static let addAgentsTitle = "Get Started…"

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
    @ObservedObject var webPanelRuntimeRegistry: WebPanelRuntimeRegistry
    let focusedPanelCommandController: FocusedPanelCommandController
    let terminalRuntimeContext: TerminalWindowRuntimeContext?
    let windowFontPoints: Double
    let windowMarkdownTextScale: Double
    let appIsActive: Bool
    let unfocusedSplitStyle: GhosttyUnfocusedSplitStyle
    let terminalShortcutNumbersByPanelID: [UUID: Int]
    let panelSessionStatusesByPanelID: [UUID: WorkspaceSessionStatus]
    let panelFlashOverlayOpacity: Double

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
                    shortcutNumber: terminalShortcutNumbersByPanelID[placement.panelID],
                    windowFontPoints: windowFontPoints,
                    windowMarkdownTextScale: windowMarkdownTextScale,
                    appIsActive: appIsActive,
                    unfocusedSplitStyle: unfocusedSplitStyle,
                    panelFlashOverlayOpacity: panelFlashOverlayOpacity,
                    store: store,
                    terminalProfileStore: terminalProfileStore,
                    terminalRuntimeRegistry: terminalRuntimeRegistry,
                    webPanelRuntimeRegistry: webPanelRuntimeRegistry,
                    focusedPanelCommandController: focusedPanelCommandController,
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
    let shortcutNumber: Int?
    let windowFontPoints: Double
    let windowMarkdownTextScale: Double
    let appIsActive: Bool
    let unfocusedSplitStyle: GhosttyUnfocusedSplitStyle
    let panelFlashOverlayOpacity: Double
    @ObservedObject var store: AppStore
    @ObservedObject var terminalProfileStore: TerminalProfileStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
    let webPanelRuntimeRegistry: WebPanelRuntimeRegistry
    let focusedPanelCommandController: FocusedPanelCommandController
    let terminalRuntimeContext: TerminalWindowRuntimeContext?
    @State private var isHovered = false
    @State private var isCloseButtonHovered = false

    private var isFocused: Bool {
        // Only the selected workspace may present a focused terminal host.
        // Hidden-but-mounted workspaces still render for background runtime
        // updates, but they must not retain keyboard focus or route shortcuts.
        isWorkspaceSelected && isTabSelected && focusedPanelID == panelID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader

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
                .overlay {
                    if panelFlashOverlayOpacity > 0 {
                        Rectangle()
                            .fill(ToastyTheme.accent.opacity(0.16 * panelFlashOverlayOpacity))
                            .overlay {
                                Rectangle()
                                    .stroke(
                                        ToastyTheme.accent.opacity(0.9 * panelFlashOverlayOpacity),
                                        lineWidth: 1.5
                                    )
                            }
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

            case .web(let webState):
                webPanelBody(state: webState)
            }
        }
        .background(ToastyTheme.surfaceBackground)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(ToastyTheme.hairline)
                .frame(width: 1)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(ToastyTheme.hairline)
                .frame(width: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ToastyTheme.hairline)
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            store.send(.focusPanel(workspaceID: workspaceID, panelID: panelID))
        }
        .onHover(perform: updateHoverState)
        .onChange(of: appIsActive) { _, nextValue in
            if nextValue == false {
                isHovered = false
                isCloseButtonHovered = false
            }
        }
    }

    private var panelHeader: some View {
        HStack(spacing: 8) {
            if showsTerminalHeaderSearch {
                panelHeaderLeadingItems

                panelHeaderTitle
                    .frame(minWidth: 0, alignment: .leading)

                Spacer(minLength: 0)

                TerminalPanelHeaderSearchBar(
                    terminalRuntimeRegistry: terminalRuntimeRegistry,
                    panelID: panelID,
                    isActivePanel: isFocused
                )
                .layoutPriority(1)

                panelHeaderTrailingContent
            } else if let localDocumentRuntime {
                panelHeaderLeadingItems

                panelHeaderTitle
                    .frame(minWidth: 0, alignment: .leading)

                Spacer(minLength: 0)

                LocalDocumentPanelHeaderSearchRegion(
                    panelID: panelID,
                    runtime: localDocumentRuntime,
                    isActivePanel: isFocused,
                    activatePanel: {
                        _ = store.send(.focusPanel(workspaceID: workspaceID, panelID: panelID))
                    }
                )

                panelHeaderTrailingContent
            } else if shortcutLabel != nil {
                panelHeaderLeadingItems

                panelHeaderTitle
                    .frame(maxWidth: .infinity, alignment: .leading)

                panelHeaderTrailingContent
            } else {
                panelHeaderLeadingItems

                panelHeaderTitle
                    .frame(maxWidth: .infinity, alignment: .leading)

                panelHeaderTrailingContent
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: PanelHeaderSearchLayout.headerHeight,
            maxHeight: PanelHeaderSearchLayout.headerHeight,
            alignment: .leading
        )
        .padding(.horizontal, PanelHeaderSearchLayout.horizontalPadding)
        .background(panelHeaderBackgroundColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(panelHeaderDividerColor)
                .frame(height: panelHeaderDividerHeight)
        }
    }

    @ViewBuilder
    private var panelHeaderLeadingItems: some View {
        let indicatorState = panelHeaderIndicatorState
        if indicatorState != .hidden {
            SessionStatusIndicator(state: indicatorState, size: 8, lineWidth: 1.4)
        }

        if let terminalProfileBadge, showsProfileBadgeInHeader {
            profileBadge(terminalProfileBadge)
        }
    }

    private var panelHeaderTitle: some View {
        HStack(spacing: 6) {
            if let browserTitleIconImage {
                BrowserTitleIconView(
                    image: browserTitleIconImage,
                    fallbackSymbolName: "globe",
                    tintColor: panelTitleTextColor,
                    size: 14
                )
            }

            Text(panelLabel)
                .font(panelTitleFont)
                .foregroundStyle(panelTitleTextColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityIdentifier("panel.header.title.\(panelID.uuidString)")
    }

    private var panelLabel: String {
        switch panelState {
        case .terminal(let terminal):
            if let panelSessionStatus, panelSessionStatus.isActive {
                return panelSessionStatus.displayTitle
            }
            return terminal.displayPanelLabel
        case .web(let webState):
            return webState.displayPanelLabel
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

    private var showsHoveredCloseAffordance: Bool {
        appIsActive && isHovered
    }

    private var resolvedPanelHeaderTrailingAccessory: WorkspaceView.PanelHeaderTrailingAccessory {
        WorkspaceView.panelHeaderTrailingAccessory(
            shortcutLabel: shortcutLabel,
            isHovered: showsHoveredCloseAffordance
        )
    }

    private var browserTitleIconImage: NSImage? {
        guard case .web(let webState) = panelState,
              webState.definition == .browser else {
            return nil
        }
        return webPanelRuntimeRegistry.browserRuntime(for: panelID).faviconImage
    }

    private var localDocumentRuntime: LocalDocumentPanelRuntime? {
        guard case .web(let webState) = panelState,
              webState.definition == .localDocument else {
            return nil
        }
        return webPanelRuntimeRegistry.localDocumentRuntime(for: panelID)
    }

    private var showsTerminalHeaderSearch: Bool {
        guard case .terminal = panelState else {
            return false
        }
        return terminalRuntimeRegistry.searchState(for: panelID)?.isPresented == true
    }

    private var showsProfileBadgeInHeader: Bool {
        guard terminalProfileBadge != nil else {
            return false
        }
        return showsTerminalHeaderSearch == false
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
    private func webPanelBody(state: WebPanelState) -> some View {
        if state.definition == .browser {
            BrowserPanelView(
                panelID: panelID,
                webState: state,
                runtime: webPanelRuntimeRegistry.browserRuntime(for: panelID),
                isEffectivelyVisible: isWorkspaceSelected && isTabSelected,
                isActivePanel: isFocused,
                activatePanel: {
                    _ = store.send(.focusPanel(workspaceID: workspaceID, panelID: panelID))
                }
            )
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
        } else if state.definition == .localDocument {
            LocalDocumentPanelView(
                webState: state,
                runtime: webPanelRuntimeRegistry.localDocumentRuntime(for: panelID),
                isEffectivelyVisible: isWorkspaceSelected && isTabSelected,
                isActivePanel: isFocused,
                textScale: windowMarkdownTextScale
            )
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
        } else {
            webPanelPlaceholder(state: state)
        }
    }

    @ViewBuilder
    private func webPanelPlaceholder(state: WebPanelState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.definition.defaultTitle)
                .font(ToastyTheme.fontMonoHeader)
                .foregroundStyle(ToastyTheme.primaryText)

            if let filePath = state.filePath {
                Text(filePath)
                    .font(ToastyTheme.fontWorkspaceSubtitle)
                    .foregroundStyle(ToastyTheme.mutedText)
                    .textSelection(.enabled)
            } else if let url = state.restorableURL {
                Text(url)
                    .font(ToastyTheme.fontWorkspaceSubtitle)
                    .foregroundStyle(ToastyTheme.mutedText)
                    .textSelection(.enabled)
            } else {
                Text("\(state.definition.defaultTitle) runtime not wired yet.")
                    .font(ToastyTheme.fontWorkspaceSubtitle)
                    .foregroundStyle(ToastyTheme.mutedText)
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .padding(18)
    }

    private func shortcutBadge(_ label: String) -> some View {
        Text(label)
            .font(ToastyTheme.fontShortcutBadge)
            .foregroundStyle(ToastyTheme.shortcutBadgeText)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(ToastyTheme.hairline, in: RoundedRectangle(cornerRadius: 3))
    }

    @ViewBuilder
    private var panelHeaderTrailingContent: some View {
        switch resolvedPanelHeaderTrailingAccessory {
        case .closeButton:
            panelHeaderCloseButton
        case .badge(let label):
            shortcutBadge(label)
        case .empty:
            EmptyView()
        }
    }

    private var panelHeaderCloseButton: some View {
        Button {
            _ = focusedPanelCommandController.closePanel(panelID: panelID)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(
                    isCloseButtonHovered
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
        .accessibilityLabel("Close Panel")
        .accessibilityIdentifier("panel.header.close.\(panelID.uuidString)")
        .help(ToasttyKeyboardShortcuts.closePanel.helpText("Close Panel"))
        .onHover { hovering in
            if hovering {
                isCloseButtonHovered = true
            } else if isCloseButtonHovered {
                isCloseButtonHovered = false
            }
        }
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

    private func updateHoverState(_ hovering: Bool) {
        let nextHoverState = appIsActive && hovering
        isHovered = nextHoverState
        if nextHoverState == false {
            isCloseButtonHovered = false
        }
    }
}

private struct LocalDocumentPanelHeaderSearchRegion: View {
    let panelID: UUID
    @ObservedObject var runtime: LocalDocumentPanelRuntime
    let isActivePanel: Bool
    let activatePanel: () -> Void

    var body: some View {
        Group {
            if runtime.searchState()?.isPresented == true {
                LocalDocumentPanelHeaderSearchBar(
                    panelID: panelID,
                    runtime: runtime,
                    isActivePanel: isActivePanel,
                    activatePanel: activatePanel
                )
                .layoutPriority(1)
            }
        }
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
    var hasUnread: Bool = false

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
        .overlay(alignment: .topTrailing) {
            if hasUnread {
                // Badge sits at the icon's top-right corner with a background-colored
                // cutout ring so the dot reads clearly against the orange icon stroke.
                ZStack {
                    Circle()
                        .fill(ToastyTheme.chromeBackground)
                        .frame(width: 11, height: 11)
                    Circle()
                        .fill(ToastyTheme.badgeBlue)
                        .frame(width: 8, height: 8)
                        .shadow(color: ToastyTheme.badgeBlue.opacity(0.5), radius: 3)
                }
                .offset(x: 2.5, y: -2.5)
            }
        }
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
            brackets.move(to: CGPoint(x: 2, y: 5))
            brackets.addLine(to: CGPoint(x: 2, y: 2))
            brackets.addLine(to: CGPoint(x: 5, y: 2))
            // Top-right
            brackets.move(to: CGPoint(x: 9, y: 2))
            brackets.addLine(to: CGPoint(x: 12, y: 2))
            brackets.addLine(to: CGPoint(x: 12, y: 5))
            // Bottom-right
            brackets.move(to: CGPoint(x: 12, y: 9))
            brackets.addLine(to: CGPoint(x: 12, y: 12))
            brackets.addLine(to: CGPoint(x: 9, y: 12))
            // Bottom-left
            brackets.move(to: CGPoint(x: 5, y: 12))
            brackets.addLine(to: CGPoint(x: 2, y: 12))
            brackets.addLine(to: CGPoint(x: 2, y: 9))

            context.stroke(
                brackets,
                with: .color(color),
                style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
            )

            // Center dot
            let dot = Path(ellipseIn: CGRect(x: 7 - 1.5, y: 7 - 1.5, width: 3, height: 3))
            context.fill(dot, with: .color(color))
        }
        .frame(width: 14, height: 14)
    }
}

/// macOS command glyph — mirrors the ⇧⌘P shortcut that opens the palette.
struct CommandPaletteIconView: View {
    let color: Color

    var body: some View {
        Image(systemName: "command")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 14, height: 14)
    }
}

/// Two side-by-side rounded rectangles — Split Horizontal icon.
struct SplitHorizontalIconView: View {
    let color: Color

    var body: some View {
        Canvas { context, _ in
            let left = Path(roundedRect: CGRect(x: 2, y: 2, width: 4, height: 10), cornerRadius: 1)
            let right = Path(roundedRect: CGRect(x: 8, y: 2, width: 4, height: 10), cornerRadius: 1)
            let style = StrokeStyle(lineWidth: 1.2)
            context.stroke(left, with: .color(color), style: style)
            context.stroke(right, with: .color(color), style: style)
        }
        .frame(width: 14, height: 14)
    }
}

/// Two stacked rounded rectangles — Split Vertical icon.
struct SplitVerticalIconView: View {
    let color: Color

    var body: some View {
        Canvas { context, _ in
            let top = Path(roundedRect: CGRect(x: 2, y: 2, width: 10, height: 4), cornerRadius: 1)
            let bottom = Path(roundedRect: CGRect(x: 2, y: 8, width: 10, height: 4), cornerRadius: 1)
            let style = StrokeStyle(lineWidth: 1.2)
            context.stroke(top, with: .color(color), style: style)
            context.stroke(bottom, with: .color(color), style: style)
        }
        .frame(width: 14, height: 14)
    }
}

// MARK: - Flash Button Style

/// Custom ButtonStyle for momentary top bar actions. Shows the "active" pill styling
/// (accent icon, primary text, elevated background + border) while pressed, with a
/// smooth fade-out on release.
private struct TopBarFlashButtonStyle<Icon: View>: ButtonStyle {
    @ViewBuilder let icon: (_ isHighlighted: Bool) -> Icon

    func makeBody(configuration: Configuration) -> some View {
        let highlighted = configuration.isPressed
        TopBarButtonChrome(highlighted: highlighted, horizontalPadding: 6) {
            icon(highlighted)
        }
            .animation(.easeOut(duration: 0.15), value: highlighted)
    }
}

private struct TopBarFlashTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let highlighted = configuration.isPressed
        TopBarButtonChrome(highlighted: highlighted) {
            configuration.label
                .font(ToastyTheme.fontSubtext)
                .foregroundStyle(highlighted ? ToastyTheme.primaryText : ToastyTheme.inactiveText)
                .lineLimit(1)
        }
            .animation(.easeOut(duration: 0.15), value: highlighted)
    }
}

private struct TopBarButtonChrome<Content: View>: View {
    let highlighted: Bool
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let content: Content

    init(
        highlighted: Bool,
        horizontalPadding: CGFloat = 8,
        verticalPadding: CGFloat = 3,
        @ViewBuilder content: () -> Content
    ) {
        self.highlighted = highlighted
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(highlighted ? ToastyTheme.elevatedBackground : Color.clear)
            .overlay(
                Rectangle()
                    .strokeBorder(highlighted ? ToastyTheme.subtleBorder : Color.clear, lineWidth: 1)
            )
            .fixedSize(horizontal: true, vertical: true)
    }
}
