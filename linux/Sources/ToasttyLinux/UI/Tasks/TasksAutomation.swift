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
        AutomationScript.summaryContributors.append { [weak ui] app in
            guard let ui, let window = app.selectedWindowController(),
                  let page = ui.feature(windowID: window.windowID)?.tasksPage else { return [:] }
            var summary = page.automationSummary
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
