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

    private typealias DetailAction = TaskBoardPresentation.DetailAction
    private typealias MenuItem = TaskBoardPresentation.MenuItem

    private struct Presentation: Equatable {
        let taskID: UUID
        let link: WorkspacePullRequestLink?
        var primary: DetailAction?
        var menu: [MenuItem] = []
        var progress: String?
        var status: String?
        var help: String?
        var done = false
        /// Why GitHub would not merge the pull request yet.
        var blocker: PullRequestMergeBlocker?
        /// A narrow column: Open PR shows as an icon, Merge drops the
        /// number, and the blocker shows as its dot.
        var compact = false

        func offers(_ item: MenuItem) -> Bool {
            menu.contains(item) || primary.map { .action($0, taskID: taskID) } == item
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
              let taskID = workspace.taskID,
              let item = ui.board.item(
                  taskSpace: workspace, statuses: ui.sessionRuntimeStore.workspaceStatuses(for: workspace.id)
              ), item.taskID == taskID else { return nil }

        var result = Presentation(taskID: taskID, link: item.pullRequest)
        result.menu = TaskBoardPresentation.menuItems(
            item, currentWorkspaceID: workspace.id, isTriageConfigured: ui.coordinator.isTriageConfigured
        ).joined().filter { entry in
            if case .openPullRequest = entry { return false } // It gets its own button.
            return true
        }
        if result.menu.contains(.action(.merge, taskID: taskID)) {
            result.blocker = item.pullRequestState?.mergeBlocker
            if result.blocker == nil { result.primary = .merge }
        } else if result.menu.contains(.action(.markDone, taskID: taskID)) {
            result.primary = .markDone
        }
        if let primary = result.primary {
            result.menu.removeAll { $0 == .action(primary, taskID: taskID) }
        }

        let pr = result.link.map { " PR #\($0.number)" } ?? ""
        switch item.merge {
        case .checking?, .merging?: result.progress = "Merging\(pr)…"
        case .waitingForChecks?: result.progress = "Waiting for Checks\(pr)…"
        case .cleaningUp?: result.progress = "Cleaning Up\(pr)…"
        case nil: break
        }
        switch item.stage {
        case .done, .toShip:
            result.status = "Done"
            result.done = true
        case .needsYou(.cleanupStopped(let reason)):
            result.status = "Cleanup Stopped"
            result.help = reason
        default:
            break
        }
        return result.link != nil || result.primary != nil || result.menu.isEmpty == false
            || result.progress != nil || result.status != nil ? result : nil
    }

    func canMerge(_ state: AppState) -> Bool {
        guard let current = presentation(state) else { return false }
        return current.offers(.action(.merge, taskID: current.taskID))
    }

    func performMergeShortcut() -> Bool {
        guard let current = presentation(ui.store.state) else { return false }
        return perform(.action(.merge, taskID: current.taskID), expected: current)
    }

    @discardableResult
    private func perform(_ item: MenuItem, expected: Presentation) -> Bool {
        // A stale control must not act on another task or PR, or offer an
        // action the current task no longer allows.
        guard let controller, isOffered(item, matching: expected) else { return false }
        ui.runWorkspaceTaskMenuItem(item, windowID: controller.windowID, parent: controller.window) { [weak self] in
            self?.isOffered(item, matching: expected) == true
        }
        return true
    }

    private func isOffered(_ item: MenuItem, matching expected: Presentation) -> Bool {
        guard let current = presentation(ui.store.state),
              current.taskID == expected.taskID, current.link == expected.link else { return false }
        return current.offers(item)
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
        if let progress = next.progress {
            let spinner = gtk_spinner_new()!
            gtk_spinner_start(cast(spinner))
            gtk_widget_set_tooltip_text(spinner, progress)
            Gtk.append(root, spinner)
            if !next.compact {
                Gtk.append(root, Gtk.label(progress, classes: ["dim-label"], ellipsize: false))
            }
        }
        if let link = next.link {
            let button = next.compact
                ? Gtk.iconButton("adw-external-link-symbolic")
                : Gtk.button("Open PR #\(link.number)", classes: ["flat"])
            gtk_widget_set_tooltip_text(button, "Open PR #\(link.number) (\(link.displayName)) in the browser")
            Gtk.setName(button, "workspace.task-control.open-pr")
            Signal.connect(button, "clicked") { [weak self] in
                guard let self, let current = self.presentation(self.ui.store.state),
                      current.taskID == next.taskID, current.link == link,
                      let url = URL(string: link.url) else { return }
                _ = DesktopLauncher.open(url, parent: self.controller?.window)
            }
            Gtk.append(root, button)
        }
        if let primary = next.primary {
            let title = primary == .merge && !next.compact ? next.link.map { "Merge PR #\($0.number)" } ?? primary.title : primary.title
            let button = Gtk.button(title, classes: ["suggested-action"])
            gtk_widget_set_tooltip_text(button, primary.help)
            Gtk.setName(button, "workspace.task-control.primary")
            Signal.connect(button, "clicked") { [weak self] in
                self?.perform(.action(primary, taskID: next.taskID), expected: next)
            }
            Gtk.append(root, button)
        }
        if !next.menu.isEmpty {
            let button = gtk_menu_button_new()!
            Gtk.setName(button, "workspace.task-control.options")
            if let status = next.status, next.progress == nil {
                gtk_menu_button_set_label(cast(button), status)
                if next.done { Gtk.addClasses(button, ["workspace-task-done"]) }
                gtk_widget_set_tooltip_text(button, next.help ?? status)
            } else {
                gtk_menu_button_set_icon_name(cast(button), "view-more-symbolic")
                gtk_widget_set_tooltip_text(button, "More task actions")
            }
            Gtk.addClasses(button, ["flat"])
            let popover = gtk_popover_new()!
            let entries = Gtk.vbox()
            for item in next.menu {
                let entry = Gtk.button(item.title, classes: ["flat"])
                if case .action(let action, _, _) = item {
                    Gtk.setName(entry, "workspace.task-control.\(action)")
                    gtk_widget_set_tooltip_text(entry, action.help)
                }
                Signal.connect(entry, "clicked") { [weak self] in
                    gtk_popover_popdown(cast(popover))
                    self?.perform(item, expected: next)
                }
                Gtk.append(entries, entry)
            }
            gtk_popover_set_child(cast(popover), entries)
            gtk_menu_button_set_popover(cast(button), popover)
            Gtk.append(root, button)
        } else if let status = next.status, next.progress == nil {
            Gtk.append(root, Gtk.label(status, classes: ["dim-label"], ellipsize: false))
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
        if rendered?.progress != nil { return "progress" }
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
