import CoreState
import SwiftUI

/// What the sidebar shows for one Inbox task. Kept apart from the view so
/// the words can be tested without hosting it.
struct SidebarInboxRowPresentation: Equatable {
    var title: String
    var detail: String
    var tag: String
    var needsUser: Bool

    static func make(_ record: TaskRecord, workspaceTitle: (UUID) -> String?) -> Self {
        let workspace = record.workspaceID.flatMap(workspaceTitle) ?? "closed workspace"
        let agent = record.resolved?.agent.map { " · \($0)" } ?? ""
        switch record.setup {
        case .routing:
            let detail = record.workspaceID.flatMap(workspaceTitle).map { "→ \($0)\(agent)" } ?? "choosing a workspace"
            return .init(title: record.title, detail: detail, tag: "routing…", needsUser: false)
        case .needsWorkspace(let reason):
            return .init(title: record.title, detail: reason, tag: "⚠ pick a workspace", needsUser: true)
        case .settingUp:
            return .init(title: record.title, detail: "→ \(workspace)\(agent)", tag: "setting up", needsUser: false)
        case .setupFailed(let reason):
            return .init(title: record.title, detail: reason, tag: "⚠ setup failed", needsUser: true)
        case .started:
            return .init(title: record.title, detail: "→ \(workspace)\(agent)", tag: "started", needsUser: false)
        }
    }

    var accessibilityLabel: String {
        "\(title), Inbox task, \(tag.replacingOccurrences(of: "⚠ ", with: "")), \(detail)"
    }

    /// The tasks the Inbox shows: those that have not started, oldest first.
    static func inboxRecords(_ records: [TaskRecord]) -> [TaskRecord] {
        records.filter { $0.setup.isStarted == false }
    }
}

/// The Inbox group at the top of the sidebar: tasks whose setup has not
/// finished. Hidden when empty. A task has no session yet, so its mark is a
/// dashed box rather than a session status color.
struct SidebarInboxSection: View {
    @ObservedObject var records: TaskRecordStore
    let coordinator: TaskCoordinator
    /// The live title of a workspace, or `nil` when it is closed.
    let workspaceTitle: (UUID) -> String?

    @State private var isExpanded = true
    @State private var hoveredTaskID: UUID?
    @State private var presentedTaskID: UUID?

    private static let railWidth: CGFloat = 12
    private static let railGap: CGFloat = 6
    private static let lineMinHeight: CGFloat = 17

    var body: some View {
        let inbox = SidebarInboxRowPresentation.inboxRecords(records.records)
        if inbox.isEmpty == false {
            VStack(alignment: .leading, spacing: 3) {
                header(count: inbox.count)
                if isExpanded {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(inbox) { record in
                            row(record)
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

    private func header(count: Int) -> some View {
        let label = "Inbox, \(count) \(count == 1 ? "task" : "tasks")"
        return Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 9)
                Text("INBOX")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                Text("\(count)")
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
        .accessibilityLabel("\(label), \(isExpanded ? "expanded" : "collapsed")")
        .accessibilityIdentifier("sidebar.inbox.toggle")
        .background {
            SidebarSemanticTextBridge(text: label)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }

    private func row(_ record: TaskRecord) -> some View {
        let presentation = SidebarInboxRowPresentation.make(record, workspaceTitle: workspaceTitle)
        let isHovered = hoveredTaskID == record.id
        let isPresented = Binding(
            get: { presentedTaskID == record.id },
            set: { isShown in
                if isShown {
                    presentedTaskID = record.id
                } else if presentedTaskID == record.id {
                    presentedTaskID = nil
                }
            }
        )
        return HStack(alignment: .top, spacing: Self.railGap) {
            RoundedRectangle(cornerRadius: 1.5)
                .strokeBorder(
                    presentation.needsUser ? ToastyTheme.sessionNeedsApprovalText : ToastyTheme.sidebarChildContextText,
                    style: StrokeStyle(lineWidth: 1, dash: [2, 1.5])
                )
                .frame(width: 9, height: 9)
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
                        .foregroundStyle(
                            presentation.needsUser ? ToastyTheme.sessionNeedsApprovalText : ToastyTheme.sidebarSessionPathText
                        )
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
        .onTapGesture { presentedTaskID = record.id }
        .onHover { isHovering in
            if isHovering {
                hoveredTaskID = record.id
            } else if hoveredTaskID == record.id {
                hoveredTaskID = nil
            }
        }
        .popover(isPresented: isPresented, arrowEdge: .trailing) {
            TaskInboxPopover(taskID: record.id, records: records, coordinator: coordinator) {
                presentedTaskID = nil
            }
        }
        .contextMenu {
            Button("Show Task…") { presentedTaskID = record.id }
            switch record.setup {
            case .setupFailed:
                Button("Retry Setup") { try? coordinator.retry(taskID: record.id) }
            case .needsWorkspace:
                Button("Retry Triage") { try? coordinator.retry(taskID: record.id) }
            default:
                EmptyView()
            }
            Divider()
            Button("Delete Task", role: .destructive) { try? coordinator.delete(taskID: record.id) }
        }
        .background {
            SidebarSemanticTextBridge(text: presentation.accessibilityLabel)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) { presentedTaskID = record.id }
        .accessibilityIdentifier("sidebar.inbox.task.\(record.id.uuidString)")
    }
}

/// Opened from an Inbox row: the whole task, why setup failed, and the
/// actions that move it on.
struct TaskInboxPopover: View {
    let taskID: UUID
    @ObservedObject var records: TaskRecordStore
    let coordinator: TaskCoordinator
    let dismiss: () -> Void

    @State private var errorMessage: String?
    @State private var choices: TaskWorkspaceChoices?
    @State private var chosen: TaskWorkspaceChoice?

    var body: some View {
        Group {
            if let record = records.record(id: taskID), record.setup.isStarted == false {
                content(record)
            } else {
                // The task started or was deleted while the popover was open.
                Text("This task left the Inbox.")
                    .font(ToastyTheme.fontBody)
                    .foregroundStyle(ToastyTheme.mutedText)
                    .padding(14)
            }
        }
        .frame(width: 320, alignment: .leading)
    }

    private func content(_ record: TaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(record.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(ToastyTheme.primaryText)
                .lineLimit(2)

            ScrollView {
                Text(record.text.isEmpty ? (record.pinned.prompt ?? "") : record.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(ToastyTheme.inactiveText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            .fixedSize(horizontal: false, vertical: true)

            if record.attachments.isEmpty == false {
                Text(record.attachments.map(\.displayName).joined(separator: ", "))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(ToastyTheme.sidebarSessionPathText)
                    .lineLimit(2)
            }

            if case .needsWorkspace(let reason) = record.setup {
                workspacePicker(reason: reason)
            }

            if case .setupFailed(let reason) = record.setup {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(ToastyTheme.inactiveText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ToastyTheme.sidebarWorkspaceTagBackground.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(ToastyTheme.sessionErrorText)
            }

            HStack(spacing: 6) {
                Button("Delete", role: .destructive) {
                    perform { try coordinator.delete(taskID: record.id) }
                }
                Spacer(minLength: 0)
                switch record.setup {
                case .setupFailed:
                    Button("Retry") {
                        perform { try coordinator.retry(taskID: record.id) }
                    }
                    .keyboardShortcut(.defaultAction)
                case .needsWorkspace:
                    Button("Retry Triage") {
                        perform { try coordinator.retry(taskID: record.id) }
                    }
                    Button(chosenTitle.map { "Start in \($0)" } ?? "Start") {
                        guard let chosen else { return }
                        perform { try coordinator.setWorkspace(taskID: record.id, choice: chosen) }
                    }
                    .disabled(chosen == nil)
                    .keyboardShortcut(.defaultAction)
                default:
                    EmptyView()
                }
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    /// Why triage could not place the task, and a menu of the open
    /// workspaces, then the recently closed ones.
    private func workspacePicker(reason: String) -> some View {
        let choices = choices ?? TaskWorkspaceChoices(open: [], recent: [])
        return VStack(alignment: .leading, spacing: 8) {
            Text(reason)
                .font(.system(size: 11))
                .foregroundStyle(ToastyTheme.inactiveText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ToastyTheme.sidebarWorkspaceTagBackground.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 8) {
                Text("Workspace")
                    .font(.system(size: 11))
                    .foregroundStyle(ToastyTheme.mutedText)
                Menu(chosenTitle ?? "Choose…") {
                    Section("Open") {
                        ForEach(choices.open) { workspace in
                            Button(workspace.title) { chosen = .open(workspace.id) }
                        }
                    }
                    if choices.recent.isEmpty == false {
                        Section("Recent") {
                            ForEach(choices.recent) { item in
                                Button("\(item.title) — closed \(item.closedAt.formatted(.relative(presentation: .named)))") {
                                    chosen = .recent(item.id)
                                }
                            }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityIdentifier("sidebar.inbox.workspacePicker")
            }
        }
        .onAppear {
            if self.choices == nil {
                self.choices = coordinator.workspaceChoices()
            }
        }
    }

    private var chosenTitle: String? {
        switch chosen {
        case .open(let id)?:
            choices?.open.first { $0.id == id }?.title
        case .recent(let id)?:
            choices?.recent.first { $0.id == id }?.title
        case nil:
            nil
        }
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
