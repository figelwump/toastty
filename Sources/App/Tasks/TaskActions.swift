import AppKit
import CoreState
import Foundation
import SwiftUI

/// The task actions the top bar, the sidebar and the Tasks view share:
/// each asks what it must, runs the coordinator, and shows a refusal.
@MainActor
enum TaskActions {
    static func mergeWithoutChecks(workspaceID: UUID, store: AppStore, sessionRuntimeStore: SessionRuntimeStore) {
        WorkspaceMergeController.live(store: store, sessionRuntimeStore: sessionRuntimeStore)
            .requestMerge(workspaceID: workspaceID, mode: .mergeAndCleanUp, route: .direct)
    }

    /// Reads what archiving would end and lose, asks the user, then
    /// archives with what they chose.
    static func archive(taskID: UUID, coordinator: TaskCoordinator) {
        guard let record = coordinator.records.record(id: taskID) else { return }
        Task { @MainActor in
            let check: TaskArchiveCheck
            do {
                check = try await coordinator.archiveCheck(taskID: taskID)
            } catch {
                presentFailure("Unable to Archive \(record.title)", error.localizedDescription)
                return
            }
            if check.unsavedDocuments > 0 {
                presentFailure(
                    "Unable to Archive \(record.title)",
                    "The task space has unsaved documents. Save or close them, then archive."
                )
                return
            }
            guard let options = confirmArchive(record: record, check: check) else { return }
            do {
                try await coordinator.archive(taskID: taskID, options: options)
            } catch {
                presentFailure("Unable to Archive \(record.title)", error.localizedDescription)
            }
        }
    }

    /// Runs one of the actions the Tasks view's detail pane offers, which the
    /// command palette offers too. Archive asks first and shows its own
    /// failures; the others throw.
    static func run(_ action: TaskBoardPresentation.DetailAction, taskID: UUID, coordinator: TaskCoordinator) throws {
        switch action {
        case .merge:
            try coordinator.requestMerge(taskID: taskID)
        case .mergeWithoutChecks:
            try coordinator.requestMerge(taskID: taskID, route: .direct)
        case .cancelMerge:
            try coordinator.cancelMerge(taskID: taskID)
        case .markDone:
            _ = try coordinator.markDone(taskID: taskID)
        case .archive:
            archive(taskID: taskID, coordinator: coordinator)
        case .cleanUp:
            try coordinator.retryCleanup(taskID: taskID)
        case .keepAsIs:
            try coordinator.dismissCleanup(taskID: taskID)
        }
    }

    /// Runs one item of a task's menu, as the detail pane's buttons do.
    /// `openTaskSpace` selects a task space; the Inbox never offers it.
    static func run(
        _ item: TaskBoardPresentation.MenuItem,
        coordinator: TaskCoordinator,
        openTaskSpace: (UUID) -> Void
    ) throws {
        switch item {
        case .openTaskSpace(let workspaceID):
            openTaskSpace(workspaceID)
        case .openPullRequest(_, let url):
            NSWorkspace.shared.open(url)
        case .trackAsTask(let workspaceID):
            _ = try coordinator.adopt(workspaceID: workspaceID)
        case .action(let action, let taskID, _):
            try run(action, taskID: taskID, coordinator: coordinator)
        case .retry(let taskID, _), .retryTriage(let taskID):
            try coordinator.retry(taskID: taskID)
        case .delete(let taskID):
            try coordinator.delete(taskID: taskID)
        }
    }

    /// Runs a context menu's item, and shows a failure in an alert, since a
    /// menu has nowhere to show it. The task may have moved on while the
    /// menu was open, so an item its menu no longer offers does nothing.
    static func runFromMenu(
        _ item: TaskBoardPresentation.MenuItem,
        coordinator: TaskCoordinator,
        openTaskSpace: (UUID) -> Void
    ) {
        guard isOffered(item, coordinator: coordinator) else { return }
        perform(failureTitle(item, coordinator: coordinator)) {
            try run(item, coordinator: coordinator, openTaskSpace: openTaskSpace)
        }
    }

    private static func isOffered(_ item: TaskBoardPresentation.MenuItem, coordinator: TaskCoordinator) -> Bool {
        let subject: TaskBoardItem.Subject
        switch item {
        case .openTaskSpace, .openPullRequest: return true
        case .trackAsTask(let workspaceID): subject = .taskSpace(workspaceID)
        case .action(_, let taskID, _), .retry(let taskID, _), .retryTriage(let taskID), .delete(let taskID):
            subject = .task(taskID)
        }
        guard let board = coordinator.board,
              let current = board.items().first(where: { $0.id == subject }) else { return false }
        return TaskBoardPresentation.menuItems(current, isTriageConfigured: coordinator.isTriageConfigured)
            .joined()
            .contains(item.withoutShortcut)
    }

    private static func failureTitle(_ item: TaskBoardPresentation.MenuItem, coordinator: TaskCoordinator) -> String {
        let taskID: UUID
        let start: String
        switch item {
        case .openTaskSpace, .openPullRequest: return "Unable to Open"
        case .trackAsTask: return "Unable to Track as Task"
        case .action(let action, let id, _): (start, taskID) = (action.failureTitle, id)
        case .retry(let id, _), .retryTriage(let id): (start, taskID) = ("Unable to Retry", id)
        case .delete(let id): (start, taskID) = ("Unable to Delete", id)
        }
        guard let title = coordinator.records.record(id: taskID)?.title else { return start }
        return "\(start) \(title)"
    }

    /// Selects the task space in the window that holds it, or else in
    /// `fallbackWindowID`, which also hides that window's Tasks view.
    static func openTaskSpace(
        workspaceID: UUID,
        fallbackWindowID: UUID,
        store: AppStore,
        sessionRuntimeStore: SessionRuntimeStore
    ) {
        let windowID = store.state.windows.first { $0.workspaceIDs.contains(workspaceID) }?.id ?? fallbackWindowID
        store.selectWorkspace(
            windowID: windowID,
            workspaceID: workspaceID,
            preferringUnreadSessionPanelIn: sessionRuntimeStore
        )
    }

    static func release(workspaceID: UUID, coordinator: TaskCoordinator) {
        perform("Unable to Start the Release") {
            _ = try coordinator.release(workspaceID: workspaceID, caller: .unmanaged)
        }
    }

    static func perform(_ failureTitle: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            presentFailure(failureTitle, error.localizedDescription)
        }
    }

    /// The lines the archive alert shows: what closes, what goes, and what
    /// stays. Kept apart from the alert so it can be tested.
    static func archiveSummary(record: TaskRecord, check: TaskArchiveCheck) -> [String] {
        var lines: [String] = []
        if record.taskSpaceWorkspaceID != nil {
            let sessions = check.agentSessions == 0 ? "" :
                " and ends its \(check.agentSessions) agent \(check.agentSessions == 1 ? "session" : "sessions")"
            lines.append("Closes the task space\(sessions).")
        }
        if check.orphanedCommits > 0 {
            lines.append("\(check.orphanedCommits) \(check.orphanedCommits == 1 ? "commit" : "commits") at the worktree's HEAD \(check.orphanedCommits == 1 ? "is" : "are") on no branch, remote branch or tag.")
        }
        if check.hasWorktree {
            if check.uncommittedFiles > 0 {
                lines.append("Removes the worktree and its \(check.uncommittedFiles) uncommitted \(check.uncommittedFiles == 1 ? "file" : "files").")
            } else {
                lines.append("Removes the worktree.")
            }
        }
        if let branch = check.branch {
            if check.unpushedCommits > 0 {
                lines.append("Keeps the branch \(branch): \(check.unpushedCommits) of its commits are on no remote branch.")
            } else {
                lines.append("Deletes the local branch \(branch). It stays on the remote.")
            }
        }
        return lines
    }

    private static func confirmArchive(record: TaskRecord, check: TaskArchiveCheck) -> TaskArchiveOptions? {
        let alert = NSAlert()
        alert.messageText = "Archive \(record.title)?"
        alert.informativeText = archiveSummary(record: record, check: check).joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: check.uncommittedFiles > 0 ? "Archive and Discard Changes" : "Archive")
        alert.addButton(withTitle: "Cancel")

        var checkboxes: [NSButton] = []
        var closePullRequest: NSButton?
        if let pullRequest = check.pullRequest {
            let box = NSButton(checkboxWithTitle: "Close \(pullRequest.displayName) on GitHub", target: nil, action: nil)
            closePullRequest = box
            checkboxes.append(box)
        }
        var deleteUnpushed: NSButton?
        if check.unpushedCommits > 0 || check.orphanedCommits > 0 {
            let count = max(check.unpushedCommits, check.orphanedCommits)
            let box = NSButton(checkboxWithTitle: "Also delete the \(count) unpushed \(count == 1 ? "commit" : "commits")", target: nil, action: nil)
            deleteUnpushed = box
            checkboxes.append(box)
        }
        if checkboxes.isEmpty == false {
            let stack = NSStackView(views: checkboxes)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            stack.frame = NSRect(x: 0, y: 0, width: 320, height: CGFloat(checkboxes.count) * 22)
            alert.accessoryView = stack
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let options = TaskArchiveOptions(
            closePullRequest: closePullRequest?.state == .on,
            deleteUnpushedCommits: deleteUnpushed?.state == .on,
            discardChanges: check.uncommittedFiles > 0
        )
        if check.orphanedCommits > 0, options.deleteUnpushedCommits == false {
            presentFailure(
                "Unable to Archive \(record.title)",
                "The worktree's HEAD has commits on no branch, remote branch or tag. Push or branch them, or choose to delete them."
            )
            return nil
        }
        return options
    }

    static func presentFailure(_ title: String, _ message: String) {
        WorkspaceMergeCoordinator.presentAlert(title: title, message: message)
    }
}

/// A task's context menu items, with a divider between sections. The rows
/// that stand for a task in the sidebar and the Tasks view all show these.
struct TaskContextMenuItems: View {
    let sections: [[TaskBoardPresentation.MenuItem]]
    let run: (TaskBoardPresentation.MenuItem) -> Void

    var body: some View {
        ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
            if index > 0 {
                Divider()
            }
            ForEach(section, id: \.self) { item in
                Button(item.title, role: item.isDestructive ? .destructive : nil) { run(item) }
            }
        }
    }
}
