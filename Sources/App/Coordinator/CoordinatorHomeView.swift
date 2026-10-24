import AppKit
import CoreState
import SwiftUI

/// Chat is supplied by the conversation adapter. Review data and task actions
/// remain available independently of that conversation's provider or lifecycle.
@MainActor
struct CoordinatorHomeView<Chat: View>: View {
    let windowID: UUID
    @ObservedObject var store: AppStore
    @ObservedObject var board: TaskBoardStore
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore
    @ObservedObject var reviews: CoordinatorReviewStore
    let actions: CoordinatorReviewActions
    let peekTask: (UUID) -> Void
    var peekContent: AnyView? = nil
    @ViewBuilder var chat: () -> Chat

    private enum Route: String, CaseIterable { case review = "Review queue", tasks = "All tasks" }
    @State private var route = Route.review
    @State private var reviewSelection = CoordinatorReviewPresentation.Selection()
    @State private var priorityError: String?

    private var selectedReview: UUID? { reviewSelection.taskID }
    private var reviewedBrief: CoordinatorReviewItem? { reviewSelection.reviewedBrief }

    var body: some View {
        let entries = CoordinatorReviewPresentation.queue(native: reviews.queue, saved: reviews.items, tasks: board.items())
        let selected = entries.first { $0.id == selectedReview }
        VStack(spacing: 0) {
            header(attentionCount: entries.filter { presentationState($0).needsAttention }.count)
            Divider()
            if route == .tasks {
                TasksView(
                    windowID: windowID, store: store, board: board,
                    sessionRuntimeStore: sessionRuntimeStore, newTask: board.newTask,
                    newTaskShortcutLabel: board.newTaskShortcutLabel(), showsHeader: false
                )
            } else {
                HSplitView {
                    chat()
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    Group {
                        if let peekContent {
                            peekContent
                        } else {
                            reviewColumn(entries, selected: selected)
                        }
                    }
                    .frame(minWidth: 360, idealWidth: 440, maxWidth: 620, maxHeight: .infinity)
                }
                .background {
                    CoordinatorHomeKeySink(close: close, move: { offset in
                        if peekContent == nil { moveSelection(offset, entries: entries, selected: selected) }
                    })
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }
        }
        .background(ToastyTheme.surfaceBackground)
        .onAppear {
            board.tasksViewDidOpen()
            selectInitialReview(entries)
            if board.revealGroupByWindowID[windowID] != nil { route = .tasks }
            updateCommandContext()
        }
        .onDisappear { board.setCoordinatorReviewShown(false, windowID: windowID) }
        .onChange(of: entries.map(\.id)) { _, _ in selectInitialReview(entries) }
        .onChange(of: route) { _, _ in updateCommandContext() }
        .onChange(of: board.revealGroupByWindowID[windowID]) { _, group in
            if group != nil { route = .tasks }
        }
        .onChange(of: board.selectionByWindowID[windowID]) { _, selection in
            if selection != nil { route = .tasks }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coordinator.home")
    }

    private func header(attentionCount: Int) -> some View {
        HStack(spacing: 14) {
            Text("Coordinator")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ToastyTheme.primaryText)
            Picker("Coordinator view", selection: $route) {
                ForEach(Route.allCases, id: \.self) { route in Text(route.rawValue).tag(route) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 208)
            .accessibilityLabel("Coordinator view")
            .accessibilityIdentifier("coordinator.home.route")
            if attentionCount > 0 {
                Text("\(attentionCount) need you")
                    .font(.system(size: 11.5))
                    .foregroundStyle(ToastyTheme.sessionNeedsApprovalText)
            }
            Spacer(minLength: 8)
            if let newTask = board.newTask {
                Button(action: newTask) {
                    HStack(spacing: 6) {
                        Label("New Task", systemImage: "plus")
                        if let shortcut = board.newTaskShortcutLabel() {
                            Text(shortcut).font(.system(size: 10, weight: .medium))
                        }
                    }
                }
                .buttonStyle(CoordinatorReviewButtonStyle(isPrimary: true))
                .accessibilityIdentifier("coordinator.home.newTask")
            }
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(ToastyTheme.inactiveText)
            .help("Close Coordinator (Esc)")
            .accessibilityLabel("Close Coordinator")
        }
        .padding(.horizontal, 18)
        .padding(.top, 40)
        .padding(.bottom, 12)
    }

    private func reviewColumn(_ entries: [CoordinatorReviewQueueEntry], selected: CoordinatorReviewQueueEntry?) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("REVIEW QUEUE").font(.system(size: 10.5, weight: .semibold)).tracking(0.8)
                Spacer()
                Text("Urgent · blocking · ready").font(.system(size: 10.5))
            }
            .foregroundStyle(ToastyTheme.inactiveText)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            if let error = reviews.loadError {
                warning("Review records could not be loaded. \(error)")
            }
            if let priorityError { warning(priorityError) }
            if entries.isEmpty {
                emptyQueue
            } else {
                queue(entries, selected: selected)
                    .frame(minHeight: 100, idealHeight: 210, maxHeight: 260)
                Divider()
                if let selected {
                    let latest = CoordinatorReviewPresentation.displayedReview(selected, saved: reviews.items)
                    let displayed = reviewedBrief?.taskID == selected.taskID ? reviewedBrief ?? latest : latest
                    if let displayed {
                        CoordinatorReviewDetailView(
                            reviewID: displayed.id, task: task(for: selected),
                            reviews: reviews, actions: actions, openTask: showTask, peekTask: peekTask,
                            reviewedBrief: reviewedBrief, currentReviewID: currentReviewID(for: selected),
                            reviewUpdateAvailable: latest.map { !CoordinatorReviewPresentation.matchesReviewedBrief($0, reviewed: reviewedBrief) } ?? false,
                            reviewUpdated: { await refreshReview(selected) }
                        )
                        .id(displayed.id)
                        .frame(maxHeight: .infinity)
                    } else {
                        missingBrief(selected)
                    }
                } else {
                    Text("Select a review to inspect its brief.")
                        .font(.system(size: 12.5)).foregroundStyle(ToastyTheme.inactiveText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(ToastyTheme.surfaceBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coordinator.review.queue")
    }

    private func queue(_ entries: [CoordinatorReviewQueueEntry], selected: CoordinatorReviewQueueEntry?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(entries) { entry in
                        CoordinatorReviewQueueRow(
                            entry: entry, review: CoordinatorReviewPresentation.displayedReview(entry, saved: reviews.items),
                            state: presentationState(entry), isSelected: selected?.id == entry.id
                        ) {
                            select(entry)
                        } priorityChanged: { priority in
                            guard let review = entry.review else { return }
                            do {
                                try actions.setPriority(reviewID: review.id, expectedRevision: review.revision, priority: priority)
                                priorityError = nil
                            } catch {
                                priorityError = error.localizedDescription
                            }
                        }
                        .contextMenu {
                            Button("Peek session") { peekTask(entry.taskID) }
                            Button("View task") { showTask(entry.taskID) }
                        }
                        .id(entry.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .onChange(of: selectedReview) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private var emptyQueue: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray").font(.system(size: 26)).foregroundStyle(ToastyTheme.mutedText)
            Text("No reviews waiting").font(.system(size: 14, weight: .medium))
            Text("Ready tasks will appear here, even when the coordinator is stopped.")
                .font(.system(size: 12)).foregroundStyle(ToastyTheme.inactiveText)
                .multilineTextAlignment(.center)
            Button("All tasks") { route = .tasks }.buttonStyle(CoordinatorReviewButtonStyle())
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(ToastyTheme.primaryText)
    }

    private func missingBrief(_ entry: CoordinatorReviewQueueEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Review brief needed", systemImage: "doc.badge.clock")
                .font(.system(size: 14, weight: .semibold))
            Text(entry.facts.taskTitle).font(.system(size: 17, weight: .semibold))
            Text(task(for: entry).map(TaskBoardPresentation.statusLine) ?? "This task needs your attention.")
                .font(.system(size: 12.5)).foregroundStyle(ToastyTheme.sessionNeedsApprovalText)
            Text("A structured brief and its evidence have not been published. Open the task to inspect its work.")
                .font(.system(size: 12.5)).foregroundStyle(ToastyTheme.inactiveText)
            HStack(spacing: 8) {
                Button("Peek session") { peekTask(entry.taskID) }
                    .buttonStyle(CoordinatorReviewButtonStyle())
                    .accessibilityIdentifier("coordinator.review.missingBrief.peek")
                Button("View task") { showTask(entry.taskID) }
                    .buttonStyle(CoordinatorReviewButtonStyle())
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(ToastyTheme.primaryText)
    }

    private func warning(_ message: String) -> some View {
        Text(message).font(.system(size: 11.5))
            .foregroundStyle(ToastyTheme.sessionNeedsApprovalText)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(ToastyTheme.sessionNeedsApprovalBackground)
    }

    private func showTask(_ taskID: UUID) {
        guard let task = board.items().first(where: { $0.taskID == taskID || $0.id == .task(taskID) }) else {
            priorityError = "The task record is unavailable. The saved brief and evidence remain available here."
            return
        }
        showTask(task)
    }

    private func showTask(_ task: TaskBoardItem) {
        board.selectionByWindowID[windowID] = task.id
        if task.stage.group == .done || task.stage.group == .archived {
            board.revealGroupByWindowID[windowID] = task.stage.group
        }
        route = .tasks
    }

    private func task(for entry: CoordinatorReviewQueueEntry) -> TaskBoardItem? {
        board.items().first { $0.taskID == entry.taskID || $0.id == .task(entry.taskID) }
    }

    private func presentationState(_ entry: CoordinatorReviewQueueEntry) -> CoordinatorReviewPresentation.State {
        guard let review = CoordinatorReviewPresentation.displayedReview(entry, saved: reviews.items) else { return .needsBrief }
        return CoordinatorReviewPresentation.state(review, task: task(for: entry))
    }

    private func moveSelection(_ offset: Int, entries: [CoordinatorReviewQueueEntry], selected: CoordinatorReviewQueueEntry?) {
        guard entries.isEmpty == false else { return }
        guard let selected, let index = entries.firstIndex(where: { $0.id == selected.id }) else {
            if let entry = offset > 0 ? entries.first : entries.last { select(entry) }
            return
        }
        let next = min(max(index + offset, 0), entries.count - 1)
        if next != index { select(entries[next]) }
    }

    private func updateCommandContext() {
        board.setCoordinatorReviewShown(route == .review, windowID: windowID)
    }

    private func selectInitialReview(_ entries: [CoordinatorReviewQueueEntry]) {
        reviewSelection.selectInitial(entries, saved: reviews.items)
    }

    private func select(_ entry: CoordinatorReviewQueueEntry) {
        reviewSelection.select(entry, saved: reviews.items)
    }

    private func currentReviewID(for entry: CoordinatorReviewQueueEntry) -> UUID? {
        guard let review = entry.review,
              board.pullRequests?.entries[review.pullRequestURL]?.lastError == nil else { return nil }
        return review.id
    }

    private func refreshReview(_ entry: CoordinatorReviewQueueEntry) async {
        if let url = entry.facts.pullRequestURL, let link = WorkspacePullRequestLink(annotationURL: url),
           let pullRequests = board.pullRequests {
            await pullRequests.refresh(link).value
            if let error = pullRequests.entries[link.url]?.lastError {
                priorityError = "The pull request could not be refreshed. \(error)"
                return
            }
        }
        // This explicit user refresh reads facts before selecting their saved
        // revision. Automatic background updates never replace that selection.
        actions.reconcile(tasks: board.items())
        guard selectedReview == entry.id,
              let updated = CoordinatorReviewPresentation.queue(native: reviews.queue, saved: reviews.items, tasks: board.items())
                .first(where: { $0.id == entry.id }) else { return }
        priorityError = nil
        select(updated)
    }

    private func close() { _ = store.send(.setTasksViewShown(windowID: windowID, shown: false)) }
}

private struct CoordinatorReviewQueueRow: View {
    let entry: CoordinatorReviewQueueEntry
    let review: CoordinatorReviewItem?
    let state: CoordinatorReviewPresentation.State
    let isSelected: Bool
    let select: () -> Void
    let priorityChanged: (CoordinatorReviewBrief.Priority?) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: select) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: state.symbol)
                        .foregroundStyle(state == .merged ? Color.green : state.needsAttention || state.isComplete ? ToastyTheme.sessionNeedsApprovalText : ToastyTheme.inactiveText)
                        .frame(width: 14).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.facts.taskTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text("\(review?.repository ?? URL(fileURLWithPath: entry.facts.projectRoot).lastPathComponent) · \(state.title)")
                            .font(.system(size: 10.5)).foregroundStyle(ToastyTheme.inactiveText).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if entry.review != nil {
                Menu {
                    Button("Use automatic priority") { priorityChanged(nil) }
                    Divider()
                    ForEach(CoordinatorReviewBrief.Priority.allCases, id: \.self) { priority in
                        Button { priorityChanged(priority) } label: {
                            if priority == entry.effectivePriority {
                                Label(CoordinatorReviewPresentation.priorityTitle(priority), systemImage: "checkmark")
                            } else {
                                Text(CoordinatorReviewPresentation.priorityTitle(priority))
                            }
                        }
                    }
                } label: {
                    Text(CoordinatorReviewPresentation.priorityTitle(entry.effectivePriority))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(entry.effectivePriority == .ready ? ToastyTheme.inactiveText : ToastyTheme.sessionNeedsApprovalText)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Set review priority")
                .accessibilityLabel("Priority for \(entry.facts.taskTitle)")
            }
        }
        .padding(10)
        .foregroundStyle(ToastyTheme.primaryText)
        .background(isSelected ? Color.white.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(isSelected ? ToastyTheme.accent.opacity(0.4) : .clear, lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coordinator.review.row")
    }
}

/// Absorb keys only while the hidden terminal still owns focus. Unlike the
/// task list's initial focus claim, this must leave the chat editor untouched.
private struct CoordinatorHomeKeySink: NSViewRepresentable {
    let close: () -> Void
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
            observers.removeAll()
            guard let window else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didUpdateNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.claimTerminalFocus() }
                })
            }
            DispatchQueue.main.async { [weak self] in self?.claimTerminalFocus() }
        }

        private func claimTerminalFocus() {
            guard let window else { return }
            var responderView = window.firstResponder as? NSView
            while let view = responderView {
                if view is TerminalHostView { window.makeFirstResponder(self); return }
                responderView = view.superview
            }
            if window.firstResponder == nil || window.firstResponder === window { window.makeFirstResponder(self) }
        }

        override func keyDown(with event: NSEvent) {
            let isPlain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            switch event.keyCode {
            case 53: close?()
            case 48 where event.modifierFlags.intersection([.command, .option, .control]).isEmpty:
                if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
                else { window?.selectNextKeyView(self) }
            case 125 where isPlain: move?(1)
            case 126 where isPlain: move?(-1)
            default: break
            }
        }

        override func cancelOperation(_: Any?) { close?() }
    }
}
