import CoreState
import SwiftUI

/// Tasks by stage: Needs you, Running and Idle as rows, To ship as one
/// header per project with its latest tasks under it, and Done as a count.
/// The iPhone's Status list uses these groups, and the Tasks view and the
/// project cards use its family and Release rules. The Mac sidebar lists
/// rows in `SidebarBuckets` instead.
struct SidebarStatusSections: Equatable {
    struct Entry: Equatable, Identifiable {
        let item: TaskBoardItem
        /// Drawn under the task that started it.
        var isLinkedChild = false
        /// Drawn dimmed: the task's own stage is in a calmer group. It lists
        /// here to keep its family together, or because it is selected and
        /// holds its place.
        var isContext = false

        var id: TaskBoardItem.Subject { item.id }
    }

    /// A task and the tasks it started, which list together in the group of
    /// the most urgent one. One level only, as in the project cards.
    struct Family: Equatable {
        var root: TaskBoardItem
        var children: [TaskBoardItem] = []
        var members: [TaskBoardItem] { [root] + children }
        var group: TaskStage.Group { members.map(\.stage.group).min() ?? root.stage.group }
    }

    /// The group the selected task's family holds while the task stays
    /// selected. See `pin(previous:selected:displayed:)`.
    struct Pin: Equatable {
        let subject: TaskBoardItem.Subject
        let group: TaskStage.Group
    }

    struct Lane: Equatable, Identifiable {
        /// See `laneKey(_:)`.
        let id: String
        let projectTitle: String
        let count: Int
        /// When the oldest task in the lane merged.
        let oldestMergedAt: Date?
        /// The project workspace Release starts a release in; `nil` when
        /// the project cannot release from Toastty or is not open.
        var releaseWorkspaceID: UUID? = nil
        /// The lane's latest tasks, drawn under its line.
        var recent = SidebarRecentToShip()
    }

    /// What a To ship lane groups by: the project's root directory, else its
    /// title, so two projects with the same title keep separate lanes.
    static func laneKey(_ item: TaskBoardItem) -> String {
        item.record?.projectRoot ?? item.projectTitle ?? "Other"
    }

    /// The groups that list rows, in their order.
    static let rowGroups: [TaskStage.Group] = [.needsYou, .running, .idle]

    var needsYou: [Entry] = []
    var running: [Entry] = []
    var idle: [Entry] = []
    var toShip: [Lane] = []
    var doneCount = 0
    /// Where the pinned family is shown, for the next `make`.
    var pin: Pin?

    var isEmpty: Bool {
        needsYou.isEmpty && running.isEmpty && idle.isEmpty && toShip.isEmpty && doneCount == 0
    }

    func entries(_ group: TaskStage.Group) -> [Entry] {
        switch group {
        case .needsYou: needsYou
        case .running: running
        case .idle: idle
        case .toShip, .done, .archived: []
        }
    }

    /// The header count: rows whose own stage is in the group, so a dimmed
    /// relative or a held row does not count.
    func count(_ group: TaskStage.Group) -> Int {
        entries(group).filter { $0.item.stage.group == group }.count
    }

    /// The group each row is drawn in, so the next selection can hold its
    /// family where the user saw it.
    var groups: [TaskBoardItem.Subject: TaskStage.Group] {
        var result: [TaskBoardItem.Subject: TaskStage.Group] = [:]
        for group in Self.rowGroups {
            for entry in entries(group) {
                result[entry.id] = group
            }
        }
        return result
    }

    /// The order the sidebar lists tasks in: by project, in the window's
    /// workspace order, then by task space, in the order the task spaces
    /// opened. Tasks with no task space in the window follow their project's
    /// task spaces, oldest first. The project cards and Jump to Next Active
    /// use the same workspace order, so a task never moves within its group.
    static func sidebarOrder(_ items: [TaskBoardItem], workspaceIDs: [UUID]) -> [TaskBoardItem] {
        let position = Dictionary(workspaceIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        func key(_ item: TaskBoardItem) -> (project: Int, taskSpace: Int, createdAt: Date) {
            (
                item.projectWorkspaceID.flatMap { position[$0] } ?? Int.max,
                item.taskSpaceWorkspaceID.flatMap { position[$0] } ?? Int.max,
                item.record?.createdAt ?? .distantFuture
            )
        }
        return items.enumerated().sorted { lhs, rhs in
            let left = key(lhs.element), right = key(rhs.element)
            if left.project != right.project { return left.project < right.project }
            if left.taskSpace != right.taskSpace { return left.taskSpace < right.taskSpace }
            if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// `items` in the order the sidebar lists them; see `sidebarOrder`.
    /// Each group keeps that order, so a row moves only when its stage
    /// changes its group.
    static func make(
        _ items: [TaskBoardItem],
        releasable: (TaskBoardItem) -> Bool = { _ in false },
        pin: Pin? = nil
    ) -> Self {
        var sections = Self()
        var familiesByGroup = Dictionary(grouping: families(items), by: \.group)
        // Selecting a task reads its turn, which can move it to a calmer
        // group under the pointer. Its family keeps its group until the
        // selection moves. The selected task resuming work, or its family
        // becoming more urgent, moves it at once and holds it there.
        if let pin, let located = locate(pin.subject, in: familiesByGroup) {
            let family = familiesByGroup[located.group]![located.index]
            let selectedIsRunning = family.members.contains { $0.id == pin.subject && $0.stage.group == .running }
            let group = selectedIsRunning ? located.group : min(located.group, pin.group)
            if group != located.group {
                let family = familiesByGroup[located.group]!.remove(at: located.index)
                let position = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
                let rank = { (family: Family) in position[family.root.id] ?? Int.max }
                var target = familiesByGroup[group] ?? []
                target.insert(family, at: target.firstIndex { rank($0) > rank(family) } ?? target.endIndex)
                familiesByGroup[group] = target
            }
            sections.pin = Pin(subject: pin.subject, group: group)
        }
        // A row whose own stage is in another group is drawn dimmed: a
        // relative listed with its family, or a held row the user has read.
        func entries(_ group: TaskStage.Group) -> [Entry] {
            (familiesByGroup[group] ?? []).flatMap { family in
                [Entry(item: family.root, isContext: family.root.stage.group != group)]
                    + family.children.map { Entry(item: $0, isLinkedChild: true, isContext: $0.stage.group != group) }
            }
        }
        sections.needsYou = entries(.needsYou)
        sections.running = entries(.running)
        sections.idle = entries(.idle)
        let shipping = Dictionary(grouping: items.filter { $0.stage == .toShip }, by: laneKey)
        sections.toShip = shipping.map { key, lane in
            Lane(
                id: key,
                projectTitle: lane.first?.projectTitle ?? "Other",
                count: lane.count,
                oldestMergedAt: lane.compactMap { $0.record?.mergedAt }.min(),
                releaseWorkspaceID: releaseWorkspaceID(lane, releasable: releasable),
                recent: SidebarRecentToShip.make(lane)
            )
        }
        .sorted { $0.projectTitle.localizedStandardCompare($1.projectTitle) == .orderedAscending }
        sections.doneCount = items.filter { $0.stage == .done }.count
        return sections
    }

    /// The project workspace a lane's Release starts in. Only a task with a
    /// merge of its own offers it: a task that is To ship through its child
    /// tasks, which may be in other projects, has nothing to release.
    static func releaseWorkspaceID(_ lane: [TaskBoardItem], releasable: (TaskBoardItem) -> Bool) -> UUID? {
        lane.first { $0.finishedThroughChildren == false && releasable($0) }?.projectWorkspaceID
    }

    private static func locate(
        _ subject: TaskBoardItem.Subject,
        in familiesByGroup: [TaskStage.Group: [Family]]
    ) -> (group: TaskStage.Group, index: Int)? {
        for group in rowGroups {
            if let index = familiesByGroup[group]?.firstIndex(where: { $0.members.contains { $0.id == subject } }) {
                return (group, index)
            }
        }
        return nil
    }

    /// The pin for the selected task: kept while the same task stays
    /// selected, else taken from the group its family was drawn in.
    static func pin(
        previous: Pin?,
        selected: TaskBoardItem.Subject?,
        displayed: [TaskBoardItem.Subject: TaskStage.Group]
    ) -> Pin? {
        guard let selected else { return nil }
        if let previous, previous.subject == selected { return previous }
        return displayed[selected].map { Pin(subject: selected, group: $0) }
    }

    /// Splits the tasks in Needs you, Running and Idle into families: each
    /// task whose parent is among them lists under that parent, unless the
    /// parent itself lists under another task. Every task is in exactly one
    /// family, in `items` order.
    static func families(_ items: [TaskBoardItem]) -> [Family] {
        let listed = items.filter { rowGroups.contains($0.stage.group) }
        let taskIDs = Set(listed.compactMap(\.taskID))
        func parent(_ item: TaskBoardItem) -> UUID? {
            guard let parentID = item.parentTaskID, parentID != item.taskID, taskIDs.contains(parentID) else { return nil }
            return parentID
        }
        let rootTaskIDs = Set(listed.filter { parent($0) == nil }.compactMap(\.taskID))
        let childrenByParentID = Dictionary(grouping: listed.filter { parent($0).map(rootTaskIDs.contains) == true }) { parent($0)! }
        let childIDs = Set(childrenByParentID.values.flatMap { $0.map(\.id) })
        return listed.filter { childIDs.contains($0.id) == false }.map { root in
            Family(root: root, children: root.taskID.flatMap { childrenByParentID[$0] } ?? [])
        }
    }

    /// Puts each task right after the task that started it when both are
    /// in the group. One level only, as in the project cards. The Tasks view
    /// lists each group this way.
    static func grouped(_ items: [TaskBoardItem]) -> [Entry] {
        let taskIDs = Set(items.compactMap(\.taskID))
        let topLevel = items.filter { item in
            item.parentTaskID.map { taskIDs.contains($0) == false || $0 == item.taskID } ?? true
        }
        let topLevelTaskIDs = Set(topLevel.compactMap(\.taskID))
        var placed: Set<TaskBoardItem.Subject> = []
        var result: [Entry] = []
        for item in items where placed.contains(item.id) == false {
            let isChild = item.parentTaskID.map { topLevelTaskIDs.contains($0) && $0 != item.taskID } ?? false
            if isChild { continue }
            result.append(Entry(item: item))
            placed.insert(item.id)
            guard let taskID = item.taskID, topLevelTaskIDs.contains(taskID) else { continue }
            for child in items where child.parentTaskID == taskID && placed.contains(child.id) == false && child.taskID != taskID {
                result.append(Entry(item: child, isLinkedChild: true))
                placed.insert(child.id)
            }
        }
        return result
    }

    static func laneDetail(_ lane: Lane, now: Date) -> String {
        guard let oldest = lane.oldestMergedAt else { return "" }
        return "oldest \(TaskAge.label(since: oldest, now: now))"
    }

    /// The To ship header's label. Collapsed, it names each project and its
    /// count, as the header's summary shows them.
    func toShipLabel(isExpanded: Bool) -> String {
        let label = SidebarToShipGroupToggle.label(count: toShip.reduce(0) { $0 + $1.count }, isExpanded: isExpanded)
        guard isExpanded == false else { return label }
        return ([label] + toShip.map { "\($0.projectTitle) \($0.count)" }).joined(separator: ", ")
    }
}

/// A project's most recently merged To ship tasks, which the sidebar lists
/// under the project so that a merged task does not seem to disappear. The
/// rest wait behind "Show N more", which opens the Tasks view.
struct SidebarRecentToShip: Equatable {
    static let limit = 3

    /// Newest merge first.
    var shown: [TaskBoardItem] = []
    var hidden: [TaskBoardItem] = []

    /// `items` that are To ship, newest merge first, split at `limit`.
    static func make(_ items: [TaskBoardItem], limit: Int = limit) -> Self {
        let sorted = items.filter { $0.stage == .toShip }.sorted { lhs, rhs in
            let lhsDate = mergedAt(lhs), rhsDate = mergedAt(rhs)
            return lhsDate != rhsDate
                ? lhsDate > rhsDate
                : lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        return Self(shown: Array(sorted.prefix(limit)), hidden: Array(sorted.dropFirst(limit)))
    }

    /// The rows under a project card. A task whose task space row the card
    /// shows, such as one whose agent is working, is left out. A quiet task
    /// space leaves the card when its task merges, so its task gets a row.
    static func card(_ items: [TaskBoardItem], projectWorkspaceID: UUID, shownTaskSpaceIDs: Set<UUID>) -> Self {
        make(items.filter { item in
            item.projectWorkspaceID == projectWorkspaceID
                && item.taskSpaceWorkspaceID.map { shownTaskSpaceIDs.contains($0) } != true
        })
    }

    /// When the task merged; a task with no merge time uses its latest
    /// change, which is when it became To ship or later.
    static func mergedAt(_ item: TaskBoardItem) -> Date {
        item.record?.mergedAt ?? item.activityAt
    }

    static func showMoreTitle(_ count: Int) -> String {
        "Show \(count) more"
    }

    static func showMoreLabel(_ count: Int) -> String {
        "Show \(count) more \(count == 1 ? "task" : "tasks") to ship in the Tasks view"
    }
}

/// "now", "5m", "3h", "2d": how long ago, for task lists.
enum TaskAge {
    static func label(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }
}

/// A sidebar row for a task with no open task space in the window, such as
/// one whose task space closed before it finished, or one that waits for its
/// workspace to be picked. It opens the task in the Tasks view.
struct SidebarTaskRecordRow: View {
    let item: TaskBoardItem
    /// Names the project on the row: a project card already names it.
    var showsProject = true
    /// The task that started this one, named with a ↖ when the list shows
    /// the row without that task.
    var parentTaskTitle: String? = nil
    /// Drawn on one line, as the Needs you segment lists rows: the status
    /// line moves to the tooltip, and one tag shows.
    var isCompact = false
    let open: () -> Void

    @State private var isHovered = false

    private var label: String {
        var label = TaskBoardPresentation.addingReleaseAfterMerge(to: "\(item.title), \(TaskBoardPresentation.statusLine(item))", item)
        if let parentTaskTitle {
            label += ", started by \(parentTaskTitle)"
        }
        return label
    }

    private var markColor: Color {
        switch item.stage {
        case .needsYou(.review), .needsYou(.readyForReview): ToastyTheme.sidebarTaskReviewMark
        case .needsYou: ToastyTheme.sessionNeedsApprovalText
        default: ToastyTheme.sidebarSubspaceQuietMark
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(markColor)
                .frame(width: 7, height: 7)
                .frame(width: 12, height: 17)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                titleLine
                if isCompact == false {
                    statusLine
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? ToastyTheme.sidebarSessionHoverBackground : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onTapGesture(perform: open)
        .onHover { isHovered = $0 }
        // A one-line row has no status line, so its tooltip carries it. An
        // empty tooltip shows nothing.
        .help(isCompact ? TaskBoardPresentation.statusLine(item) : "")
        .background {
            SidebarSemanticTextBridge(text: label)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            SidebarView.styledSessionNameText(item.title, isEmphasized: false)
                .foregroundStyle(ToastyTheme.sidebarSessionAgentText)
                .lineLimit(1)
            if TaskBoardPresentation.releaseAfterMergeRequestedAt(item) != nil {
                TaskReleaseAfterMergeMark()
            }
            if isCompact {
                Spacer(minLength: 0)
                compactTag
            }
        }
        .frame(minHeight: 17, alignment: .leading)
    }

    /// The one tag a one-line row shows: its pull request, else the task
    /// that started it, else its project where several share a list.
    @ViewBuilder
    private var compactTag: some View {
        if let pullRequest = item.pullRequest {
            SidebarView.sidebarTaskTag("#\(pullRequest.number)")
        } else if let parentTaskTitle {
            SidebarView.parentTaskTag(parentTaskTitle, maximumWidth: 90)
        } else if showsProject, let project = item.projectTitle {
            SidebarView.sidebarTaskTag(project)
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            SidebarView.styledSessionSummaryText(TaskBoardPresentation.statusLine(item))
                .foregroundStyle(ToastyTheme.sidebarSummaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
            if showsProject, let project = item.projectTitle {
                SidebarView.sidebarTaskTag(project)
            }
            if let parentTaskTitle {
                SidebarView.parentTaskTag(parentTaskTitle, maximumWidth: 90)
            }
        }
    }
}

/// A sidebar group's title: "TO SHIP 3".
struct SidebarGroupTitle: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(0.8)
            Text("\(count)")
                .font(ToastyTheme.fontWorkspaceAgentCount)
                .foregroundStyle(ToastyTheme.sidebarSessionPathText)
        }
    }
}

/// "› TO SHIP 3", which expands and collapses a To ship group in place: the
/// one under each project card. While
/// collapsed, `summary` shows on the right.
struct SidebarToShipGroupToggle: View {
    let count: Int
    @Binding var isExpanded: Bool
    var summary: Text?
    /// Shows the purple To ship mark before the title. A project card uses
    /// it because its line has no purple project summary.
    var showsMark = false
    /// What the toggle says; starts with `label(count:isExpanded:)`.
    let accessibilityText: String

    nonisolated static func label(count: Int, isExpanded: Bool) -> String {
        "To ship, \(count) \(count == 1 ? "task" : "tasks"), \(isExpanded ? "expanded" : "collapsed")"
    }

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 9)
                if showsMark {
                    // The same mark as the card's old "To ship N" count.
                    Image(systemName: "arrow.up.square")
                        .font(ToastyTheme.fontWorkspaceSessionChip)
                        .foregroundStyle(ToastyTheme.sidebarTaskToShipMark)
                }
                SidebarGroupTitle(title: "To ship", count: count)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if isExpanded == false, let summary {
                    summary
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .foregroundStyle(ToastyTheme.sidebarChildContextText)
            .frame(minHeight: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide the tasks to ship" : "Show the tasks to ship")
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isHeader)
        .background {
            SidebarSemanticTextBridge(text: accessibilityText)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }
}

/// "Show N more →" under a project's latest To ship tasks.
struct SidebarShowMoreToShipButton: View {
    let count: Int
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(SidebarRecentToShip.showMoreTitle(count))
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(ToastyTheme.fontWorkspaceSessionChip)
            .foregroundStyle(isHovered ? ToastyTheme.sidebarSessionAgentText : ToastyTheme.sidebarSessionPathText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Show the other tasks to ship in the Tasks view")
        .accessibilityLabel(SidebarRecentToShip.showMoreLabel(count))
        .background {
            SidebarSemanticTextBridge(text: SidebarRecentToShip.showMoreLabel(count))
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }
}

/// The violet Release pill on a To ship project, as in the mockups.
struct TaskReleaseButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(ToastyTheme.sidebarTaskToShipMark)
                .padding(.horizontal, 7)
                .frame(height: 17)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(ToastyTheme.sidebarTaskToShipMarkBackground)
                        .brightness(isHovered ? 0.06 : 0)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Start a release task for this project's merged tasks")
        .accessibilityLabel(title)
    }
}
