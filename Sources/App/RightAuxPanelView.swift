import AppKit
import CoreState
import SwiftUI

struct RightAuxPanelView: View {
    nonisolated static let resizeHandleHitWidth: CGFloat = 10
    private nonisolated static let resizeHandleHairlineWidth: CGFloat = 1
    private nonisolated static let resizeHandleHighlightWidth: CGFloat = 3

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
    let openLocalFileSearch: @MainActor (UUID) -> Void
    let openBrowser: @MainActor (UUID) -> Void
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
                        webPanelRuntimeRegistry: webPanelRuntimeRegistry,
                        openLocalFileSearch: { openLocalFileSearch(windowID) },
                        openBrowser: { openBrowser(windowID) }
                    )
                }

                panelStack
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ToastyTheme.surfaceBackground)
        .accessibilityIdentifier("right-panel.\(workspace.id.uuidString).\(workspaceTab.id.uuidString)")
        .onChange(of: acceptsPanelInteraction) { _, isActive in
            if isActive == false {
                cancelResizeHandleInteraction()
            }
        }
    }

    private var resizeHandle: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(ToastyTheme.hairline)
                .frame(width: Self.resizeHandleHairlineWidth)
                .allowsHitTesting(false)

            Rectangle()
                .fill(resizeHandleHighlightColor)
                .frame(width: Self.resizeHandleHighlightWidth)
                .animation(.easeOut(duration: 0.12), value: resizeHandleHighlighted)
                .allowsHitTesting(false)

            PointerInteractionRegion(
                name: "right-panel-resize-handle",
                metadata: [
                    "workspaceID": workspace.id.uuidString,
                    "workspaceTabID": workspaceTab.id.uuidString,
                    "isWorkspaceSelected": "\(isWorkspaceSelected)",
                    "isWorkspaceTabSelected": "\(isWorkspaceTabSelected)",
                    "rightAuxPanelVisible": "\(workspaceTab.rightAuxPanel.isVisible)",
                    "acceptsPanelInteraction": "\(acceptsPanelInteraction)",
                    "effectiveContentWidth": String(format: "%.1f", effectiveContentWidth),
                ],
                cursor: .resizeLeftRight,
                onBegan: { _ in
                    guard acceptsPanelInteraction else { return }
                    resizeStartWidth = Double(effectiveContentWidth)
                    updateResizeHandleInteraction(dragging: true)
                },
                onChanged: { value in
                    guard acceptsPanelInteraction else { return }
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
            .frame(width: Self.resizeHandleHitWidth)
            .frame(maxHeight: .infinity)
            .accessibilityLabel("Resize Right Panel")
            .accessibilityIdentifier("right-panel.resize")
            .onDisappear {
                releaseResizeHandleInteraction()
            }
        }
        .frame(width: Self.resizeHandleHitWidth)
        .frame(maxHeight: .infinity)
    }

    private var resizeHandleHighlighted: Bool {
        resizeHandleHovered || resizeHandleDragging
    }

    private var acceptsPanelInteraction: Bool {
        isWorkspaceSelected && isWorkspaceTabSelected && workspaceTab.rightAuxPanel.isVisible
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
        if nextHovered != resizeHandleHovered || nextDragging != resizeHandleDragging {
            ToasttyLog.info(
                "right panel resize handle interaction changed",
                category: .input,
                metadata: [
                    "workspaceID": workspace.id.uuidString,
                    "workspaceTabID": workspaceTab.id.uuidString,
                    "hovered": "\(nextHovered)",
                    "dragging": "\(nextDragging)",
                    "acceptsPanelInteraction": "\(acceptsPanelInteraction)",
                    "appIsActive": "\(appIsActive)",
                    "effectiveContentWidth": String(format: "%.1f", effectiveContentWidth),
                ]
            )
        }
        resizeHandleHovered = nextHovered
        resizeHandleDragging = nextDragging
    }

    private func cancelResizeHandleInteraction() {
        resizeStartWidth = nil
        resizeHandleHovered = false
        resizeHandleDragging = false
    }

    private func releaseResizeHandleInteraction() {
        guard resizeHandleHovered || resizeHandleDragging else { return }

        DispatchQueue.main.async {
            resizeHandleHovered = false
            resizeHandleDragging = false
        }
    }

    private var panelStack: some View {
        Group {
            if workspaceTab.rightAuxPanel.tabIDs.isEmpty {
                RightAuxPanelEmptyStateView(
                    openLocalFileSearch: { openLocalFileSearch(windowID) },
                    openBrowser: { openBrowser(windowID) }
                )
            } else {
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct RightAuxPanelEmptyStateView: View {
    let openLocalFileSearch: @MainActor () -> Void
    let openBrowser: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            ToastCharacterView(size: 96)
                .padding(.bottom, 18)

            Text("A fresh slice on the side")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(ToastyTheme.primaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

            Text("Nothing open here yet.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ToastyTheme.emptyStateMutedText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)

            VStack(spacing: 10) {
                RightAuxPanelEmptyStateActionButton(
                    title: "Find local file",
                    subtitle: "Open a document from this workspace.",
                    systemImage: "magnifyingglass",
                    action: openLocalFileSearch
                )
                .accessibilityIdentifier("right-panel.empty.find-local-file")

                RightAuxPanelEmptyStateActionButton(
                    title: "Open browser",
                    subtitle: "Start with a blank page.",
                    systemImage: "globe",
                    action: openBrowser
                )
                .accessibilityIdentifier("right-panel.empty.open-browser")
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: 340)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ToastyTheme.surfaceBackground)
        .accessibilityIdentifier("right-panel.empty")
    }
}

private struct RightAuxPanelEmptyStateActionButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: @MainActor () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isHovered ? ToastyTheme.accent : ToastyTheme.inactiveText)
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ToastyTheme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(subtitle)
                        .font(ToastyTheme.fontSubtext)
                        .foregroundStyle(ToastyTheme.inactiveText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? ToastyTheme.elevatedBackground : ToastyTheme.chromeBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isHovered ? ToastyTheme.subtleBorder : ToastyTheme.hairline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
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
    let openLocalFileSearch: @MainActor () -> Void
    let openBrowser: @MainActor () -> Void

    @State private var hoveredTabID: UUID?
    @State private var hoveredCloseTabID: UUID?

    nonisolated private static let height: CGFloat = 30
    nonisolated private static let idealTabWidth: CGFloat = 142
    nonisolated private static let minimumTabWidth: CGFloat = 82
    nonisolated private static let spacing: CGFloat = -1
    nonisolated private static let addButtonContainerWidth: CGFloat = 38
    nonisolated private static let addButtonSize: CGFloat = 22

    nonisolated static func showsTabStrip(tabCount: Int) -> Bool {
        tabCount > 0
    }

    nonisolated static func resolvedTabWidth(availableWidth: CGFloat, tabCount: Int) -> CGFloat {
        guard tabCount > 0 else { return idealTabWidth }
        guard availableWidth.isFinite, availableWidth > 0 else { return idealTabWidth }

        let spacingWidth = CGFloat(max(tabCount - 1, 0)) * spacing
        let fittedWidth = floor((availableWidth - spacingWidth) / CGFloat(tabCount))
        return min(idealTabWidth, max(minimumTabWidth, fittedWidth))
    }

    nonisolated static func tabListAvailableWidth(totalWidth: CGFloat) -> CGFloat {
        guard totalWidth.isFinite, totalWidth > 0 else { return 0 }

        return max(0, totalWidth - addButtonContainerWidth)
    }

    var body: some View {
        GeometryReader { geometry in
            let tabListWidth = Self.tabListAvailableWidth(totalWidth: geometry.size.width)
            let tabWidth = Self.resolvedTabWidth(
                availableWidth: tabListWidth,
                tabCount: tabs.count
            )

            HStack(spacing: 0) {
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
                .frame(width: tabListWidth, height: Self.height, alignment: .leading)
                .clipped()

                addPanelMenu
                    .frame(
                        width: min(Self.addButtonContainerWidth, max(0, geometry.size.width)),
                        height: Self.height
                    )
                    .background(ToastyTheme.chromeBackground)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(ToastyTheme.hairline)
                            .frame(width: 1)
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

    private var addPanelMenu: some View {
        Menu {
            Button(action: openBrowser) {
                Label("Open Browser", systemImage: "globe")
            }
            .accessibilityIdentifier("right-panel.tabs.add.open-browser")

            Button(action: openLocalFileSearch) {
                Label("Find Local File", systemImage: "magnifyingglass")
            }
            .accessibilityIdentifier("right-panel.tabs.add.find-local-file")
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(ToastyTheme.elevatedBackground)

                RoundedRectangle(cornerRadius: 5)
                    .stroke(ToastyTheme.subtleBorder, lineWidth: 1)

                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ToastyTheme.inactiveText)
            }
            .frame(width: Self.addButtonSize, height: Self.addButtonSize)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .help("Add to Right Panel")
        .accessibilityLabel("Add to Right Panel")
        .accessibilityIdentifier("right-panel.tabs.add")
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
