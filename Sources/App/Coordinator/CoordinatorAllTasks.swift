import CoreState
import Foundation

/// The All tasks page beside the chat: every task the board knows of, in
/// its stage group, with the primary action and menu that the sidebar's
/// Needs you rows offer. The page sends back a row ID and an action ID;
/// `resolve` finds what that action is now, so a row drawn before the task
/// moved on never runs an action the task no longer offers.
enum CoordinatorAllTasks {
    struct Group: Encodable, Equatable {
        var id: String
        var title: String
        /// Every task in the group; Done and Archived send only the newest
        /// `finishedRowLimit` rows.
        var total: Int
    }

    struct Action: Encodable, Equatable {
        var id: String
        var title: String
        var isDestructive = false
    }

    struct Row: Encodable, Equatable {
        /// The task's ID, or its task space's for a task space with no task.
        var id: String
        var taskID: String?
        var title: String
        var project: String?
        var projectID: String? = nil
        var group: String
        var stageLabel: String
        var stageTone: String
        var status: String
        var activityAt: Date
        /// Whether the chat has a card for the task, which Open shows.
        var hasCard: Bool
        var primary: Action?
        /// The question the page asks before the primary action runs.
        var confirm: String?
        var menu: [[Action]]
    }

    /// What an action ID stands for now.
    enum Resolved: Equatable {
        /// The task's card in the chat, else its task space.
        case open(TaskBoardItem)
        case setup(taskID: UUID)
        case menu(TaskBoardPresentation.MenuItem)
        case release(projectWorkspaceID: UUID)
    }

    static let setupActionID = "setup"
    static let openActionID = "open"
    static let releaseActionID = "release"

    /// Done and Archived only grow; every chat refresh sends the rows.
    static let finishedRowLimit = 200

    static func groups(_ items: [TaskBoardItem]) -> [Group] {
        TaskStage.Group.allCases.map { group in
            Group(id: groupID(group), title: TaskBoardPresentation.groupTitle(group), total: items.count { $0.stage.group == group })
        }
    }

    /// The items to send: all of them, but the newest `finishedRowLimit` of
    /// Done and of Archived. `items` comes newest first.
    static func shownItems(_ items: [TaskBoardItem]) -> [TaskBoardItem] {
        var finished: [TaskStage.Group: Int] = [:]
        return items.filter { item in
            let group = item.stage.group
            guard group == .done || group == .archived else { return true }
            finished[group, default: 0] += 1
            return finished[group]! <= finishedRowLimit
        }
    }

    static func groupID(_ group: TaskStage.Group) -> String {
        switch group {
        case .needsYou: "needsYou"
        case .running: "running"
        case .idle: "idle"
        case .toShip: "toShip"
        case .done: "done"
        case .archived: "archived"
        }
    }

    static func rowID(_ item: TaskBoardItem) -> String {
        switch item.id {
        case .task(let id), .taskSpace(let id): id.uuidString
        }
    }

    /// Newest change first within each group; the page orders the groups.
    static func rows(
        _ items: [TaskBoardItem],
        cards: (UUID) -> CoordinatorChatCardIndex.TaskCards?,
        canRelease: (TaskBoardItem) -> Bool,
        isTriageConfigured: Bool,
        mergePolicy: (TaskBoardItem) -> String
    ) -> [Row] {
        items.map { item in
            let taskCards = item.taskID.flatMap(cards)
            var sections = menu(item, isTriageConfigured: isTriageConfigured).map { $0.map(action) }
            if item.stage.group == .toShip, item.projectWorkspaceID != nil, canRelease(item) {
                sections.append([releaseAction(item)])
            }
            var (label, tone) = CoordinatorChatTaskView.label(item)
            // Match the task's chat card and the sidebar: an open question
            // outranks every stage but a failed agent.
            if taskCards?.hasUnansweredQuestion == true, item.stage != .needsYou(.agentError) {
                (label, tone) = ("question", "amber")
            }
            let (primary, confirm) = primaryAction(item, cards: taskCards, mergePolicy: mergePolicy)
            return Row(
                id: rowID(item),
                taskID: item.taskID?.uuidString,
                title: item.title,
                project: projectTitle(item),
                projectID: projectID(item),
                group: groupID(item.stage.group),
                stageLabel: label,
                stageTone: tone,
                status: TaskBoardPresentation.statusLine(item),
                activityAt: item.activityAt,
                hasCard: taskCards != nil,
                primary: primary,
                confirm: confirm,
                menu: sections
            )
        }
    }

    /// The project a row names, which the page's project filter matches.
    static func projectTitle(_ item: TaskBoardItem) -> String? {
        item.projectTitle ?? item.record?.projectRoot.map { URL(filePath: $0).lastPathComponent }
    }

    static func projectID(_ item: TaskBoardItem) -> String? {
        item.projectID ?? item.record?.projectRoot ?? item.projectWorkspaceID.map { "workspace:\($0.uuidString)" }
    }

    struct Project: Encodable, Equatable {
        var id: String
        var title: String
        /// The normalized root for display matching; the filter ID stays stable.
        var rootPath: String? = nil
    }

    static func projects(_ items: [TaskBoardItem]) -> [Project] {
        var titles: [String: String] = [:]
        for item in items {
            if let id = projectID(item), let title = projectTitle(item) { titles[id] = title }
        }
        return titles.map {
            Project(id: $0.key, title: $0.value,
                    rootPath: $0.key.hasPrefix("/") ? TasksConfigFile.normalizedPath($0.key) : nil)
        }.sorted {
            $0.title == $1.title ? $0.id < $1.id : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    struct Today: Encodable, Equatable {
        struct Completion: Encodable, Equatable {
            var rowID: String
            var kind: String
            var at: Date
        }
        var completed: [Completion] = []
    }

    /// A release today takes precedence over a merge today. Mark Done and
    /// unrelated activity do not turn an old merge into today's work.
    static func today(_ items: [TaskBoardItem], now: Date, calendar: Calendar = .autoupdatingCurrent) -> Today {
        let completed = items.compactMap { item -> Today.Completion? in
            if let at = item.record?.shippedAt, calendar.isDate(at, inSameDayAs: now) {
                return .init(rowID: rowID(item), kind: "released", at: at)
            }
            if let at = item.record?.mergedAt, calendar.isDate(at, inSameDayAs: now) {
                return .init(rowID: rowID(item), kind: "merged", at: at)
            }
            return nil
        }.sorted { $0.at != $1.at ? $0.at > $1.at : $0.rowID < $1.rowID }
        return Today(completed: completed)
    }

    /// The Needs you row's primary action for a task that needs the user;
    /// Open for any other task that has a card or an open task space.
    static func primaryAction(
        _ item: TaskBoardItem,
        cards: CoordinatorChatCardIndex.TaskCards?,
        mergePolicy: (TaskBoardItem) -> String
    ) -> (Action?, confirm: String?) {
        let hasCard = cards != nil
        if TaskBoardPresentation.showsSetup(item), item.taskID != nil {
            return (Action(id: setupActionID, title: "Set Up"), nil)
        }
        if item.stage.group == .needsYou, let primary = SidebarNeedsYouRow.primaryAction(item, cards: cards) {
            switch primary {
            case .setup:
                return (Action(id: setupActionID, title: "Set Up"), nil)
            case .merge(let taskID, _):
                let question = SidebarNeedsYouRow.mergeQuestion(primary) ?? "Merge?"
                return (action(.action(.merge, taskID: taskID)), "\(question) \(mergePolicy(item))")
            case .action(let detail, let taskID):
                return (action(.action(detail, taskID: taskID)), nil)
            case .answer(let workspaceID):
                return (Action(id: actionID(.openTaskSpace(workspaceID: workspaceID)), title: "Answer"), nil)
            case .openTaskSpace(let workspaceID):
                return (Action(id: actionID(.openTaskSpace(workspaceID: workspaceID)), title: "Open"), nil)
            case .openInChat:
                // Open shows the task's card, which the task has.
                return (Action(id: openActionID, title: primary.title), nil)
            }
        }
        guard hasCard || item.taskSpaceWorkspaceID != nil else { return (nil, nil) }
        return (Action(id: openActionID, title: "Open"), nil)
    }

    /// The sidebar's menu for the task, with Delete for an archived task.
    /// `rows` adds Release for a To ship task whose project can release.
    static func menu(_ item: TaskBoardItem, isTriageConfigured: Bool) -> [[TaskBoardPresentation.MenuItem]] {
        var sections = TaskBoardPresentation.menuItems(item, isTriageConfigured: isTriageConfigured)
        if item.stage.group == .archived, let taskID = item.taskID {
            sections.append([.delete(taskID: taskID)])
        }
        return sections
    }

    static func releaseAction(_ item: TaskBoardItem) -> Action {
        Action(id: releaseActionID, title: "Release \(item.projectTitle ?? "the project")…")
    }

    static func action(_ item: TaskBoardPresentation.MenuItem) -> Action {
        Action(id: actionID(item), title: item.withoutShortcut.title, isDestructive: item.isDestructive)
    }

    /// A stable ID for a menu item, which `resolve` maps back.
    static func actionID(_ item: TaskBoardPresentation.MenuItem) -> String {
        switch item {
        case .openTaskSpace: "openTaskSpace"
        case .openPullRequest: "openPullRequest"
        case .trackAsTask: "trackAsTask"
        case .action(let action, _, _): "action:\(action.description)"
        case .retry: "retry"
        case .retryTriage: "retryTriage"
        case .delete: "delete"
        }
    }

    /// What `actionID` does for the row now, from the board's current
    /// items; `nil` when the row is gone or no longer offers it.
    static func resolve(
        rowID: String,
        actionID: String,
        items: [TaskBoardItem],
        canRelease: (TaskBoardItem) -> Bool,
        isTriageConfigured: Bool
    ) -> Resolved? {
        guard let item = items.first(where: { Self.rowID($0) == rowID }) else { return nil }
        if actionID == setupActionID {
            guard TaskBoardPresentation.showsSetup(item), let taskID = item.taskID else { return nil }
            return .setup(taskID: taskID)
        }
        if actionID == openActionID {
            if TaskBoardPresentation.showsSetup(item), let taskID = item.taskID { return .setup(taskID: taskID) }
            return .open(item)
        }
        if actionID == releaseActionID {
            guard item.stage.group == .toShip, canRelease(item), let project = item.projectWorkspaceID else { return nil }
            return .release(projectWorkspaceID: project)
        }
        let offered = menu(item, isTriageConfigured: isTriageConfigured).joined()
            .map(\.withoutShortcut)
        // The primary action of a Needs you row is in its menu too, except
        // Answer and Open, which open the task space.
        var candidates = Array(offered)
        if item.stage.group == .needsYou, let primary = SidebarNeedsYouRow.primaryAction(item) {
            switch primary {
            case .setup: break
            case .answer(let workspaceID), .openTaskSpace(let workspaceID):
                candidates.append(.openTaskSpace(workspaceID: workspaceID))
            case .openInChat:
                break // Its action ID is `openActionID`, handled above.
            case .merge(let taskID, _):
                candidates.append(.action(.merge, taskID: taskID))
            case .action(let detail, let taskID):
                candidates.append(.action(detail, taskID: taskID))
            }
        }
        return candidates.first { Self.actionID($0) == actionID }.map(Resolved.menu)
    }
}
