import CoreState
import SwiftUI

/// Tasks grouped by stage: Needs you and Running as rows, To ship as one
/// lane per project with its latest tasks, and Done as a count. The Tasks
/// view lists these. Kept apart from the view so the grouping can be tested
/// without hosting it.
struct SidebarStatusSections: Equatable {
    struct Entry: Equatable, Identifiable {
        let item: TaskBoardItem
        /// Drawn under the task that started it, which is in the same group.
        var isLinkedChild = false

        var id: TaskBoardItem.Subject { item.id }
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

    var needsYou: [Entry] = []
    var running: [Entry] = []
    var toShip: [Lane] = []
    var doneCount = 0

    var isEmpty: Bool {
        needsYou.isEmpty && running.isEmpty && toShip.isEmpty && doneCount == 0
    }

    /// `items` newest activity first, as the board gives them. Needs you
    /// keeps that order, so the latest request is on top; Running sorts by
    /// project and title, so rows hold still while agents work.
    static func make(_ items: [TaskBoardItem], releasable: (TaskBoardItem) -> Bool = { _ in false }) -> Self {
        var sections = Self()
        sections.needsYou = grouped(items.filter { $0.stage.group == .needsYou })
        sections.running = grouped(items.filter { $0.stage.group == .running }.sorted { lhs, rhs in
            let lhsProject = lhs.projectTitle ?? ""
            let rhsProject = rhs.projectTitle ?? ""
            return lhsProject != rhsProject
                ? lhsProject.localizedStandardCompare(rhsProject) == .orderedAscending
                : lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        })
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

    /// Puts each task right after the task that started it when both are
    /// in the group. One level only, as in the project cards.
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
