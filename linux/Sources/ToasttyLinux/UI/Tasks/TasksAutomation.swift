#if TOASTTY_LINUX_APP_LOGIC
import CGtk
import CGtkShim
import CoreState
import Foundation
@testable import ToasttyAppLogic

extension LinuxAppController {
    /// Script commands for the tasks UI (Broadway tests):
    ///
    ///     click tasks.view.new           # activate a widget by name in the selected window or its dialog
    ///     tasks select 2                 # click the Tasks view's row 2 (0-based, rows only)
    ///     tasks open 2                   # double-click row 2 (opens its task space)
    ///     tasks key down|up|escape       # a key press in the Tasks view
    ///     tasks menu 0 Archive…          # row 0's context menu, choose an item by title
    ///     expect tasksView=shown tasksRows=3 tasksSelected=Fix_the_build
    func installTasksAutomation(ui: TasksUI) {
        AutomationScript.extensionCommands["click"] = { app, name, script in
            guard let window = app.selectedWindowController() else { script.reportFailure("click: no window"); return }
            let roots = [window.visibleDialog.map { widget($0) }, window.window].compactMap { $0 }
            guard let target = roots.lazy.compactMap({ Gtk.find(named: name, in: $0) }).first else {
                script.reportFailure("click: no widget named \(name)")
                return
            }
            gtk_widget_activate(target)
        }
        AutomationScript.extensionCommands["tasks"] = { [weak ui] app, argument, script in
            guard let ui, let window = app.selectedWindowController(),
                  let page = ui.feature(windowID: window.windowID)?.tasksPage else {
                script.reportFailure("tasks: no Tasks view")
                return
            }
            let parts = argument.split(separator: " ", maxSplits: 2).map(String.init)
            switch parts.first ?? "" {
            case "select", "open":
                guard parts.count > 1, let index = Int(parts[1]), let row = page.rowSubject(at: index) else {
                    script.reportFailure("tasks \(parts.first ?? ""): no row \(parts.dropFirst().first ?? "")")
                    return
                }
                page.automationClick(row, count: parts[0] == "open" ? 2 : 1)
            case "key":
                switch parts.dropFirst().first ?? "" {
                case "down": page.moveSelection(by: 1)
                case "up": page.moveSelection(by: -1)
                case "escape": _ = ui.store.send(.setTasksViewShown(windowID: window.windowID, shown: false))
                default: script.reportFailure("tasks key: down, up or escape")
                }
            case "wait-idle":
                // GTK defers tab closes and other button work to default
                // idle. An endlessly scheduled Tasks render must not starve it.
                var reachedIdle = false
                MainLoop.idle { reachedIdle = true }
                if !MainLoop.spin(untilMilliseconds: 2000, { reachedIdle }) {
                    script.reportFailure("tasks: a default-priority idle never ran")
                }
            case "menu":
                guard parts.count > 2, let index = Int(parts[1]), let row = page.rowSubject(at: index) else {
                    script.reportFailure("tasks menu: usage tasks menu <row> <title>")
                    return
                }
                if page.automationRunMenuItem(row, title: parts[2].replacingOccurrences(of: "_", with: " ")) == false {
                    script.reportFailure("tasks menu: no item \(parts[2])")
                }
            default:
                script.reportFailure("tasks: unknown \(argument)")
            }
        }
        // Quick entry:
        //     quick-entry open | type Fix_the_build | submit | create | cancel
        //     quick-entry picker workspace|agent | choose 1 | close-picker
        //     expect quickEntry=open quickEntryCanSubmit=true quickEntryPicker=agent
        AutomationScript.extensionCommands["quick-entry"] = { [weak ui] _, argument, script in
            guard let ui, let frontend = ui.quickEntryFrontend else { script.reportFailure("quick-entry: unavailable"); return }
            let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
            let model = frontend.automationModel
            switch parts.first ?? "" {
            case "open": ui.board.newTask?()
            case "type": frontend.automationType((parts.count > 1 ? parts[1] : "").replacingOccurrences(of: "_", with: " "))
            case "submit": model?.submit()
            case "create": model?.createTask()
            case "cancel": model?.cancel()
            case "picker": ui.tasks.quickEntry.togglePicker(parts.count > 1 && parts[1] == "agent" ? .agent : .workspace)
            case "close-picker": ui.tasks.quickEntry.closePicker(refocusText: true)
            case "screenshot":
                let url = script.resolvePath(parts.count > 1 ? parts[1] : "quick-entry.png")
                if let failure = frontend.automationScreenshot(url) { script.reportFailure("quick-entry screenshot: \(failure)") }
            case "choose":
                guard let picker = ui.tasks.quickEntry.picker, parts.count > 1, let index = Int(parts[1]),
                      picker.rows.indices.contains(index) else {
                    script.reportFailure("quick-entry choose: no row \(parts.dropFirst().first ?? "")")
                    return
                }
                picker.choose(rowID: picker.rows[index].id)
            default:
                script.reportFailure("quick-entry: unknown \(argument)")
            }
        }
        AutomationScript.summaryContributors.append { [weak ui] _ in
            ui?.quickEntryFrontend?.automationSummary ?? [:]
        }
        AutomationScript.summaryContributors.append { [weak ui] app in
            guard let ui, let window = app.selectedWindowController(),
                  let page = ui.feature(windowID: window.windowID)?.tasksPage else { return [:] }
            var summary = page.automationSummary
            summary.merge(ui.feature(windowID: window.windowID)?.sidebarView.automationSummary ?? [:]) { first, _ in first }
            summary["tasksView"] = window.visibleMainPage == TasksWindowFeature.tasksPageName ? "shown" : "hidden"
            summary["taskCount"] = String(ui.board.items().filter { $0.record != nil }.count)
            return summary
        }
    }
}

extension TasksPage {
    /// The row subjects, in list order.
    var rowSubjects: [TaskBoardItem.Subject] {
        automationListModel.compactMap { item in
            if case .row(let row) = item { return row.subject }
            return nil
        }
    }

    func rowSubject(at index: Int) -> TaskBoardItem.Subject? {
        let rows = rowSubjects
        return rows.indices.contains(index) ? rows[index] : nil
    }

    var automationSummary: [String: String] {
        var rows: [Row] = []
        var groups: [String] = []
        for item in automationListModel {
            switch item {
            case .row(let row): rows.append(row)
            case .header(_, let id, let count, _, _, _): groups.append("\(id):\(count)")
            case .lane: break
            }
        }
        var summary: [String: String] = [
            "tasksRows": String(rows.count),
            "tasksGroups": groups.joined(separator: ","),
            "tasksSelected": rows.first(where: \.isSelected)?.title ?? "",
            "tasksMarks": rows.map { TaskMarkWidget.cssClass($0.mark) }.joined(separator: ","),
        ]
        summary["tasksDetail"] = automationDetailTitle ?? ""
        summary["tasksDetailError"] = automationDetailError ?? ""
        summary["tasksBanner"] = automationBanner ?? ""
        return summary
    }
}
#endif
