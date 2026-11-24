#if TOASTTY_LINUX_APP_LOGIC
import CoreState
import Foundation
import RemoteProtocol
@testable import ToasttyAppLogic

/// The sidebar while tasks are on (docs/tasks.md "The sidebar and the
/// Tasks view"), as a model: one card per project with its agent sessions,
/// task spaces and tasks in the buckets Needs you, Ready to review, Running
/// and Idle; an Other tasks card; the To ship and Done lines; and the Needs
/// you segment. The rules are the shared ones (`SidebarBuckets`,
/// `SidebarBucket`, `SidebarSubspacePresentation`, `SidebarRecentToShip`);
/// macOS assembles the same in `SidebarView.makeBucketedSidebar`.
struct SidebarTasksModel: Equatable {
    struct TaskSpaceRow: Equatable {
        let workspaceID: UUID
        let title: String
        let mark: TaskStageMarkKind
        let summary: String?
        let tag: String?
        let isSelected: Bool
        let isUnread: Bool
    }

    struct TaskRow: Equatable {
        let subject: TaskBoardItem.Subject
        let title: String
        let mark: TaskStageMarkKind
        let statusLine: String
        let tag: String?
    }

    enum RowKind: Equatable {
        case session(SidebarSessionRowModel, workspaceID: UUID)
        case taskSpace(TaskSpaceRow)
        case task(TaskRow)
    }

    struct Row: Equatable {
        let key: SidebarRowKey
        let kind: RowKind
        let isLinkedChild: Bool
        let isContext: Bool
    }

    struct Section: Equatable {
        let bucket: SidebarBucket
        let rows: [Row]
    }

    struct Card: Equatable {
        /// nil for Other tasks.
        let workspaceID: UUID?
        let title: String
        let isSelected: Bool
        let isCollapsed: Bool
        let counts: [Int]
        let sections: [Section]
        let toShipCount: Int
        let doneCount: Int
        let toShipRows: [TaskRow]
        let isToShipExpanded: Bool
    }

    var segment: SidebarSegment
    var cards: [Card] = []
    var needsYouCount = 0
    var readyToReviewCount = 0
    var webhookCount = 0
    var newTaskLabel: String?

    /// Which bucket each row was drawn in, and the pinned row: the selected
    /// row keeps its bucket while the user reads it.
    struct Memory {
        var segment: SidebarSegment?
        var pin: SidebarBucketPin?
        var displayed: [SidebarRowKey: SidebarBucket] = [:]
    }

    @MainActor
    static func make(
        ui: TasksUI,
        state: AppState,
        windowID: UUID,
        sessions: any LinuxSessionSource,
        memory: inout Memory,
        expandedToShip: Set<UUID>
    ) -> SidebarTasksModel? {
        let board = ui.board
        guard board.isEnabled, let window = state.window(id: windowID) else { return nil }
        let segment = window.sidebarSegment
        var model = SidebarTasksModel(segment: segment)
        model.webhookCount = (ui.coordinator.webhooks?.pendingWebhooks.count ?? 0) + (ui.coordinator.webhooks?.stoppedWebhooks.count ?? 0)
        model.newTaskLabel = board.newTaskShortcut?.label
        if memory.segment != segment {
            memory = Memory(segment: segment)
        }
        let selectedWorkspace = state.selectedWorkspaceSelection().flatMap { $0.windowID == windowID ? $0.workspace : nil }
        let selectedKey: SidebarRowKey? = selectedWorkspace.flatMap { workspace in
            workspace.parentWorkspaceID != nil ? .workspace(workspace.id) : workspace.focusedPanelID.map(SidebarRowKey.panel)
        }
        let pin = SidebarBuckets.pin(previous: memory.pin, selected: selectedKey, displayed: memory.displayed)
        let allItems = board.items()
        let windowItems = board.items(windowID: windowID)
        let itemsByTaskID = Dictionary(allItems.compactMap { item in item.taskID.map { ($0, item) } }, uniquingKeysWith: { first, _ in first })
        let windowWorkspaceIDs = Set(window.workspaceIDs)
        func rowKey(_ item: TaskBoardItem) -> SidebarRowKey {
            if let space = item.taskSpaceWorkspaceID, windowWorkspaceIDs.contains(space) { return .workspace(space) }
            return .task(item.id)
        }
        func parentItem(ofTaskID taskID: UUID?) -> TaskBoardItem? {
            taskID.flatMap { itemsByTaskID[$0]?.parentTaskID }.flatMap { itemsByTaskID[$0] }
        }
        let topLevel = state.topLevelWorkspaceIDs(in: windowID)
        var nestedTaskSpaceIDs: Set<UUID> = []
        for id in topLevel { nestedTaskSpaceIDs.formUnion(state.subspaceWorkspaceIDs(of: id)) }
        let recordItems = SidebarStatusSections.sidebarOrder(
            windowItems.filter { item in
                item.taskSpaceWorkspaceID.map(nestedTaskSpaceIDs.contains) != true && SidebarBucket(item.stage) != nil
            },
            workspaceIDs: window.workspaceIDs
        )
        let now = Date()
        func taskRow(_ item: TaskBoardItem) -> TaskRow {
            TaskRow(
                subject: item.id,
                title: item.title,
                mark: TaskStageMarkKind(item),
                statusLine: TaskBoardPresentation.statusLine(item, now: now),
                tag: item.pullRequest.map { "PR #\($0.number)" } ?? parentItem(ofTaskID: item.taskID).map { "↖ \($0.title)" }
            )
        }
        func recordCandidates(_ items: [TaskBoardItem]) -> [SidebarBucketCandidate<RowKind>] {
            items.compactMap { item in
                guard let bucket = SidebarBucket(item.stage) else { return nil }
                return SidebarBucketCandidate(
                    key: rowKey(item), bucket: bucket, parent: parentItem(ofTaskID: item.taskID).map(rowKey),
                    payload: .task(taskRow(item))
                )
            }
        }

        var displayed: [SidebarRowKey: SidebarBucket] = [:]
        var nextPin: SidebarBucketPin?
        func card(
            workspaceID: UUID?,
            title: String,
            candidates: [SidebarBucketCandidate<RowKind>],
            isSelected: Bool
        ) -> Card {
            let counts = SidebarBuckets.counts(candidates)
            let layout = segment == .all
                ? SidebarBuckets.layout(candidates, pin: pin)
                : SidebarBuckets.needsYou(candidates, pin: pin)
            displayed.merge(layout.displayed) { first, _ in first }
            nextPin = layout.pin ?? nextPin
            model.needsYouCount += counts[.needsYou] ?? 0
            model.readyToReviewCount += counts[.readyToReview] ?? 0
            let sections = SidebarBucket.allCases.compactMap { bucket -> Section? in
                let entries = layout.entries(bucket)
                guard entries.isEmpty == false else { return nil }
                return Section(bucket: bucket, rows: entries.map { entry in
                    Row(key: entry.key, kind: entry.payload, isLinkedChild: entry.isLinkedChild, isContext: entry.isContext)
                })
            }
            let shownTaskSpaceIDs = Set(candidates.compactMap { candidate -> UUID? in
                if case .workspace(let id) = candidate.key { return id }
                return nil
            })
            let toShip = workspaceID.map { SidebarRecentToShip.card(windowItems, projectWorkspaceID: $0, shownTaskSpaceIDs: shownTaskSpaceIDs) }
                ?? SidebarRecentToShip.make(windowItems.filter { item in item.projectWorkspaceID.map(topLevel.contains) != true })
            let doneCount = windowItems.filter { item in
                item.stage.group == .done && (workspaceID.map { item.projectWorkspaceID == $0 } ?? (item.projectWorkspaceID.map(topLevel.contains) != true))
            }.count
            let cardKey = workspaceID ?? Self.otherTasksCardID
            return Card(
                workspaceID: workspaceID,
                title: title,
                isSelected: isSelected,
                isCollapsed: workspaceID.map { window.collapsedSidebarWorkspaceIDs.contains($0) } ?? false,
                counts: SidebarBucket.allCases.map { counts[$0] ?? 0 },
                sections: sections,
                toShipCount: toShip.shown.count + toShip.hidden.count,
                doneCount: doneCount,
                toShipRows: expandedToShip.contains(cardKey) ? toShip.shown.map(taskRow) : [],
                isToShipExpanded: expandedToShip.contains(cardKey)
            )
        }

        for workspaceID in topLevel {
            guard let workspace = state.workspacesByID[workspaceID] else { continue }
            let isCardSelected = selectedWorkspace.map { $0.id == workspaceID || $0.parentWorkspaceID == workspaceID } ?? false
            var candidates: [SidebarBucketCandidate<RowKind>] = []
            for status in sessions.sessions(workspaceID: workspaceID) {
                let row = SidebarModel.sessionRow(
                    status,
                    workspace: workspace,
                    isFocused: selectedWorkspace?.id == workspaceID && workspace.focusedPanelID == status.panelID,
                    isFlagged: sessions.isFlaggedForLater(sessionID: status.sessionID),
                    pendingQuestion: sessions.pendingQuestion(sessionID: status.sessionID)
                )
                candidates.append(SidebarBucketCandidate(
                    key: .panel(status.panelID),
                    bucket: .session(kind: row.statusKind, isUnread: row.isUnread),
                    payload: .session(row, workspaceID: workspaceID)
                ))
            }
            for subspaceID in state.subspaceWorkspaceIDs(of: workspaceID) {
                guard let space = state.workspacesByID[subspaceID] else { continue }
                let statuses = sessions.sessions(workspaceID: subspaceID)
                let item = board.item(taskSpace: space, statuses: statuses)
                let lines = statuses.map { status in
                    (kind: status.status.kind, showsUnreadSessionAccent: SidebarSessionPresentation.showsUnreadSessionAccent(
                        for: status.panelID, in: space,
                        selectedWorkspaceID: selectedWorkspace?.id, selectedPanelID: selectedWorkspace?.focusedPanelID
                    ))
                }
                let status = SidebarSubspacePresentation.rowStatus(
                    sessionStatus: SidebarSubspacePresentation.rowStatus(sessionStatuses: lines),
                    isDone: space.doneAt != nil,
                    stage: item?.stage,
                    waitsOutside: item?.record?.waiting != nil
                )
                // A finished task leaves its project's card; the footer
                // counts it and the Tasks view lists it.
                // (`SidebarSubspacePresentation.isHiddenAsFinished`: finished,
                // not held open, and no agent in it works or waits.)
                let isQuiet = lines.contains { [.working, .needsApproval, .error].contains($0.kind) } == false
                if status == .done || status == .toShip, item?.cleanupHeldUntil == nil, isQuiet {
                    continue
                }
                let mark: TaskStageMarkKind = item.map(TaskStageMarkKind.init) ?? Self.mark(status)
                let summary: String? = item.flatMap { item in
                    if case .needsYou(.awaitingReply) = item.stage { return TaskBoardPresentation.replyLine(item) }
                    if status == .waiting { return TaskBoardPresentation.waitingLine(item) }
                    return TaskBoardPresentation.statusLine(item, now: now)
                } ?? statuses.first.map { $0.status.summary }
                let parent = parentItem(ofTaskID: space.taskID)
                let row = TaskSpaceRow(
                    workspaceID: subspaceID,
                    title: item?.title ?? space.title,
                    mark: mark,
                    summary: summary?.isEmpty == true ? nil : summary,
                    tag: item?.pullRequest.map { "PR #\($0.number)" } ?? parent.map { "↖ \($0.title)" },
                    isSelected: selectedWorkspace?.id == subspaceID,
                    isUnread: lines.contains { $0.showsUnreadSessionAccent }
                )
                candidates.append(SidebarBucketCandidate(
                    key: .workspace(subspaceID),
                    bucket: SidebarBucket.subspace(status: status, stage: item?.stage),
                    parent: parent.map(rowKey),
                    payload: .taskSpace(row)
                ))
            }
            candidates += recordCandidates(recordItems.filter { $0.projectWorkspaceID == workspaceID })
            model.cards.append(card(workspaceID: workspaceID, title: workspace.title, candidates: candidates, isSelected: isCardSelected))
        }
        let topLevelSet = Set(topLevel)
        let otherCandidates = recordCandidates(recordItems.filter { $0.projectWorkspaceID.map(topLevelSet.contains) != true })
        if otherCandidates.isEmpty == false {
            model.cards.append(card(workspaceID: nil, title: Self.otherTasksTitle, candidates: otherCandidates, isSelected: false))
        }
        memory.pin = nextPin
        memory.displayed = displayed
        return model
    }

    static let otherTasksTitle = "Other tasks"
    static let otherTasksCardID = UUID(uuidString: "00000000-0000-0000-0000-00000000071D")!

    /// A task space row's mark from its status, for a task space without a
    /// task record.
    static func mark(_ status: SidebarSubspacePresentation.RowStatus) -> TaskStageMarkKind {
        switch status {
        case .ready: .ready
        case .question: .question
        case .needsApproval: .needsInput
        case .error: .error
        case .review: .review
        case .working: .working
        case .idle: .quiet
        case .toShip: .toShip
        case .done: .done
        case .waiting: .waiting
        }
    }
}
#endif
