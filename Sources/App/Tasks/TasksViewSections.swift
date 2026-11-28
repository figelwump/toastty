import CoreState
import Foundation

/// The groups the Tasks view lists, in sidebar order. Needs you is split as
/// the sidebar splits it: what blocks an agent, then Ready to review. To
/// ship lists its tasks under one header per project.
struct TasksViewSections: Equatable {
    struct Lane: Equatable, Identifiable {
        /// The project's root directory, or its title for tasks without one:
        /// two projects with the same title keep separate lanes.
        let id: String
        let projectTitle: String
        let entries: [SidebarStatusSections.Entry]
    }

    var needsYou: [SidebarStatusSections.Entry] = []
    /// Tasks in Needs you whose open pull request or ready mark waits for
    /// the user's review.
    var readyToReview: [SidebarStatusSections.Entry] = []
    var running: [SidebarStatusSections.Entry] = []
    var idle: [SidebarStatusSections.Entry] = []
    var toShip: [Lane] = []
    var done: [SidebarStatusSections.Entry] = []
    var archived: [SidebarStatusSections.Entry] = []

    static func make(_ items: [TaskBoardItem]) -> Self {
        // Needs you, Running and Idle list a task by the bucket the sidebar
        // lists its task space's row in: the more urgent of its stage and its
        // sessions. To ship, Done and Archived list by stage.
        let buckets = Dictionary(
            items.compactMap { item in SidebarBucket.task(item).map { (item.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        func entries(_ isListed: (SidebarBucket) -> Bool) -> [SidebarStatusSections.Entry] {
            SidebarStatusSections.grouped(items.filter { buckets[$0.id].map(isListed) == true })
        }
        func entries(_ group: TaskStage.Group) -> [SidebarStatusSections.Entry] {
            SidebarStatusSections.grouped(items.filter { $0.stage.group == group })
        }
        var sections = Self()
        // A family lists in Needs you when any member blocks an agent, else
        // in Ready to review; a member whose own state is calmer is dimmed.
        var family: [SidebarStatusSections.Entry] = []
        func placeFamily() {
            guard family.isEmpty == false else { return }
            let bucket = family.compactMap { buckets[$0.id] }.min() ?? .needsYou
            let placed = family.map { entry in
                var entry = entry
                entry.isContext = buckets[entry.id] != bucket
                return entry
            }
            if bucket == .readyToReview { sections.readyToReview += placed } else { sections.needsYou += placed }
            family = []
        }
        for entry in entries(\.isListedInNeedsYouSegment) {
            if entry.isLinkedChild == false { placeFamily() }
            family.append(entry)
        }
        placeFamily()
        sections.running = entries { $0 == .running }
        sections.idle = entries { $0 == .idle }
        // Lanes first, then families in each lane: a child in another
        // project's lane lists apart from its parent.
        let toShipItems = items.filter { $0.stage.group == .toShip }
        sections.toShip = Dictionary(grouping: toShipItems, by: SidebarStatusSections.laneKey)
            .map { key, items in
                let entries = SidebarStatusSections.grouped(items)
                return Lane(
                    id: key,
                    projectTitle: entries.first?.item.projectTitle ?? "Other",
                    entries: entries
                )
            }
            .sorted { $0.projectTitle.localizedStandardCompare($1.projectTitle) == .orderedAscending }
        sections.done = entries(.done)
        sections.archived = entries(.archived)
        return sections
    }

    /// Every entry in display order, for picking a selection.
    var all: [SidebarStatusSections.Entry] {
        needsYou + readyToReview + running + idle + toShip.flatMap(\.entries) + done + archived
    }

    /// The entries the list shows, in order: Done and Archived only while
    /// they are expanded.
    func visible(isDoneExpanded: Bool, isArchivedExpanded: Bool) -> [SidebarStatusSections.Entry] {
        needsYou + readyToReview + running + idle + toShip.flatMap(\.entries)
            + (isDoneExpanded ? done : []) + (isArchivedExpanded ? archived : [])
    }

    /// The row an arrow key selects: the next or previous visible row, or
    /// the first or last when the selection is not among them. `nil` at
    /// either end.
    static func selection(
        movingFrom selected: TaskBoardItem.Subject?,
        by offset: Int,
        in visible: [TaskBoardItem.Subject]
    ) -> TaskBoardItem.Subject? {
        guard let index = selected.flatMap(visible.firstIndex(of:)) else {
            return offset > 0 ? visible.first : visible.last
        }
        let target = index + offset
        return visible.indices.contains(target) ? visible[target] : nil
    }

    /// The row to select once `selected` leaves the list, as when it was
    /// archived or marked done into a collapsed group: the next row it had
    /// that still shows, or else the one before it. `nil` when the list did
    /// not show it before, or shows nothing now.
    static func selection(
        replacing selected: TaskBoardItem.Subject,
        before: [TaskBoardItem.Subject],
        after: [TaskBoardItem.Subject]
    ) -> TaskBoardItem.Subject? {
        guard let index = before.firstIndex(of: selected) else { return nil }
        let remaining = Set(after)
        return before[(index + 1)...].first(where: remaining.contains)
            ?? before[..<index].last(where: remaining.contains)
    }
}
