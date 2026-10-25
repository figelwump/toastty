import CoreState
import Foundation

/// Which task the command palette acts on.
extension TaskBoardStore {
    /// The task commands act on in a window: while the coordinator chat
    /// shows, the task of its open card, else the task whose task space is
    /// the selected workspace. `nil` when neither applies.
    func currentTask(in selection: WindowCommandSelection, statuses: (UUID) -> [WorkspaceSessionStatus]) -> TaskBoardCurrentTask? {
        guard isEnabled else { return nil }
        guard let state = coordinator?.store.state else { return nil }
        if state.showsCoordinatorChat(windowID: selection.windowID) {
            guard let taskID = CoordinatorChatController.shared?.currentTaskID,
                  let item = items().first(where: { $0.taskID == taskID }) else { return nil }
            return TaskBoardCurrentTask(item: item, source: .coordinatorChat)
        }
        let workspace = selection.workspace
        guard workspace.taskID != nil || state.subspaceParentIDsByWorkspaceID()[workspace.id] != nil,
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
        /// The task of the card open in the coordinator chat.
        case coordinatorChat
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
