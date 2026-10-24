import CoreState
import SwiftUI

/// One task in the sidebar's Needs you list: why it waits, one line on what
/// to look at, the action that settles it most often, and the task's menu.
/// Kept apart from the view so it can be tested without hosting it.
struct SidebarNeedsYouRow: Equatable, Identifiable {
    enum Tone: Equatable {
        case review
        case question
        case problem
        case finished
        case quiet
    }

    /// The button next to the ▾ menu.
    enum PrimaryAction: Equatable {
        /// Asks in the row first, then merges as the Merge button does.
        case merge(taskID: UUID, pullRequestNumber: Int?)
        case action(TaskBoardPresentation.DetailAction, taskID: UUID)
        /// The agent asked something; it waits in its task space.
        case answer(workspaceID: UUID)
        case openTaskSpace(workspaceID: UUID)

        var title: String {
            switch self {
            case .merge: "Merge"
            case .action(let action, _): action.title
            case .answer: "Answer"
            case .openTaskSpace: "Open"
            }
        }

        var isMerge: Bool {
            if case .merge = self { return true }
            return false
        }

        var isProminent: Bool { isMerge }
    }

    let id: TaskBoardItem.Subject
    let title: String
    let reason: String
    let tone: Tone
    let projectTitle: String?
    /// The packet's `look_at`, else the task's status line.
    let detail: String
    let packetVersion: Int?
    let primary: PrimaryAction?
    let menu: [[TaskBoardPresentation.MenuItem]]
    let taskSpaceWorkspaceID: UUID?

    var taskID: UUID? {
        if case .task(let id) = id { return id }
        return nil
    }

    /// The start of the row's Accessibility identifiers, from its task or
    /// task space ID, which two rows never share.
    var identifier: String {
        switch id {
        case .task(let id): "sidebar.needsYou.task.\(id.uuidString)"
        case .taskSpace(let id): "sidebar.needsYou.taskSpace.\(id.uuidString)"
        }
    }

    var accessibilityLabel: String {
        [title, reason, projectTitle.map { "in \($0)" }, detail].compactMap { $0 }.joined(separator: ", ")
    }

    /// `items` newest activity first, as the board gives them, so the
    /// latest request is on top. Tasks that have not reached their task
    /// space stay in the Inbox.
    static func rows(_ items: [TaskBoardItem], lookAt: (TaskRecord) -> String?) -> [Self] {
        items.filter { $0.stage.group == .needsYou }.map { make($0, lookAt: lookAt) }
    }

    static func make(_ item: TaskBoardItem, lookAt: (TaskRecord) -> String?) -> Self {
        let (reason, tone) = reasonAndTone(item.stage)
        let packetLookAt = item.record.flatMap { $0.packetVersion == nil ? nil : lookAt($0) }
        return Self(
            id: item.id,
            title: item.title,
            reason: reason,
            tone: tone,
            projectTitle: item.projectTitle,
            detail: packetLookAt ?? TaskBoardPresentation.statusLine(item),
            packetVersion: item.record?.packetVersion,
            primary: primaryAction(item),
            menu: TaskBoardPresentation.menuItems(item),
            taskSpaceWorkspaceID: item.taskSpaceWorkspaceID
        )
    }

    static func reasonAndTone(_ stage: TaskStage) -> (String, Tone) {
        guard case .needsYou(let attention) = stage else { return ("", .quiet) }
        switch attention {
        case .review, .readyForReview: return ("review", .review)
        case .agentNeedsInput: return ("question", .question)
        case .agentError: return ("stuck", .problem)
        case .agentFinished: return ("finished", .finished)
        case .taskSpaceClosed: return ("closed", .quiet)
        case .cleanupStopped: return ("clean up", .quiet)
        case .pickWorkspace, .setupFailed, .moveFailed: return ("setup", .problem)
        }
    }

    /// Merge for a pull request waiting for review; else the detail action
    /// that settles the task (Clean Up, Mark Done for reviewed work without a
    /// pull request, Archive for a closed task space); else the task space,
    /// where the agent waits: Answer for a question, Open otherwise.
    static func primaryAction(_ item: TaskBoardItem) -> PrimaryAction? {
        guard let taskID = item.taskID else {
            return item.taskSpaceWorkspaceID.map { .openTaskSpace(workspaceID: $0) }
        }
        let actions = TaskBoardPresentation.detailActions(item)
        if item.stage == .needsYou(.review), actions.contains(.merge) {
            return .merge(taskID: taskID, pullRequestNumber: item.pullRequest?.number)
        }
        if actions.contains(.cleanUp) {
            return .action(.cleanUp, taskID: taskID)
        }
        if item.stage == .needsYou(.readyForReview), actions.contains(.markDone) {
            return .action(.markDone, taskID: taskID)
        }
        if item.stage == .needsYou(.taskSpaceClosed), actions.contains(.archive) {
            return .action(.archive, taskID: taskID)
        }
        guard let workspaceID = item.taskSpaceWorkspaceID else { return nil }
        return item.stage == .needsYou(.agentNeedsInput) ? .answer(workspaceID: workspaceID) : .openTaskSpace(workspaceID: workspaceID)
    }
}

/// Reads each packet's `look_at` once per version, off the main thread: a
/// row shows its status line until the read finishes, then redraws. A packet
/// never changes after it is published, so a new version is the only reason
/// to read again.
@MainActor
final class SidebarPacketLookAtCache: ObservableObject {
    private struct Key: Hashable {
        let taskID: UUID
        let version: Int
    }

    private var values: [Key: String?] = [:]
    private var pending: Set<Key> = []
    /// Changes when a read finishes, so the sidebar redraws.
    @Published private(set) var loadedCount = 0

    func lookAt(_ record: TaskRecord, packets: TaskPacketStore) -> String? {
        guard let version = record.packetVersion else { return nil }
        let key = Key(taskID: record.id, version: version)
        if let cached = values[key] { return cached }
        guard pending.insert(key).inserted else { return nil }
        Task { @MainActor [weak self] in
            let value = await Task.detached(priority: .utility) {
                try? packets.read(taskID: key.taskID, version: key.version).lookAt
            }.value
            guard let self else { return }
            self.values[key] = value
            self.pending.remove(key)
            self.loadedCount += 1
        }
        return nil
    }
}

/// Needs you, between the Coordinator row and the projects.
struct SidebarNeedsYouSection: View {
    let rows: [SidebarNeedsYouRow]
    /// nil while there is no coordinator chat to open a packet in.
    let openPacket: ((UUID) -> Void)?
    let openTaskSpace: (UUID) -> Void
    let merge: (UUID) -> Void
    let run: (TaskBoardPresentation.MenuItem) -> Void

    @State private var confirmingMergeID: TaskBoardItem.Subject?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("NEEDS YOU")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .kerning(0.8)
                    .foregroundStyle(ToastyTheme.sidebarSessionPathText)
                Spacer(minLength: 0)
                Text("\(rows.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(ToastyTheme.sidebarSessionPathText)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Needs you, \(rows.count)")
            .background {
                SidebarSemanticTextBridge(text: "Needs you, \(rows.count)")
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }

            if rows.isEmpty {
                Text("Nothing needs you.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(ToastyTheme.sidebarSummaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
            } else {
                ForEach(rows) { row in
                    SidebarNeedsYouRowView(
                        row: row,
                        isConfirmingMerge: confirmingMergeID == row.id && row.primary?.isMerge == true,
                        open: { open(row) },
                        primary: { runPrimary(row) },
                        confirmMerge: {
                            confirmingMergeID = nil
                            // The row's action now, which may have changed
                            // while the question showed.
                            if case .merge(let taskID, _)? = row.primary { merge(taskID) }
                        },
                        cancelMerge: { confirmingMergeID = nil },
                        openPacket: openPacket.flatMap { action in row.packetVersion == nil ? nil : row.taskID.map { id in { action(id) } } },
                        run: run
                    )
                }
            }
        }
        .padding(.bottom, 6)
        .onChange(of: rows) { _, rows in
            // A question left showing would come back when its row does.
            if let confirmingMergeID, rows.contains(where: { $0.id == confirmingMergeID && $0.primary?.isMerge == true }) == false {
                self.confirmingMergeID = nil
            }
        }
    }

    /// The row's body opens the packet in the coordinator chat, or, before
    /// that chat exists, the task space.
    private func open(_ row: SidebarNeedsYouRow) {
        if let openPacket, let taskID = row.taskID {
            openPacket(taskID)
        } else if let workspaceID = row.taskSpaceWorkspaceID {
            openTaskSpace(workspaceID)
        }
    }

    private func runPrimary(_ row: SidebarNeedsYouRow) {
        switch row.primary {
        case .merge?:
            confirmingMergeID = row.id
        case .action(let action, let taskID)?:
            run(.action(action, taskID: taskID))
        case .answer(let workspaceID)?, .openTaskSpace(let workspaceID)?:
            openTaskSpace(workspaceID)
        case nil:
            break
        }
    }
}

private struct SidebarNeedsYouRowView: View {
    let row: SidebarNeedsYouRow
    let isConfirmingMerge: Bool
    let open: () -> Void
    let primary: () -> Void
    let confirmMerge: () -> Void
    let cancelMerge: () -> Void
    let openPacket: (() -> Void)?
    let run: (TaskBoardPresentation.MenuItem) -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            summary
            if isConfirmingMerge {
                mergeConfirmation
            } else {
                actions
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ToastyTheme.sidebarAttentionApprovalTint, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isHovered ? ToastyTheme.sessionNeedsApprovalText.opacity(0.45) : Color.clear, lineWidth: 1)
        }
        .onHover { isHovered = $0 }
        .contextMenu { menuItems }
    }

    private var summary: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    reasonBadge
                    SidebarView.styledSessionNameText(row.title, isEmphasized: true)
                        .foregroundStyle(ToastyTheme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let project = row.projectTitle {
                        Text(project)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(ToastyTheme.sidebarSessionPathText)
                            .lineLimit(1)
                    }
                }
                Text(row.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(ToastyTheme.sidebarSummaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(openPacket == nil ? "Open the task space" : "Open the packet in the coordinator")
        .accessibilityLabel(row.accessibilityLabel)
        .background {
            SidebarSemanticTextBridge(text: row.accessibilityLabel)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }

    private var reasonBadge: some View {
        let (text, fill) = Self.colors(row.tone)
        return Text(row.reason)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(text)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(fill, in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }

    static func colors(_ tone: SidebarNeedsYouRow.Tone) -> (Color, Color) {
        switch tone {
        case .review: (ToastyTheme.sidebarTaskReviewMark, ToastyTheme.sidebarTaskReviewMarkBackground)
        case .question: (ToastyTheme.sessionNeedsApprovalText, ToastyTheme.sessionNeedsApprovalBackground)
        case .problem: (ToastyTheme.sessionErrorText, ToastyTheme.sessionErrorBackground)
        case .finished: (ToastyTheme.sessionReadyText, ToastyTheme.sessionReadyBackground)
        case .quiet: (ToastyTheme.sidebarSessionPathText, ToastyTheme.workspaceNewBadgeBackground)
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            if let primaryAction = row.primary {
                Button(primaryAction.title, action: primary)
                    .buttonStyle(SidebarNeedsYouButtonStyle(isProminent: primaryAction.isProminent))
                    .accessibilityIdentifier("\(row.identifier).primary")
            }
            Menu {
                menuItems
            } label: {
                Text("▾")
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(SidebarNeedsYouButtonStyle(isProminent: false))
            .fixedSize()
            .accessibilityLabel("More actions for \(row.title)")
            .accessibilityIdentifier("\(row.identifier).menu")
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if let openPacket {
            Button("Open Packet", action: openPacket)
            Divider()
        }
        TaskContextMenuItems(sections: row.menu, run: run)
    }

    private var mergeConfirmation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.primary.flatMap(Self.mergeQuestion) ?? "Merge?")
                .font(.system(size: 11.5))
                .foregroundStyle(ToastyTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                // No Return or Esc shortcut: a sidebar row has no focus of
                // its own, so either would act from the terminal.
                Button("Merge", action: confirmMerge)
                    .buttonStyle(SidebarNeedsYouButtonStyle(isProminent: true))
                    .accessibilityIdentifier("\(row.identifier).confirmMerge")
                Button("Cancel", action: cancelMerge)
                    .buttonStyle(SidebarNeedsYouButtonStyle(isProminent: false))
                    .accessibilityIdentifier("\(row.identifier).cancelMerge")
                Spacer(minLength: 0)
            }
        }
    }

    static func mergeQuestion(_ primary: SidebarNeedsYouRow.PrimaryAction) -> String? {
        guard case .merge(_, let number) = primary else { return nil }
        return "Merge \(number.map { "PR #\($0)" } ?? "the pull request")?"
    }
}

private struct SidebarNeedsYouButtonStyle: ButtonStyle {
    let isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: isProminent ? .semibold : .medium))
            .foregroundStyle(isProminent ? Color(hex: 0x10241A) : ToastyTheme.primaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 2)
            .background(
                isProminent ? ToastyTheme.sessionReadyText : Color(hex: 0x323236),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay {
                if isProminent == false {
                    RoundedRectangle(cornerRadius: 6).stroke(Color(hex: 0x38383C), lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}
