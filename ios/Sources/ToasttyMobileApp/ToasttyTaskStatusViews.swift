import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain

/// Home's segments while the Mac runs its task system, as in the Mac
/// sidebar: All lists each project as a card with its rows in buckets;
/// Needs you lists only what needs the user.
enum ToasttyHomeSegment: String, CaseIterable {
    case all
    case needsYou

    static let defaultSegment = ToasttyHomeSegment.all
    static let preferenceKey = "toastty-mobile-home-segment"

    var title: String {
        switch self {
        case .all: "All"
        case .needsYou: "Needs you"
        }
    }
}

/// Which task the detail sheet shows.
struct ToasttyTaskDetailSelection: Identifiable, Equatable {
    let id: UUID
    /// The task as it was when the sheet opened, for when the Mac stops
    /// listing it while the sheet is open.
    var fallback: RemoteTaskSummary? = nil
}

extension View {
    /// The task detail sheet, on the task the Mac lists now.
    func toasttyTaskDetailSheet(
        _ selection: Binding<ToasttyTaskDetailSelection?>,
        controller: HomeScreenController,
        openWorkspace: @escaping (UUID) -> Void
    ) -> some View {
        sheet(item: selection) { selection in
            if let task = controller.snapshot.taskBoard?.task(id: selection.id) ?? selection.fallback {
                ToasttyTaskDetailSheet(
                    task: task,
                    canOpenTaskSpace: controller.snapshot.openableTaskSpaceID(of: task) != nil,
                    openTaskSpace: openWorkspace,
                    controller: controller
                )
            }
        }
    }
}

/// A task in a list of tasks from several projects: its task space's row
/// while the task space is open, else its own row, which opens its detail.
/// Each row names its project.
struct ToasttyTaskListRow: View {
    let task: RemoteTaskSummary
    var isLinkedChild = false
    /// Off under a heading that already names the project, such as a To
    /// ship lane.
    var showsProject = true
    let controller: HomeScreenController
    let openWorkspace: (UUID) -> Void
    let openTask: (UUID) -> Void

    var body: some View {
        Group {
            if let taskSpaceID = task.taskSpaceWorkspaceID, let subspace = controller.snapshot.subspaceRow(id: taskSpaceID) {
                ToasttySubspaceRow(
                    row: subspace,
                    parentTitle: task.projectTitle ?? "",
                    controller: controller,
                    openWorkspace: openWorkspace,
                    projectTag: showsProject ? task.projectTitle : nil
                )
            } else {
                ToasttyTaskRow(
                    task: task, freshness: controller.freshness, controller: controller, showsProject: showsProject
                ) {
                    openTask(task.id)
                }
            }
        }
        .toasttyLinkedChild(isLinkedChild)
        .toasttyListRow()
    }
}

extension View {
    /// A row drawn under the task that started it: indented, with the Mac's
    /// ↳ in the indent, level with the row's title and left of its status
    /// mark. The Tasks tab and Home's cards both draw it.
    func toasttyLinkedChild(_ isLinkedChild: Bool) -> some View {
        padding(.leading, isLinkedChild ? ToasttyChildArrowMark.indent : 0)
            // On the title's baseline, which a one-line row centres in its
            // minimum height.
            .overlay(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline)) {
                if isLinkedChild {
                    ToasttyChildArrowMark()
                }
            }
    }
}

/// The ↳ before a nested task's status mark, as the Mac's
/// `TaskChildArrowMark` draws it. VoiceOver skips it, as on the Mac.
struct ToasttyChildArrowMark: View {
    /// How far a nested row moves right.
    static let indent: CGFloat = 18

    var body: some View {
        // A line in the rows' title font, so the arrow stays level with the
        // title at every text size.
        Text(" ")
            .font(.subheadline)
            .frame(width: Self.indent)
            .overlay {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(ToasttyDesignTokens.mutedText.opacity(0.8))
            }
            .padding(.leading, 4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// "NEEDS YOU 4": a task group's title and count, in the group's color.
struct ToasttyTaskGroupHeader: View {
    let title: String
    let count: Int
    /// Nil for the calm groups.
    var tint: Color? = nil

    var body: some View {
        let color = tint.flatMap { count > 0 ? $0 : nil } ?? ToasttyDesignTokens.mutedText
        HStack(spacing: 6) {
            Text(title.uppercased())
                .tracking(0.8)
            Text("\(count)")
            Spacer(minLength: 0)
        }
        .font(.caption2.monospaced().weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(title), \(count)")
    }
}

/// "1/3 merged" on a parent task's row: how many of the tasks it started
/// have merged.
struct ToasttyChildProgressChip: View {
    let progress: RemoteTaskChildProgress

    static func label(_ progress: RemoteTaskChildProgress) -> String {
        "\(progress.merged)/\(progress.total) merged"
    }

    var body: some View {
        Text(Self.label(progress))
            .font(.caption2.monospaced())
            .foregroundStyle(ToasttyDesignTokens.secondaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(ToasttyDesignTokens.chipSurface, in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }
}

extension RemoteTaskSummary {
    /// The child progress a row shows: only while the task has children.
    var shownChildProgress: RemoteTaskChildProgress? {
        childProgress.flatMap { $0.total > 0 ? $0 : nil }
    }
}

/// How wide a row's chip or tag can be.
enum ToasttyRowTagWidth {
    /// The width of its text up to a cap, on a line it shares with the
    /// title: the default text sizes.
    case capped
    /// The width of its text, whatever that is: a large text size, where a
    /// fit check then moves a tag that is too wide to a line of its own.
    case natural
    /// On a line of its own: the row's width, and it shortens only past it.
    case ownLine
}

extension View {
    /// Sizes a chip or tag whose text shortens with a tail or middle
    /// ellipsis. `cap` applies only to `.capped`.
    func toasttyRowTagWidth(_ width: ToasttyRowTagWidth, cap: CGFloat) -> some View {
        frame(maxWidth: width == .capped ? cap : nil)
            .fixedSize(horizontal: width != .ownLine, vertical: true)
    }
}

/// The project a row belongs to, where rows from several projects share a
/// list. It takes the width of the name up to a cap, and a longer name
/// shortens in the middle, so the row's status line keeps its room.
struct ToasttyProjectTag: View {
    let title: String
    var width = ToasttyRowTagWidth.capped

    /// About fifteen characters, so a question beside the tag keeps most
    /// of the line.
    static let maximumWidth: CGFloat = 100

    var body: some View {
        Text(title)
            .font(.caption2.monospaced())
            .foregroundStyle(ToasttyDesignTokens.mutedText)
            .lineLimit(1)
            .truncationMode(.middle)
            .toasttyRowTagWidth(width, cap: Self.maximumWidth)
    }
}

/// A row's child progress and project at a large text size: side by side
/// when both fit the row, else one under the other, where the project takes
/// the row's width and shortens only past it. Neither can push the row off
/// the screen.
struct ToasttyLargeTextTags: View {
    let progress: RemoteTaskChildProgress?
    let project: String?

    var body: some View {
        if progress != nil || project != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { tags(project: .natural) }
                VStack(alignment: .leading, spacing: 3) { tags(project: .ownLine) }
            }
        }
    }

    @ViewBuilder
    private func tags(project width: ToasttyRowTagWidth) -> some View {
        if let progress {
            ToasttyChildProgressChip(progress: progress)
        }
        if let project {
            ToasttyProjectTag(title: project, width: width)
        }
    }
}

/// How a row draws on one line, as the Needs you segment lists rows: its
/// one tag, and the second line it keeps for a question or a failure.
struct ToasttyCompactRow: Equatable {
    let tag: MobileHomeRowTag?
    let detail: String?
    /// The task that started this one, when the row lists without it. The
    /// tag shows it only when the row has no pull request; VoiceOver always
    /// says it, as on the Mac.
    var parentTitle: String? = nil

    /// What the tag says to VoiceOver.
    var tagAccessibilityLabel: String? {
        switch tag {
        case .pullRequestAnnotation(let annotation): ToasttyWorkspaceAnnotationAccessibility.label(for: annotation)
        case .pullRequest(let pullRequest): "PR #\(pullRequest.number)"
        case .parent(let title): "started by \(title)"
        case .childProgress(let progress): ToasttyChildProgressChip.label(progress)
        case .project(let project): project
        case nil: nil
        }
    }

    /// The parent for VoiceOver, unless the tag already says it.
    var parentAccessibilityLabel: String? {
        if case .parent = tag { return nil }
        return parentTitle.map { "started by \($0)" }
    }
}

/// The one tag on a one-line row. As on the Mac, the tag keeps the width of
/// its text up to its cap, and the title shortens first.
struct ToasttyCompactRowTag: View {
    let tag: MobileHomeRowTag
    var width = ToasttyRowTagWidth.capped

    /// An annotation's text can be long.
    static let chipMaximumWidth: CGFloat = 110

    var body: some View {
        content
            .layoutPriority(1)
    }

    @ViewBuilder
    private var content: some View {
        switch tag {
        case .pullRequestAnnotation(let annotation):
            // Without the link arrow, as in All: the row opens the task
            // space, not the pull request.
            ToasttyAnnotationChip(
                annotation: RemoteWorkspaceAnnotation(key: annotation.key, text: annotation.text, color: annotation.color),
                size: .compact
            )
            .toasttyRowTagWidth(width, cap: Self.chipMaximumWidth)
        case .pullRequest(let pullRequest):
            ToasttyTaskPullRequestChip(pullRequest: pullRequest, showsLink: false)
        case .parent(let title):
            ToasttyParentTaskTag(title: title, width: width)
        case .childProgress(let progress):
            ToasttyChildProgressChip(progress: progress)
        case .project(let project):
            ToasttyProjectTag(title: project, width: width)
        }
    }
}

/// "↖ Parent title", on a row that lists without the task that started
/// it. A long title shortens.
struct ToasttyParentTaskTag: View {
    let title: String
    var width = ToasttyRowTagWidth.capped

    static let maximumWidth: CGFloat = 130

    var body: some View {
        Text("↖ \(title)")
            .font(.caption2.monospaced())
            .foregroundStyle(ToasttyDesignTokens.secondaryText)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(ToasttyDesignTokens.chipSurface, in: RoundedRectangle(cornerRadius: 4))
            .toasttyRowTagWidth(width, cap: Self.maximumWidth)
    }
}

/// A task with no open task space, such as one whose setup failed or one
/// that merged: its mark, title, status line and project. It opens the
/// task's detail. As on the Mac, the pull request chip gives way when the
/// title has no room, and the child progress sits on the status line. A
/// one-line row (`compact`) shows one tag, and its second line only for a
/// question or a failure.
struct ToasttyTaskRow: View {
    let task: RemoteTaskSummary
    let freshness: LiveProjectionFreshness
    var controller: HomeScreenController?
    var compact: ToasttyCompactRow? = nil
    /// Off where a heading already names the project: its own card in Home,
    /// or its To ship lane.
    var showsProject = true
    let open: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// What a title keeps before a chip gives way, as on the Mac.
    static let titleReservedWidth: CGFloat = 90

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(" ")
                    .font(.subheadline)
                    .frame(width: 16)
                    .overlay { ToasttyTaskMark(task: task, freshness: freshness) }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    if dynamicTypeSize.isAccessibilitySize {
                        largeTextLines
                    } else if let compact {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            titleText
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let tag = compact.tag {
                                ToasttyCompactRowTag(tag: tag)
                            }
                            chevron
                        }
                        if let detail = compact.detail {
                            statusText(detail)
                        }
                    } else {
                        ViewThatFits(in: .horizontal) {
                            titleLine(showsPullRequest: true)
                            titleLine(showsPullRequest: false)
                        }
                        HStack(spacing: 6) {
                            statusText(task.statusLine)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let progress = task.shownChildProgress {
                                ToasttyChildProgressChip(progress: progress)
                            }
                            if let project = shownProject {
                                ToasttyProjectTag(title: project)
                            }
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
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Shows the task")
        .accessibilityIdentifier("toastty-task-row-\(task.id.uuidString)")
        .contextMenu {
            Button("Show Task", systemImage: "info.circle", action: open)
            if let controller {
                ToasttyTaskActionMenuItems(task: task, controller: controller)
            }
        }
    }

    private var shownProject: String? {
        showsProject ? task.projectTitle : nil
    }

    /// Large text wraps the title and the status, and moves the tags to
    /// their own lines, as the session and task space rows do.
    @ViewBuilder
    private var largeTextLines: some View {
        titleText
        HStack(spacing: 6) {
            if let compact {
                if let tag = compact.tag {
                    ToasttyCompactRowTag(tag: tag, width: .ownLine)
                }
            } else if let pullRequest = task.pullRequest {
                ToasttyTaskPullRequestChip(pullRequest: pullRequest, showsLink: false)
            }
            chevron
        }
        if let compact {
            if let detail = compact.detail {
                statusText(detail)
            }
        } else {
            statusText(task.statusLine)
            ToasttyLargeTextTags(progress: task.shownChildProgress, project: shownProject)
        }
    }

    private var titleText: some View {
        Text(task.title)
            .font(.subheadline.weight(task.group == .needsYou ? .bold : .medium))
            .foregroundStyle(ToasttyDesignTokens.primaryText)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func titleLine(showsPullRequest: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            titleText
                .frame(minWidth: 0, idealWidth: Self.titleReservedWidth, maxWidth: .infinity, alignment: .leading)
            if showsPullRequest, let pullRequest = task.pullRequest {
                ToasttyTaskPullRequestChip(pullRequest: pullRequest, showsLink: false)
            }
            chevron
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(ToasttyDesignTokens.mutedText)
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .foregroundStyle(ToasttyDesignTokens.secondaryText)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var accessibilityLabel: String {
        // A one-line row still says its status, which its hidden second
        // line would show.
        let parts: [String?] = if let compact {
            [task.title, compact.detail ?? task.statusLine, compact.tagAccessibilityLabel, compact.parentAccessibilityLabel]
        } else {
            [
                task.title, task.statusLine, shownProject, task.shownChildProgress.map(ToasttyChildProgressChip.label),
                // The chip, which the status line does not always name.
                task.pullRequest.map { "PR #\($0.number)" },
            ]
        }
        return parts.compactMap { $0 }.joined(separator: ", ")
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
    /// Off in a list row: the row opens the task, not the pull request, so
    /// its chip shows no link arrow, as a task space row's chip.
    var showsLink = true

    var body: some View {
        ToasttyAnnotationChip(
            annotation: RemoteWorkspaceAnnotation(
                key: "github-pr",
                text: "PR #\(pullRequest.number)",
                url: showsLink ? pullRequest.url : nil,
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
                    if let macStep = task.macStep {
                        ToasttyTaskMacStepNote(text: macStep)
                    }
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

/// What only the Mac can do for a task, such as picking its workspace, in
/// the task's detail above the actions the phone can take.
struct ToasttyTaskMacStepNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "desktopcomputer")
                .font(.subheadline)
                .foregroundStyle(ToasttyDesignTokens.amberText)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(ToasttyDesignTokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(ToasttyDesignTokens.raisedSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ToasttyDesignTokens.border))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("toastty-task-detail-mac-step")
    }
}
