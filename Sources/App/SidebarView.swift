import CoreState
import SwiftUI

private struct SidebarSemanticTextBridge: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.isHidden = true
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBezeled = false
        label.isBordered = false
        label.setAccessibilityElement(false)
        return label
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.stringValue = text
    }
}

struct SidebarView: View {
    struct WorkspaceDragState: Equatable {
        let workspaceID: UUID
        let sourceIndex: Int
        let startPointerY: CGFloat
        var translationHeight: CGFloat
        var targetIndex: Int
    }

    let windowID: UUID
    @ObservedObject var store: AppStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore
    let terminalRuntimeContext: TerminalWindowRuntimeContext
    /// Test seam for asserting scroll requests without depending on AppKit's
    /// NSScrollView behavior inside unit-test hosting views.
    let scrollRequestObserver: ((UUID, Bool) -> Void)?
    /// Test seam for asserting click targets against the same geometry used by drag reordering.
    let workspaceHeaderFrameObserver: (([UUID: CGRect]) -> Void)?
    @State private var renamingWorkspaceID: UUID?
    @State private var renameDraftTitle = ""
    @State private var hoveredPanelID: UUID?
    @State private var hoveredWorkspaceID: UUID?
    @State private var flashingWorkspaceID: UUID?
    @State private var flashingSessionPanelID: UUID?
    @State private var flashingSessionOverlayOpacity = 0.0
    @State private var activeSidebarFlashRequestID: UUID?
    @State private var lastHandledSidebarFlashRequestID: UUID?
    @State private var sidebarFlashClearWorkItem: DispatchWorkItem?
    @State private var sidebarFlashResetWorkItem: DispatchWorkItem?
    @State private var activeWorkspaceDrag: WorkspaceDragState?
    @State private var measuredWorkspaceHeaderFramesByID: [UUID: CGRect] = [:]

    /// Fixed height for the session detail text area (1 line at the detail
    /// font size). Reserving a constant height prevents the sidebar from
    /// jittering as streaming summaries change length.
    private static let sessionDetailFixedHeight: CGFloat = {
        // 10pt system font default line height ≈ 12pt; 1 line.
        let font = NSFont.systemFont(ofSize: 10, weight: .regular)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return lineHeight
    }()
    private static let sessionStatusesTopSpacing: CGFloat = 0
    private static let sessionFlashPeakDuration: Double = 0.18
    private static let sessionFlashSettleDuration: Double = 0.28
    private nonisolated static let workspaceDragActivationDistance: CGFloat = 4

    nonisolated static func workspaceReorderTargetIndex(
        orderedWorkspaceIDs: [UUID],
        measuredHeaderFramesByID: [UUID: CGRect],
        draggedWorkspaceID: UUID,
        pointerY: CGFloat
    ) -> Int? {
        guard pointerY.isFinite else { return nil }

        let measuredFrames = orderedWorkspaceIDs.compactMap { workspaceID -> CGRect? in
            guard workspaceID != draggedWorkspaceID else { return nil }
            return measuredHeaderFramesByID[workspaceID]
        }
        guard measuredFrames.count == max(orderedWorkspaceIDs.count - 1, 0) else { return nil }
        guard measuredFrames.isEmpty == false else { return 0 }

        for (index, frame) in measuredFrames.enumerated() {
            if pointerY < frame.midY {
                return index
            }
        }
        return measuredFrames.count
    }

    nonisolated static func workspaceInsertionIndicatorY(
        orderedWorkspaceIDs: [UUID],
        measuredHeaderFramesByID: [UUID: CGRect],
        draggedWorkspaceID: UUID,
        targetIndex: Int
    ) -> CGFloat? {
        let measuredFrames = orderedWorkspaceIDs.compactMap { workspaceID -> CGRect? in
            guard workspaceID != draggedWorkspaceID else { return nil }
            return measuredHeaderFramesByID[workspaceID]
        }
        guard measuredFrames.count == max(orderedWorkspaceIDs.count - 1, 0) else { return nil }
        guard measuredFrames.isEmpty == false else { return nil }
        guard targetIndex >= 0, targetIndex <= measuredFrames.count else { return nil }

        if targetIndex == 0 {
            return measuredFrames[0].minY
        }
        if targetIndex == measuredFrames.count {
            return measuredFrames[measuredFrames.count - 1].maxY
        }
        return measuredFrames[targetIndex].minY
    }

    init(
        windowID: UUID,
        store: AppStore,
        terminalRuntimeRegistry: TerminalRuntimeRegistry,
        sessionRuntimeStore: SessionRuntimeStore,
        terminalRuntimeContext: TerminalWindowRuntimeContext,
        scrollRequestObserver: ((UUID, Bool) -> Void)? = nil,
        workspaceHeaderFrameObserver: (([UUID: CGRect]) -> Void)? = nil
    ) {
        self.windowID = windowID
        self.store = store
        self.terminalRuntimeRegistry = terminalRuntimeRegistry
        self.sessionRuntimeStore = sessionRuntimeStore
        self.terminalRuntimeContext = terminalRuntimeContext
        self.scrollRequestObserver = scrollRequestObserver
        self.workspaceHeaderFrameObserver = workspaceHeaderFrameObserver
    }

    private var selectedWorkspaceID: UUID? {
        store.selectedWorkspaceID(in: windowID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if let window = store.window(id: windowID) {
                            ForEach(Array(window.workspaceIDs.enumerated()), id: \.element) { index, workspaceID in
                                if let workspace = store.state.workspacesByID[workspaceID] {
                                    workspaceRow(
                                        workspaceID: workspaceID,
                                        workspace: workspace,
                                        shortcutLabel: DisplayShortcutConfig.workspaceSwitchShortcutLabel(for: index + 1),
                                        isSelected: selectedWorkspaceID == workspaceID,
                                        index: index + 1,
                                        orderedWorkspaceIDs: window.workspaceIDs
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
                    .coordinateSpace(name: SidebarWorkspaceListCoordinateSpace.name)
                    .onPreferenceChange(WorkspaceHeaderFramePreferenceKey.self) { framesByID in
                        measuredWorkspaceHeaderFramesByID = framesByID
                        workspaceHeaderFrameObserver?(framesByID)
                    }
                    .overlay(alignment: .topLeading) {
                        if let activeWorkspaceDrag,
                           activeWorkspaceDrag.targetIndex != activeWorkspaceDrag.sourceIndex,
                           let indicatorY = Self.workspaceInsertionIndicatorY(
                               orderedWorkspaceIDs: store.window(id: windowID)?.workspaceIDs ?? [],
                               measuredHeaderFramesByID: measuredWorkspaceHeaderFramesByID,
                               draggedWorkspaceID: activeWorkspaceDrag.workspaceID,
                               targetIndex: activeWorkspaceDrag.targetIndex
                           ) {
                            Rectangle()
                                .fill(ToastyTheme.accent)
                                .frame(maxWidth: .infinity)
                                .frame(height: 2)
                                .offset(y: indicatorY - 1)
                                .allowsHitTesting(false)
                        }
                    }
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
            pruneTransientWorkspaceDragState()
        }
        .onChange(of: store.pendingRenameWorkspaceRequest) { _, _ in
            guard let request = store.consumePendingWorkspaceRenameRequest(windowID: windowID),
                  let window = store.window(id: windowID),
                  window.workspaceIDs.contains(request.workspaceID),
                  let workspace = store.state.workspacesByID[request.workspaceID] else { return }
            beginWorkspaceRename(workspace)
        }
        .onAppear {
            schedulePendingSidebarSessionFlashRequestHandling()
        }
        .onChange(of: store.pendingSidebarSessionFlashRequest) { _, _ in
            schedulePendingSidebarSessionFlashRequestHandling()
        }
        .onDisappear {
            cancelWorkspaceDrag()
            sidebarFlashClearWorkItem?.cancel()
            sidebarFlashResetWorkItem?.cancel()
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
        index: Int,
        orderedWorkspaceIDs: [UUID]
    ) -> some View {
        let row = Group {
            if renamingWorkspaceID == workspaceID {
                workspaceRenameRow(
                    workspaceID: workspaceID,
                    workspace: workspace,
                    shortcutLabel: shortcutLabel,
                    isSelected: isSelected,
                    sourceIndex: index - 1,
                    orderedWorkspaceIDs: orderedWorkspaceIDs
                )
            } else {
                workspaceButton(
                    workspaceID: workspaceID,
                    workspace: workspace,
                    shortcutLabel: shortcutLabel,
                    isSelected: isSelected,
                    sourceIndex: index - 1,
                    orderedWorkspaceIDs: orderedWorkspaceIDs
                )
            }
        }
        .offset(y: activeWorkspaceDrag?.workspaceID == workspaceID ? activeWorkspaceDrag?.translationHeight ?? 0 : 0)
        .zIndex(activeWorkspaceDrag?.workspaceID == workspaceID ? 1 : 0)
        .accessibilityIdentifier("sidebar.workspace.\(index)")

        if activeWorkspaceDrag == nil {
            row.contextMenu {
                Button(ToasttyKeyboardShortcuts.renameWorkspace.menuTitle("Rename Workspace")) {
                    beginWorkspaceRename(workspace)
                }

                Button(ToasttyKeyboardShortcuts.closeWorkspace.menuTitle("Close workspace"), role: .destructive) {
                    requestWorkspaceClose(workspaceID: workspaceID)
                }
            }
        } else {
            row
        }
    }

    private func workspaceButton(
        workspaceID: UUID,
        workspace: WorkspaceState,
        shortcutLabel: String?,
        isSelected: Bool,
        sourceIndex: Int,
        orderedWorkspaceIDs: [UUID]
    ) -> some View {
        let sessionStatuses = sessionRuntimeStore.workspaceStatuses(for: workspace.id)

        return workspaceRowChrome(
            workspaceID: workspaceID,
            isSelected: isSelected,
            isFlashing: flashingWorkspaceID == workspaceID
        ) {
            VStack(alignment: .leading, spacing: 0) {
                workspaceHeaderContent {
                    workspacePrimaryContent(
                        workspace: workspace,
                        shortcutLabel: shortcutLabel,
                        selectionSubtitle: nil,
                        isSelected: isSelected
                    ) {
                        Text(workspace.title)
                            .font(isSelected ? ToastyTheme.fontWorkspaceName : ToastyTheme.fontWorkspaceNameInactive)
                            .foregroundStyle(isSelected ? ToastyTheme.primaryText : ToastyTheme.inactiveText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .background(workspaceHeaderFrameMeasurement(workspaceID: workspaceID))
                .contentShape(Rectangle())
                .overlay {
                    PointerInteractionRegion(
                        name: "workspace-sidebar-row",
                        metadata: [
                            "workspaceID": workspaceID.uuidString,
                            "sourceIndex": "\(sourceIndex)",
                        ],
                        onBegan: { _ in
                            beginWorkspaceInteraction(workspaceID: workspaceID)
                        },
                        onChanged: { value in
                            updateWorkspaceDrag(
                                workspaceID: workspaceID,
                                sourceIndex: sourceIndex,
                                orderedWorkspaceIDs: orderedWorkspaceIDs,
                                value: value
                            )
                        },
                        onEnded: { value in
                            finishWorkspaceInteraction(
                                workspaceID: workspaceID,
                                workspace: workspace,
                                value: value
                            )
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(workspace.title)
                .accessibilityAction {
                    handleWorkspaceButtonActivation(workspaceID: workspaceID, workspace: workspace)
                }

                if !sessionStatuses.isEmpty {
                    sessionStatusesContent(sessionStatuses, workspace: workspace)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 14)
                }
            }
        }
    }

    private func workspaceRenameRow(
        workspaceID: UUID,
        workspace: WorkspaceState,
        shortcutLabel: String?,
        isSelected: Bool,
        sourceIndex _: Int,
        orderedWorkspaceIDs _: [UUID]
    ) -> some View {
        let sessionStatuses = sessionRuntimeStore.workspaceStatuses(for: workspace.id)

        return workspaceRowChrome(
            workspaceID: workspaceID,
            isSelected: isSelected,
            isFlashing: flashingWorkspaceID == workspaceID
        ) {
            VStack(alignment: .leading, spacing: 0) {
                workspaceHeaderContent {
                    workspacePrimaryContent(
                        workspace: workspace,
                        shortcutLabel: shortcutLabel,
                        selectionSubtitle: nil,
                        isSelected: isSelected
                    ) {
                        WorkspaceRenameTextField(
                            text: $renameDraftTitle,
                            itemID: workspaceID,
                            placeholder: "Workspace name",
                            font: ToastyTheme.sidebarWorkspaceNameNSFont(isSelected: isSelected),
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
                }
                .background(workspaceHeaderFrameMeasurement(workspaceID: workspaceID))

                if !sessionStatuses.isEmpty {
                    sessionStatusesContent(sessionStatuses, workspace: workspace)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 14)
                }
            }
        }
    }

    private func workspaceRowChrome<Content: View>(
        workspaceID: UUID,
        isSelected: Bool,
        isFlashing: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? ToastyTheme.elevatedBackground
                : activeWorkspaceDrag == nil && hoveredWorkspaceID == workspaceID ? ToastyTheme.elevatedBackground
                : Color.clear)
            .overlay {
                Rectangle()
                    .fill(ToastyTheme.accent.opacity(0.28 * (isFlashing ? flashingSessionOverlayOpacity : 0)))
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isSelected ? ToastyTheme.accent : Color.clear)
                    .frame(width: 2)
            }
            .contentShape(Rectangle())
            .onHover { isHovering in
                guard activeWorkspaceDrag == nil else { return }
                if isHovering {
                    hoveredWorkspaceID = workspaceID
                } else if hoveredWorkspaceID == workspaceID {
                    hoveredWorkspaceID = nil
                }
            }
    }

    private func workspaceHeaderContent<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(.top, Self.sessionStatusesTopSpacing)
    }

    private func selectionSubtitle(for workspace: WorkspaceState) -> String? {
        let paneCount = workspace.layoutTree.allSlotInfos.count
        return workspaceSubtitle(paneCount: paneCount)
    }

    @ViewBuilder
    private func sessionStatusContent(
        _ workspaceSessionStatus: WorkspaceSessionStatus,
        workspace: WorkspaceState,
        isHovered: Bool
    ) -> some View {
        let status = workspaceSessionStatus.status
        let isLaterFlagged = sessionRuntimeStore.isLaterFlagged(sessionID: workspaceSessionStatus.sessionID)
        let showsUnreadSessionAccent = showsUnreadSessionAccent(
            for: workspaceSessionStatus.panelID,
            in: workspace
        )
        let accessibilityLabel = Self.sessionAccessibilityLabel(
            agentName: workspaceSessionStatus.displayTitle,
            chipKind: Self.sessionStatusChipKind(
                for: status,
                showsUnreadSessionAccent: showsUnreadSessionAccent
            ),
            detailText: normalizedSessionDetail(status.detail),
            cwd: Self.abbreviatedPathLabel(workspaceSessionStatus.cwd),
            isLaterFlagged: isLaterFlagged
        )
        let canFocusPanel = Self.canFocusSessionPanel(workspaceSessionStatus.panelID, in: workspace)
        let isActivePanel = store.selectedWorkspaceID(in: windowID) == workspace.id
            && store.selectedWorkspace(in: windowID)?.focusedPanelID == workspaceSessionStatus.panelID
        let isFlashing = flashingSessionPanelID == workspaceSessionStatus.panelID

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
                        isLaterFlagged: isLaterFlagged,
                        showsUnreadSessionAccent: showsUnreadSessionAccent,
                        isActivePanel: isActivePanel,
                        isHovered: isHovered,
                        isFlashing: isFlashing
                    )
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    guard activeWorkspaceDrag == nil else { return }
                    if isHovering {
                        hoveredPanelID = workspaceSessionStatus.panelID
                    } else if hoveredPanelID == workspaceSessionStatus.panelID {
                        hoveredPanelID = nil
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityIdentifier("sidebar.workspace.session.\(workspaceSessionStatus.sessionID)")
            } else {
                sessionStatusLabel(
                    workspaceSessionStatus,
                    status: status,
                    isLaterFlagged: isLaterFlagged,
                    showsUnreadSessionAccent: showsUnreadSessionAccent,
                    isActivePanel: isActivePanel,
                    isHovered: false,
                    isFlashing: isFlashing
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
            }
        }
        .contextMenu {
            if workspaceSessionStatus.agent != .processWatch {
                Button(
                    ToasttyKeyboardShortcuts.toggleLaterFlag.menuTitle(
                        Self.laterFlagActionTitle(isFlaggedForLater: isLaterFlagged)
                    )
                ) {
                    sessionRuntimeStore.setLaterFlag(
                        sessionID: workspaceSessionStatus.sessionID,
                        isFlagged: !isLaterFlagged
                    )
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        // SwiftUI context menus can collapse the hosted AppKit text tree into
        // drawing-only layers. Keep a zero-size hidden text bridge so row text
        // remains discoverable to host-based tests and AppKit inspectors.
        .background {
            SidebarSemanticTextBridge(text: accessibilityLabel)
                .frame(width: 0, height: 0)
        }
    }

    private func sessionStatusLabel(
        _ workspaceSessionStatus: WorkspaceSessionStatus,
        status: SessionStatus,
        isLaterFlagged: Bool,
        showsUnreadSessionAccent: Bool,
        isActivePanel: Bool,
        isHovered: Bool,
        isFlashing: Bool
    ) -> some View {
        let indicatorState = Self.sessionIndicatorState(for: status.kind)
        let chipKind = Self.sessionStatusChipKind(
            for: status,
            showsUnreadSessionAccent: showsUnreadSessionAccent
        )
        let borderColor = sessionStatusBorderColor(
            showsUnreadSessionAccent: showsUnreadSessionAccent,
            isHovered: isHovered
        )
        let flashOpacity = isFlashing ? flashingSessionOverlayOpacity : 0
        let detailText = normalizedSessionDetail(status.detail)

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if indicatorState != .hidden {
                    SessionStatusIndicator(state: indicatorState, size: 8, lineWidth: 1.4)
                }

                Self.styledSessionAgentText(
                    workspaceSessionStatus.displayTitle,
                    statusKind: status.kind,
                    showsUnreadSessionAccent: showsUnreadSessionAccent
                )
                    .foregroundStyle(ToastyTheme.sidebarSessionAgentText)
                    .lineLimit(1)

                if let chipKind {
                    sessionStatusChip(kind: chipKind)
                }

                Spacer(minLength: 0)

                if isLaterFlagged {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(
                            ToastyTheme.accent.opacity(showsUnreadSessionAccent ? 0.98 : 0.88)
                        )
                        .accessibilityHidden(true)
                } else if workspaceSessionStatus.agent == .processWatch {
                    // Watched processes cannot be flagged (see SessionRegistry.setLaterFlag),
                    // so this slot is mutually exclusive with the flag icon above.
                    Image(systemName: "bell.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(
                            ToastyTheme.sidebarSessionWatchIcon.opacity(showsUnreadSessionAccent ? 0.98 : 0.88)
                        )
                        .accessibilityHidden(true)
                }
            }

            if status.kind != .idle || detailText != nil {
                sessionDetailLabel(
                    detailText ?? " ",
                    statusKind: status.kind,
                    showsUnreadSessionAccent: showsUnreadSessionAccent
                )
            }

            if let cwd = Self.abbreviatedPathLabel(workspaceSessionStatus.cwd) {
                Text(cwd)
                    .font(ToastyTheme.fontWorkspaceSessionPath)
                    .fontWeight(Self.sessionBodyFontWeight(showsUnreadSessionAccent: showsUnreadSessionAccent))
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
                .fill(
                    sessionStatusBackgroundColor(
                        showsUnreadSessionAccent: showsUnreadSessionAccent,
                        isActivePanel: isActivePanel,
                        isHovered: isHovered
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .fill(ToastyTheme.accent.opacity(0.42 * flashOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(borderColor, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(ToastyTheme.accent.opacity(flashOpacity), lineWidth: 1.75)
        )
        .contentShape(RoundedRectangle(cornerRadius: 5))
    }

    private func workspaceHeaderFrameMeasurement(workspaceID: UUID) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: WorkspaceHeaderFramePreferenceKey.self,
                value: [
                    workspaceID: geometry.frame(in: .named(SidebarWorkspaceListCoordinateSpace.name))
                ]
            )
        }
    }

    nonisolated static func workspaceDragActivationExceeded(translation: CGSize) -> Bool {
        abs(translation.height) >= workspaceDragActivationDistance
    }

    nonisolated static func pointerMovementWithinTapTolerance(translation: CGSize) -> Bool {
        let distanceSquared = (translation.width * translation.width) + (translation.height * translation.height)
        return distanceSquared < (workspaceDragActivationDistance * workspaceDragActivationDistance)
    }

    private func updateWorkspaceDrag(
        workspaceID: UUID,
        sourceIndex: Int,
        orderedWorkspaceIDs: [UUID],
        value: PointerInteractionValue
    ) {
        let baseMetadata = workspaceDragLogMetadata(
            workspaceID: workspaceID,
            sourceIndex: sourceIndex,
            value: value
        )
        if renamingWorkspaceID != nil {
            ToasttyLog.info(
                "workspace sidebar drag ignored",
                category: .input,
                metadata: baseMetadata.merging(["reason": "renaming-workspace"], uniquingKeysWith: { _, new in new })
            )
            return
        }
        guard Self.workspaceDragActivationExceeded(translation: value.translation) else {
            ToasttyLog.info(
                "workspace sidebar drag below activation threshold",
                category: .input,
                metadata: baseMetadata
            )
            return
        }

        hoveredWorkspaceID = nil
        hoveredPanelID = nil

        var dragState = activeWorkspaceDrag
        if dragState?.workspaceID != workspaceID {
            let startPointerY = (measuredWorkspaceHeaderFramesByID[workspaceID]?.minY ?? 0) + value.startLocation.y
            dragState = WorkspaceDragState(
                workspaceID: workspaceID,
                sourceIndex: sourceIndex,
                startPointerY: startPointerY,
                translationHeight: value.translation.height,
                targetIndex: sourceIndex
            )
            ToasttyLog.info(
                "workspace sidebar drag activated",
                category: .input,
                metadata: baseMetadata.merging(
                    [
                        "startPointerY": "\(startPointerY)",
                        "orderedWorkspaceCount": "\(orderedWorkspaceIDs.count)",
                    ],
                    uniquingKeysWith: { _, new in new }
                )
            )
        } else {
            dragState?.translationHeight = value.translation.height
        }

        let pointerY = (dragState?.startPointerY ?? value.location.y) + value.translation.height
        let targetIndex = Self.workspaceReorderTargetIndex(
            orderedWorkspaceIDs: orderedWorkspaceIDs,
            measuredHeaderFramesByID: measuredWorkspaceHeaderFramesByID,
            draggedWorkspaceID: workspaceID,
            pointerY: pointerY
        ) ?? sourceIndex
        let previousTargetIndex = dragState?.targetIndex
        dragState?.targetIndex = targetIndex
        activeWorkspaceDrag = dragState
        if previousTargetIndex != targetIndex {
            ToasttyLog.info(
                "workspace sidebar drag target changed",
                category: .input,
                metadata: baseMetadata.merging(
                    [
                        "pointerY": "\(pointerY)",
                        "targetIndex": "\(targetIndex)",
                        "previousTargetIndex": previousTargetIndex.map(String.init) ?? "nil",
                    ],
                    uniquingKeysWith: { _, new in new }
                )
            )
        }
    }

    private func finishWorkspaceInteraction(
        workspaceID: UUID,
        workspace: WorkspaceState,
        value: PointerInteractionValue
    ) {
        if activeWorkspaceDrag?.workspaceID == workspaceID {
            ToasttyLog.info(
                "workspace sidebar drag finishing",
                category: .input,
                metadata: workspaceDragLogMetadata(workspaceID: workspaceID, sourceIndex: nil, value: value)
            )
            finishWorkspaceDrag()
            return
        }

        guard activeWorkspaceDrag == nil else { return }
        guard Self.pointerMovementWithinTapTolerance(translation: value.translation) else { return }
        ToasttyLog.info(
            "workspace sidebar pointer ended as tap",
            category: .input,
            metadata: workspaceDragLogMetadata(workspaceID: workspaceID, sourceIndex: nil, value: value)
        )
        handleWorkspaceButtonActivation(workspaceID: workspaceID, workspace: workspace)
    }

    private func finishWorkspaceDrag() {
        guard let activeWorkspaceDrag else { return }
        cancelWorkspaceDrag()

        guard activeWorkspaceDrag.targetIndex != activeWorkspaceDrag.sourceIndex else {
            ToasttyLog.info(
                "workspace sidebar drag finished without reorder",
                category: .input,
                metadata: [
                    "workspaceID": activeWorkspaceDrag.workspaceID.uuidString,
                    "sourceIndex": "\(activeWorkspaceDrag.sourceIndex)",
                    "targetIndex": "\(activeWorkspaceDrag.targetIndex)",
                    "translationHeight": "\(activeWorkspaceDrag.translationHeight)",
                ]
            )
            return
        }
        ToasttyLog.info(
            "workspace sidebar drag committing reorder",
            category: .input,
            metadata: [
                "workspaceID": activeWorkspaceDrag.workspaceID.uuidString,
                "sourceIndex": "\(activeWorkspaceDrag.sourceIndex)",
                "targetIndex": "\(activeWorkspaceDrag.targetIndex)",
                "translationHeight": "\(activeWorkspaceDrag.translationHeight)",
            ]
        )
        _ = store.send(
            .moveWorkspace(
                windowID: windowID,
                fromIndex: activeWorkspaceDrag.sourceIndex,
                toIndex: activeWorkspaceDrag.targetIndex
            )
        )
    }

    private func cancelWorkspaceDrag() {
        activeWorkspaceDrag = nil
    }

    private func beginWorkspaceInteraction(workspaceID: UUID) {
        guard let activeWorkspaceDrag else { return }
        ToasttyLog.info(
            "workspace sidebar stale drag cancelled on new pointer sequence",
            category: .input,
            metadata: [
                "newWorkspaceID": workspaceID.uuidString,
                "activeWorkspaceID": activeWorkspaceDrag.workspaceID.uuidString,
                "sourceIndex": "\(activeWorkspaceDrag.sourceIndex)",
                "targetIndex": "\(activeWorkspaceDrag.targetIndex)",
                "translationHeight": "\(activeWorkspaceDrag.translationHeight)",
            ]
        )
        cancelWorkspaceDrag()
    }

    private func workspaceDragLogMetadata(
        workspaceID: UUID,
        sourceIndex: Int?,
        value: PointerInteractionValue
    ) -> [String: String] {
        var metadata: [String: String] = [
            "workspaceID": workspaceID.uuidString,
            "startLocation": DraggableInteractionLog.pointDescription(value.startLocation),
            "location": DraggableInteractionLog.pointDescription(value.location),
            "translation": DraggableInteractionLog.sizeDescription(value.translation),
        ]
        if let sourceIndex {
            metadata["sourceIndex"] = "\(sourceIndex)"
        }
        if let activeWorkspaceDrag {
            metadata["activeWorkspaceID"] = activeWorkspaceDrag.workspaceID.uuidString
            metadata["activeSourceIndex"] = "\(activeWorkspaceDrag.sourceIndex)"
            metadata["activeTargetIndex"] = "\(activeWorkspaceDrag.targetIndex)"
            metadata["activeTranslationHeight"] = "\(activeWorkspaceDrag.translationHeight)"
        }
        if let measuredFrame = measuredWorkspaceHeaderFramesByID[workspaceID] {
            metadata["measuredFrame"] = DraggableInteractionLog.rectDescription(measuredFrame)
        }
        return metadata
    }

    @MainActor
    private func schedulePendingSidebarSessionFlashRequestHandling() {
        DispatchQueue.main.async {
            handlePendingSidebarSessionFlashRequest()
        }
    }

    @MainActor
    private func handlePendingSidebarSessionFlashRequest() {
        guard let request = store.pendingSidebarSessionFlashRequest,
              request.windowID == windowID,
              lastHandledSidebarFlashRequestID != request.requestID else {
            return
        }

        guard let consumedRequest = store.consumePendingSidebarSessionFlashRequest(
            windowID: windowID,
            requestID: request.requestID
        ) else {
            return
        }

        lastHandledSidebarFlashRequestID = consumedRequest.requestID
        if let panelID = consumedRequest.panelID,
           sessionRuntimeStore
            .workspaceStatuses(for: consumedRequest.workspaceID)
            .contains(where: { $0.panelID == panelID }) {
            flashSidebarSelection(
                workspaceID: nil,
                panelID: panelID,
                requestID: consumedRequest.requestID
            )
        } else {
            flashSidebarSelection(
                workspaceID: consumedRequest.workspaceID,
                panelID: nil,
                requestID: consumedRequest.requestID
            )
        }
    }

    @MainActor
    private func flashSidebarSelection(
        workspaceID: UUID?,
        panelID: UUID?,
        requestID: UUID
    ) {
        activeSidebarFlashRequestID = requestID
        sidebarFlashClearWorkItem?.cancel()
        sidebarFlashResetWorkItem?.cancel()
        sidebarFlashClearWorkItem = nil
        sidebarFlashResetWorkItem = nil
        flashingWorkspaceID = workspaceID
        flashingSessionPanelID = panelID
        flashingSessionOverlayOpacity = 0

        withAnimation(.easeOut(duration: 0.08)) {
            flashingSessionOverlayOpacity = 1
        }

        let clearWorkItem = DispatchWorkItem { [requestID] in
            guard activeSidebarFlashRequestID == requestID else { return }
            sidebarFlashClearWorkItem = nil
            withAnimation(.easeOut(duration: Self.sessionFlashSettleDuration)) {
                flashingSessionOverlayOpacity = 0
            }
        }
        sidebarFlashClearWorkItem = clearWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.sessionFlashPeakDuration,
            execute: clearWorkItem
        )

        let resetWorkItem = DispatchWorkItem { [requestID] in
            guard activeSidebarFlashRequestID == requestID else { return }
            activeSidebarFlashRequestID = nil
            flashingWorkspaceID = nil
            flashingSessionPanelID = nil
            flashingSessionOverlayOpacity = 0
            sidebarFlashResetWorkItem = nil
        }
        sidebarFlashResetWorkItem = resetWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.sessionFlashPeakDuration + Self.sessionFlashSettleDuration,
            execute: resetWorkItem
        )
    }

    private func sessionStatusBackgroundColor(
        showsUnreadSessionAccent: Bool,
        isActivePanel: Bool,
        isHovered: Bool
    ) -> Color {
        if isActivePanel {
            return isHovered ? ToastyTheme.sidebarSessionActiveHoverBackground
                : ToastyTheme.sidebarSessionActiveBackground
        }
        if showsUnreadSessionAccent {
            return ToastyTheme.sidebarSessionUnreadBackground
        }
        return isHovered ? ToastyTheme.sidebarSessionHoverBackground : Color.clear
    }

    private func sessionStatusBorderColor(
        showsUnreadSessionAccent: Bool,
        isHovered: Bool
    ) -> Color {
        if showsUnreadSessionAccent {
            return ToastyTheme.sidebarSessionUnreadBorder
        }
        return isHovered ? ToastyTheme.sidebarSessionHoverBorder : Color.clear
    }

    private func sessionStatusChip(kind: SessionStatusKind) -> some View {
        Text(Self.sessionStatusChipLabel(for: kind))
            .font(ToastyTheme.fontWorkspaceSessionChip)
            .foregroundStyle(ToastyTheme.sessionStatusTextColor(for: kind))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                ToastyTheme.sessionStatusBackgroundColor(for: kind),
                in: RoundedRectangle(cornerRadius: 4)
            )
    }

    @ViewBuilder
    private func sessionDetailLabel(
        _ text: String,
        statusKind: SessionStatusKind,
        showsUnreadSessionAccent: Bool
    ) -> some View {
        // Keep weight inside the Font itself instead of chaining
        // `.fontWeight(...)` after `.italic()`. For these small sidebar labels,
        // SwiftUI can otherwise collapse the italicized detail text back to the
        // upright face.
        let styled = Self.styledSessionDetailText(
            text,
            statusKind: statusKind,
            showsUnreadSessionAccent: showsUnreadSessionAccent
        )

        // Fixed 2-line height prevents sidebar jitter as summaries
        // stream in at varying lengths. The placeholder sets the
        // intrinsic height; the real text overlays it.
        styled
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

    private func normalizedSessionDetail(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
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
        _ = store.focusExplicitlyNavigatedPanel(
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID
        )
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
        scrollRequestObserver?(selectedWorkspaceID, animated)

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

    private func pruneTransientWorkspaceDragState() {
        guard let window = store.window(id: windowID) else {
            measuredWorkspaceHeaderFramesByID = [:]
            cancelWorkspaceDrag()
            return
        }

        let workspaceIDs = Set(window.workspaceIDs)
        measuredWorkspaceHeaderFramesByID = measuredWorkspaceHeaderFramesByID.filter { workspaceIDs.contains($0.key) }
        if let activeWorkspaceDrag,
           workspaceIDs.contains(activeWorkspaceDrag.workspaceID) == false {
            cancelWorkspaceDrag()
        }
    }

    private func workspaceSubtitle(paneCount: Int) -> String {
        paneCount == 1 ? "1 pane" : "\(paneCount) panes"
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

    static func sessionStatusChipKind(
        for status: SessionStatus,
        showsUnreadSessionAccent: Bool
    ) -> SessionStatusKind? {
        switch status.kind {
        case .needsApproval, .error:
            return status.kind
        case .ready:
            return showsUnreadSessionAccent ? .ready : nil
        case .idle, .working:
            return nil
        }
    }

    static func sessionStatusChipLabel(for kind: SessionStatusKind) -> String {
        switch kind {
        case .needsApproval:
            return "needs approval"
        case .ready:
            return "ready"
        case .error:
            return "error"
        case .idle, .working:
            return ""
        }
    }

    static func laterFlagActionTitle(isFlaggedForLater: Bool) -> String {
        isFlaggedForLater ? "Clear Later Flag" : "Flag for Later"
    }

    static func sessionAccessibilityLabel(
        agentName: String,
        chipKind: SessionStatusKind?,
        detailText: String?,
        cwd: String?,
        isLaterFlagged: Bool
    ) -> String {
        var components = [agentName]
        if let chipKind {
            components.append(sessionStatusChipLabel(for: chipKind))
        }
        if let detailText {
            components.append(detailText)
        }
        if let cwd {
            components.append(cwd)
        }
        if isLaterFlagged {
            components.append("flagged for later")
        }
        return components.joined(separator: ", ")
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

    static func sessionAgentFontWeight(showsUnreadSessionAccent: Bool) -> Font.Weight {
        showsUnreadSessionAccent ? .heavy : .medium
    }

    static func sessionBodyFontWeight(showsUnreadSessionAccent: Bool) -> Font.Weight {
        showsUnreadSessionAccent ? .bold : .regular
    }

    static func sessionTextUsesItalic(for kind: SessionStatusKind) -> Bool {
        kind == .working
    }

    static func styledSessionAgentText(
        _ text: String,
        statusKind: SessionStatusKind,
        showsUnreadSessionAccent: Bool
    ) -> Text {
        styledSessionText(
            text,
            font: ToastyTheme.workspaceSessionAgentFont(
                weight: sessionAgentFontWeight(showsUnreadSessionAccent: showsUnreadSessionAccent)
            ),
            usesItalic: sessionTextUsesItalic(for: statusKind)
        )
    }

    static func styledSessionDetailText(
        _ text: String,
        statusKind: SessionStatusKind,
        showsUnreadSessionAccent: Bool
    ) -> Text {
        styledSessionText(
            text,
            font: ToastyTheme.workspaceSessionDetailFont(
                weight: sessionBodyFontWeight(showsUnreadSessionAccent: showsUnreadSessionAccent)
            ),
            usesItalic: sessionTextUsesItalic(for: statusKind)
        )
    }

    static func styledSessionText(
        _ text: String,
        font: Font,
        usesItalic: Bool
    ) -> Text {
        let base = Text(text).font(font)
        return usesItalic ? base.italic() : base
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

private enum SidebarWorkspaceListCoordinateSpace {
    static let name = "sidebar-workspaces.list"
}

private struct WorkspaceHeaderFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
