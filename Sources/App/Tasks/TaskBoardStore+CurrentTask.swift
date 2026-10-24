import CoreState
import Foundation

/// Which task the Tasks view and the command palette act on.
extension TaskBoardStore {
    /// The task a window's Tasks view shows in its detail pane: the chosen
    /// row, or else the first row in display order.
    func tasksViewSelection(windowID: UUID, items: [TaskBoardItem]? = nil) -> TaskBoardItem? {
        let items = items ?? self.items()
        if let chosen = selectionByWindowID[windowID], let item = items.first(where: { $0.id == chosen }) {
            return item
        }
        return TasksViewSections.make(items).all.first?.item
    }

    /// Keeps a window's Tasks view selection in the list it shows. When the
    /// selected row leaves it, for example once archived or marked done into
    /// the collapsed Done group, its neighbour takes the selection. A view
    /// that opens again compares with the list it showed last.
    func tasksViewListDidChange(windowID: UUID, visible: [TaskBoardItem.Subject]) {
        let before = tasksViewListByWindowID[windowID] ?? []
        tasksViewListByWindowID[windowID] = visible
        guard let chosen = selectionByWindowID[windowID], visible.contains(chosen) == false,
              let next = TasksViewSections.selection(replacing: chosen, before: before, after: visible) else { return }
        selectionByWindowID[windowID] = next
    }

    /// The task commands act on in a window: the Tasks view's selected row
    /// while the view shows, otherwise the task whose task space is the
    /// selected workspace. `nil` when neither applies.
    func currentTask(in selection: WindowCommandSelection, statuses: (UUID) -> [WorkspaceSessionStatus]) -> TaskBoardCurrentTask? {
        guard isEnabled else { return nil }
        if selection.window.showsTasksView {
            guard !coordinatorReviewWindowIDs.contains(selection.windowID) else { return nil }
            return tasksViewSelection(windowID: selection.windowID).map { TaskBoardCurrentTask(item: $0, source: .tasksView) }
        }
        let workspace = selection.workspace
        guard let state = coordinator?.store.state,
              workspace.taskID != nil || state.subspaceParentIDsByWorkspaceID()[workspace.id] != nil,
              let item = item(taskSpace: workspace, statuses: statuses(workspace.id)) else { return nil }
        // The top bar's Merge button, and its shortcut, read the pull
        // request from the task space's annotation, not the record.
        return TaskBoardCurrentTask(
            item: item,
            source: .selectedTaskSpace,
            hasMergeButton: TaskBoard.pullRequestLink(workspace) != nil
        )
    }
}

struct TaskBoardCurrentTask: Equatable {
    enum Source: Equatable {
        /// The row selected in the Tasks view.
        case tasksView
        /// The task space selected in the window, which the top bar's
        /// controls and their shortcuts act on too.
        case selectedTaskSpace
    }

    let item: TaskBoardItem
    let source: Source
    /// Whether the selected task space's top bar has a Merge button, which
    /// Option+Shift+M presses.
    var hasMergeButton = false
}
