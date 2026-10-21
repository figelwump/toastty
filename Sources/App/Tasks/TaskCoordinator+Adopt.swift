import CoreState
import Foundation

extension TaskCoordinator {
    /// Gives a task space without a record one, so Toastty tracks it as a
    /// task from now on: its stage, its pull request, and its place in the
    /// Done history after it closes. Until then the task space is only
    /// watched. Adopting one that already has a record returns that record.
    @discardableResult
    func adopt(workspaceID: UUID) throws -> TaskRecord {
        guard let workspace = store.state.workspacesByID[workspaceID] else {
            throw TaskError("No open workspace has ID \(workspaceID.uuidString).")
        }
        if let taskID = workspace.taskID, let existing = records.record(id: taskID) {
            return existing
        }
        guard let parentID = store.state.subspaceParentIDsByWorkspaceID()[workspaceID],
              let parent = store.state.workspacesByID[parentID] else {
            throw TaskError("\"\(workspace.title)\" is a top-level workspace. Only a task space can become a task.")
        }
        guard let panelID = workspace.focusedPanelID ?? workspace.orderedTabs.first?.panels.keys.min(by: { $0.uuidString < $1.uuidString }) else {
            throw TaskError("\"\(workspace.title)\" has no panes.")
        }
        let title = TaskRecord.defaultTitle(for: workspace.title) ?? "Task"
        var record = TaskRecord(
            createdAt: now(),
            text: "",
            title: title,
            slug: TaskRecord.uniqueSlug(
                TaskRecord.sanitizedSlug(title) ?? "task",
                taken: Set(records.records.map(\.slug))
            ),
            titleSetByUser: true,
            source: .adopted,
            workspaceID: parentID,
            projectRoot: parent.rootDirectory,
            setup: .started,
            operation: TaskOperation(taskSpace: TaskOperation.TaskSpace(workspaceID: workspaceID, panelID: panelID))
        )
        record.pullRequestURL = TaskBoard.pullRequestLink(workspace)?.url
        do {
            try records.insert(record)
        } catch {
            throw TaskError("Toastty could not save the task: \(error.localizedDescription)")
        }
        _ = store.send(.setWorkspaceTaskID(workspaceID: workspaceID, taskID: record.id))
        // Saved now, so a crash cannot leave the record without its link.
        flushLayout()
        ToasttyLog.info("Adopted a task space as a task", category: .tasks, metadata: [
            "task_id": record.id.uuidString,
            "workspace_id": workspaceID.uuidString,
        ])
        return record
    }
}
