import CoreState
import Foundation

/// What the workspace page shows for one top-level workspace, and what
/// `workspace.overview` returns: the synopsis, the latest tasks with what
/// they did, every task of the workspace, and its kept Scratchpads.
struct WorkspaceOverviewModel {
    struct Synopsis: Equatable {
        var text: String
        /// An agent wrote it (`workspace.synopsis.set`); otherwise Toastty
        /// made it from the workspace's tasks.
        var isWritten: Bool
        var updatedAt: Date?
    }

    struct RecentTask {
        var item: TaskBoardItem
        /// The agent's latest reply, or, without one, the task's request.
        var outcome: String?
        var outcomeIsRequest: Bool
    }

    struct Scratchpad: Equatable {
        var entry: WorkspaceScratchpadEntry
        var title: String
        var purpose: String?
        var revision: Int
        var updatedAt: Date?
        var isMissing: Bool
        var isLinked: Bool { entry.source?.isLinked == true }
        var sourceTaskTitle: String? { entry.source?.taskTitle }
    }

    static let recentCount = 5

    var workspaceID: UUID
    var title: String
    var projectRoot: String?
    var synopsis: Synopsis
    /// The workspace's tasks, every stage.
    var items: [TaskBoardItem]
    var recent: [RecentTask]
    /// Everything older than Recent, in the same activity order.
    var pastItems: ArraySlice<TaskBoardItem> { items.dropFirst(recent.count) }
    var scratchpads: [Scratchpad]
    var openCount: Int
    var finishedCount: Int

    /// The workspace's tasks: those placed in it, those whose task space it
    /// holds, and those of its project folder.
    static func items(_ all: [TaskBoardItem], workspaceID: UUID, projectRoot: String?, state: AppState) -> [TaskBoardItem] {
        all.filter { item in
            if item.projectWorkspaceID == workspaceID || item.record?.workspaceID == workspaceID { return true }
            if let space = item.taskSpaceWorkspaceID, state.workspacesByID[space]?.parentWorkspaceID == workspaceID { return true }
            if let projectRoot, let root = item.record?.projectRoot, root == projectRoot { return true }
            return false
        }
    }

    static func isFinished(_ item: TaskBoardItem) -> Bool {
        switch item.stage.group {
        case .toShip, .done, .archived: true
        case .needsYou, .running, .idle: false
        }
    }

    @MainActor
    static func make(workspaceID: UUID, service: WorkspaceOverviewService, now: Date = Date()) -> WorkspaceOverviewModel? {
        let state = service.store.state
        guard let workspace = state.workspacesByID[workspaceID] else { return nil }
        let root = service.projectRoot(of: workspaceID)
        let items = Self.items(service.board?.items() ?? [], workspaceID: workspaceID, projectRoot: root, state: state)
            .sorted { $0.activityAt > $1.activityAt }
        let recent = items.prefix(recentCount).map { item -> RecentTask in
            if let record = item.record, let outcome = service.refreshOutcome(of: record) {
                return RecentTask(item: item, outcome: outcome.text, outcomeIsRequest: false)
            }
            let request = item.record.map { WorkspaceOverviewStore.clipped($0.text, to: 400) }
            return RecentTask(item: item, outcome: request?.isEmpty == false ? request : nil, outcomeIsRequest: true)
        }
        service.syncLinked(forWorkspace: workspaceID)
        let scratchpads = service.scratchpads(forWorkspace: workspaceID).map { entry -> Scratchpad in
            let document = service.document(entry.documentID)
            return Scratchpad(
                entry: entry,
                title: document?.title ?? "Scratchpad",
                purpose: document?.purpose,
                revision: document?.revision ?? 0,
                updatedAt: document?.updatedAt,
                isMissing: document == nil
            )
        }
        let finished = items.filter(isFinished).count
        let synopsis: Synopsis = service.synopsis(forWorkspace: workspaceID).map {
            Synopsis(text: $0.text, isWritten: true, updatedAt: $0.updatedAt)
        } ?? Synopsis(
            text: generatedSynopsis(title: workspace.title, projectRoot: root, items: items, finished: finished),
            isWritten: false,
            updatedAt: nil
        )
        return WorkspaceOverviewModel(
            workspaceID: workspaceID,
            title: workspace.title,
            projectRoot: root,
            synopsis: synopsis,
            items: items,
            recent: Array(recent),
            scratchpads: scratchpads,
            openCount: items.count - finished,
            finishedCount: finished
        )
    }

    /// The synopsis until an agent writes one: where the workspace works,
    /// how many tasks it has had, and the latest three.
    static func generatedSynopsis(title: String, projectRoot: String?, items: [TaskBoardItem], finished: Int) -> String {
        var sentences: [String] = []
        if let projectRoot {
            sentences.append("\(title) works in \(tildePath(projectRoot)).")
        }
        if items.isEmpty {
            sentences.append("It has no tasks yet.")
        } else {
            let open = items.count - finished
            let count = items.count == 1 ? "1 task" : "\(items.count) tasks"
            sentences.append("It has had \(count): \(open) open and \(finished) finished.")
            let latest = items.prefix(3).map { "“\($0.title)”" }
            sentences.append("Latest: \(latest.joined(separator: ", ")).")
        }
        return sentences.joined(separator: " ")
    }

    static func tildePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard home.isEmpty == false, home != "/" else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
