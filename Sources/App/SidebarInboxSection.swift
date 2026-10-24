import CoreState
import SwiftUI

/// What the sidebar shows for one Inbox task. Kept apart from the view so
/// the words can be tested without hosting it.
struct SidebarInboxRowPresentation: Equatable {
    var title: String
    /// Where the task stands, in full, for accessibility.
    var detail: String
    var tag: String
    var needsUser: Bool
    /// The short text after the tag; `nil` when the full detail is too long
    /// for the row and belongs in the popover.
    var hint: String?

    static func make(_ record: TaskRecord, workspaceTitle: (UUID) -> String?) -> Self {
        let workspace = record.workspaceID.flatMap(workspaceTitle) ?? "closed workspace"
        let agent = record.resolved?.agent.map { " · \($0)" } ?? ""
        switch record.setup {
        case .routing:
            let detail = record.workspaceID.flatMap(workspaceTitle).map { "→ \($0)\(agent)" } ?? "choosing a workspace"
            return .init(title: record.title, detail: detail, tag: "setting up", needsUser: false, hint: detail)
        case .needsWorkspace(let reason):
            let hint = record.suggestedWorkspace.map { "suggests \($0.title)" }
            return .init(title: record.title, detail: [hint, reason].compactMap { $0 }.joined(separator: ". "), tag: "⚠ pick a workspace", needsUser: true, hint: hint)
        case .settingUp:
            let detail = "→ \(workspace)\(agent)"
            return .init(title: record.title, detail: detail, tag: "setting up", needsUser: false, hint: detail)
        case .setupFailed(let reason):
            return .init(title: record.title, detail: reason, tag: "⚠ setup failed", needsUser: true)
        case .started:
            switch record.startWork?.state {
            case .running?:
                let detail = startWorkStep(record)
                return .init(title: record.title, detail: detail, tag: "moving to worktree", needsUser: false, hint: detail)
            case .failed(let reason)?:
                return .init(title: record.title, detail: reason, tag: "⚠ worktree failed", needsUser: true)
            case .finished?, nil:
                let detail = "→ \(workspace)\(agent)"
                return .init(title: record.title, detail: detail, tag: "started", needsUser: false, hint: detail)
            }
        }
    }

    /// What a move into a worktree is doing now, from the steps it saved.
    static func startWorkStep(_ record: TaskRecord) -> String {
        let operation = record.operation
        if record.worktree == nil {
            return "making the worktree"
        }
        if operation.hookFinishedAt == nil {
            return "running create_hook"
        }
        guard let session = operation.worktreeSession, session.sessionID != nil else {
            return "waiting for the agent's turn to end"
        }
        if session.forked, session.nativeConversationID == nil {
            return "waiting for the forked agent"
        }
        return "closing the old session"
    }

    var accessibilityLabel: String {
        "\(title), Inbox task, \(tag.replacingOccurrences(of: "⚠ ", with: "")), \(detail)"
    }

    /// The tasks the Inbox shows, oldest first: those that have not
    /// started, and those moving into a worktree or whose move failed.
    static func inboxRecords(_ records: [TaskRecord]) -> [TaskRecord] {
        records.filter(isInInbox)
    }

    static func isInInbox(_ record: TaskRecord) -> Bool {
        guard record.setup.isStarted else { return true }
        switch record.startWork?.state {
        case .running?, .failed?: return true
        case .finished?, nil: return false
        }
    }

    /// Whether Retry applies: setup or a move into a worktree failed.
    static func canRetry(_ record: TaskRecord) -> Bool {
        if case .setupFailed = record.setup { return true }
        if record.setup.isStarted, case .failed? = record.startWork?.state { return true }
        return false
    }

    /// Why setup or the move failed, for the popover.
    static func failureReason(_ record: TaskRecord) -> String? {
        if case .setupFailed(let reason) = record.setup { return reason }
        if record.setup.isStarted, case .failed(let reason)? = record.startWork?.state { return reason }
        return nil
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
                // The tag first, so a narrow sidebar cuts the hint after it
                // rather than leaving one letter of a long reason before it.
                HStack(spacing: 6) {
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
                    if let hint = presentation.hint {
                        SidebarView.styledSessionSummaryText(hint)
                            .foregroundStyle(ToastyTheme.sidebarSummaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
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
            TaskInboxCard(taskID: record.id, records: records, coordinator: coordinator) {
                presentedTaskID = nil
            }
            .inboxPopoverChrome()
        }
        .contextMenu {
            Button("Show Task…") { presentedTaskID = record.id }
            Divider()
            TaskContextMenuItems(sections: [
                TaskBoardPresentation.inboxMenuItems(record, isTriageConfigured: coordinator.isTriageConfigured),
            ]) { menuItem in
                TaskActions.runFromMenu(menuItem, coordinator: coordinator) { _ in }
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
        .accessibilityAction(.default) { presentedTaskID = record.id }
        .accessibilityIdentifier("sidebar.inbox.task.\(record.id.uuidString)")
    }
}
