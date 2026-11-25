#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CoreState
import Foundation
@testable import ToasttyAppLogic

/// The selected task space's subtitle, matching the macOS workspace header.
/// Task actions go through the same coordinator and confirmations as Tasks.
@MainActor
final class WorkspaceTaskControl {
    let root = Gtk.hbox(spacing: 4, classes: ["workspace-task-control"])
    private unowned let ui: TasksUI
    private weak var controller: LinuxWindowController?
    private var rendered: Presentation?

    private enum Action: Equatable {
        case openPullRequest
        case task(TaskBoardPresentation.DetailAction)
    }

    private struct Presentation: Equatable {
        let taskID: UUID
        let link: WorkspacePullRequestLink?
        let title: String
        var primary: Action?
        var menu: [TaskBoardPresentation.DetailAction] = []
        var progress = false
        var done = false
        var help: String?
        var checksRunning = false

        var canMerge: Bool {
            offers(.merge)
        }

        func offers(_ action: TaskBoardPresentation.DetailAction) -> Bool {
            primary == .task(action) || menu.contains(action)
        }
    }

    init(ui: TasksUI, controller: LinuxWindowController) {
        self.ui = ui
        self.controller = controller
        Gtk.setName(root, "workspace.task-control")
        gtk_widget_set_halign(root, GTK_ALIGN_CENTER)
        Gtk.setVisible(root, false)
    }

    private func presentation(_ state: AppState) -> Presentation? {
        guard let windowID = controller?.windowID,
              state.window(id: windowID)?.showsTasksView != true,
              let workspace = state.workspaceSelection(in: windowID)?.workspace,
              workspace.parentWorkspaceID != nil,
              let taskID = workspace.taskID,
              ui.coordinator.records.record(id: taskID) != nil else { return nil }

        let runtime = ui.sessionRuntimeStore
        let item = ui.board.item(taskSpace: workspace, statuses: runtime.workspaceStatuses(for: workspace.id))
        let request = runtime.workspaceMergeRequests[workspace.id]
        if let link = WorkspaceMergePresentation.pullRequestLink(in: workspace),
           let merge = WorkspaceMergePresentation.make(
               workspace: workspace,
               request: request,
               isCheckingMerge: item?.merge == .checking,
               isTaskMerged: item?.hasMerged == true,
               pullRequestState: runtime.pullRequestStateCache?.state(for: link)
           ) {
            var result = Presentation(taskID: taskID, link: link, title: merge.title)
            switch merge {
            case .ready(_, _, let blocker):
                result.primary = blocker == nil ? .task(.merge) : .openPullRequest
                result.menu = blocker == nil ? [] : [.merge]
                result.menu += [.mergeWithoutChecks, .archive]
                result.help = blocker.map { "\($0.label): open \(link.displayName)" }
                    ?? TaskBoardPresentation.DetailAction.merge.help
                result.checksRunning = blocker == .checksRunning
            case .merging, .cleaningUp, .closing:
                result.progress = true
            case .cleanupFailed(_, let reason):
                result.menu = [.cleanUp, .keepAsIs]
                result.help = reason
            case .done:
                result.done = true
                result.menu = item?.cleanupHeldUntil != nil ? [.closeTaskSpace] : [.archive]
            }
            return result
        }

        switch item?.stage {
        case .needsYou(.readyForReview):
            return Presentation(
                taskID: taskID, link: nil, title: "Complete Task", primary: .task(.markDone),
                help: "Mark this task done and close its task space"
            )
        case .done:
            return Presentation(taskID: taskID, link: nil, title: "Done", menu: [.archive], done: true)
        default:
            return Presentation(taskID: taskID, link: nil, title: "Archive Task…", primary: .task(.archive))
        }
    }

    func canMerge(_ state: AppState) -> Bool { presentation(state)?.canMerge == true }

    func performMergeShortcut() -> Bool {
        guard let current = presentation(ui.store.state), current.canMerge else { return false }
        perform(.task(.merge), expected: current)
        return true
    }

    private func perform(_ action: Action, expected: Presentation, fromPrimaryButton: Bool = false) {
        // A menu or delayed click must not act on a different task or PR
        // after a workspace selection, or merge when the button now opens the PR.
        guard let current = presentation(ui.store.state),
              current.taskID == expected.taskID, current.link == expected.link,
              !fromPrimaryButton || current.primary == action else { return }
        switch action {
        case .openPullRequest:
            guard current.primary == action else { return }
            if let url = current.link.flatMap({ URL(string: $0.url) }) {
                _ = DesktopLauncher.open(url, parent: controller?.window)
            }
        case .task(.markDone):
            guard current.offers(.markDone) else { return }
            confirmComplete(taskID: current.taskID)
        case .task(let action):
            guard current.offers(action) else { return }
            TaskActions.perform(action.failureTitle) {
                try TaskActions.run(action, taskID: current.taskID, coordinator: ui.coordinator)
            }
        }
    }

    private func confirmComplete(taskID: UUID) {
        guard let controller, let record = ui.coordinator.records.record(id: taskID) else { return }
        TaskActions.perform("Unable to Complete Task") {
            let check = try ui.coordinator.completeCheck(taskID: taskID)
            guard check.unsavedDocuments == 0 else {
                throw TaskError("The task space has unsaved documents. Save or close them, then complete the task.")
            }
            Dialogs.confirm(
                parent: controller.window, heading: "Complete “\(record.title)”?",
                body: TaskActions.completeSummary(check).joined(separator: "\n"),
                confirmLabel: "Complete Task", destructive: false, confirmIsDefault: true
            ) { [weak self] in
                guard let self, let current = self.presentation(self.ui.store.state),
                      current.taskID == taskID, current.offers(.markDone) else { return }
                TaskActions.perform("Unable to Complete Task") {
                    try self.ui.coordinator.complete(taskID: taskID)
                }
            }
        }
    }

    func render(_ state: AppState) {
        let next = presentation(state)
        guard next != rendered else { return }
        rendered = next
        Gtk.removeAllChildren(root)
        Gtk.setVisible(root, next != nil)
        guard let next else { return }

        let buttons = Gtk.hbox(classes: next.primary != nil && !next.menu.isEmpty ? ["linked"] : [])
        Gtk.append(root, buttons)
        let suggested = next.primary == .task(.merge) || next.primary == .task(.markDone)
        if let primary = next.primary {
            let button = Gtk.button(next.title, classes: suggested ? ["suggested-action"] : [])
            if let help = next.help { gtk_widget_set_tooltip_text(button, help) }
            Gtk.setName(button, "workspace.task-control.primary")
            Signal.connect(button, "clicked") { [weak self] in
                self?.perform(primary, expected: next, fromPrimaryButton: true)
            }
            Gtk.append(buttons, button)
        }
        if !next.menu.isEmpty {
            let button = gtk_menu_button_new()!
            Gtk.setName(button, "workspace.task-control.options")
            if next.primary != nil {
                gtk_menu_button_set_icon_name(cast(button), "pan-down-symbolic")
                if suggested { Gtk.addClasses(button, ["suggested-action"]) }
            } else {
                gtk_menu_button_set_label(cast(button), next.title)
                Gtk.addClasses(button, next.done ? ["flat", "workspace-task-done"] : ["flat"])
            }
            gtk_widget_set_tooltip_text(button, next.primary != nil ? "More ways to finish this task" : next.help ?? next.title)
            let popover = gtk_popover_new()!
            let entries = Gtk.vbox()
            for action in next.menu {
                let title: String
                switch action {
                case .merge: title = next.link.map { "Merge PR #\($0.number)" } ?? action.title
                case .archive: title = "Archive Task…"
                case .cleanUp: title = "Retry Clean Up"
                case .keepAsIs: title = "Don’t Clean Up"
                default: title = action.title
                }
                let entry = Gtk.button(title, classes: ["flat"])
                Gtk.setName(entry, "workspace.task-control.\(action)")
                Signal.connect(entry, "clicked") { [weak self] in
                    gtk_popover_popdown(cast(popover))
                    self?.perform(.task(action), expected: next)
                }
                Gtk.append(entries, entry)
            }
            gtk_popover_set_child(cast(popover), entries)
            gtk_menu_button_set_popover(cast(button), popover)
            Gtk.append(buttons, button)
        }
        if next.progress {
            let spinner = gtk_spinner_new()!
            gtk_spinner_start(cast(spinner))
            Gtk.append(root, spinner)
            Gtk.append(root, Gtk.label(next.title, classes: ["dim-label"]))
        }
        if next.checksRunning {
            Gtk.append(root, Gtk.label(PullRequestMergeBlocker.checksRunning.label, classes: ["dim-label"]))
        }
    }

    /// Read the rendered button so Broadway checks catch a hidden or
    /// missing control, not just the state that would produce it.
    var automationLabel: String {
        guard gtk_widget_get_mapped(root) != 0 else { return "none" }
        if let button = Gtk.find(named: "workspace.task-control.primary", in: root),
           let label = gtk_button_get_label(cast(button)) {
            return String(cString: label).components(separatedBy: " #")[0]
        }
        return rendered?.progress == true ? "progress" : "options"
    }
}
#endif
