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
    @State private var newTask: ToasttyNewTaskModel?
    @State private var newSession: ToasttyNewSessionModel?
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
        // As in Home: while the connection is not live, the list says that
        // it shows the last update, and offers Retry.
        .safeAreaInset(edge: .top, spacing: 0) {
            if controller.connectionNoticeMessage != nil {
                ToasttyConnectionNotice(controller: controller, refresh: refresh)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(ToasttyDesignTokens.background)
            }
        }
        .background(ToasttyDesignTokens.background)
        .navigationTitle("Tasks")
        .navigationBarTitleDisplayMode(.inline)
        // Home's +, as the Mac's Tasks view has a New Task button.
        .toolbar { newWorkToolbarItem }
        .toasttyNewTaskSheet($newTask, controller: controller)
        .toasttyNewSessionSheet($newSession, controller: controller)
        .toasttyTaskDetailSheet($taskDetail, controller: controller, openWorkspace: openWorkspace)
        // What a release or a task action started, as Home says it.
        .toasttySubspaceDoneNotice(controller)
        .toasttyTaskActionPresenter(controller)
    }

    /// The button draws its own amber circle, so it takes no bar background
    /// where the system would add one.
    @ToolbarContentBuilder
    private var newWorkToolbarItem: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) { newWorkButton }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { newWorkButton }
        }
    }

    private var newWorkButton: some View {
        ToasttyNewWorkButton(
            controller: controller,
            identifierPrefix: "toastty-mobile-tasks",
            newTask: $newTask,
            newSession: $newSession
        )
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
                    // The lane's line names the project.
                    ToasttyTaskListRow(
                        task: task, showsProject: false,
                        controller: controller, openWorkspace: openWorkspace, openTask: openTask
                    )
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
    /// the project can release from Toastty. Release… sits beside the name
    /// when the line has room, else under it, so a long name or a large
    /// text size does not cut the name to a few letters.
    private func laneHeader(_ lane: MobileTaskSections.Lane) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                laneTitle(lane)
                Spacer(minLength: 0)
                laneRelease(lane)
            }
            VStack(alignment: .leading, spacing: 4) {
                laneTitle(lane)
                laneRelease(lane)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
    }

    private func laneTitle(_ lane: MobileTaskSections.Lane) -> some View {
        HStack(spacing: 6) {
            Text(lane.projectTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ToasttyDesignTokens.taskToShip)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(lane.count)")
                .font(.caption2.monospaced())
                .foregroundStyle(ToasttyDesignTokens.mutedText)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("toastty-tasks-lane-\(lane.id)")
    }

    @ViewBuilder
    private func laneRelease(_ lane: MobileTaskSections.Lane) -> some View {
        if let release = lane.release {
            ToasttyReleaseButton(
                release: release,
                controller: controller,
                accessibilityIdentifier: "toastty-tasks-lane-release-\(lane.id)"
            )
        }
    }
}
