import CoreState
import SwiftUI

/// The Status segment's groups, below the Inbox: Needs you and Running as
/// rows, To ship as one line per project, and Done as a count. Kept apart
/// from the view so the grouping can be tested without hosting it.
struct SidebarStatusSections: Equatable {
    struct Entry: Equatable, Identifiable {
        let item: TaskBoardItem
        /// Drawn under the task that started it, which is in the same group.
        var isLinkedChild = false

        var id: TaskBoardItem.Subject { item.id }
    }

    struct Lane: Equatable, Identifiable {
        let projectTitle: String
        let count: Int
        /// When the oldest task in the lane merged.
        let oldestMergedAt: Date?

        var id: String { projectTitle }
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
    static func make(_ items: [TaskBoardItem]) -> Self {
        var sections = Self()
        sections.needsYou = grouped(items.filter { $0.stage.group == .needsYou })
        sections.running = grouped(items.filter { $0.stage.group == .running }.sorted { lhs, rhs in
            let lhsProject = lhs.projectTitle ?? ""
            let rhsProject = rhs.projectTitle ?? ""
            return lhsProject != rhsProject
                ? lhsProject.localizedStandardCompare(rhsProject) == .orderedAscending
                : lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        })
        let shipping = Dictionary(grouping: items.filter { $0.stage == .toShip }, by: { $0.projectTitle ?? "Other" })
        sections.toShip = shipping.map { title, lane in
            Lane(projectTitle: title, count: lane.count, oldestMergedAt: lane.compactMap { $0.record?.mergedAt }.min())
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
/// project card; the rest open the Tasks view.
struct SidebarStatusSegment<RowContent: View>: View {
    let sections: SidebarStatusSections
    let openTasksView: (TaskBoardItem.Subject?) -> Void
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
                header("Needs you", count: sections.needsYou.count, isHot: true)
                rows(sections.needsYou)
            }
            if sections.running.isEmpty == false {
                header("Running", count: sections.running.count)
                rows(sections.running)
            }
            if sections.toShip.isEmpty == false {
                header("To ship", count: sections.toShip.reduce(0) { $0 + $1.count })
                ForEach(sections.toShip) { lane in
                    laneRow(lane)
                }
            }
            if sections.doneCount > 0 {
                Button {
                    openTasksView(nil)
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
                .accessibilityLabel("Done, \(sections.doneCount) tasks, opens the Tasks view")
                .accessibilityIdentifier("sidebar.status.done")
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 10)
        .accessibilityIdentifier("sidebar.status")
    }

    private func rows(_ entries: [SidebarStatusSections.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(entries) { entry in
                row(entry)
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

    private func laneRow(_ lane: SidebarStatusSections.Lane) -> some View {
        Button {
            openTasksView(nil)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(ToastyTheme.sidebarTaskToShipMarkBackground)
                    .frame(width: 10, height: 10)
                    .overlay {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 6.5, weight: .black))
                            .foregroundStyle(ToastyTheme.sidebarTaskToShipMark)
                    }
                    .frame(width: 12, height: 17)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(lane.projectTitle) · \(lane.count) \(lane.count == 1 ? "task" : "tasks")")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ToastyTheme.sidebarSessionAgentText)
                        .lineLimit(1)
                        .frame(minHeight: 17, alignment: .leading)
                    let detail = SidebarStatusSections.laneDetail(lane, now: Date())
                    if detail.isEmpty == false {
                        Text(detail)
                            .font(ToastyTheme.fontWorkspaceSessionChip)
                            .foregroundStyle(ToastyTheme.sidebarSummaryText)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarStatusRowButtonStyle())
        .accessibilityLabel("\(lane.projectTitle), \(lane.count) tasks to ship")
        .accessibilityIdentifier("sidebar.status.toShip.\(lane.projectTitle)")
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title), \(TaskBoardPresentation.statusLine(item))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
    }
}
