import CoreState
import Foundation

/// Pure presentation logic for the Subspaces group under a workspace card:
/// one list of the workspaces spawned under it, sorted by what needs the
/// user first, with a ⑂ chip on the session that spawned each one.
@MainActor
enum SidebarSubspacePresentation {
    /// Row status, in the order rows sort. Agent approval and error states
    /// always win; `ready` covers an unread finished turn. `review` and
    /// `toShip` come from the task's stage: a pull request waiting for the
    /// user, and a merge waiting for a release. `done` is the workspace's
    /// done mark or the task's stage rather than a session state, so finished
    /// tasks sink to the bottom.
    enum RowStatus: Int, Comparable, Sendable {
        case ready = 0
        case needsApproval
        case error
        case review
        case working
        case idle
        case toShip
        case done

        static func < (lhs: RowStatus, rhs: RowStatus) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var needsAttention: Bool {
            self == .needsApproval || self == .error
        }

        /// Which status wins when a subspace has several sessions. This is
        /// not the sort order: approval and error outrank ready, but ready
        /// rows still list first because they are the quickest to act on.
        fileprivate var precedence: Int {
            switch self {
            case .needsApproval: return 4
            case .error: return 3
            case .ready: return 2
            case .working: return 1
            case .idle, .review, .toShip, .done: return 0
            }
        }
    }

    struct SessionLine: Equatable, Sendable {
        let title: String
        let panelID: UUID
        var agentLabel: String? = nil
        let statusKind: SessionStatusKind
        let isWaiting: Bool
        var showsUnreadSessionAccent = false
        let summary: String?
        var turnStartedAt: Date? = nil
        var statusUpdatedAt: Date? = nil
    }

    struct Row: Equatable, Identifiable, Sendable {
        let id: UUID
        let title: String
        let status: RowStatus
        /// The task's stage, when the task system is on.
        var stage: TaskStage? = nil
        /// The project the row belongs to, shown where rows from several
        /// projects share a list.
        var projectTag: String? = nil
        /// The task space of the task that started this one, when an agent
        /// split its work. The row draws under that one.
        var linkedParentID: UUID? = nil
        /// Set when the row draws under its parent in this list.
        var isLinkedChild = false
        /// How many of the tasks this one started have merged, such as
        /// "1/3 merged".
        var childProgressLabel: String? = nil
        /// The workspace's done mark, which `status` shows only while its
        /// sessions are quiet.
        var isDone: Bool { doneAt != nil }
        /// When the workspace was marked done, including quiet spaces with no sessions.
        var doneAt: Date? = nil
        let annotations: [String: WorkspaceAnnotation]
        var primaryAnnotationKey: String? = nil
        /// See `rowSummary(sessions:)`.
        let summary: String?
        let spawningSessionID: String?
        let spawnerName: String?
        /// The spawning session's panel while it is still running, so the
        /// ↖ tag can jump to it.
        var spawnerPanelID: UUID? = nil
        /// The workspace that panel is in: usually the parent, but a session
        /// elsewhere can nest a subspace under it.
        var spawnerWorkspaceID: UUID? = nil
        let sessions: [SessionLine]
        /// Position in the window's workspace order. Working rows keep this
        /// order; other groups use it when their recency times are equal.
        let creationIndex: Int
        /// Absolute path of where the subspace lives; see
        /// `path(sessionCWDs:workspace:)`.
        var path: String? = nil
        /// The task's menu items when the task space has a task record; see
        /// `TaskBoardPresentation.menuItems`.
        var taskMenu: [[TaskBoardPresentation.MenuItem]]? = nil

        /// The latest status update from any session in this subspace.
        /// Metadata changes do not update these times.
        var latestActivityAt: Date? {
            sessions.lazy.compactMap(\.statusUpdatedAt).max()
        }

        /// Progress changes the working row's text, not its position. Rows
        /// that need the user follow the session that sets their status, so
        /// another session's background progress cannot move them.
        fileprivate var sortActivityAt: Date? {
            switch status {
            case .working:
                return nil
            case .done:
                return [doneAt, latestActivityAt].compactMap { $0 }.max()
            case .idle, .review, .toShip:
                return latestActivityAt
            case .ready, .needsApproval, .error:
                return sessions.lazy.filter {
                    SidebarSubspacePresentation.rowStatus(
                        kind: $0.statusKind, showsUnreadSessionAccent: $0.showsUnreadSessionAccent
                    ) == status
                }.compactMap(\.statusUpdatedAt).max()
            }
        }

        /// A subspace is waiting only when none of its working sessions is
        /// actively making progress. Attention and unread ready states win.
        var isWaiting: Bool {
            guard status == .working else { return false }
            let workingSessions = sessions.filter { $0.statusKind == .working }
            return workingSessions.isEmpty == false && workingSessions.allSatisfy(\.isWaiting)
        }

        /// The one annotation chip the row shows: the workspace's primary annotation,
        /// or its `github-pr` annotation when none is marked primary.
        var rowAnnotation: (key: String, annotation: WorkspaceAnnotation)? {
            for key in [primaryAnnotationKey, SidebarSubspacePresentation.annotationKeyPullRequest] {
                if let key, let annotation = annotations[key] {
                    return (key, annotation)
                }
            }
            return nil
        }
    }

    /// The slot the selected row holds while it stays selected.
    struct Pin: Equatable, Sendable {
        let rowID: UUID
        let index: Int
    }

    struct Tally: Equatable, Sendable {
        var ready = 0
        var needsApproval = 0
        var error = 0
        var review = 0

        var isEmpty: Bool { ready == 0 && needsApproval == 0 && error == 0 && review == 0 }
    }

    /// Tone of the ⑂ chip on a spawning session's row.
    enum ChipTone: Equatable, Sendable {
        case neutral
        case needsApproval
        case error
    }

    struct SpawnerChip: Equatable, Sendable {
        let count: Int
        let tone: ChipTone
        let isFilterActive: Bool
        /// The card whose group the chip filters, when the session nested
        /// its subspaces under another card rather than its own.
        var targetWorkspaceTitle: String? = nil
    }

    nonisolated static let annotationKeyPullRequest = "github-pr"
    static let groupTitle = "Task Spaces"

    /// The done mark replaces a quiet status (idle, or a finished turn not
    /// yet read, such as the one that set the mark). A session that is
    /// working or wants the user still shows, since the user may need to act.
    static func rowStatus(sessionStatus: RowStatus, isDone: Bool) -> RowStatus {
        guard isDone else { return sessionStatus }
        switch sessionStatus {
        case .idle, .ready, .done, .review, .toShip: return .done
        case .needsApproval, .error, .working: return sessionStatus
        }
    }

    /// The same, with the task's stage: a working agent or one that wants
    /// the user still shows first, since the user may need to act; a quiet
    /// task space shows where its task stands.
    static func rowStatus(sessionStatus: RowStatus, isDone: Bool, stage: TaskStage?) -> RowStatus {
        switch sessionStatus {
        case .needsApproval, .error, .working:
            return sessionStatus
        case .idle, .ready, .review, .toShip, .done:
            break
        }
        switch stage {
        case .needsYou(.review)?, .needsYou(.readyForReview)?:
            return .review
        case .toShip?:
            return .toShip
        case .done?, .archived?:
            return .done
        case .inbox?, .running?, .needsYou?:
            // The stage already counts a done mark that means the work is
            // done; one a merge set as the user's acceptance does not make
            // the task done while the merge runs.
            return sessionStatus
        case nil:
            return rowStatus(sessionStatus: sessionStatus, isDone: isDone)
        }
    }

    /// Whether a project's Task Spaces group leaves the row out: its task
    /// is finished and nothing in it is running or waiting for the user.
    /// The Tasks view still lists it.
    static func isHiddenAsFinished(_ row: Row) -> Bool {
        switch row.status {
        case .done, .toShip:
            // The row's status shows one session; any other agent that is
            // working or waiting keeps the row too.
            return row.sessions.contains { session in
                session.statusKind == .working || session.statusKind == .needsApproval || session.statusKind == .error
            } == false
        case .ready, .needsApproval, .error, .review, .working, .idle:
            return false
        }
    }

    /// Combines a subspace's live sessions into one status.
    static func rowStatus(
        sessionStatuses: [(kind: SessionStatusKind, showsUnreadSessionAccent: Bool)]
    ) -> RowStatus {
        var status = RowStatus.idle
        for session in sessionStatuses {
            let candidate = rowStatus(kind: session.kind, showsUnreadSessionAccent: session.showsUnreadSessionAccent)
            if candidate.precedence > status.precedence {
                status = candidate
            }
        }
        return status
    }

    /// The row's summary comes from a session in the state that sets the
    /// row's status, so the dot and the text describe the same session.
    /// Among those, the one that reported most recently wins, and the text
    /// follows whichever agent is making progress. Sessions without a
    /// summary are skipped; ties keep panel order.
    static func rowSummary(sessions: [SessionLine]) -> String? {
        sessions
            .filter { $0.summary != nil }
            .max { lhs, rhs in
                let lhsPrecedence = rowStatus(kind: lhs.statusKind, showsUnreadSessionAccent: lhs.showsUnreadSessionAccent).precedence
                let rhsPrecedence = rowStatus(kind: rhs.statusKind, showsUnreadSessionAccent: rhs.showsUnreadSessionAccent).precedence
                if lhsPrecedence != rhsPrecedence {
                    return lhsPrecedence < rhsPrecedence
                }
                return (lhs.statusUpdatedAt ?? .distantPast) < (rhs.statusUpdatedAt ?? .distantPast)
            }?
            .summary
    }

    nonisolated private static func rowStatus(kind: SessionStatusKind, showsUnreadSessionAccent: Bool) -> RowStatus {
        switch kind {
        case .needsApproval: return .needsApproval
        case .error: return .error
        case .ready: return showsUnreadSessionAccent ? .ready : .idle
        case .working: return .working
        case .idle: return .idle
        }
    }

    static func sortedRows(_ rows: [Row]) -> [Row] {
        rows.sorted { lhs, rhs in
            if lhs.status != rhs.status {
                return lhs.status < rhs.status
            }
            let lhsActivityAt = lhs.sortActivityAt ?? .distantPast
            let rhsActivityAt = rhs.sortActivityAt ?? .distantPast
            if lhsActivityAt != rhsActivityAt {
                return lhsActivityAt > rhsActivityAt
            }
            return lhs.creationIndex < rhs.creationIndex
        }
    }

    /// Keeps the order the user was looking at while the pointer is over the
    /// list, so a row cannot slide away as they aim at it. Rows that appeared
    /// since the freeze follow in sorted order.
    static func orderedRows(_ rows: [Row], frozenOrder: [UUID]?) -> [Row] {
        let sorted = sortedRows(rows)
        guard let frozenOrder else { return sorted }
        let rowsByID = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0) })
        var result = frozenOrder.compactMap { rowsByID[$0] }
        let placed = Set(result.map(\.id))
        result += sorted.filter { placed.contains($0.id) == false }
        return result
    }

    /// Selecting a row reads it, which would sort a ready row away from
    /// where the user found it, most visibly after a Next Unread jump. So
    /// the selected row keeps the slot it had in `displayedOrder`, the order
    /// on screen before the selection changed, until the selection moves.
    /// The pin survives a filter that hides the row for a while.
    static func pin(
        previous: Pin?,
        selectedRowID: UUID?,
        displayedOrder: [UUID]?,
        unpinnedOrder: [UUID]
    ) -> Pin? {
        guard let selectedRowID else { return nil }
        if let previous, previous.rowID == selectedRowID {
            return previous
        }
        guard let unpinnedIndex = unpinnedOrder.firstIndex(of: selectedRowID) else {
            return nil
        }
        let index = displayedOrder?.firstIndex(of: selectedRowID) ?? unpinnedIndex
        return Pin(rowID: selectedRowID, index: index)
    }

    static func applyingPin(_ pin: Pin?, to rows: [Row]) -> [Row] {
        guard let pin, let currentIndex = rows.firstIndex(where: { $0.id == pin.rowID }) else {
            return rows
        }
        var result = rows
        let row = result.remove(at: currentIndex)
        result.insert(row, at: min(pin.index, result.count))
        return result
    }

    /// Draws each linked child right under the task that started it, in
    /// the order the children already had. A child whose parent is not in
    /// the list keeps its own place.
    static func groupingLinkedChildren(_ rows: [Row]) -> [Row] {
        // One level only: a child's own children draw as top-level rows.
        let rowIDs = Set(rows.map(\.id))
        let topLevelIDs = Set(rows.filter { row in
            row.linkedParentID.map { $0 == row.id || rowIDs.contains($0) == false } ?? true
        }.map(\.id))
        let childrenByParentID = Dictionary(grouping: rows.filter { row in
            row.linkedParentID.map(topLevelIDs.contains) == true && topLevelIDs.contains(row.id) == false
        }, by: { $0.linkedParentID! })
        guard childrenByParentID.isEmpty == false else { return rows }
        let childIDs = Set(childrenByParentID.values.flatMap { $0.map(\.id) })
        var result: [Row] = []
        for row in rows where childIDs.contains(row.id) == false {
            result.append(row)
            for var child in childrenByParentID[row.id] ?? [] {
                child.isLinkedChild = true
                result.append(child)
            }
        }
        return result
    }

    static func childProgressLabel(merged: Int, total: Int) -> String {
        "\(merged)/\(total) merged"
    }

    static func filteredRows(_ rows: [Row], spawningSessionID: String?) -> [Row] {
        guard let spawningSessionID else { return rows }
        return rows.filter { $0.spawningSessionID == spawningSessionID }
    }

    static func tally(_ rows: [Row]) -> Tally {
        rows.reduce(into: Tally()) { tally, row in
            switch row.status {
            case .ready: tally.ready += 1
            case .needsApproval: tally.needsApproval += 1
            case .error: tally.error += 1
            case .review: tally.review += 1
            case .working, .idle, .toShip, .done: break
            }
        }
    }

    static func needsAttention(_ rows: [Row]) -> Bool {
        rows.contains { $0.status.needsAttention }
    }

    /// Spawner tags only help when the group mixes more than one spawner.
    static func showsSpawnerTags(_ rows: [Row]) -> Bool {
        Set(rows.map { $0.spawningSessionID ?? "" }).count > 1
    }

    /// A spawner in another workspace has no ⑂ chip in this card, so its rows
    /// carry the tag even when the group has only one spawner.
    static func showsSpawnerTag(_ row: Row, parentWorkspaceID: UUID, groupShowsSpawnerTags: Bool) -> Bool {
        groupShowsSpawnerTags || row.spawnerWorkspaceID.map { $0 != parentWorkspaceID } == true
    }

    static func spawnerTagLabel(_ name: String) -> String {
        SidebarSessionPresentation.parentSessionTagLabel(parentName: name)
    }

    static func spawnerChip(
        sessionID: String,
        rows: [Row],
        activeFilterSessionID: String?,
        targetWorkspaceTitle: String? = nil
    ) -> SpawnerChip? {
        let spawned = rows.filter { $0.spawningSessionID == sessionID }
        guard spawned.isEmpty == false else { return nil }
        let tone: ChipTone = if spawned.contains(where: { $0.status == .error }) {
            .error
        } else if spawned.contains(where: { $0.status == .needsApproval }) {
            .needsApproval
        } else {
            .neutral
        }
        return SpawnerChip(
            count: spawned.count,
            tone: tone,
            isFilterActive: activeFilterSessionID == sessionID,
            targetWorkspaceTitle: targetWorkspaceTitle
        )
    }

    /// Whether a filter should drop because a row it hides now needs the
    /// user, the same rule that expands a collapsed group.
    static func filterHidesAttention(_ rows: [Row], spawningSessionID: String?) -> Bool {
        guard let spawningSessionID else { return false }
        return rows.contains { $0.spawningSessionID != spawningSessionID && $0.status.needsAttention }
    }

    static func headerCountLabel(shownCount: Int, totalCount: Int) -> String {
        shownCount == totalCount ? "\(totalCount)" : "\(shownCount)/\(totalCount)"
    }

    /// The rail mark toggles the done mark only while it is a box: idle,
    /// done, or a ready turn the user can wave off. A working, approval, or
    /// error mark is about the agent, not the task.
    static func showsDoneToggle(_ row: Row) -> Bool {
        switch row.status {
        case .idle, .ready, .done, .review: return true
        case .needsApproval, .error, .working, .toShip: return false
        }
    }

    static func doneToggleActionTitle(isDone: Bool) -> String {
        isDone ? "Mark as not done" : "Mark as done"
    }

    static func spawnerFilterActionTitle(_ chip: SpawnerChip) -> String {
        switch (chip.isFilterActive, chip.targetWorkspaceTitle) {
        case (true, nil): return "Show all task spaces"
        case let (true, title?): return "Show all task spaces in \(title)"
        case (false, nil): return "Show only its task spaces"
        case let (false, title?): return "Show its task spaces in \(title)"
        }
    }

    static func filterBarLabel(spawnerName: String) -> String {
        "Only task spaces from \(spawnerName)"
    }

    static func groupAccessibilityLabel(rowCount: Int, isExpanded: Bool, tally: Tally) -> String {
        var components = ["\(rowCount) \(rowCount == 1 ? "task space" : "task spaces")"]
        components.append(isExpanded ? "expanded" : "collapsed")
        if tally.ready > 0 { components.append("\(tally.ready) ready") }
        if tally.needsApproval > 0 { components.append("\(tally.needsApproval) need approval") }
        if tally.error > 0 { components.append("\(tally.error) with errors") }
        if tally.review > 0 { components.append("\(tally.review) ready for review") }
        return components.joined(separator: ", ")
    }

    static func rowAccessibilityLabel(_ row: Row, showsSpawnerTag: Bool) -> String {
        var components = [row.title, "task space"]
        switch row.status {
        case .ready: components.append("ready")
        case .needsApproval: components.append("needs approval")
        case .error: components.append("error")
        case .working: components.append(row.isWaiting ? "waiting" : "working")
        case .review: components.append("ready for review")
        case .toShip: components.append("merged, to ship")
        case .done: components.append("done")
        case .idle: break
        }
        if let projectTag = row.projectTag {
            components.append("in \(projectTag)")
        }
        if let rowAnnotation = row.rowAnnotation {
            components.append(rowAnnotation.annotation.text)
        }
        if let summary = row.summary {
            components.append(summary)
        }
        if showsSpawnerTag, let spawnerName = row.spawnerName {
            components.append("spawned by \(spawnerName)")
        }
        return components.joined(separator: ", ")
    }

    static func spawnerChipAccessibilityLabel(_ chip: SpawnerChip) -> String {
        var label = chip.count == 1 ? "1 task space" : "\(chip.count) task spaces"
        if let targetWorkspaceTitle = chip.targetWorkspaceTitle {
            label += " in \(targetWorkspaceTitle)"
        }
        switch chip.tone {
        case .needsApproval: label += ", one needs approval"
        case .error: label += ", one has an error"
        case .neutral: break
        }
        if chip.isFilterActive {
            label += ", filtering the Task Spaces list"
        }
        return label
    }

    static let hoverTipSessionLimit = 3

    /// The hover card for a subspace row: every annotation, its sessions as
    /// compact rows, and where the subspace lives, since the row itself only
    /// has room for one session's summary and the PR chip.
    static func hoverTipModel(
        _ row: Row,
        annotationColorToken: (String) -> AnnotationColorToken
    ) -> SubspaceHoverTipModel {
        let sessions = row.sessions.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = hoverSessionRank(lhs.element)
                let rhsRank = hoverSessionRank(rhs.element)
                return lhsRank != rhsRank ? lhsRank < rhsRank : lhs.offset < rhs.offset
            }
            .map { _, session in
                SubspaceHoverTipModel.Session(
                    title: session.title,
                    panelID: session.panelID,
                    agentLabel: session.agentLabel,
                    isUnread: session.statusKind == .ready && session.showsUnreadSessionAccent,
                    railState: SidebarSessionPresentation.sessionRailState(
                        for: session.statusKind,
                        showsUnreadSessionAccent: session.showsUnreadSessionAccent
                    ),
                    badgeKind: session.statusKind == .needsApproval || session.statusKind == .error
                        ? session.statusKind
                        : nil,
                    isWaiting: session.isWaiting,
                    turnStartedAt: session.turnStartedAt,
                    summary: session.summary
                )
            }
        return SubspaceHoverTipModel(
            name: row.title,
            sessions: Array(sessions.prefix(hoverTipSessionLimit)),
            hiddenSessionCount: max(0, sessions.count - hoverTipSessionLimit),
            annotations: row.annotations.sorted { $0.key < $1.key }.map { key, annotation in
                SubspaceHoverTipModel.Annotation(
                    key: key,
                    text: annotation.text,
                    colorToken: annotationColorToken(key)
                )
            },
            path: row.path.map(SidebarSessionPresentation.abbreviatedHomePathLabel),
            absolutePath: row.path,
            spawnerName: row.spawnerName
        )
    }

    /// Where the subspace lives. Toastty does not record a directory for the
    /// workspace itself, so this is the directory of the first agent that
    /// reports one (the worktree, for agent-spawned subspaces). Another
    /// agent's launch directory is a closer match than a terminal's live cwd,
    /// so the first terminal's directory is only the fallback when no agent
    /// reports a directory.
    static func path(sessionCWDs: [String?], workspace: WorkspaceState) -> String? {
        let sessionPath = sessionCWDs.lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.isEmpty == false }
        return sessionPath ?? firstTerminalDirectory(in: workspace)
    }

    private static func firstTerminalDirectory(in workspace: WorkspaceState) -> String? {
        for tab in workspace.orderedTabs {
            for slot in tab.layoutTree.allSlotInfos {
                if case .terminal(let terminal) = tab.panels[slot.panelID],
                   let directory = terminal.agentLaunchWorkingDirectory {
                    return directory
                }
            }
        }
        return nil
    }

    /// Attention first, then an unread finished turn, then work in progress.
    private static func hoverSessionRank(_ session: SessionLine) -> Int {
        switch session.statusKind {
        case .needsApproval: return 0
        case .error: return 1
        case .ready: return session.showsUnreadSessionAccent ? 2 : 4
        case .working: return 3
        case .idle: return 4
        }
    }
}
