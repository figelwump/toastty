import CoreState
import Foundation

/// Pure presentation logic for the Subspaces group under a workspace card:
/// one list of the workspaces spawned under it, sorted by what needs the
/// user first, with a ⑂ chip on the session that spawned each one.
@MainActor
enum SidebarSubspacePresentation {
    /// Row status, in the order rows sort. Agent approval and error states
    /// always win; `ready` covers both an unread finished turn and a task
    /// the agent marked ready through its `task-status` annotation.
    enum RowStatus: Int, Comparable, Sendable {
        case ready = 0
        case needsApproval
        case error
        case working
        case idle

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
            case .idle: return 0
            }
        }
    }

    struct SessionLine: Equatable, Sendable {
        let title: String
        let statusKind: SessionStatusKind
        let summary: String?
    }

    struct Row: Equatable, Identifiable, Sendable {
        let id: UUID
        let title: String
        let status: RowStatus
        /// The `github-pr` annotation, the only chip a subspace row shows.
        let pullRequest: WorkspaceAnnotation?
        /// The first session's summary, or the task-status text when no
        /// session is running.
        let summary: String?
        let spawningSessionID: String?
        let spawnerName: String?
        /// The spawning session's panel while it is still running, so the
        /// ↖ tag can jump to it.
        var spawnerPanelID: UUID? = nil
        let sessions: [SessionLine]
        /// Position in the window's workspace order, the tie-breaker so rows
        /// with the same status never swap.
        let creationIndex: Int
    }

    struct Tally: Equatable, Sendable {
        var ready = 0
        var needsApproval = 0
        var error = 0

        var isEmpty: Bool { ready == 0 && needsApproval == 0 && error == 0 }
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
    }

    static let annotationKeyPullRequest = "github-pr"
    static let annotationKeyTaskStatus = "task-status"
    static let groupTitle = "Subspaces"

    /// Combines a subspace's live sessions and its `task-status` annotation
    /// into one status. A running agent outranks a stale "Ready" annotation;
    /// an annotation that says ready lifts an otherwise quiet workspace.
    static func rowStatus(
        sessionStatuses: [(kind: SessionStatusKind, showsUnreadSessionAccent: Bool)],
        taskStatusText: String?
    ) -> RowStatus {
        var status = RowStatus.idle
        for session in sessionStatuses {
            let candidate: RowStatus
            switch session.kind {
            case .needsApproval:
                candidate = .needsApproval
            case .error:
                candidate = .error
            case .ready:
                candidate = session.showsUnreadSessionAccent ? .ready : .idle
            case .working:
                candidate = .working
            case .idle:
                candidate = .idle
            }
            if candidate.precedence > status.precedence {
                status = candidate
            }
        }
        if status == .idle, taskStatusSaysReady(taskStatusText) {
            return .ready
        }
        return status
    }

    static func taskStatusSaysReady(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("ready")
    }

    static func sortedRows(_ rows: [Row]) -> [Row] {
        rows.sorted { lhs, rhs in
            if lhs.status != rhs.status {
                return lhs.status < rhs.status
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
            case .working, .idle: break
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

    static func spawnerTagLabel(_ name: String) -> String {
        SidebarSessionPresentation.parentSessionTagLabel(parentName: name)
    }

    static func spawnerChip(
        sessionID: String,
        rows: [Row],
        activeFilterSessionID: String?
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
            isFilterActive: activeFilterSessionID == sessionID
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

    static func spawnerFilterActionTitle(isFilterActive: Bool) -> String {
        isFilterActive ? "Show all subspaces" : "Show only its subspaces"
    }

    static func filterBarLabel(spawnerName: String) -> String {
        "Only subspaces from \(spawnerName)"
    }

    static func groupAccessibilityLabel(rowCount: Int, isExpanded: Bool, tally: Tally) -> String {
        var components = ["\(rowCount) \(rowCount == 1 ? "subspace" : "subspaces")"]
        components.append(isExpanded ? "expanded" : "collapsed")
        if tally.ready > 0 { components.append("\(tally.ready) ready") }
        if tally.needsApproval > 0 { components.append("\(tally.needsApproval) need approval") }
        if tally.error > 0 { components.append("\(tally.error) with errors") }
        return components.joined(separator: ", ")
    }

    static func rowAccessibilityLabel(_ row: Row, showsSpawnerTag: Bool) -> String {
        var components = [row.title, "subspace"]
        switch row.status {
        case .ready: components.append("ready")
        case .needsApproval: components.append("needs approval")
        case .error: components.append("error")
        case .working: components.append("working")
        case .idle: break
        }
        if let pullRequest = row.pullRequest {
            components.append(pullRequest.text)
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
        var label = chip.count == 1 ? "1 subspace" : "\(chip.count) subspaces"
        switch chip.tone {
        case .needsApproval: label += ", one needs approval"
        case .error: label += ", one has an error"
        case .neutral: break
        }
        if chip.isFilterActive {
            label += ", filtering the Subspaces list"
        }
        return label
    }

    /// The hover card for a subspace row: every session in the workspace,
    /// since the row only has room for the first one's summary.
    static func hoverTipModel(_ row: Row) -> SessionChildHoverTipModel {
        let bodyLines: [String] = row.sessions.isEmpty
            ? [row.summary.map { "No agent · \($0)" } ?? "No agent"]
            : row.sessions.map { session in
                var line = "\(session.title) — \(sessionStatusLabel(session.statusKind))"
                if let summary = session.summary {
                    line += ": \(summary)"
                }
                return line
            }
        var metaItems = [rowStatusLabel(row.status)]
        if let pullRequest = row.pullRequest {
            metaItems.append(pullRequest.text)
        }
        if let spawnerName = row.spawnerName {
            metaItems.append("spawned by \(spawnerName)")
        }
        return SessionChildHoverTipModel(
            name: row.title,
            typeLabel: "subspace",
            statusDotColorKind: statusDotColorKind(row.status),
            bodyText: bodyLines.joined(separator: "\n"),
            executionProfileText: nil,
            metaItems: metaItems
        )
    }

    private static func rowStatusLabel(_ status: RowStatus) -> String {
        switch status {
        case .ready: return "ready"
        case .needsApproval: return "needs approval"
        case .error: return "error"
        case .working: return "working"
        case .idle: return "idle"
        }
    }

    private static func statusDotColorKind(_ status: RowStatus) -> SessionChildHoverTipModel.StatusDotColorKind {
        switch status {
        case .ready: return .ready
        case .needsApproval: return .needsApproval
        case .error: return .error
        case .working: return .working
        case .idle: return .idle
        }
    }

    private static func sessionStatusLabel(_ kind: SessionStatusKind) -> String {
        switch kind {
        case .working: return "working"
        case .idle: return "idle"
        case .needsApproval, .ready, .error:
            return SidebarSessionPresentation.sessionStatusChipLabel(for: kind)
        }
    }
}
