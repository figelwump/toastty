#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CoreState
import Foundation
@testable import ToasttyAppLogic

/// The selected task space's actions, at the end of the window's header bar
/// (the macOS workspace header's task controls). Open PR and the primary
/// action are separate buttons; rarer actions are in a menu. Task actions
/// go through the same coordinator and confirmations as Tasks.
@MainActor
final class WorkspaceTaskControl {
    let root = Gtk.hbox(spacing: 6, classes: ["workspace-task-control"])
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
        /// The primary button's title, or the state the control shows
        /// without one ("Done", "Merging PR #42…").
        let title: String
        var primary: Action?
        var menu: [TaskBoardPresentation.DetailAction] = []
        var progress = false
        var done = false
        var help: String?
        /// Why GitHub would not merge the pull request yet.
        var blocker: PullRequestMergeBlocker?
        /// A narrow column: Open PR shows as an icon, Merge drops the
        /// number, and the blocker shows as its dot.
        var compact = false

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
        gtk_widget_set_valign(root, GTK_ALIGN_CENTER)
        Gtk.setVisible(root, false)
        controller.onContentWidthChanged.append { [weak self] _ in
            guard let self else { return }
            self.render(self.ui.store.state)
        }
    }

    /// Below this column width the full labels would squeeze the title.
    private static let compactWidth: Int32 = 960

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
                // While GitHub reports a blocker, the status takes Merge's
                // place and Merge stays in the menu.
                result.primary = blocker == nil ? .task(.merge) : nil
                result.menu = blocker == nil ? [] : [.merge]
                result.menu += [.mergeWithoutChecks, .archive]
                result.help = TaskBoardPresentation.DetailAction.merge.help
                result.blocker = blocker
            case .merging, .cleaningUp, .closing:
                result.progress = true
            case .cleanupFailed(_, let reason):
                result = Presentation(taskID: taskID, link: link, title: "Cleanup Stopped")
                result.menu = [.cleanUp, .keepAsIs]
                result.help = reason
            case .done:
                result = Presentation(taskID: taskID, link: link, title: "Done")
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
        var next = presentation(state)
        if let width = controller?.contentWidth, width > 0, width < Self.compactWidth {
            next?.compact = true
        }
        guard next != rendered else { return }
        rendered = next
        Gtk.removeAllChildren(root)
        Gtk.setVisible(root, next != nil)
        guard let next else { return }

        if let blocker = next.blocker {
            let status = Gtk.hbox(spacing: 6, classes: ["workspace-task-status"])
            let dot = Gtk.hbox(classes: ["workspace-task-status-dot"])
            gtk_widget_set_valign(dot, GTK_ALIGN_CENTER)
            Gtk.append(status, dot)
            if !next.compact {
                Gtk.append(status, Gtk.label(blocker.label, classes: ["dim-label"], ellipsize: false))
            }
            gtk_widget_set_valign(status, GTK_ALIGN_CENTER)
            let pullRequest = next.link?.displayName ?? "the pull request"
            gtk_widget_set_tooltip_text(status, "\(blocker.label): GitHub would not merge \(pullRequest) yet")
            Gtk.append(root, status)
        }
        if next.progress {
            let spinner = gtk_spinner_new()!
            gtk_spinner_start(cast(spinner))
            gtk_widget_set_tooltip_text(spinner, next.title)
            Gtk.append(root, spinner)
            if !next.compact {
                Gtk.append(root, Gtk.label(next.title, classes: ["dim-label"], ellipsize: false))
            }
        }
        if let link = next.link {
            let button = next.compact
                ? Gtk.iconButton("adw-external-link-symbolic")
                : Gtk.button("Open PR #\(link.number)", classes: ["flat"])
            gtk_widget_set_tooltip_text(button, "Open PR #\(link.number) (\(link.displayName)) in the browser")
            Gtk.setName(button, "workspace.task-control.open-pr")
            Signal.connect(button, "clicked") { [weak self] in
                self?.perform(.openPullRequest, expected: next)
            }
            Gtk.append(root, button)
        }
        if let primary = next.primary {
            let suggested = primary == .task(.merge) || primary == .task(.markDone)
            let title = next.compact && primary == .task(.merge) ? "Merge" : next.title
            let button = Gtk.button(title, classes: suggested ? ["suggested-action", "task-success-action"] : [])
            if let help = next.help { gtk_widget_set_tooltip_text(button, help) }
            Gtk.setName(button, "workspace.task-control.primary")
            Signal.connect(button, "clicked") { [weak self] in
                self?.perform(primary, expected: next, fromPrimaryButton: true)
            }
            Gtk.append(root, button)
        }
        if !next.menu.isEmpty {
            let button = gtk_menu_button_new()!
            Gtk.setName(button, "workspace.task-control.options")
            if next.primary != nil || next.blocker != nil {
                gtk_menu_button_set_icon_name(cast(button), "view-more-symbolic")
                gtk_widget_set_tooltip_text(button, "More ways to finish this task")
            } else {
                // Done or a stopped cleanup: the state is the menu's label.
                gtk_menu_button_set_label(cast(button), next.title)
                if next.done { Gtk.addClasses(button, ["workspace-task-done"]) }
                gtk_widget_set_tooltip_text(button, next.help ?? next.title)
            }
            Gtk.addClasses(button, ["flat"])
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
            Gtk.append(root, button)
        }
        // Sets the task's buttons apart from the agent buttons after them.
        let separator = gtk_separator_new(GTK_ORIENTATION_VERTICAL)!
        Gtk.addClasses(separator, ["workspace-task-separator"])
        Gtk.append(root, separator)
    }

    /// Read the rendered button so Broadway checks catch a hidden or
    /// missing control, not just the state that would produce it.
    var automationLabel: String {
        guard gtk_widget_get_mapped(root) != 0 else { return "none" }
        if let button = Gtk.find(named: "workspace.task-control.primary", in: root),
           let label = gtk_button_get_label(cast(button)) {
            return String(cString: label).components(separatedBy: " #")[0]
        }
        if rendered?.progress == true { return "progress" }
        if rendered?.done == true { return "done" }
        if let button = Gtk.find(named: "workspace.task-control.open-pr", in: root),
           gtk_widget_get_mapped(button) != 0 {
            return "Open PR"
        }
        return "options"
    }

    /// The control's buttons, in order: `open-pr`, `primary`, `options`.
    var automationButtons: String {
        guard gtk_widget_get_mapped(root) != 0 else { return "none" }
        let names = ["open-pr", "primary", "options"].filter {
            Gtk.find(named: "workspace.task-control.\($0)", in: root).map { gtk_widget_get_mapped($0) != 0 } ?? false
        }
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }

    var automationCompact: Bool { rendered?.compact == true }

    /// The blocker the control shows in Merge's place, or "none".
    var automationStatus: String {
        guard gtk_widget_get_mapped(root) != 0, let blocker = rendered?.blocker else { return "none" }
        return blocker.label
    }
}
#endif
