import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain

/// Home's segments while the Mac runs its task system, as in the Mac
/// sidebar: Projects lists each workspace with its task spaces; Status
/// lists the tasks by where they stand.
enum ToasttyHomeSegment: String, CaseIterable {
    case projects
    case status

    static let defaultSegment = ToasttyHomeSegment.projects
    static let preferenceKey = "toastty-mobile-home-segment"

    var title: String {
        switch self {
        case .projects: "Projects"
        case .status: "Status"
        }
    }

    /// "Status 4" while tasks need the user, like the Mac's Tasks badge.
    static func statusTitle(needsYouCount: Int) -> String {
        needsYouCount > 0 ? "Status \(needsYouCount)" : "Status"
    }
}

/// Which task the detail sheet shows.
struct ToasttyTaskDetailSelection: Identifiable, Equatable {
    let id: UUID
}

/// The Status segment: Needs you, Running and Idle as rows, To ship as one
/// line per project, and Done as a count. Emits sibling rows so the List
/// gives each its own cell. A task with an open task space draws as that
/// task space's row; the rest open the task's detail.
struct ToasttyTaskStatusList: View {
    let board: MobileTaskBoard
    let controller: HomeScreenController
    let openWorkspace: (UUID) -> Void
    let openTask: (UUID) -> Void

    @AppStorage("toastty-mobile-status-to-ship-expanded") private var isToShipExpanded = false

    var body: some View {
        if board.isEmpty {
            ContentUnavailableView(
                "No tasks",
                systemImage: "checklist",
                description: Text("Tasks you start on your Mac show here.")
            )
            .foregroundStyle(ToasttyDesignTokens.secondaryText)
            .padding(.vertical, 32)
            .toasttyListRow()
        }
        ForEach([RemoteTaskGroup.needsYou, .running, .idle], id: \.self) { group in
            let entries = board.entries(group)
            if entries.isEmpty == false {
                ToasttyTaskGroupHeader(
                    title: Self.groupTitle(group),
                    count: board.count(group),
                    isHot: group == .needsYou
                )
                .padding(.top, 10)
                .toasttyListRow(vertical: 0)
                ForEach(entries, id: \.taskID) { entry in
                    if let task = board.task(id: entry.taskID) {
                        row(task, isLinkedChild: entry.isLinkedChild, isContext: entry.isContext)
                    }
                }
            }
        }
        if board.toShip.isEmpty == false {
            toShipHeader
                .padding(.top, 10)
                .toasttyListRow(vertical: 0)
            if isToShipExpanded {
                ForEach(board.toShip) { lane in
                    HStack(spacing: 6) {
                        Text(lane.projectTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ToasttyDesignTokens.taskToShip)
                        Text("\(lane.count)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(ToasttyDesignTokens.mutedText)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 30)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("toastty-status-to-ship-lane-\(lane.id)")
                    .toasttyListRow()
                    ForEach(lane.recentTaskIDs, id: \.self) { taskID in
                        if let task = board.task(id: taskID) {
                            row(task, isLinkedChild: false, isContext: false)
                        }
                    }
                }
            }
        }
        if board.doneCount > 0 {
            ToasttyTaskGroupHeader(title: "Done", count: board.doneCount, isHot: false)
                .padding(.top, 10)
                .accessibilityIdentifier("toastty-status-done")
                .toasttyListRow(vertical: 0)
        }
    }

    @ViewBuilder
    private func row(_ task: RemoteTaskSummary, isLinkedChild: Bool, isContext: Bool) -> some View {
        Group {
            if let taskSpaceID = task.taskSpaceWorkspaceID, let subspace = controller.snapshot.subspaceRow(id: taskSpaceID) {
                ToasttySubspaceRow(
                    row: subspace,
                    parentTitle: task.projectTitle ?? "",
                    controller: controller,
                    openWorkspace: openWorkspace,
                    projectTag: task.projectTitle
                )
            } else {
                ToasttyTaskRow(task: task, freshness: controller.freshness, controller: controller) {
                    openTask(task.id)
                }
            }
        }
        .padding(.leading, isLinkedChild ? 18 : 0)
        .opacity(isContext ? 0.55 : 1)
        .toasttyListRow()
    }

    private var toShipHeader: some View {
        Button {
            isToShipExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isToShipExpanded ? "chevron.down" : "chevron.right")
                    .imageScale(.small)
                    .frame(width: 12)
                Image(systemName: "arrow.up.square")
                    .foregroundStyle(ToasttyDesignTokens.taskToShip)
                Text("TO SHIP")
                    .tracking(0.8)
                Text("\(board.toShipCount)")
                if isToShipExpanded == false {
                    Text(board.toShip.map { "\($0.projectTitle) \($0.count)" }.joined(separator: " · "))
                        .foregroundStyle(ToasttyDesignTokens.taskToShip)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .font(.caption2.monospaced())
            .foregroundStyle(ToasttyDesignTokens.mutedText)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("To ship, \(board.toShipCount) \(board.toShipCount == 1 ? "task" : "tasks")")
        .accessibilityValue(isToShipExpanded ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("toastty-status-to-ship")
    }

    static func groupTitle(_ group: RemoteTaskGroup) -> String {
        switch group {
        case .needsYou: "Needs you"
        case .running: "Running"
        case .idle: "Idle"
        case .toShip: "To ship"
        case .done: "Done"
        case .archived: "Archived"
        }
    }
}

/// "NEEDS YOU 4": a Status group's title and count.
struct ToasttyTaskGroupHeader: View {
    let title: String
    let count: Int
    let isHot: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .tracking(0.8)
            Text("\(count)")
                .foregroundStyle(isHot && count > 0 ? ToasttyDesignTokens.amberText : ToasttyDesignTokens.mutedText)
            Spacer(minLength: 0)
        }
        .font(.caption2.monospaced().weight(.semibold))
        .foregroundStyle(isHot && count > 0 ? ToasttyDesignTokens.amberText : ToasttyDesignTokens.mutedText)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(title), \(count)")
    }
}

/// A task with no open task space, such as one whose setup failed or one
/// that merged: its mark, title, status line and project. It opens the
/// task's detail.
struct ToasttyTaskRow: View {
    let task: RemoteTaskSummary
    let freshness: LiveProjectionFreshness
    var controller: HomeScreenController?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(" ")
                    .font(.subheadline)
                    .frame(width: 16)
                    .overlay { ToasttyTaskMark(task: task, freshness: freshness) }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(task.title)
                            .font(.subheadline.weight(task.group == .needsYou ? .bold : .medium))
                            .foregroundStyle(ToasttyDesignTokens.primaryText)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let pullRequest = task.pullRequest {
                            ToasttyTaskPullRequestChip(pullRequest: pullRequest)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(ToasttyDesignTokens.mutedText)
                    }
                    HStack(spacing: 6) {
                        Text(task.statusLine)
                            .font(.caption.monospaced())
                            .foregroundStyle(ToasttyDesignTokens.secondaryText)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let project = task.projectTitle {
                            Text(project)
                                .font(.caption2.monospaced())
                                .foregroundStyle(ToasttyDesignTokens.mutedText)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(ToasttySessionRow.shape)
        }
        .buttonStyle(ToasttySessionRowButtonStyle(tint: .clear))
        .accessibilityLabel([task.title, task.statusLine, task.projectTitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Shows the task")
        .accessibilityIdentifier("toastty-task-row-\(task.id.uuidString)")
        .contextMenu {
            Button("Show Task", systemImage: "info.circle", action: open)
            if let controller {
                ToasttyTaskActionMenuItems(task: task, controller: controller)
            }
        }
    }
}

/// A task's mark where it has no task space row: the same squares as the
/// task space marks.
struct ToasttyTaskMark: View {
    let task: RemoteTaskSummary
    let freshness: LiveProjectionFreshness

    var body: some View {
        switch task.mark {
        case .starting?:
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(ToasttyDesignTokens.mutedText, style: StrokeStyle(lineWidth: 1.2, dash: [2.5, 2]))
                .frame(width: 13, height: 13)
        case .question?:
            ToasttySubspaceRailMark(status: .question, freshness: freshness)
        case .review?:
            ToasttySubspaceRailMark(status: .review, freshness: freshness)
        case .toShip?:
            ToasttySubspaceRailMark(status: .toShip, freshness: freshness)
        case .done?:
            ToasttySubspaceRailMark(status: .done, freshness: freshness)
        case nil:
            if task.group == .needsYou {
                RoundedRectangle(cornerRadius: 2)
                    .fill(freshness == .live ? ToasttyDesignTokens.amber : ToasttyDesignTokens.mutedText)
                    .frame(width: 8, height: 8)
            } else {
                ToasttySubspaceRailMark(status: .idle, freshness: freshness)
            }
        }
    }
}

/// "PR #263" in the annotation chip style, for a task whose task space
/// closed and so has no annotation of its own.
struct ToasttyTaskPullRequestChip: View {
    let pullRequest: RemoteTaskPullRequest

    var body: some View {
        ToasttyAnnotationChip(
            annotation: RemoteWorkspaceAnnotation(
                key: "github-pr",
                text: "PR #\(pullRequest.number)",
                url: pullRequest.url,
                color: Self.color(pullRequest.state)
            ),
            size: .compact
        )
        .fixedSize()
    }

    static func color(_ state: RemoteTaskPullRequestState?) -> String {
        switch state {
        case .merged?: "#B98CE0"
        case .closed?: "#B7AEA5"
        case .open?, .draft?, nil: "#5BA08A"
        }
    }

    static func stateLabel(_ state: RemoteTaskPullRequestState?) -> String? {
        switch state {
        case .open?: "open"
        case .draft?: "draft"
        case .merged?: "merged"
        case .closed?: "closed"
        case nil: nil
        }
    }
}

/// Under a project in the Projects segment: the tasks that left its list
/// because they finished. Tapping it shows them in Status.
struct ToasttyProjectFinishedFooter: View {
    let tally: RemoteTaskProjectTally
    let showStatus: () -> Void

    var body: some View {
        Button(action: showStatus) {
            HStack(spacing: 12) {
                if tally.toShipCount > 0 {
                    Label("To ship \(tally.toShipCount)", systemImage: "arrow.up.square")
                        .foregroundStyle(ToasttyDesignTokens.taskToShip)
                }
                if tally.doneCount > 0 {
                    Label("Done \(tally.doneCount)", systemImage: "checkmark.square")
                        .foregroundStyle(ToasttyDesignTokens.mutedText)
                }
                Spacer(minLength: 0)
            }
            .font(.caption2.monospaced())
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows tasks by status")
        .accessibilityIdentifier("toastty-project-finished-\(tally.projectWorkspaceID.uuidString)")
    }
}

/// A task's detail: its stage and why, its status line, its pull request,
/// its project, and the actions the Mac offers for it now.
struct ToasttyTaskDetailSheet: View {
    let task: RemoteTaskSummary
    let canOpenTaskSpace: Bool
    let openTaskSpace: (UUID) -> Void
    var controller: HomeScreenController?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(task.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(ToasttyDesignTokens.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("toastty-task-detail-title")
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(task.stageTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Self.stageColor(task))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Self.stageColor(task).opacity(0.18), in: Capsule())
                        Text(task.stageReason)
                            .font(.caption)
                            .foregroundStyle(ToasttyDesignTokens.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("toastty-task-detail-stage")
                    Text(task.statusLine)
                        .font(.callout.monospaced())
                        .foregroundStyle(ToasttyDesignTokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    // The live task's actions; a task the Mac no longer
                    // lists offers none.
                    if let controller, let current = controller.snapshot.taskBoard?.task(id: task.id) {
                        ToasttyTaskActionButtons(task: current, controller: controller)
                    }
                    if let pullRequest = task.pullRequest {
                        Link(destination: pullRequest.url) {
                            HStack(spacing: 6) {
                                ToasttyTaskPullRequestChip(pullRequest: pullRequest)
                                if let state = ToasttyTaskPullRequestChip.stateLabel(pullRequest.state) {
                                    Text(state)
                                        .font(.caption)
                                        .foregroundStyle(ToasttyDesignTokens.mutedText)
                                }
                                Image(systemName: "arrow.up.right")
                                    .font(.caption2)
                                    .foregroundStyle(ToasttyDesignTokens.mutedText)
                            }
                        }
                        .accessibilityLabel("Open pull request \(pullRequest.number) on GitHub")
                        .accessibilityIdentifier("toastty-task-detail-pull-request")
                    }
                    if let project = task.projectTitle {
                        LabeledContent("Project", value: project)
                            .font(.caption)
                            .foregroundStyle(ToasttyDesignTokens.secondaryText)
                    }
                    if canOpenTaskSpace, let taskSpaceID = task.taskSpaceWorkspaceID {
                        Button("Open Task Space") {
                            dismiss()
                            openTaskSpace(taskSpaceID)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("toastty-task-detail-open-task-space")
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(ToasttyDesignTokens.background)
            .navigationTitle("Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("toastty-task-detail")
        .modifier(ToasttyOptionalTaskActionPresenter(controller: controller))
    }

    static func stageColor(_ task: RemoteTaskSummary) -> Color {
        switch task.mark {
        case .question?: return ToasttyDesignTokens.taskQuestion
        case .review?: return ToasttyDesignTokens.taskReview
        case .toShip?: return ToasttyDesignTokens.taskToShip
        case .done?: return ToasttyDesignTokens.green
        case .starting?: return ToasttyDesignTokens.mutedText
        case nil: return task.group == .needsYou ? ToasttyDesignTokens.amberText : ToasttyDesignTokens.secondaryText
        }
    }
}

/// A sheet's own presenter, when it has a controller to act through.
struct ToasttyOptionalTaskActionPresenter: ViewModifier {
    let controller: HomeScreenController?

    func body(content: Content) -> some View {
        if let controller {
            content.toasttyTaskActionPresenter(controller)
        } else {
            content
        }
    }
}
