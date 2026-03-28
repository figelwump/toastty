import CoreState
import SwiftUI

struct SidebarView: View {
    let windowID: UUID
    @ObservedObject var store: AppStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore
    let terminalRuntimeContext: TerminalWindowRuntimeContext
    @State private var renamingWorkspaceID: UUID?
    @State private var renameDraftTitle = ""
    @State private var hoveredPanelID: UUID?

    /// Fixed height for the session detail text area (1 line at the detail
    /// font size). Reserving a constant height prevents the sidebar from
    /// jittering as streaming summaries change length.
    private static let sessionDetailFixedHeight: CGFloat = {
        // 10pt system font default line height ≈ 12pt; 1 line.
        let font = NSFont.systemFont(ofSize: 10, weight: .regular)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return lineHeight
    }()

    private var selectedWorkspaceID: UUID? {
        store.selectedWorkspaceID(in: windowID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let window = store.window(id: windowID) {
                            ForEach(Array(window.workspaceIDs.enumerated()), id: \.element) { index, workspaceID in
                                if let workspace = store.state.workspacesByID[workspaceID] {
                                    workspaceRow(
                                        workspaceID: workspaceID,
                                        workspace: workspace,
                                        shortcutLabel: DisplayShortcutConfig.workspaceSwitchShortcutLabel(for: index + 1),
                                        isSelected: selectedWorkspaceID == workspaceID,
                                        index: index + 1
                                    )
                                    .id(workspaceID)
                                }
                            }
                        } else {
                            Text("No windows")
                                .font(ToastyTheme.fontBody)
                                .foregroundStyle(ToastyTheme.mutedText)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                // Keep the titlebar region opaque while letting rows scroll
                // underneath it instead of showing through the traffic-light area.
                .safeAreaInset(edge: .top, spacing: 0) {
                    sidebarTitlebarCover
                }
                .onAppear {
                    scrollToSelectedWorkspace(using: proxy, animated: false)
                }
                .onChange(of: selectedWorkspaceID) { _, _ in
                    scrollToSelectedWorkspace(using: proxy, animated: true)
                }
            }

            Button {
                cancelWorkspaceRename()
                store.send(.createWorkspace(windowID: windowID, title: nil))
            } label: {
                HStack(spacing: 6) {
                    Canvas { context, _ in
                        var plus = Path()
                        plus.move(to: CGPoint(x: 5.5, y: 2))
                        plus.addLine(to: CGPoint(x: 5.5, y: 9))
                        plus.move(to: CGPoint(x: 2, y: 5.5))
                        plus.addLine(to: CGPoint(x: 9, y: 5.5))
                        context.stroke(
                            plus,
                            with: .color(ToastyTheme.inactiveText),
                            style: StrokeStyle(lineWidth: 1.1, lineCap: .round)
                        )
                    }
                    .frame(width: 11, height: 11)

                    Text("New workspace")
                        .font(ToastyTheme.fontWorkspaceNameInactive)
                        .foregroundStyle(ToastyTheme.inactiveText)
                        .lineLimit(1)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 2)
                }
            }
            .buttonStyle(SidebarRowButtonStyle())
            .accessibilityIdentifier("sidebar.workspaces.new")
            .padding(.horizontal, 8)
        }
        .padding(.bottom, 10)
        .background(ToastyTheme.chromeBackground)
        .onChange(of: store.state.workspacesByID) { _, _ in
            pruneTransientSidebarState()
        }
        .onChange(of: store.pendingRenameWorkspaceRequest) { _, _ in
            guard let request = store.consumePendingWorkspaceRenameRequest(windowID: windowID),
                  let window = store.window(id: windowID),
                  window.workspaceIDs.contains(request.workspaceID),
                  let workspace = store.state.workspacesByID[request.workspaceID] else { return }
            beginWorkspaceRename(workspace)
        }
    }

    private var sidebarTitlebarCover: some View {
        Rectangle()
            .fill(ToastyTheme.chromeBackground)
            .frame(maxWidth: .infinity)
            .frame(height: ToastyTheme.sidebarTopPadding)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func workspaceRow(
        workspaceID: UUID,
        workspace: WorkspaceState,
        shortcutLabel: String?,
        isSelected: Bool,
        index: Int
    ) -> some View {
        Group {
            if renamingWorkspaceID == workspaceID {
                workspaceRenameRow(
                    workspaceID: workspaceID,
                    workspace: workspace,
                    shortcutLabel: shortcutLabel,
                    isSelected: isSelected
                )
            } else {
                workspaceButton(
                    workspaceID: workspaceID,
                    workspace: workspace,
                    shortcutLabel: shortcutLabel,
                    isSelected: isSelected
                )
            }
        }
        .contextMenu {
            Button(ToasttyKeyboardShortcuts.renameWorkspace.menuTitle("Rename Workspace")) {
                beginWorkspaceRename(workspace)
            }

            Button(ToasttyKeyboardShortcuts.closeWorkspace.menuTitle("Close workspace"), role: .destructive) {
                requestWorkspaceClose(workspaceID: workspaceID)
            }
        }
        .accessibilityIdentifier("sidebar.workspace.\(index)")
    }

    private func workspaceButton(
        workspaceID: UUID,
        workspace: WorkspaceState,
        shortcutLabel: String?,
        isSelected: Bool
    ) -> some View {
        let sessionStatuses = sessionRuntimeStore.workspaceStatuses(for: workspace.id)

        return workspaceRowChrome(isSelected: isSelected) {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    handleWorkspaceButtonActivation(workspaceID: workspaceID, workspace: workspace)
                } label: {
                    workspacePrimaryContent(
                        workspace: workspace,
                        shortcutLabel: shortcutLabel,
                        selectionSubtitle: selectionSubtitle(for: workspace),
                        isSelected: isSelected
                    ) {
                        Text(workspace.title)
                            .font(isSelected ? ToastyTheme.fontWorkspaceName : ToastyTheme.fontWorkspaceNameInactive)
                            .foregroundStyle(isSelected ? ToastyTheme.primaryText : ToastyTheme.inactiveText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .buttonStyle(SidebarRowButtonStyle())

                if !sessionStatuses.isEmpty {
                    sessionStatusesContent(sessionStatuses, workspace: workspace)
                }
            }
        }
    }

    private func workspaceRenameRow(
        workspaceID: UUID,
        workspace: WorkspaceState,
        shortcutLabel: String?,
        isSelected: Bool
    ) -> some View {
        let sessionStatuses = sessionRuntimeStore.workspaceStatuses(for: workspace.id)

        return workspaceRowChrome(isSelected: isSelected) {
            VStack(alignment: .leading, spacing: 2) {
                workspacePrimaryContent(
                    workspace: workspace,
                    shortcutLabel: shortcutLabel,
                    selectionSubtitle: selectionSubtitle(for: workspace),
                    isSelected: isSelected
                ) {
                    WorkspaceRenameTextField(
                        text: $renameDraftTitle,
                        itemID: workspaceID,
                        placeholder: "Workspace name",
                        font: .systemFont(ofSize: 12, weight: .semibold),
                        accessibilityID: renameTextFieldAccessibilityID(for: workspaceID),
                        onSubmit: {
                            commitWorkspaceRename(workspaceID: workspaceID)
                        },
                        onCancel: {
                            cancelWorkspaceRename()
                            scheduleWorkspaceSlotFocusRestore()
                        }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !sessionStatuses.isEmpty {
                    sessionStatusesContent(sessionStatuses, workspace: workspace)
                }
            }
        }
    }

    private func workspaceRowChrome<Content: View>(
        isSelected: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? ToastyTheme.elevatedBackground : Color.clear)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isSelected ? ToastyTheme.accent : Color.clear)
                    .frame(width: 2)
            }
            .contentShape(Rectangle())
    }

    private func workspacePrimaryContent<Title: View>(
        workspace: WorkspaceState,
        shortcutLabel: String?,
        selectionSubtitle: String?,
        isSelected: Bool,
        @ViewBuilder titleView: () -> Title
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                titleView()

                if workspace.unreadNotificationCount > 0 {
                    Circle()
                        .fill(ToastyTheme.badgeBlue)
                        .frame(width: 7, height: 7)
                        .shadow(color: ToastyTheme.badgeBlue.opacity(0.5), radius: 3, x: 0, y: 0)
                }

                Spacer(minLength: 0)

                // Keyboard shortcut badge pill
                if let shortcutLabel {
                    shortcutBadge(shortcutLabel)
                }
            }

            if let selectionSubtitle {
                Text(selectionSubtitle)
                    .font(ToastyTheme.fontWorkspaceSubtitle)
                    .foregroundStyle(isSelected ? ToastyTheme.inactiveText : ToastyTheme.inactiveWorkspaceSubtitleText)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func sessionStatusesContent(
        _ workspaceSessionStatuses: [WorkspaceSessionStatus],
        workspace: WorkspaceState
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(workspaceSessionStatuses, id: \.sessionID) { workspaceSessionStatus in
                sessionStatusContent(
                    workspaceSessionStatus,
                    workspace: workspace,
                    isHovered: hoveredPanelID == workspaceSessionStatus.panelID
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectionSubtitle(for workspace: WorkspaceState) -> String? {
        let paneCount = workspace.layoutTree.allSlotInfos.count
        return workspaceSubtitle(workspace: workspace, paneCount: paneCount)
    }

    @ViewBuilder
    private func sessionStatusContent(
        _ workspaceSessionStatus: WorkspaceSessionStatus,
        workspace: WorkspaceState,
        isHovered: Bool
    ) -> some View {
        let status = workspaceSessionStatus.status
        let showsUnreadSessionAccent = showsUnreadSessionAccent(
            for: workspaceSessionStatus.panelID,
            in: workspace
        )
        let canFocusPanel = Self.canFocusSessionPanel(workspaceSessionStatus.panelID, in: workspace)
        let isActivePanel = store.selectedWorkspaceID(in: windowID) == workspace.id
            && store.selectedWorkspace(in: windowID)?.focusedPanelID == workspaceSessionStatus.panelID

        Group {
            if canFocusPanel {
                Button {
                    focusSessionPanel(
                        workspaceID: workspace.id,
                        panelID: workspaceSessionStatus.panelID
                    )
                } label: {
                    sessionStatusLabel(
                        workspaceSessionStatus,
                        status: status,
                        showsUnreadSessionAccent: showsUnreadSessionAccent,
                        isActivePanel: isActivePanel,
                        isHovered: isHovered
                    )
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    if isHovering {
                        hoveredPanelID = workspaceSessionStatus.panelID
                    } else if hoveredPanelID == workspaceSessionStatus.panelID {
                        hoveredPanelID = nil
                    }
                }
                .accessibilityIdentifier("sidebar.workspace.session.\(workspaceSessionStatus.sessionID)")
            } else {
                sessionStatusLabel(
                    workspaceSessionStatus,
                    status: status,
                    showsUnreadSessionAccent: showsUnreadSessionAccent,
                    isActivePanel: isActivePanel,
                    isHovered: false
                )
            }
        }
    }

    private func sessionStatusLabel(
        _ workspaceSessionStatus: WorkspaceSessionStatus,
        status: SessionStatus,
        showsUnreadSessionAccent: Bool,
        isActivePanel: Bool,
        isHovered: Bool
    ) -> some View {
        let indicatorState = Self.sessionIndicatorState(for: status.kind)
        let unreadOutlineKind = Self.unreadSessionOutlineKind(
            for: status,
            showsUnreadSessionAccent: showsUnreadSessionAccent
        )
        // Preserve the status outline until the session is read; hover still
        // gets feedback from the row background fill.
        let borderColor = unreadOutlineKind
            .map { ToastyTheme.sessionStatusOutlineColor(for: $0) }
            ?? (isHovered ? ToastyTheme.sidebarSessionHoverBorder : Color.clear)

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if indicatorState != .hidden {
                    SessionStatusIndicator(state: indicatorState, size: 8, lineWidth: 1.4)
                }

                Text(workspaceSessionStatus.agent.displayName)
                    .font(ToastyTheme.fontWorkspaceSessionAgent)
                    .foregroundStyle(ToastyTheme.sidebarSessionAgentText)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            if status.kind != .idle {
                // Fixed 2-line height prevents sidebar jitter as summaries
                // stream in at varying lengths. The placeholder sets the
                // intrinsic height; the real text overlays it.
                Text(status.detail ?? " ")
                    .font(ToastyTheme.fontWorkspaceSessionDetail)
                    .foregroundStyle(ToastyTheme.sidebarSessionDetailText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: Self.sessionDetailFixedHeight,
                        alignment: .topLeading
                    )
            }

            if let cwd = Self.abbreviatedPathLabel(workspaceSessionStatus.cwd) {
                Text(cwd)
                    .font(ToastyTheme.fontWorkspaceSessionPath)
                    .foregroundStyle(ToastyTheme.sidebarSessionPathText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isActivePanel
                      ? (isHovered ? ToastyTheme.sidebarSessionActiveHoverBackground
                         : ToastyTheme.sidebarSessionActiveBackground)
                      : isHovered ? ToastyTheme.sidebarSessionHoverBackground
                      : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(borderColor, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 5))
    }
    private func handleWorkspaceButtonActivation(workspaceID: UUID, workspace: WorkspaceState) {
        if let currentEvent = NSApp.currentEvent,
           currentEvent.type == .leftMouseUp,
           currentEvent.clickCount == 2 {
            beginWorkspaceRename(workspace)
            return
        }

        cancelWorkspaceRename()
        store.selectWorkspace(
            windowID: windowID,
            workspaceID: workspaceID,
            preferringUnreadSessionPanelIn: sessionRuntimeStore
        )
    }

    private func focusSessionPanel(workspaceID: UUID, panelID: UUID) {
        cancelWorkspaceRename()

        if store.selectedWorkspaceID(in: windowID) != workspaceID {
            _ = store.send(.selectWorkspace(windowID: windowID, workspaceID: workspaceID))
        }

        _ = store.send(.focusPanel(workspaceID: workspaceID, panelID: panelID))
        terminalRuntimeContext.scheduleWorkspaceFocusRestore(
            workspaceID: workspaceID,
            avoidStealingKeyboardFocus: false
        )
    }

    private func beginWorkspaceRename(_ workspace: WorkspaceState) {
        renamingWorkspaceID = workspace.id
        renameDraftTitle = workspace.title
    }

    private func commitWorkspaceRename(workspaceID: UUID) {
        guard let workspace = store.state.workspacesByID[workspaceID] else {
            cancelWorkspaceRename()
            scheduleWorkspaceSlotFocusRestore()
            return
        }

        let trimmedTitle = renameDraftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.isEmpty == false else {
            renameDraftTitle = workspace.title
            cancelWorkspaceRename()
            scheduleWorkspaceSlotFocusRestore()
            return
        }

        _ = store.send(.renameWorkspace(workspaceID: workspaceID, title: trimmedTitle))
        cancelWorkspaceRename()
        scheduleWorkspaceSlotFocusRestore()
    }

    private func cancelWorkspaceRename() {
        renamingWorkspaceID = nil
        renameDraftTitle = ""
    }

    private func scheduleWorkspaceSlotFocusRestore() {
        guard let workspaceID = store.selectedWorkspace(in: windowID)?.id else { return }
        terminalRuntimeContext.scheduleWorkspaceFocusRestore(
            workspaceID: workspaceID,
            avoidStealingKeyboardFocus: false
        )
    }

    private func renameTextFieldAccessibilityID(for workspaceID: UUID) -> String {
        "sidebar.workspace.rename.\(workspaceID.uuidString)"
    }

    private func requestWorkspaceClose(workspaceID: UUID) {
        _ = store.requestWorkspaceClose(workspaceID: workspaceID)
    }

    private func scrollToSelectedWorkspace(
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        guard let selectedWorkspaceID else { return }

        Task { @MainActor in
            if animated {
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(selectedWorkspaceID)
                }
            } else {
                proxy.scrollTo(selectedWorkspaceID)
            }
        }
    }

    private func pruneTransientSidebarState() {
        if let renamingWorkspaceID,
           store.state.workspacesByID[renamingWorkspaceID] == nil {
            cancelWorkspaceRename()
        }
    }

    private func workspaceSubtitle(workspace: WorkspaceState, paneCount: Int) -> String {
        let paneLabel = paneCount == 1 ? "1 pane" : "\(paneCount) panes"
        if let activitySubtext = terminalRuntimeRegistry.workspaceActivitySubtext(for: workspace.id),
           activitySubtext.isEmpty == false {
            return "\(paneLabel) · \(activitySubtext)"
        }
        return paneLabel
    }

    private func showsUnreadSessionAccent(
        for panelID: UUID,
        in workspace: WorkspaceState
    ) -> Bool {
        Self.showsUnreadSessionAccent(
            for: panelID,
            in: workspace,
            selectedWorkspaceID: store.selectedWorkspaceID(in: windowID),
            selectedPanelID: store.selectedWorkspace(in: windowID)?.focusedPanelID
        )
    }

    static func showsUnreadSessionAccent(
        for panelID: UUID,
        in workspace: WorkspaceState,
        selectedWorkspaceID: UUID?,
        selectedPanelID: UUID?
    ) -> Bool {
        guard let tabID = workspace.tabID(containingPanelID: panelID),
              workspace.tab(id: tabID)?.unreadPanelIDs.contains(panelID) == true else {
            return false
        }

        if selectedWorkspaceID == workspace.id,
           selectedPanelID == panelID {
            return false
        }

        return true
    }

    static func unreadSessionOutlineKind(
        for status: SessionStatus,
        showsUnreadSessionAccent: Bool
    ) -> SessionStatusKind? {
        guard showsUnreadSessionAccent else {
            return nil
        }

        switch status.kind {
        case .needsApproval, .ready, .error:
            return status.kind
        case .idle, .working:
            return nil
        }
    }

    static func canFocusSessionPanel(_ panelID: UUID, in workspace: WorkspaceState) -> Bool {
        workspace.panelState(for: panelID) != nil && workspace.slotID(containingPanelID: panelID) != nil
    }

    static func sessionIndicatorState(for kind: SessionStatusKind) -> SessionStatusIndicatorState {
        switch kind {
        case .working:
            return .spinner
        case .needsApproval, .ready, .error, .idle:
            return .hidden
        }
    }

    static func abbreviatedPathLabel(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let normalizedPath = (trimmed as NSString).standardizingPath
        let pathString = normalizedPath as NSString
        let lastComponent = pathString.lastPathComponent
        if lastComponent.isEmpty == false, lastComponent != "/", pathString.pathComponents.count > 1 {
            return ".../\(lastComponent)"
        }
        return pathString.abbreviatingWithTildeInPath
    }

    /// Reusable keyboard shortcut badge pill (e.g. "⌥1", "⌘⇧N").
    private func shortcutBadge(_ label: String) -> some View {
        Text(label)
            .font(ToastyTheme.fontShortcutBadge)
            .foregroundStyle(ToastyTheme.shortcutBadgeText)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(ToastyTheme.hairline, in: RoundedRectangle(cornerRadius: 3))
    }
}

private struct SidebarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
