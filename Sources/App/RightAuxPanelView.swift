import AppKit
import CoreState
import SwiftUI

struct RightAuxPanelStackView: View {
    let windowID: UUID
    let workspaceIDs: [UUID]
    let selectedWorkspaceID: UUID?
    let renderedWidth: CGFloat
    let effectiveContentWidth: CGFloat
    @ObservedObject var store: AppStore
    @ObservedObject var terminalProfileStore: TerminalProfileStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
    @ObservedObject var webPanelRuntimeRegistry: WebPanelRuntimeRegistry
    let focusedPanelCommandController: FocusedPanelCommandController
    let windowFontPoints: Double
    let windowMarkdownTextScale: Double
    let appIsActive: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(workspaceIDs, id: \.self) { workspaceID in
                if let workspace = store.state.workspacesByID[workspaceID] {
                    ForEach(workspace.orderedTabs) { workspaceTab in
                        let isSelectedWorkspace = selectedWorkspaceID == workspaceID
                        let isSelectedTab = workspace.resolvedSelectedTabID == workspaceTab.id
                        let isVisible = isSelectedWorkspace &&
                            isSelectedTab &&
                            workspaceTab.rightAuxPanel.isVisible &&
                            workspaceTab.rightAuxPanel.tabIDs.isEmpty == false
                        let keepsMountedContentVisible = isSelectedWorkspace &&
                            isSelectedTab &&
                            workspaceTab.rightAuxPanel.tabIDs.isEmpty == false

                        RightAuxPanelView(
                            windowID: windowID,
                            workspace: workspace,
                            workspaceTab: workspaceTab,
                            isWorkspaceSelected: isSelectedWorkspace,
                            isWorkspaceTabSelected: isSelectedTab,
                            store: store,
                            terminalProfileStore: terminalProfileStore,
                            terminalRuntimeRegistry: terminalRuntimeRegistry,
                            webPanelRuntimeRegistry: webPanelRuntimeRegistry,
                            focusedPanelCommandController: focusedPanelCommandController,
                            effectiveContentWidth: effectiveContentWidth,
                            windowFontPoints: windowFontPoints,
                            windowMarkdownTextScale: windowMarkdownTextScale,
                            appIsActive: appIsActive
                        )
                        .opacity(WorkspaceView.mountedContentOpacity(isVisible: keepsMountedContentVisible))
                        .allowsHitTesting(isVisible && renderedWidth > 0)
                        .accessibilityHidden(!isVisible)
                        .zIndex(isVisible ? 1 : 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(renderedWidth > 0 ? ToastyTheme.surfaceBackground : Color.clear)
        .accessibilityIdentifier("right-panel.stack")
    }
}

struct RightAuxPanelView: View {
    let windowID: UUID
    let workspace: WorkspaceState
    let workspaceTab: WorkspaceTabState
    let isWorkspaceSelected: Bool
    let isWorkspaceTabSelected: Bool
    @ObservedObject var store: AppStore
    @ObservedObject var terminalProfileStore: TerminalProfileStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
    @ObservedObject var webPanelRuntimeRegistry: WebPanelRuntimeRegistry
    let focusedPanelCommandController: FocusedPanelCommandController
    let effectiveContentWidth: CGFloat
    let windowFontPoints: Double
    let windowMarkdownTextScale: Double
    let appIsActive: Bool

    @State private var resizeStartWidth: Double?
    @State private var resizeHandleHovered = false
    @State private var resizeHandleDragging = false

    var body: some View {
        HStack(spacing: 0) {
            resizeHandle

            VStack(alignment: .leading, spacing: 0) {
                if RightAuxPanelTabStrip.showsTabStrip(tabCount: workspaceTab.rightAuxPanel.tabIDs.count) {
                    RightAuxPanelTabStrip(
                        workspaceID: workspace.id,
                        tabs: workspaceTab.rightAuxPanel.orderedTabs,
                        activeTabID: workspaceTab.rightAuxPanel.activeTabID,
                        appIsActive: appIsActive,
                        store: store,
                        focusedPanelCommandController: focusedPanelCommandController,
                        webPanelRuntimeRegistry: webPanelRuntimeRegistry
                    )
                }

                panelStack
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ToastyTheme.surfaceBackground)
        .accessibilityIdentifier("right-panel.\(workspace.id.uuidString).\(workspaceTab.id.uuidString)")
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(ToastyTheme.hairline)
            .frame(width: 1)
            .overlay {
                Rectangle()
                    .fill(resizeHandleHighlightColor)
                    .frame(width: 3)
                    .animation(.easeOut(duration: 0.12), value: resizeHandleHighlighted)
            }
            .overlay {
                PointerInteractionRegion(
                    name: "right-panel-resize-handle",
                    metadata: [
                        "workspaceID": workspace.id.uuidString,
                        "workspaceTabID": workspaceTab.id.uuidString,
                    ],
                    cursor: .resizeLeftRight,
                    onBegan: { _ in
                        resizeStartWidth = Double(effectiveContentWidth)
                        updateResizeHandleInteraction(dragging: true)
                    },
                    onChanged: { value in
                        let startingWidth = resizeStartWidth ?? Double(effectiveContentWidth)
                        resizeStartWidth = startingWidth
                        let nextWidth = startingWidth - Double(value.translation.width)
                        _ = store.send(.setRightAuxPanelWidth(workspaceID: workspace.id, width: nextWidth))
                    },
                    onEnded: { _ in
                        resizeStartWidth = nil
                        updateResizeHandleInteraction(dragging: false)
                    },
                    onHoverChanged: { hovering in
                        updateResizeHandleInteraction(hovered: hovering)
                    }
                )
                    .frame(width: 10)
                    .accessibilityLabel("Resize Right Panel")
                    .accessibilityIdentifier("right-panel.resize")
            }
            .onDisappear {
                releaseResizeHandleInteraction()
            }
    }

    private var resizeHandleHighlighted: Bool {
        resizeHandleHovered || resizeHandleDragging
    }

    private var resizeHandleHighlightColor: Color {
        resizeHandleHighlighted
            ? ToastyTheme.accent.opacity(appIsActive ? 0.9 : 0.55)
            : Color.clear
    }

    private func updateResizeHandleInteraction(
        hovered: Bool? = nil,
        dragging: Bool? = nil
    ) {
        let nextHovered = hovered ?? resizeHandleHovered
        let nextDragging = dragging ?? resizeHandleDragging
        resizeHandleHovered = nextHovered
        resizeHandleDragging = nextDragging
    }

    private func releaseResizeHandleInteraction() {
        guard resizeHandleHovered || resizeHandleDragging else { return }

        DispatchQueue.main.async {
            resizeHandleHovered = false
            resizeHandleDragging = false
        }
    }

    private var panelStack: some View {
        ZStack(alignment: .topLeading) {
            ForEach(workspaceTab.rightAuxPanel.orderedTabs) { tab in
                let isActiveTab = workspaceTab.rightAuxPanel.activeTabID == tab.id

                PanelCardView(
                    workspaceID: workspace.id,
                    panelID: tab.panelID,
                    panelState: tab.panelState,
                    isWorkspaceSelected: isWorkspaceSelected && isWorkspaceTabSelected,
                    isTabSelected: isActiveTab,
                    focusedPanelID: workspaceTab.rightAuxPanel.focusedPanelID,
                    hasUnreadNotification: workspaceTab.unreadPanelIDs.contains(tab.panelID),
                    panelSessionStatus: nil,
                    shortcutNumber: nil,
                    windowFontPoints: windowFontPoints,
                    windowMarkdownTextScale: windowMarkdownTextScale,
                    appIsActive: appIsActive,
                    unfocusedSplitStyle: .disabled,
                    panelFlashOverlayOpacity: 0,
                    store: store,
                    terminalProfileStore: terminalProfileStore,
                    terminalRuntimeRegistry: terminalRuntimeRegistry,
                    webPanelRuntimeRegistry: webPanelRuntimeRegistry,
                    focusedPanelCommandController: focusedPanelCommandController,
                    terminalRuntimeContext: nil
                )
                .opacity(WorkspaceView.mountedContentOpacity(isVisible: isActiveTab))
                .allowsHitTesting(isWorkspaceSelected && isWorkspaceTabSelected && isActiveTab)
                .accessibilityHidden(!(isWorkspaceSelected && isWorkspaceTabSelected && isActiveTab))
                .zIndex(isActiveTab ? 1 : 0)
                .id(tab.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct RightAuxPanelTabStrip: View {
    let workspaceID: UUID
    let tabs: [RightAuxPanelTabState]
    let activeTabID: UUID?
    let appIsActive: Bool
    @ObservedObject var store: AppStore
    let focusedPanelCommandController: FocusedPanelCommandController
    @ObservedObject var webPanelRuntimeRegistry: WebPanelRuntimeRegistry

    @State private var hoveredTabID: UUID?
    @State private var hoveredCloseTabID: UUID?

    nonisolated private static let height: CGFloat = 30
    nonisolated private static let idealTabWidth: CGFloat = 142
    nonisolated private static let minimumTabWidth: CGFloat = 82
    nonisolated private static let spacing: CGFloat = -1

    nonisolated static func showsTabStrip(tabCount: Int) -> Bool {
        tabCount > 1
    }

    nonisolated static func resolvedTabWidth(availableWidth: CGFloat, tabCount: Int) -> CGFloat {
        guard tabCount > 0 else { return idealTabWidth }
        guard availableWidth.isFinite, availableWidth > 0 else { return idealTabWidth }

        let spacingWidth = CGFloat(max(tabCount - 1, 0)) * spacing
        let fittedWidth = floor((availableWidth - spacingWidth) / CGFloat(tabCount))
        return min(idealTabWidth, max(minimumTabWidth, fittedWidth))
    }

    var body: some View {
        GeometryReader { geometry in
            let tabWidth = Self.resolvedTabWidth(
                availableWidth: geometry.size.width,
                tabCount: tabs.count
            )

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.spacing) {
                        ForEach(tabs) { tab in
                            tabButton(tab)
                                .frame(width: tabWidth, height: Self.height)
                                .id(tab.id)
                        }
                    }
                    .frame(height: Self.height, alignment: .leading)
                }
                .onAppear {
                    scrollActiveTabIntoView(proxy: proxy)
                }
                .onChange(of: activeTabID) { _, _ in
                    scrollActiveTabIntoView(proxy: proxy)
                }
            }
        }
        .frame(height: Self.height)
        .background(ToastyTheme.chromeBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ToastyTheme.hairline)
                .frame(height: 1)
        }
        .accessibilityIdentifier("right-panel.tabs")
    }

    private func tabButton(_ tab: RightAuxPanelTabState) -> some View {
        let isActive = activeTabID == tab.id
        let isHovered = appIsActive && hoveredTabID == tab.id
        let showsClose = isHovered

        return ZStack(alignment: .trailing) {
            Button {
                _ = store.send(
                    .selectRightAuxPanelTab(
                        workspaceID: workspaceID,
                        tabID: tab.id,
                        focus: true
                    )
                )
            } label: {
                tabChrome(tab: tab, isActive: isActive, isHovered: isHovered)
            }
            .buttonStyle(.plain)

            if showsClose {
                closeButton(for: tab)
                    .padding(.trailing, 7)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredTabID = tab.id
            } else if hoveredTabID == tab.id {
                hoveredTabID = nil
                if hoveredCloseTabID == tab.id {
                    hoveredCloseTabID = nil
                }
            }
        }
        .accessibilityLabel(tab.panelState.notificationLabel)
        .accessibilityIdentifier("right-panel.tab.\(tab.id.uuidString)")
    }

    private func tabChrome(
        tab: RightAuxPanelTabState,
        isActive: Bool,
        isHovered: Bool
    ) -> some View {
        HStack(spacing: 6) {
            tabIcon(for: tab)

            Text(tab.panelState.notificationLabel)
                .font(ToastyTheme.fontWorkspaceTab)
                .foregroundStyle(tabTextColor(isActive: isActive, isHovered: isHovered))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear
                .frame(width: ToastyTheme.workspaceTabTrailingSlotWidth)
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(tabBackground(isActive: isActive, isHovered: isHovered))
        .overlay {
            if !isActive {
                Rectangle()
                    .stroke(ToastyTheme.subtleBorder, lineWidth: 1)
            }
        }
    }

    private func tabIcon(for tab: RightAuxPanelTabState) -> some View {
        let imageName: String
        switch tab.panelState {
        case .terminal:
            imageName = "terminal"
        case .web(let webState):
            switch webState.definition {
            case .browser:
                imageName = "globe"
            case .localDocument:
                imageName = "doc.text"
            case .scratchpad:
                imageName = "square.and.pencil"
            case .diff:
                imageName = "arrow.triangle.branch"
            }
        }

        return Image(systemName: imageName)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ToastyTheme.inactiveText)
            .frame(width: 12, height: 12)
    }

    private func closeButton(for tab: RightAuxPanelTabState) -> some View {
        Button {
            _ = focusedPanelCommandController.closePanel(panelID: tab.panelID)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(
                    hoveredCloseTabID == tab.id
                        ? ToastyTheme.workspaceTabCloseButtonHover
                        : ToastyTheme.workspaceTabCloseButton
                )
                .frame(width: 15, height: 15)
                .background(
                    ToastyTheme.workspaceTabCloseBackground,
                    in: RoundedRectangle(cornerRadius: 4)
                )
        }
        .buttonStyle(.plain)
        .help(ToasttyKeyboardShortcuts.closePanel.helpText("Close Panel"))
        .accessibilityLabel("Close Panel")
        .accessibilityIdentifier("right-panel.tab.close.\(tab.id.uuidString)")
        .onHover { hovering in
            if hovering {
                hoveredCloseTabID = tab.id
            } else if hoveredCloseTabID == tab.id {
                hoveredCloseTabID = nil
            }
        }
    }

    private func tabBackground(isActive: Bool, isHovered: Bool) -> Color {
        if isActive {
            return ToastyTheme.workspaceTabSelectedBackground
        }
        if isHovered {
            return ToastyTheme.workspaceTabHoverBackground
        }
        return ToastyTheme.chromeBackground
    }

    private func tabTextColor(isActive: Bool, isHovered: Bool) -> Color {
        if isActive {
            return ToastyTheme.primaryText
        }
        if isHovered {
            return ToastyTheme.workspaceTabHoverText
        }
        return ToastyTheme.workspaceTabUnselectedText
    }

    private func scrollActiveTabIntoView(proxy: ScrollViewProxy) {
        guard let activeTabID else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.12)) {
                proxy.scrollTo(activeTabID, anchor: .center)
            }
        }
    }
}
