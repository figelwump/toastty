import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain

/// The Tasks tab: every task by where it stands, as the Mac's Tasks view
/// lists them. To ship comes first, one lane per project, because this is
/// where a release starts; then Needs you, Ready to review, Running and
/// Idle, then the Done count. Emits sibling rows so the List gives each its
/// own cell; a plain List's section headers would pin and cover rows.
struct ToasttyTasksTabView: View {
    let controller: HomeScreenController
    let refresh: () async -> Void
    let openWorkspace: (UUID) -> Void
    /// A group to show, from a card's To ship line or Done count in Home.
    @Binding var scrollRequest: ToasttyTasksScrollRequest?

    @State private var taskDetail: ToasttyTaskDetailSelection?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let toShipGroupID = "tasks-group-to-ship"
    static let doneGroupID = "tasks-group-done"

    static func laneID(_ id: String) -> String {
        "tasks-lane-\(id)"
    }

    var body: some View {
        let sections = controller.snapshot.taskBoard.map(MobileTaskSections.make) ?? MobileTaskSections()
        ScrollViewReader { proxy in
            List {
                content(sections)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 4, for: .scrollContent)
            .contentMargins(.bottom, 40, for: .scrollContent)
            .animation(reduceMotion ? nil : .default, value: sections)
            .onChange(of: scrollRequest, initial: true) { _, request in
                guard let request else { return }
                scrollRequest = nil
                // After the tab switch lays the list out.
                Task { @MainActor in
                    withAnimation(reduceMotion ? nil : .default) {
                        proxy.scrollTo(Self.scrollID(request.target, in: sections), anchor: .top)
                    }
                }
            }
        }
        .refreshable {
            await refresh()
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("toastty-mobile-tasks")
        .background(ToasttyDesignTokens.background)
        .navigationTitle("Tasks")
        .navigationBarTitleDisplayMode(.inline)
        .toasttyTaskDetailSheet($taskDetail, controller: controller, openWorkspace: openWorkspace)
        .toasttyTaskActionPresenter(controller)
    }

    static func scrollID(_ target: ToasttyTasksTabTarget, in sections: MobileTaskSections) -> String {
        switch target {
        case .toShip(let projectID):
            projectID.flatMap(sections.laneID(projectID:)).map(laneID) ?? toShipGroupID
        case .done:
            doneGroupID
        }
    }

    @ViewBuilder
    private func content(_ sections: MobileTaskSections) -> some View {
        if sections.isEmpty {
            ContentUnavailableView(
                "No tasks",
                systemImage: "checklist",
                description: Text("Tasks you start on your Mac or from Home show here.")
            )
            .foregroundStyle(ToasttyDesignTokens.secondaryText)
            .padding(.vertical, 32)
            .toasttyListRow()
        }
        if sections.toShip.isEmpty == false {
            toShipHeader(count: sections.toShipCount)
                .padding(.top, 10)
                .id(Self.toShipGroupID)
                .toasttyListRow(vertical: 0)
            ForEach(sections.toShip) { lane in
                laneHeader(lane)
                    .id(Self.laneID(lane.id))
                    .toasttyListRow(vertical: 0)
                ForEach(lane.tasks) { task in
                    ToasttyTaskListRow(task: task, controller: controller, openWorkspace: openWorkspace, openTask: openTask)
                }
            }
        }
        ForEach(TaskBucket.allCases, id: \.self) { bucket in
            let entries = sections.entries(bucket)
            if entries.isEmpty == false {
                ToasttyTaskGroupHeader(title: bucket.title, count: sections.count(bucket), tint: bucket.tint)
                    .padding(.top, 10)
                    .accessibilityIdentifier("toastty-tasks-group-\(bucket)")
                    .toasttyListRow(vertical: 0)
                ForEach(entries) { entry in
                    ToasttyTaskListRow(
                        task: entry.task, isLinkedChild: entry.isLinkedChild, isContext: entry.isContext,
                        controller: controller, openWorkspace: openWorkspace, openTask: openTask
                    )
                }
            }
        }
        if sections.doneCount > 0 {
            ToasttyTaskGroupHeader(title: "Done", count: sections.doneCount)
                .padding(.top, 10)
                .id(Self.doneGroupID)
                .accessibilityIdentifier("toastty-tasks-group-done")
                .toasttyListRow(vertical: 0)
        }
    }

    private func openTask(_ taskID: UUID) {
        taskDetail = ToasttyTaskDetailSelection(id: taskID, fallback: controller.snapshot.taskBoard?.task(id: taskID))
    }

    private func toShipHeader(count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.square")
            Text("TO SHIP")
                .tracking(0.8)
            Text("\(count)")
            Spacer(minLength: 0)
        }
        .font(.caption2.monospaced().weight(.semibold))
        .foregroundStyle(ToasttyDesignTokens.taskToShip)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("To ship, \(count)")
        .accessibilityIdentifier("toastty-tasks-group-to-ship")
    }

    /// A project's line in To ship: its name and count, and Release… when
    /// the project can release from Toastty.
    private func laneHeader(_ lane: MobileTaskSections.Lane) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(lane.projectTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ToasttyDesignTokens.taskToShip)
                    .lineLimit(1)
                Text("\(lane.count)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(ToasttyDesignTokens.mutedText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("toastty-tasks-lane-\(lane.id)")
            Spacer(minLength: 0)
            if let release = lane.release {
                ToasttyReleaseButton(
                    release: release,
                    controller: controller,
                    accessibilityIdentifier: "toastty-tasks-lane-release-\(lane.id)"
                )
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
    }
}
