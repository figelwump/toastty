import CoreState
import SwiftUI

/// The Status segment's groups: Needs you, Running and Idle as rows, To
/// ship as one header per project with its latest tasks under it, and Done
/// as a count. Kept apart from the view so the grouping can be tested
/// without hosting it.
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

    /// Where a family is on screen: its group, and the families above it
    /// there, by their first task.
    struct Slot: Equatable {
        let group: TaskStage.Group
        let above: [TaskBoardItem.Subject]
    }

    /// Where the selected task's family holds while the task stays selected.
    /// See `pin(previous:selected:displayed:)`.
    struct Pin: Equatable {
        let subject: TaskBoardItem.Subject
        let slot: Slot
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

    /// Each family's slot on screen, by every member, so the next selection
    /// can pin its family where the user saw it.
    var slots: [TaskBoardItem.Subject: Slot] {
        var result: [TaskBoardItem.Subject: Slot] = [:]
        for group in Self.rowGroups {
            var above: [TaskBoardItem.Subject] = []
            var slot = Slot(group: group, above: [])
            for entry in entries(group) {
                if entry.isLinkedChild == false {
                    slot = Slot(group: group, above: above)
                    above.append(entry.id)
                }
                result[entry.id] = slot
            }
        }
        return result
    }

    /// `items` newest activity first, as the board gives them. Needs you
    /// keeps that order, so the latest request is on top; Running and Idle
    /// sort by project and title, so rows hold still while agents work.
    static func make(
        _ items: [TaskBoardItem],
        releasable: (TaskBoardItem) -> Bool = { _ in false },
        pin: Pin? = nil
    ) -> Self {
        var sections = Self()
        var familiesByGroup = Dictionary(grouping: families(items), by: \.group)
        for group in rowGroups {
            familiesByGroup[group] = sortedFamilies(familiesByGroup[group] ?? [], group: group, items: items)
        }
        // Selecting a task reads its turn, which can move it to a calmer
        // group under the pointer. Its family keeps its group, and stays
        // right after the families that were above it and are still there,
        // until the selection moves: rows above it can leave or arrive, but it
        // never jumps past a row. Anything more urgent still moves it, and
        // it holds in its new place from then on.
        if let pin, let located = locate(pin.subject, in: familiesByGroup) {
            let group = min(located.group, pin.slot.group)
            let family = familiesByGroup[located.group]!.remove(at: located.index)
            var target = familiesByGroup[group] ?? []
            let insertion = group == pin.slot.group
                ? target.lastIndex { $0.members.contains { pin.slot.above.contains($0.id) } }.map { $0 + 1 } ?? 0
                : located.index
            target.insert(family, at: insertion)
            familiesByGroup[group] = target
            sections.pin = Pin(subject: pin.subject, slot: Slot(group: group, above: target.prefix(insertion).map(\.root.id)))
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
                releaseWorkspaceID: lane.first(where: releasable)?.projectWorkspaceID,
                recent: SidebarRecentToShip.make(lane)
            )
        }
        .sorted { $0.projectTitle.localizedStandardCompare($1.projectTitle) == .orderedAscending }
        sections.doneCount = items.filter { $0.stage == .done }.count
        return sections
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
    /// selected, else taken from where the task's family was on screen.
    static func pin(
        previous: Pin?,
        selected: TaskBoardItem.Subject?,
        displayed: [TaskBoardItem.Subject: Slot]
    ) -> Pin? {
        guard let selected else { return nil }
        if let previous, previous.subject == selected { return previous }
        return displayed[selected].map { Pin(subject: selected, slot: $0) }
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

    /// Needs you lists the family with the newest request first: its newest
    /// member that needs you. Running and Idle sort by project and title,
    /// so rows hold still while agents work. Children always sort by project
    /// and title, so reading one does not move it within its family.
    private static func sortedFamilies(_ families: [Family], group: TaskStage.Group, items: [TaskBoardItem]) -> [Family] {
        let sorted = families.map { family in
            var family = family
            family.children.sort(by: byProjectAndTitle)
            return family
        }
        switch group {
        case .needsYou:
            let position = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            func rank(_ family: Family) -> Int {
                family.members.filter { $0.stage.group == group }.compactMap { position[$0.id] }.min() ?? Int.max
            }
            return sorted.sorted { rank($0) < rank($1) }
        case .running, .idle, .toShip, .done, .archived:
            return sorted.sorted { byProjectAndTitle($0.root, $1.root) }
        }
    }

    private static func byProjectAndTitle(_ lhs: TaskBoardItem, _ rhs: TaskBoardItem) -> Bool {
        let lhsProject = lhs.projectTitle ?? ""
        let rhsProject = rhs.projectTitle ?? ""
        return lhsProject != rhsProject
            ? lhsProject.localizedStandardCompare(rhsProject) == .orderedAscending
            : lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
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
        let count = toShip.reduce(0) { $0 + $1.count }
        let label = "To ship, \(count) \(count == 1 ? "task" : "tasks"), \(isExpanded ? "expanded" : "collapsed")"
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

/// Draws `SidebarStatusSections`. Rows with an open task space come from
/// the sidebar's own task space row, so they look and act the same as in a
/// project card; the rest open the Tasks view. To ship starts collapsed to
/// one line that names each project.
struct SidebarStatusSegment<RowContent: View>: View {
    let sections: SidebarStatusSections
    @Binding var isToShipExpanded: Bool
    /// Opens the Tasks view at a group.
    let openTasksGroup: (TaskStage.Group) -> Void
    var release: (UUID) -> Void = { _ in }
    /// Opens the Tasks view at To ship with a lane's first hidden task
    /// selected.
    var showMoreToShip: (TaskBoardItem.Subject?) -> Void = { _ in }
    /// Draws a group's rows, and the To ship tasks under each lane.
    @ViewBuilder let row: (SidebarStatusSections.Entry) -> RowContent

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if sections.isEmpty {
                Text("No tasks in this window.")
                    .font(ToastyTheme.fontWorkspaceSessionChip)
                    .foregroundStyle(ToastyTheme.sidebarSessionPathText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            if sections.needsYou.isEmpty == false {
                header("Needs you", count: sections.count(.needsYou), isHot: true)
                rows(sections.needsYou)
            }
            if sections.running.isEmpty == false {
                header("Running", count: sections.count(.running))
                rows(sections.running)
            }
            if sections.idle.isEmpty == false {
                header("Idle", count: sections.count(.idle))
                rows(sections.idle)
            }
            if sections.toShip.isEmpty == false {
                toShipHeader
                if isToShipExpanded {
                    ForEach(sections.toShip) { lane in
                        laneRow(lane)
                        laneTasks(lane)
                    }
                }
            }
            if sections.doneCount > 0 {
                Button {
                    openTasksGroup(.done)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .frame(width: 9)
                        groupTitle("Done", count: sections.doneCount)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(ToastyTheme.sidebarChildContextText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .help("Show finished tasks in the Tasks view")
                .accessibilityLabel(Self.doneLabel(sections.doneCount))
                .accessibilityIdentifier("sidebar.status.done")
                .background {
                    SidebarSemanticTextBridge(text: Self.doneLabel(sections.doneCount))
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 10)
        // A container's identifier would otherwise replace its rows' and
        // buttons' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.status")
    }

    static func doneLabel(_ count: Int) -> String {
        "Done, \(count) \(count == 1 ? "task" : "tasks"), opens the Tasks view"
    }

    static func laneLabel(_ lane: SidebarStatusSections.Lane, now: Date) -> String {
        let label = "\(lane.projectTitle), \(lane.count) \(lane.count == 1 ? "task" : "tasks") to ship"
        let detail = SidebarStatusSections.laneDetail(lane, now: now)
        return detail.isEmpty ? label : "\(label), \(detail)"
    }

    /// Each project in violet with its count, as the expanded headers name
    /// them.
    static func toShipSummary(_ lanes: [SidebarStatusSections.Lane]) -> Text {
        lanes.enumerated().reduce(Text(verbatim: "")) { summary, element in
            let (index, lane) = element
            let separator = index == 0
                ? Text(verbatim: "")
                : Text(verbatim: "  ·  ").foregroundStyle(ToastyTheme.sidebarSubspaceQuietMark)
            return summary + separator
                + Text(verbatim: lane.projectTitle).foregroundStyle(ToastyTheme.sidebarTaskToShipMark)
                + Text(verbatim: " \(lane.count)")
                .font(ToastyTheme.fontWorkspaceAgentCount)
                .foregroundStyle(ToastyTheme.sidebarSessionPathText)
        }
        .font(.system(size: 10.5, weight: .semibold))
    }

    private func rows(_ entries: [SidebarStatusSections.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(entries) { entry in
                row(entry)
                    // Its own stage is in a calmer group; see `Entry.isContext`.
                    .opacity(entry.isContext ? 0.55 : 1)
            }
        }
    }

    private func header(_ title: String, count: Int, isHot: Bool = false) -> some View {
        groupTitle(title, count: count)
            .foregroundStyle(isHot ? Color(hex: 0xF2C46B) : ToastyTheme.sidebarChildContextText)
            .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .background {
                SidebarSemanticTextBridge(text: "\(title), \(count)")
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
            .accessibilityAddTraits(.isHeader)
    }

    private func groupTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(0.8)
            Text("\(count)")
                .font(ToastyTheme.fontWorkspaceAgentCount)
                .foregroundStyle(ToastyTheme.sidebarSessionPathText)
        }
    }

    /// "› TO SHIP 3", which expands and collapses the group in place.
    /// Collapsed, it names each project and its count on the right.
    private var toShipHeader: some View {
        let label = sections.toShipLabel(isExpanded: isToShipExpanded)
        return Button {
            isToShipExpanded.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isToShipExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 9)
                groupTitle("To ship", count: sections.toShip.reduce(0) { $0 + $1.count })
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if isToShipExpanded == false {
                    Self.toShipSummary(sections.toShip)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .foregroundStyle(ToastyTheme.sidebarChildContextText)
            .frame(minHeight: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .help(isToShipExpanded ? "Hide the tasks to ship" : "Show the tasks to ship")
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("sidebar.status.toShip")
        .background {
            SidebarSemanticTextBridge(text: label)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }

    /// A project's header, drawn as in the Tasks view: its name and count in
    /// violet, with Release on the right.
    private func laneRow(_ lane: SidebarStatusSections.Lane) -> some View {
        HStack(spacing: 8) {
            laneButton(lane)
            if let workspaceID = lane.releaseWorkspaceID {
                TaskReleaseButton(title: "Release") { release(workspaceID) }
                    .padding(.trailing, 8)
                    .accessibilityIdentifier("sidebar.status.toShip.\(lane.projectTitle).release")
            }
        }
        .padding(.top, 4)
    }

    /// The lane's latest tasks, under the lane's title.
    @ViewBuilder
    private func laneTasks(_ lane: SidebarStatusSections.Lane) -> some View {
        if lane.recent.shown.isEmpty == false {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(lane.recent.shown) { item in
                    row(SidebarStatusSections.Entry(item: item))
                }
                if lane.recent.hidden.isEmpty == false {
                    SidebarShowMoreToShipButton(count: lane.recent.hidden.count) {
                        showMoreToShip(lane.recent.hidden.first?.id)
                    }
                    // Lines up with the task titles: the row's padding,
                    // status mark and gap.
                    .padding(.leading, 26)
                    .padding(.trailing, 8)
                    .padding(.vertical, 3)
                    .accessibilityIdentifier("sidebar.status.toShip.\(lane.projectTitle).more")
                }
            }
        }
    }

    private func laneButton(_ lane: SidebarStatusSections.Lane) -> some View {
        let now = Date()
        let detail = SidebarStatusSections.laneDetail(lane, now: now)
        return Button {
            openTasksGroup(.toShip)
        } label: {
            Text("\(lane.projectTitle) · \(lane.count) \(lane.count == 1 ? "task" : "tasks")")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ToastyTheme.sidebarTaskToShipMark)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: 17, alignment: .leading)
                .padding(.vertical, 2)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarStatusRowButtonStyle())
        .help(detail.isEmpty ? "Show To ship in the Tasks view" : "Show To ship in the Tasks view (\(detail))")
        .accessibilityLabel(Self.laneLabel(lane, now: now))
        .accessibilityIdentifier("sidebar.status.toShip.\(lane.projectTitle)")
        .background {
            SidebarSemanticTextBridge(text: Self.laneLabel(lane, now: now))
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }
}

private struct SidebarStatusRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? ToastyTheme.sidebarSessionHoverBackground : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
    }
}

/// A Status row for a task with no open task space, such as one whose task
/// space closed before it finished. It opens the task in the Tasks view.
struct SidebarTaskRecordRow: View {
    let item: TaskBoardItem
    let open: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(item.stage.needsUser ? ToastyTheme.sessionNeedsApprovalText : ToastyTheme.sidebarSubspaceQuietMark)
                .frame(width: 7, height: 7)
                .frame(width: 12, height: 17)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                SidebarView.styledSessionNameText(item.title, isEmphasized: false)
                    .foregroundStyle(ToastyTheme.sidebarSessionAgentText)
                    .lineLimit(1)
                    .frame(minHeight: 17, alignment: .leading)
                HStack(spacing: 6) {
                    SidebarView.styledSessionSummaryText(TaskBoardPresentation.statusLine(item))
                        .foregroundStyle(ToastyTheme.sidebarSummaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let project = item.projectTitle {
                        SidebarView.sidebarTaskTag(project)
                    }
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
        .background {
            SidebarSemanticTextBridge(text: "\(item.title), \(TaskBoardPresentation.statusLine(item))")
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title), \(TaskBoardPresentation.statusLine(item))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
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
