import AppKit
import CoreState
import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore
    @State private var renamingWorkspaceID: UUID?
    @State private var renameDraftTitle = ""
    @State private var pendingWorkspaceClose: PendingWorkspaceClose?
    @State private var hoveredPanelID: UUID?
    @FocusState private var focusedRenameWorkspaceID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Logo header: orange icon + "Toastty"
            HStack(spacing: 8) {
                Text("T")
                    .font(.system(size: 11, weight: .heavy, design: .default))
                    .foregroundStyle(ToastyTheme.accentDark)
                    .frame(width: 20, height: 20)
                    .background(ToastyTheme.accent, in: RoundedRectangle(cornerRadius: 5))

                Text("Toastty")
                    .font(ToastyTheme.fontLogoTitle)
                    .foregroundStyle(ToastyTheme.primaryText)
                    .tracking(-0.26) // -0.02em at 13px
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .padding(.bottom, 6)
            .accessibilityIdentifier("sidebar.workspaces.title")

            if let window = store.selectedWindow {
                ForEach(Array(window.workspaceIDs.enumerated()), id: \.element) { index, workspaceID in
                    if let workspace = store.state.workspacesByID[workspaceID] {
                        workspaceRow(
                            workspaceID: workspaceID,
                            workspace: workspace,
                            shortcutLabel: "⌘\(index + 1)",
                            isSelected: window.selectedWorkspaceID == workspaceID,
                            index: index + 1
                        )
                    }
                }
            } else {
                Text("No windows")
                    .font(ToastyTheme.fontBody)
                    .foregroundStyle(ToastyTheme.mutedText)
            }

            Spacer(minLength: 0)

            // New workspace button — full-width, matches workspace item sizing
            Button {
                guard let windowID = store.selectedWindow?.id else { return }
                cancelWorkspaceRename()
                store.send(.createWorkspace(windowID: windowID, title: nil))
            } label: {
                HStack(spacing: 6) {
                    // Plus icon matching 11×11 stroke icon language
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
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(ToastyTheme.chromeBackground)
        .alert(
            "Close this workspace?",
            isPresented: pendingWorkspaceCloseBinding,
            presenting: pendingWorkspaceClose
        ) { closeTarget in
            Button("Cancel", role: .cancel) {
                pendingWorkspaceClose = nil
            }
            Button("Close", role: .destructive) {
                confirmWorkspaceClose(closeTarget.workspaceID)
            }
        } message: { _ in
            Text("Closing this workspace will close all terminals and panels within it.")
        }
        .onChange(of: store.state.workspacesByID) { _, _ in
            pruneTransientSidebarState()
        }
    }

    @ViewBuilder
    private func workspaceRow(
        workspaceID: UUID,
        workspace: WorkspaceState,
        shortcutLabel: String,
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
            Button("Rename") {
                beginWorkspaceRename(workspace)
            }
            Button("Close", role: .destructive) {
                requestWorkspaceClose(workspaceID: workspaceID)
            }
        }
        .accessibilityIdentifier("sidebar.workspace.\(index)")
    }

    private func workspaceButton(
        workspaceID: UUID,
        workspace: WorkspaceState,
        shortcutLabel: String,
        isSelected: Bool
    ) -> some View {
        let sessionStatuses = sessionRuntimeStore.workspaceStatuses(for: workspace.id)

        return workspaceRowChrome(isSelected: isSelected) {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    handleWorkspaceButtonActivation(workspaceID: workspaceID, workspace: workspace)
                } label: {
                    workspacePrimaryContent(
                        shortcutLabel: shortcutLabel,
                        selectionSubtitle: selectionSubtitle(for: workspace, sessionStatuses: sessionStatuses),
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
        shortcutLabel: String,
        isSelected: Bool
    ) -> some View {
        let sessionStatuses = sessionRuntimeStore.workspaceStatuses(for: workspace.id)

        return workspaceRowChrome(isSelected: isSelected) {
            VStack(alignment: .leading, spacing: 2) {
                workspacePrimaryContent(
                    shortcutLabel: shortcutLabel,
                    selectionSubtitle: selectionSubtitle(for: workspace, sessionStatuses: sessionStatuses),
                    isSelected: isSelected
                ) {
                    TextField("Workspace name", text: $renameDraftTitle)
                        .textFieldStyle(.plain)
                        .font(ToastyTheme.fontWorkspaceName)
                        .foregroundStyle(ToastyTheme.primaryText)
                        .focused($focusedRenameWorkspaceID, equals: workspaceID)
                        .accessibilityIdentifier(renameTextFieldAccessibilityID(for: workspaceID))
                        .onSubmit {
                            commitWorkspaceRename(workspaceID: workspaceID)
                        }
                        .onExitCommand {
                            cancelWorkspaceRename()
                        }
                        .onAppear {
                            focusedRenameWorkspaceID = workspaceID
                            scheduleRenameSelection(workspaceID: workspaceID)
                        }
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
        // Left accent border: orange for selected, transparent for others
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isSelected ? ToastyTheme.accent : Color.clear)
                .frame(width: 2)
        }
        .contentShape(Rectangle())
    }

    private func workspacePrimaryContent<Title: View>(
        shortcutLabel: String,
        selectionSubtitle: String?,
        isSelected: Bool,
        @ViewBuilder titleView: () -> Title
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                titleView()

                Spacer(minLength: 0)

                shortcutBadge(shortcutLabel)
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

    private var pendingWorkspaceCloseBinding: Binding<Bool> {
        Binding(
            get: { pendingWorkspaceClose != nil },
            set: { isPresented in
                if !isPresented {
                    pendingWorkspaceClose = nil
                }
            }
        )
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

    private func selectionSubtitle(
        for workspace: WorkspaceState,
        sessionStatuses: [WorkspaceSessionStatus]
    ) -> String? {
        guard sessionStatuses.isEmpty || sessionStatuses.contains(where: { $0.status.kind == .working }) else {
            return nil
        }
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
        let showsUnreadIndicator = workspace.unreadPanelIDs.contains(workspaceSessionStatus.panelID)
        let canFocusPanel = workspace.panels[workspaceSessionStatus.panelID] != nil

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
                        showsUnreadIndicator: showsUnreadIndicator,
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
                    showsUnreadIndicator: showsUnreadIndicator,
                    isHovered: false
                )
            }
        }
    }

    private func sessionStatusLabel(
        _ workspaceSessionStatus: WorkspaceSessionStatus,
        status: SessionStatus,
        showsUnreadIndicator: Bool,
        isHovered: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if showsUnreadIndicator {
                    sessionStatusIndicator(for: workspaceSessionStatus.status.kind)
                }

                Text(workspaceSessionStatus.agent.rawValue)
                    .font(ToastyTheme.fontWorkspaceSessionAgent)
                    .foregroundStyle(ToastyTheme.sidebarSessionAgentText)
                    .lineLimit(1)

                sessionStatusChip(status)

                Spacer(minLength: 0)
            }

            if let detail = status.detail {
                Text(detail)
                    .font(ToastyTheme.fontWorkspaceSessionDetail)
                    .foregroundStyle(ToastyTheme.sidebarSessionDetailText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if let cwd = abbreviatedPathLabel(workspaceSessionStatus.cwd) {
                Text(cwd)
                    .font(ToastyTheme.fontWorkspaceSessionPath)
                    .foregroundStyle(ToastyTheme.sidebarSessionPathText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? ToastyTheme.sidebarSessionHoverBackground : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isHovered ? ToastyTheme.sidebarSessionHoverBorder : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 4))
    }

    private func handleWorkspaceButtonActivation(workspaceID: UUID, workspace: WorkspaceState) {
        if let currentEvent = NSApp.currentEvent,
           currentEvent.type == .leftMouseUp,
           currentEvent.clickCount == 2 {
            beginWorkspaceRename(workspace)
            return
        }

        guard let windowID = store.selectedWindow?.id else { return }
        cancelWorkspaceRename()
        store.send(.selectWorkspace(windowID: windowID, workspaceID: workspaceID))
    }

    private func focusSessionPanel(workspaceID: UUID, panelID: UUID) {
        guard let windowID = store.selectedWindow?.id else { return }
        cancelWorkspaceRename()

        if store.selectedWorkspace?.id != workspaceID {
            _ = store.send(.selectWorkspace(windowID: windowID, workspaceID: workspaceID))
        }

        _ = store.send(.focusPanel(workspaceID: workspaceID, panelID: panelID))
        terminalRuntimeRegistry.scheduleSelectedWorkspaceSlotFocusRestore()
    }

    private func beginWorkspaceRename(_ workspace: WorkspaceState) {
        renamingWorkspaceID = workspace.id
        renameDraftTitle = workspace.title
        focusedRenameWorkspaceID = workspace.id
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
        focusedRenameWorkspaceID = nil
        renameDraftTitle = ""
    }

    private func scheduleWorkspaceSlotFocusRestore(attempt: Int = 0) {
        let delay = attempt == 0 ? 0 : 16
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) {
            if terminalRuntimeRegistry.focusSelectedWorkspaceSlotIfPossible() {
                return
            }

            guard attempt < 12 else { return }
            scheduleWorkspaceSlotFocusRestore(attempt: attempt + 1)
        }
    }

    private func scheduleRenameSelection(workspaceID: UUID, attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) {
            guard renamingWorkspaceID == workspaceID,
                  focusedRenameWorkspaceID == workspaceID else { return }

            if let editor = currentRenameEditor(workspaceID: workspaceID) {
                editor.selectAll(nil)
                return
            }

            guard attempt < 12 else { return }
            scheduleRenameSelection(workspaceID: workspaceID, attempt: attempt + 1)
        }
    }

    private func currentRenameEditor(workspaceID: UUID) -> NSTextView? {
        guard let keyWindow = NSApp.keyWindow,
              let editor = keyWindow.firstResponder as? NSTextView,
              let textField = editor.delegate as? NSTextField else {
            return nil
        }

        let expectedIdentifier = renameTextFieldAccessibilityID(for: workspaceID)
        guard textField.accessibilityIdentifier() == expectedIdentifier else { return nil }
        return editor
    }

    private func renameTextFieldAccessibilityID(for workspaceID: UUID) -> String {
        "sidebar.workspace.rename.\(workspaceID.uuidString)"
    }

    private func requestWorkspaceClose(workspaceID: UUID) {
        guard store.state.workspacesByID[workspaceID] != nil else { return }
        pendingWorkspaceClose = PendingWorkspaceClose(workspaceID: workspaceID)
    }

    private func confirmWorkspaceClose(_ workspaceID: UUID) {
        pendingWorkspaceClose = nil
        if renamingWorkspaceID == workspaceID {
            cancelWorkspaceRename()
        }
        _ = store.send(.closeWorkspace(workspaceID: workspaceID))
    }

    private func pruneTransientSidebarState() {
        if let renamingWorkspaceID,
           store.state.workspacesByID[renamingWorkspaceID] == nil {
            cancelWorkspaceRename()
        }

        if let pendingWorkspaceClose,
           store.state.workspacesByID[pendingWorkspaceClose.workspaceID] == nil {
            self.pendingWorkspaceClose = nil
        }
    }

    private struct PendingWorkspaceClose: Identifiable {
        let workspaceID: UUID

        var id: UUID { workspaceID }
    }

    /// Build a subtitle string like "3 panes · dev server running" or "1 pane"
    private func workspaceSubtitle(workspace: WorkspaceState, paneCount: Int) -> String {
        let paneLabel = paneCount == 1 ? "1 pane" : "\(paneCount) panes"
        if let activitySubtext = terminalRuntimeRegistry.workspaceActivitySubtext(for: workspace.id),
           activitySubtext.isEmpty == false {
            return "\(paneLabel) · \(activitySubtext)"
        }
        return paneLabel
    }

    private func sessionStatusChip(_ status: SessionStatus) -> some View {
        Text(status.summary)
            .font(ToastyTheme.fontWorkspaceSessionChip)
            .foregroundStyle(ToastyTheme.sessionStatusTextColor(for: status.kind))
            .padding(.horizontal, 4)
            .background(
                ToastyTheme.sessionStatusBackgroundColor(for: status.kind),
                in: RoundedRectangle(cornerRadius: 2)
            )
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func sessionStatusIndicator(for kind: SessionStatusKind) -> some View {
        let indicatorColor = ToastyTheme.sessionStatusIndicatorColor(for: kind)

        return Circle()
            .fill(indicatorColor)
            .frame(width: 7, height: 7)
            .shadow(color: indicatorColor.opacity(0.45), radius: 3, x: 0, y: 0)
    }

    private func abbreviatedPathLabel(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return (trimmed as NSString).abbreviatingWithTildeInPath
    }

    /// Reusable keyboard shortcut badge pill (e.g. "⌘1", "⌘⇧N").
    private func shortcutBadge(_ label: String) -> some View {
        Text(label)
            .font(ToastyTheme.fontShortcutBadge)
            .foregroundStyle(ToastyTheme.shortcutBadgeText)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(ToastyTheme.hairline, in: RoundedRectangle(cornerRadius: 3))
    }
}

/// Keeps sidebar rows visually stable while pressed (no default plain-style press highlight flash).
private struct SidebarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
