import AppKit
import CoreState
import SwiftUI

/// The groups the Tasks view lists, in sidebar order. To ship lists its
/// tasks under one header per project.
struct TasksViewSections: Equatable {
    struct Lane: Equatable, Identifiable {
        /// The project's root directory, or its title for tasks without one:
        /// two projects with the same title keep separate lanes.
        let id: String
        let projectTitle: String
        let entries: [SidebarStatusSections.Entry]
        /// Where Release starts a release; `nil` when the project cannot
        /// release from Toastty.
        var releaseWorkspaceID: UUID? = nil
    }

    var needsYou: [SidebarStatusSections.Entry] = []
    var running: [SidebarStatusSections.Entry] = []
    var idle: [SidebarStatusSections.Entry] = []
    var toShip: [Lane] = []
    var done: [SidebarStatusSections.Entry] = []
    var archived: [SidebarStatusSections.Entry] = []

    static func make(_ items: [TaskBoardItem], releasable: (TaskBoardItem) -> Bool = { _ in false }) -> Self {
        func entries(_ group: TaskStage.Group) -> [SidebarStatusSections.Entry] {
            SidebarStatusSections.grouped(items.filter { $0.stage.group == group })
        }
        var sections = Self()
        sections.needsYou = entries(.needsYou)
        sections.running = entries(.running)
        sections.idle = entries(.idle)
        sections.toShip = Dictionary(grouping: entries(.toShip), by: { SidebarStatusSections.laneKey($0.item) })
            .map { key, entries in
                Lane(
                    id: key,
                    projectTitle: entries.first?.item.projectTitle ?? "Other",
                    entries: entries,
                    releaseWorkspaceID: entries.map(\.item).first(where: releasable)?.projectWorkspaceID
                )
            }
            .sorted { $0.projectTitle.localizedStandardCompare($1.projectTitle) == .orderedAscending }
        sections.done = entries(.done)
        sections.archived = entries(.archived)
        return sections
    }

    /// Every entry in display order, for picking a selection.
    var all: [SidebarStatusSections.Entry] {
        needsYou + running + idle + toShip.flatMap(\.entries) + done + archived
    }

    /// The entries the list shows, in order: Done and Archived only while
    /// they are expanded.
    func visible(isDoneExpanded: Bool, isArchivedExpanded: Bool) -> [SidebarStatusSections.Entry] {
        needsYou + running + idle + toShip.flatMap(\.entries)
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

/// The full task board: a window-level mode that covers the workspace
/// content while it is shown. Selecting a workspace leaves it.
struct TasksView: View {
    let windowID: UUID
    @ObservedObject var store: AppStore
    @ObservedObject var board: TaskBoardStore
    /// Observed so agent activity redraws the list.
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore
    let newTask: (() -> Void)?
    var newTaskShortcutLabel: String? = nil

    @State private var isDoneExpanded = false
    @State private var isArchivedExpanded = false
    /// The row an arrow key selected, to scroll into view.
    @State private var keyboardSelection: TaskBoardItem.Subject?

    private static let detailWidth: CGFloat = 360

    var body: some View {
        let items = board.items()
        let sections = TasksViewSections.make(items, releasable: board.canRelease)
        let selected = board.tasksViewSelection(windowID: windowID, items: items)
        let visibleIDs = sections.visible(isDoneExpanded: isDoneExpanded, isArchivedExpanded: isArchivedExpanded).map(\.id)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let configError = board.configError {
                    configErrorBanner(configError)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        list(sections, selectedID: selected?.id)
                            .padding(.bottom, 16)
                    }
                    // The request can come while the view opens or while it
                    // already shows.
                    .onAppear { revealRequestedGroup(using: proxy) }
                    .onChange(of: board.revealGroupByWindowID[windowID]) { _, _ in
                        revealRequestedGroup(using: proxy)
                    }
                    .onChange(of: keyboardSelection) { _, subject in
                        guard let subject, let entry = sections.all.first(where: { $0.id == subject }) else { return }
                        proxy.scrollTo(Self.rowIdentity(entry))
                        keyboardSelection = nil
                    }
                }

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
            board.tasksViewListDidChange(windowID: windowID, visible: visibleIDs)
        }
        // A selected task that leaves the list, such as one just archived,
        // hands the selection to its neighbour.
        .onChange(of: visibleIDs) { _, ids in
            board.tasksViewListDidChange(windowID: windowID, visible: ids)
        }
        // Holds keyboard focus in this window while the view shows, so keys
        // never reach the terminal underneath, closes the view on Esc, and
        // moves the selection with Up and Down Arrow.
        .background {
            TasksViewKeySink(
                close: { _ = store.send(.setTasksViewShown(windowID: windowID, shown: false)) },
                move: { offset in
                    guard let next = TasksViewSections.selection(movingFrom: selected?.id, by: offset, in: visibleIDs) else { return }
                    board.selectionByWindowID[windowID] = next
                    keyboardSelection = next
                }
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        // A container's identifier would replace its children's.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tasks.view")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Tasks")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ToastyTheme.primaryText)
            Spacer(minLength: 0)
            if let newTask {
                Button(action: newTask) {
                    HStack(spacing: 7) {
                        Label("New Task", systemImage: "plus")
                        if let newTaskShortcutLabel {
                            Text(newTaskShortcutLabel)
                                .font(.system(size: 10.5, weight: .medium))
                                .padding(.horizontal, 4)
                                .overlay { RoundedRectangle(cornerRadius: 3).stroke(Color(hex: 0x9A6208), lineWidth: 1) }
                        }
                    }
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
            groupHeader(.needsYou, count: sections.needsYou.count, isHot: sections.needsYou.isEmpty == false)
            rows(sections.needsYou, selectedID: selectedID)
            groupHeader(.running, count: sections.running.count)
            rows(sections.running, selectedID: selectedID)
            groupHeader(.idle, count: sections.idle.count)
            rows(sections.idle, selectedID: selectedID)
            groupHeader(.toShip, count: sections.toShip.reduce(0) { $0 + $1.entries.count })
                .id(TaskStage.Group.toShip)
            ForEach(sections.toShip) { lane in
                HStack(spacing: 8) {
                    Text("\(lane.projectTitle) · \(lane.entries.count) \(lane.entries.count == 1 ? "task" : "tasks")")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ToastyTheme.sidebarTaskToShipMark)
                    Spacer(minLength: 0)
                    if let workspaceID = lane.releaseWorkspaceID, let coordinator = board.coordinator {
                        TaskReleaseButton(title: "Release…") {
                            TaskActions.release(workspaceID: workspaceID, coordinator: coordinator)
                        }
                        .accessibilityIdentifier("tasks.view.toShip.\(lane.projectTitle).release")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                rows(lane.entries, selectedID: selectedID)
            }
            collapsibleGroup(.done, entries: sections.done, isExpanded: $isDoneExpanded, selectedID: selectedID)
                .id(TaskStage.Group.done)
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
            .accessibilityLabel(Self.collapsibleGroupLabel(group, count: entries.count, isExpanded: isExpanded.wrappedValue))
            .background {
                SidebarSemanticTextBridge(text: Self.collapsibleGroupLabel(group, count: entries.count, isExpanded: isExpanded.wrappedValue))
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
            if isExpanded.wrappedValue {
                rows(entries, selectedID: selectedID)
            }
        }
    }

    static func collapsibleGroupLabel(_ group: TaskStage.Group, count: Int, isExpanded: Bool) -> String {
        "\(TaskBoardPresentation.groupTitle(group)), \(count), \(isExpanded ? "expanded" : "collapsed")"
    }

    /// Shows the group the sidebar asked for, once.
    private func revealRequestedGroup(using proxy: ScrollViewProxy) {
        guard let group = board.revealGroupByWindowID.removeValue(forKey: windowID) else { return }
        if group == .done {
            isDoneExpanded = true
        }
        // After the expanded rows lay out, so the group's top lands at the
        // top of the list.
        Task { @MainActor in
            proxy.scrollTo(group, anchor: .top)
        }
    }

    private func rows(_ entries: [SidebarStatusSections.Entry], selectedID: TaskBoardItem.Subject?) -> some View {
        ForEach(entries) { entry in
            TasksViewRow(entry: entry, isSelected: entry.id == selectedID) {
                board.selectionByWindowID[windowID] = entry.id
            }
            .contextMenu {
                if let coordinator = board.coordinator {
                    TaskContextMenuItems(sections: TaskBoardPresentation.menuItems(
                        entry.item,
                        isTriageConfigured: coordinator.isTriageConfigured
                    )) { menuItem in
                        TaskActions.runFromMenu(menuItem, coordinator: coordinator) { workspaceID in
                            TaskActions.openTaskSpace(
                                workspaceID: workspaceID,
                                fallbackWindowID: windowID,
                                store: store,
                                sessionRuntimeStore: sessionRuntimeStore
                            )
                        }
                    }
                }
            }
            // The lazy stack kept a row's old drawing when its task moved to
            // another group while the view showed, so a row is rebuilt
            // whenever its group or status line changes.
            .id(Self.rowIdentity(entry))
        }
    }

    private static func rowIdentity(_ entry: SidebarStatusSections.Entry) -> RowIdentity {
        RowIdentity(
            subject: entry.id,
            group: entry.item.stage.group,
            statusLine: TaskBoardPresentation.statusLine(entry.item),
            hasUnreadTurn: entry.item.hasUnreadTurn
        )
    }

    private struct RowIdentity: Hashable {
        let subject: TaskBoardItem.Subject
        let group: TaskStage.Group
        let statusLine: String
        let hasUnreadTurn: Bool
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
                // Bolder while a finished turn is unread, as in the sidebar.
                Text(item.title)
                    .font(.system(size: 13, weight: item.hasUnreadTurn ? .semibold : .medium))
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
            // A watched task space with no agent activity has no date.
            if item.activityAt > .distantPast {
                Text(TaskAge.label(since: item.activityAt, now: Date()))
                    .font(.system(size: 11.5))
                    .foregroundStyle(ToastyTheme.mutedText)
            }
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
        .background {
            SidebarSemanticTextBridge(text: accessibilityLabel)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
        .accessibilityIdentifier("tasks.view.row")
    }

    private var accessibilityLabel: String {
        let item = entry.item
        return "\(item.title), \(item.hasUnreadTurn ? "unread, " : "")\(TaskBoardPresentation.statusLine(item))"
    }
}

/// The Tasks view's first responder. SwiftUI focus alone did not keep the
/// terminal under the view from getting keys back when the window became
/// key again, so this AppKit view takes first responder in its own window
/// when it appears and again whenever a terminal has it while the view shows.
/// Esc here closes the view. It is not a keyboard shortcut: AppKit offers
/// those to the main window too, which would take Esc from a panel open over
/// the view, such as quick entry.
private struct TasksViewKeySink: NSViewRepresentable {
    let close: () -> Void
    /// Moves the selection by one row: -1 for Up Arrow, 1 for Down Arrow.
    let move: (Int) -> Void

    func makeNSView(context _: Context) -> KeySinkView {
        let view = KeySinkView()
        view.close = close
        view.move = move
        return view
    }

    func updateNSView(_ view: KeySinkView, context _: Context) {
        view.close = close
        view.move = move
    }

    final class KeySinkView: NSView {
        var close: (() -> Void)?
        var move: ((Int) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didUpdateNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.claimIfATerminalHasFocus() }
                })
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }

        private func claimIfATerminalHasFocus() {
            guard let window else { return }
            if window.firstResponder === window || (window.firstResponder as? NSView)?.enclosingTerminalHost != nil {
                window.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            // Esc closes and the plain arrows move the selection; other keys
            // stop here instead of reaching the terminal or beeping.
            let isPlain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            switch event.keyCode {
            case 53: close?()
            case 125 where isPlain: move?(1)
            case 126 where isPlain: move?(-1)
            default: break
            }
        }

        override func cancelOperation(_: Any?) {
            close?()
        }
    }
}

private extension NSView {
    /// The terminal this view is part of, if any.
    var enclosingTerminalHost: TerminalHostView? {
        var view: NSView? = self
        while let current = view {
            if let host = current as? TerminalHostView { return host }
            view = current.superview
        }
        return nil
    }
}

/// The detail pane's buttons: amber for the main action, outlined for the
/// rest, as in the mockup.
private struct TasksViewButtonStyle: ButtonStyle {
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: isPrimary ? .semibold : .medium))
            .foregroundStyle(isPrimary ? Color(hex: 0x1A1206) : ToastyTheme.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isPrimary ? ToastyTheme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                if isPrimary == false {
                    RoundedRectangle(cornerRadius: 7).stroke(Color(hex: 0x383838), lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(TaskBoardPresentation.originLine(item, now: Date()))
                    .font(.system(size: 11.5))
                    .foregroundStyle(ToastyTheme.mutedText)
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ToastyTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let record = item.record, let coordinator = board.coordinator, item.stage.isBeforeStart {
                    // Setup or the move has not finished: the setup card's
                    // controls, with the workspace picker when triage could
                    // not place it.
                    TaskSetupCard(taskID: record.id, records: coordinator.records, coordinator: coordinator)
                } else {
                    if let text = item.record?.text, text.isEmpty == false, text != item.title {
                        Text(text)
                            .font(.system(size: 12))
                            .foregroundStyle(ToastyTheme.inactiveText)
                            .lineLimit(14)
                            .textSelection(.enabled)
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
            Spacer(minLength: 0)
        }
        // The detail is short; long task text is cut to 14 lines.
        .background(ToastyTheme.surfaceBackground)
        .background {
            SidebarSemanticTextBridge(text: "Task detail, \(item.title), \(TaskBoardPresentation.stageDescription(item).stage)")
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
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

    /// The task's menu as buttons: where to go on one line, what to do on
    /// the next.
    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let coordinator = board.coordinator {
                ForEach(Array(TaskBoardPresentation.menuItems(item).enumerated()), id: \.offset) { _, section in
                    HStack(spacing: 8) {
                        ForEach(section, id: \.self) { menuItem in
                            menuButton(menuItem, coordinator: coordinator)
                        }
                    }
                }
            }
        }
    }

    private func menuButton(_ menuItem: TaskBoardPresentation.MenuItem, coordinator: TaskCoordinator) -> some View {
        let isPrimary: Bool
        let help: String?
        let identifier: String
        switch menuItem {
        case .openTaskSpace:
            (isPrimary, help, identifier) = (true, nil, "tasks.view.detail.open")
        case .trackAsTask:
            (isPrimary, help, identifier) = (false, "Give this task space a task record, so its history stays after it closes.", "tasks.view.detail.adopt")
        case .action(let action, _, _):
            (isPrimary, help, identifier) = (action.isPrimary, action.help, "tasks.view.detail.\(action)")
        case .openPullRequest:
            (isPrimary, help, identifier) = (false, nil, "tasks.view.detail.openPullRequest")
        case .delete:
            (isPrimary, help, identifier) = (false, nil, "tasks.view.detail.delete")
        case .retry, .retryTriage:
            // The setup card shows these in the pane.
            (isPrimary, help, identifier) = (false, nil, "tasks.view.detail.retry")
        }
        return Button(menuItem.title, role: menuItem.isDestructive ? .destructive : nil) {
            perform { try TaskActions.run(menuItem, coordinator: coordinator, openTaskSpace: openTaskSpace) }
        }
        .buttonStyle(TasksViewButtonStyle(isPrimary: isPrimary))
        .help(help ?? "")
        .accessibilityIdentifier(identifier)
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
        TaskActions.openTaskSpace(
            workspaceID: workspaceID,
            fallbackWindowID: windowID,
            store: store,
            sessionRuntimeStore: sessionRuntimeStore
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
