import CoreState
import SwiftUI

/// What the sidebar shows for one Inbox task. Kept apart from the view so
/// the words can be tested without hosting it.
struct SidebarInboxRowPresentation: Equatable {
    var title: String
    var detail: String
    var tag: String
    var needsUser: Bool

    static func make(
        _ item: TaskInboxItem,
        workspaceTitle: (UUID) -> String?,
        now: Date
    ) -> Self {
        switch item.phase {
        case .routing:
            return .init(
                title: item.displayTitle,
                detail: "\(sourceLabel(item.source)) · \(ageLabel(from: item.createdAt, to: now))",
                tag: "routing…",
                needsUser: false
            )
        case .settingUp:
            return .init(
                title: item.displayTitle,
                detail: item.plan.map { planLabel($0, workspaceTitle: workspaceTitle) } ?? "Setting up",
                tag: "setting up",
                needsUser: false
            )
        case .needsWorkspace:
            return .init(
                title: item.displayTitle,
                detail: item.problem ?? TaskPlacementProblem.noWorkspace.message,
                tag: "⚠ pick a workspace",
                needsUser: true
            )
        case .setupFailed:
            return .init(
                title: item.displayTitle,
                detail: item.problem ?? "Setup failed.",
                tag: "⚠ setup failed",
                needsUser: true
            )
        }
    }

    var accessibilityLabel: String {
        "\(title), Inbox task, \(tag.replacingOccurrences(of: "⚠ ", with: "")), \(detail)"
    }

    static func sourceLabel(_ source: TaskInboxItem.Source) -> String {
        switch source {
        case .mac: "Mac"
        case .cli: "CLI"
        }
    }

    static func ageLabel(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86_400: return "\(seconds / 3600) h ago"
        default: return "\(seconds / 86_400) d ago"
        }
    }

    static func planLabel(_ plan: TaskInboxItem.Plan, workspaceTitle: (UUID) -> String?) -> String {
        var parts = ["→ " + (workspaceTitle(plan.workspaceID) ?? "workspace"), plan.profileID]
        if let model = plan.model { parts.append(model) }
        return parts.joined(separator: " · ")
    }
}

/// The Inbox group at the top of the sidebar: quick tasks that have no
/// task space yet. Hidden when empty. Task state uses a dashed box and a
/// plain word tag, never a session status color, because no session
/// exists yet.
struct SidebarInboxSection: View {
    @ObservedObject var inbox: TaskInboxStore
    @ObservedObject var store: AppStore
    let coordinator: TaskInboxCoordinator?

    @State private var isExpanded = true
    @State private var hoveredTaskID: UUID?
    @State private var presentedTaskID: UUID?

    private static let railWidth: CGFloat = 12
    private static let railGap: CGFloat = 6
    private static let lineMinHeight: CGFloat = 17

    var body: some View {
        if inbox.items.isEmpty == false {
            VStack(alignment: .leading, spacing: 3) {
                header
                if isExpanded {
                    TimelineView(.periodic(from: .now, by: 30)) { timeline in
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(inbox.items) { item in
                                row(item, now: timeline.date)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, 2)
            .padding(.bottom, 10)
            .accessibilityIdentifier("sidebar.inbox")
        }
    }

    private var header: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 9)
                Text("INBOX")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                Text("\(inbox.items.count)")
                    .font(ToastyTheme.fontWorkspaceAgentCount)
                    .foregroundStyle(ToastyTheme.sidebarSessionPathText)
                Spacer(minLength: 0)
            }
            .foregroundStyle(ToastyTheme.sidebarChildContextText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 16)
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .accessibilityLabel("Inbox, \(inbox.items.count) \(inbox.items.count == 1 ? "task" : "tasks"), \(isExpanded ? "expanded" : "collapsed")")
        .accessibilityIdentifier("sidebar.inbox.toggle")
        .background {
            SidebarSemanticTextBridge(text: "Inbox, \(inbox.items.count) \(inbox.items.count == 1 ? "task" : "tasks")")
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }

    private func row(_ item: TaskInboxItem, now: Date) -> some View {
        let presentation = SidebarInboxRowPresentation.make(
            item,
            workspaceTitle: { store.state.workspacesByID[$0]?.title },
            now: now
        )
        let isHovered = hoveredTaskID == item.id
        let isPresented = Binding(
            get: { presentedTaskID == item.id },
            set: { if $0 { presentedTaskID = item.id } else if presentedTaskID == item.id { presentedTaskID = nil } }
        )
        return HStack(alignment: .top, spacing: Self.railGap) {
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(ToastyTheme.sidebarChildContextText, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                .frame(width: 10, height: 10)
                .frame(width: Self.railWidth, height: Self.lineMinHeight)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                SidebarView.styledSessionNameText(presentation.title, isEmphasized: false)
                    .foregroundStyle(ToastyTheme.sidebarSessionAgentText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minHeight: Self.lineMinHeight, alignment: .leading)
                HStack(spacing: 6) {
                    SidebarView.styledSessionSummaryText(presentation.detail)
                        .foregroundStyle(ToastyTheme.sidebarSummaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text(presentation.tag)
                        .font(ToastyTheme.fontWorkspaceSessionChip)
                        .foregroundStyle(ToastyTheme.sidebarSessionPathText)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(ToastyTheme.sidebarWorkspaceTagBackground, in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? ToastyTheme.sidebarSessionHoverBackground : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(isHovered ? ToastyTheme.sidebarSessionHoverBorder : Color.clear, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onTapGesture { presentedTaskID = item.id }
        .onHover { isHovering in
            if isHovering {
                hoveredTaskID = item.id
            } else if hoveredTaskID == item.id {
                hoveredTaskID = nil
            }
        }
        .popover(isPresented: isPresented, arrowEdge: .trailing) {
            if let coordinator {
                TaskInboxPopover(taskID: item.id, inbox: inbox, coordinator: coordinator) {
                    presentedTaskID = nil
                }
            }
        }
        .contextMenu {
            if let coordinator {
                Button("Show Task…") { presentedTaskID = item.id }
                if item.phase == .needsWorkspace || item.phase == .setupFailed {
                    Button(item.phase == .setupFailed ? "Retry Setup" : "Retry Triage") {
                        try? coordinator.retry(taskID: item.id)
                    }
                }
                Divider()
                Button("Delete Task", role: .destructive) {
                    coordinator.delete(taskID: item.id)
                }
            }
        }
        .background {
            SidebarSemanticTextBridge(text: presentation.accessibilityLabel)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) { presentedTaskID = item.id }
        .accessibilityIdentifier("sidebar.inbox.task.\(item.id.uuidString)")
    }
}

/// Opened from an Inbox row: the whole task, why it waits, and the actions
/// that move it on.
struct TaskInboxPopover: View {
    let taskID: UUID
    @ObservedObject var inbox: TaskInboxStore
    let coordinator: TaskInboxCoordinator
    let dismiss: () -> Void

    @State private var selectedWorkspaceID: UUID?
    @State private var errorMessage: String?

    var body: some View {
        if let item = inbox.item(id: taskID) {
            content(item)
                .frame(width: 320, alignment: .leading)
                .onAppear { selectedWorkspaceID = defaultWorkspaceID(for: item) }
        } else {
            // The task started or was deleted while the popover was open.
            Text("This task left the Inbox.")
                .font(ToastyTheme.fontBody)
                .foregroundStyle(ToastyTheme.mutedText)
                .padding(14)
                .frame(width: 320, alignment: .leading)
        }
    }

    private func content(_ item: TaskInboxItem) -> some View {
        let canPlace = item.phase == .needsWorkspace || item.phase == .setupFailed
        let workspaces = canPlace ? coordinator.placementContext(excluding: item.id).placeableWorkspaces : []
        return VStack(alignment: .leading, spacing: 8) {
            Text(item.displayTitle)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(ToastyTheme.primaryText)
                .lineLimit(2)

            ScrollView {
                Text(item.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(ToastyTheme.inactiveText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            .fixedSize(horizontal: false, vertical: true)

            if item.attachments.isEmpty == false {
                HStack(spacing: 6) {
                    ForEach(item.attachments, id: \.path) { attachment in
                        Text(attachment.displayName)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(ToastyTheme.sidebarSessionPathText)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(ToastyTheme.sidebarWorkspaceTagBackground, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }

            if let note = item.problem ?? item.suggestion?.reason {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(ToastyTheme.inactiveText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ToastyTheme.sidebarWorkspaceTagBackground.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
            }

            if canPlace {
                Text("WORKSPACE")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(0.7)
                    .foregroundStyle(ToastyTheme.mutedText)
                if workspaces.isEmpty {
                    Text("No workspace has a directory yet. Open a terminal in one first.")
                        .font(.system(size: 11))
                        .foregroundStyle(ToastyTheme.mutedText)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(workspaces.enumerated()), id: \.element.id) { index, workspace in
                                workspaceChoice(
                                    workspace,
                                    number: index < 9 ? index + 1 : nil,
                                    isSuggested: workspace.id == item.suggestion?.workspaceID
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(ToastyTheme.sessionErrorText)
            }

            HStack(spacing: 6) {
                Button("Delete", role: .destructive) {
                    coordinator.delete(taskID: item.id)
                    dismiss()
                }
                Spacer(minLength: 0)
                if canPlace {
                    Button(item.phase == .setupFailed ? "Retry" : "Retry Triage") {
                        perform { try coordinator.retry(taskID: item.id) }
                    }
                    Button("Start") {
                        guard let workspaceID = selectedWorkspaceID else { return }
                        perform { try coordinator.place(taskID: item.id, workspaceID: workspaceID) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedWorkspaceID == nil)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    /// `number` is the key that picks it, for the first nine.
    @ViewBuilder
    private func workspaceChoice(_ workspace: TaskPlacementContext.Workspace, number: Int?, isSuggested: Bool) -> some View {
        if let number {
            workspaceChoiceButton(workspace, number: number, isSuggested: isSuggested)
                .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: [])
        } else {
            workspaceChoiceButton(workspace, number: nil, isSuggested: isSuggested)
        }
    }

    private func workspaceChoiceButton(_ workspace: TaskPlacementContext.Workspace, number: Int?, isSuggested: Bool) -> some View {
        let isSelected = selectedWorkspaceID == workspace.id
        return Button {
            selectedWorkspaceID = workspace.id
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ToastyTheme.primaryText)
                    Text(workspace.directory ?? "")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(ToastyTheme.sidebarSessionPathText)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
                if isSuggested {
                    Text("suggested")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(ToastyTheme.accent)
                }
                if let number {
                    Text("\(number)")
                        .font(ToastyTheme.fontShortcutBadge)
                        .foregroundStyle(ToastyTheme.subtleText)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected ? ToastyTheme.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(workspace.title)\(isSuggested ? ", suggested" : "")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func defaultWorkspaceID(for item: TaskInboxItem) -> UUID? {
        let workspaces = coordinator.placementContext(excluding: item.id).placeableWorkspaces
        let preferred = [item.pins.workspaceID, item.suggestion?.workspaceID, item.plan?.workspaceID]
            .compactMap { $0 }
            .first { id in workspaces.contains { $0.id == id } }
        return preferred ?? workspaces.first?.id
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            errorMessage = nil
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
