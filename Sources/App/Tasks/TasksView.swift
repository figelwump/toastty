import AppKit
import CoreState
import SwiftUI

/// The groups the Tasks view lists, in sidebar order. Inbox shows only when
/// it has tasks; To ship lists its tasks under one header per project.
struct TasksViewSections: Equatable {
    struct Lane: Equatable, Identifiable {
        let projectTitle: String
        let entries: [SidebarStatusSections.Entry]
        var id: String { projectTitle }
    }

    var inbox: [SidebarStatusSections.Entry] = []
    var needsYou: [SidebarStatusSections.Entry] = []
    var running: [SidebarStatusSections.Entry] = []
    var toShip: [Lane] = []
    var done: [SidebarStatusSections.Entry] = []
    var archived: [SidebarStatusSections.Entry] = []

    static func make(_ items: [TaskBoardItem]) -> Self {
        func entries(_ group: TaskStage.Group) -> [SidebarStatusSections.Entry] {
            SidebarStatusSections.grouped(items.filter { $0.stage.group == group })
        }
        var sections = Self()
        sections.inbox = entries(.inbox)
        sections.needsYou = entries(.needsYou)
        sections.running = entries(.running)
        sections.toShip = Dictionary(grouping: entries(.toShip), by: { $0.item.projectTitle ?? "Other" })
            .map { Lane(projectTitle: $0.key, entries: $0.value) }
            .sorted { $0.projectTitle.localizedStandardCompare($1.projectTitle) == .orderedAscending }
        sections.done = entries(.done)
        sections.archived = entries(.archived)
        return sections
    }

    /// Every entry in display order, for picking a selection.
    var all: [SidebarStatusSections.Entry] {
        inbox + needsYou + running + toShip.flatMap(\.entries) + done + archived
    }
}

/// The full task board: a window-level mode that covers the workspace
/// content while it is shown. Selecting a workspace leaves it.
struct TasksView: View {
    let windowID: UUID
    @ObservedObject var store: AppStore
    @ObservedObject var board: TaskBoardStore
    /// Observed so agent activity redraws the list.
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore
    let newTask: (() -> Void)?

    @State private var isDoneExpanded = false
    @State private var isArchivedExpanded = false
    /// Taken on appear, so the terminal under the view loses keyboard focus.
    @FocusState private var isListFocused: Bool

    private static let detailWidth: CGFloat = 360

    var body: some View {
        let items = board.items()
        let sections = TasksViewSections.make(items)
        let selected = selectedItem(in: items, sections: sections)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let configError = board.configError {
                    configErrorBanner(configError)
                }
                ScrollView {
                    list(sections, selectedID: selected?.id)
                        .padding(.bottom, 16)
                }
                .focusable()
                .focusEffectDisabled()
                .focused($isListFocused)
            }
            .frame(maxWidth: .infinity)

            Rectangle()
                .fill(ToastyTheme.hairline)
                .frame(width: 1)

            Group {
                if let selected {
                    TasksViewDetail(
                        item: selected,
                        windowID: windowID,
                        store: store,
                        board: board,
                        sessionRuntimeStore: sessionRuntimeStore
                    )
                    .id(selected.id)
                } else {
                    Text("No tasks yet.")
                        .font(ToastyTheme.fontBody)
                        .foregroundStyle(ToastyTheme.mutedText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: Self.detailWidth)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(ToastyTheme.surfaceBackground)
        .onAppear {
            board.tasksViewDidOpen()
            isListFocused = true
        }
        .accessibilityIdentifier("tasks.view")
        .background {
            // Esc leaves the Tasks view, back to the selected workspace.
            Button("Close Tasks") { _ = store.send(.setTasksViewShown(windowID: windowID, shown: false)) }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Tasks")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ToastyTheme.primaryText)
            Spacer(minLength: 0)
            if let newTask {
                Button(action: newTask) {
                    Label("New Task", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x1A1206))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(ToastyTheme.accent, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tasks.view.new")
            }
            Button {
                _ = store.send(.setTasksViewShown(windowID: windowID, shown: false))
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ToastyTheme.inactiveText)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close the Tasks view (Esc)")
            .accessibilityLabel("Close Tasks")
            .accessibilityIdentifier("tasks.view.close")
        }
        .padding(.horizontal, 18)
        .padding(.top, 40)
        .padding(.bottom, 10)
    }

    private func configErrorBanner(_ message: String) -> some View {
        Text("tasks.toml: \(message)")
            .font(.system(size: 11.5))
            .foregroundStyle(ToastyTheme.sessionNeedsApprovalText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ToastyTheme.sessionNeedsApprovalBackground, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
            .accessibilityIdentifier("tasks.view.configError")
    }

    @ViewBuilder
    private func list(_ sections: TasksViewSections, selectedID: TaskBoardItem.Subject?) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if sections.inbox.isEmpty == false {
                groupHeader(.inbox, count: sections.inbox.count)
                rows(sections.inbox, selectedID: selectedID)
            }
            groupHeader(.needsYou, count: sections.needsYou.count, isHot: sections.needsYou.isEmpty == false)
            rows(sections.needsYou, selectedID: selectedID)
            groupHeader(.running, count: sections.running.count)
            rows(sections.running, selectedID: selectedID)
            groupHeader(.toShip, count: sections.toShip.reduce(0) { $0 + $1.entries.count })
            ForEach(sections.toShip) { lane in
                Text("\(lane.projectTitle) · \(lane.entries.count) \(lane.entries.count == 1 ? "task" : "tasks")")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ToastyTheme.sidebarTaskToShipMark)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
                rows(lane.entries, selectedID: selectedID)
            }
            collapsibleGroup(.done, entries: sections.done, isExpanded: $isDoneExpanded, selectedID: selectedID)
            if sections.archived.isEmpty == false {
                collapsibleGroup(.archived, entries: sections.archived, isExpanded: $isArchivedExpanded, selectedID: selectedID)
            }
        }
    }

    private func groupHeader(_ group: TaskStage.Group, count: Int, isHot: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(TaskBoardPresentation.groupTitle(group).uppercased())
                .tracking(0.8)
            Text("\(count)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(ToastyTheme.inactiveText)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(isHot ? Color(hex: 0xF2C46B) : ToastyTheme.mutedText)
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("tasks.view.group.\(group)")
    }

    private func collapsibleGroup(
        _ group: TaskStage.Group,
        entries: [SidebarStatusSections.Entry],
        isExpanded: Binding<Bool>,
        selectedID: TaskBoardItem.Subject?
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    groupHeader(group, count: entries.count)
                        .padding(.horizontal, -18)
                }
                .padding(.horizontal, 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(TaskBoardPresentation.groupTitle(group)), \(entries.count), \(isExpanded.wrappedValue ? "expanded" : "collapsed")")
            if isExpanded.wrappedValue {
                rows(entries, selectedID: selectedID)
            }
        }
    }

    private func rows(_ entries: [SidebarStatusSections.Entry], selectedID: TaskBoardItem.Subject?) -> some View {
        ForEach(entries) { entry in
            TasksViewRow(entry: entry, isSelected: entry.id == selectedID) {
                board.selectionByWindowID[windowID] = entry.id
            }
        }
    }

    /// The chosen task, or the first one that needs the user, or the first.
    private func selectedItem(in items: [TaskBoardItem], sections: TasksViewSections) -> TaskBoardItem? {
        if let chosen = board.selectionByWindowID[windowID], let item = items.first(where: { $0.id == chosen }) {
            return item
        }
        return sections.all.first?.item
    }
}

private struct TasksViewRow: View {
    let entry: SidebarStatusSections.Entry
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovered = false

    var body: some View {
        let item = entry.item
        HStack(alignment: .top, spacing: 10) {
            TaskStageMark(item: item)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ToastyTheme.primaryText)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let project = item.projectTitle {
                        SidebarView.sidebarTaskTag(project)
                    }
                    if let link = item.pullRequest {
                        Text("PR #\(link.number)")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color(hex: 0x8FD18F))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color(hex: 0x1D2A1D), in: RoundedRectangle(cornerRadius: 4))
                            .overlay { RoundedRectangle(cornerRadius: 4).stroke(Color(hex: 0x3C5C3C), lineWidth: 1) }
                    } else if let branch = item.branch {
                        Text(branch)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(ToastyTheme.sidebarSessionPathText)
                            .lineLimit(1)
                    }
                    Text(TaskBoardPresentation.statusLine(item))
                        .font(.system(size: 11.5))
                        .foregroundStyle(ToastyTheme.inactiveText.opacity(0.8))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text(TaskAge.label(since: item.activityAt, now: Date()))
                .font(.system(size: 11.5))
                .foregroundStyle(ToastyTheme.mutedText)
        }
        .padding(.vertical, 9)
        .padding(.leading, entry.isLinkedChild ? 36 : 18)
        .padding(.trailing, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color(hex: 0x1C1C1C) : (isHovered ? Color(hex: 0x161616) : Color.clear))
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(ToastyTheme.accent).frame(width: 2)
            }
        }
        .overlay(alignment: .top) {
            Rectangle().fill(ToastyTheme.hairline).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title), \(TaskBoardPresentation.statusLine(item))")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
        .accessibilityIdentifier("tasks.view.row")
    }
}

/// The detail pane: the task as written, where it stands, what happened to
/// it, and what can be done next.
private struct TasksViewDetail: View {
    let item: TaskBoardItem
    let windowID: UUID
    @ObservedObject var store: AppStore
    @ObservedObject var board: TaskBoardStore
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore

    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(TaskBoardPresentation.originLine(item, now: Date()))
                    .font(.system(size: 11.5))
                    .foregroundStyle(ToastyTheme.mutedText)
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ToastyTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let record = item.record, let coordinator = board.coordinator, item.stage.group == .inbox {
                    // Setup has not finished: the Inbox's own controls, with
                    // the workspace picker when triage could not place it.
                    TaskInboxPopover(taskID: record.id, records: coordinator.records, coordinator: coordinator) {}
                        .padding(-12)
                } else {
                    if let text = item.record?.text, text.isEmpty == false, text != item.title {
                        Text(text)
                            .font(.system(size: 12))
                            .foregroundStyle(ToastyTheme.inactiveText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    status
                    history
                    actions
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(ToastyTheme.sessionErrorText)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 40)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("tasks.view.detail")
    }

    private var status: some View {
        let stage = TaskBoardPresentation.stageDescription(item)
        return card("Status") {
            keyValue("Stage", stage.stage, why: stage.why)
            if let pullRequest = TaskBoardPresentation.pullRequestLine(item) {
                keyValue("PR", pullRequest)
            }
            if let branch = item.branch {
                keyValue("Branch", branch, monospaced: true)
            }
            if let agent = item.record?.resolved?.agent {
                keyValue("Agent", [agent, item.record?.resolved?.model].compactMap { $0 }.joined(separator: " · "))
            }
        }
    }

    @ViewBuilder
    private var history: some View {
        let lines = TaskBoardPresentation.history(item)
        if lines.isEmpty == false {
            card("History") {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(ToastyTheme.inactiveText)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if let workspaceID = item.taskSpaceWorkspaceID {
                Button("Open Task Space") { openTaskSpace(workspaceID) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("tasks.view.detail.open")
            }
            if let link = item.pullRequest, let url = URL(string: link.url) {
                Button("Open PR") { NSWorkspace.shared.open(url) }
            }
            if case .taskSpace(let workspaceID) = item.id, let coordinator = board.coordinator {
                Button("Track as Task") {
                    perform { _ = try coordinator.adopt(workspaceID: workspaceID) }
                }
                .help("Give this task space a task record, so its history stays after it closes.")
                .accessibilityIdentifier("tasks.view.detail.adopt")
            }
            if let record = item.record, item.stage == .needsYou(.taskSpaceClosed), let coordinator = board.coordinator {
                Button("Delete", role: .destructive) {
                    perform { try coordinator.delete(taskID: record.id) }
                }
            }
        }
        .controlSize(.small)
    }

    /// A titled box, as the mockup draws Status and History.
    private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(ToastyTheme.mutedText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Rectangle().fill(ToastyTheme.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 7, content: content)
                .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ToastyTheme.elevatedBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color(hex: 0x2A2A2A), lineWidth: 1) }
    }

    private func keyValue(_ key: String, _ value: String, why: String? = nil, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key)
                .font(.system(size: 12))
                .foregroundStyle(ToastyTheme.mutedText)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                .foregroundStyle(ToastyTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            if let why {
                Text(why)
                    .font(.system(size: 11))
                    .foregroundStyle(ToastyTheme.mutedText)
                    .lineLimit(2)
            }
        }
    }

    private func openTaskSpace(_ workspaceID: UUID) {
        let windowID = store.state.windows.first { $0.workspaceIDs.contains(workspaceID) }?.id ?? self.windowID
        store.selectWorkspace(
            windowID: windowID,
            workspaceID: workspaceID,
            preferringUnreadSessionPanelIn: sessionRuntimeStore
        )
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
