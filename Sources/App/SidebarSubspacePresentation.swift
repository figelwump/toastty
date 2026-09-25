import CoreState
import Foundation

/// Pure presentation logic for the Subspaces group under a workspace card:
/// one list of the workspaces spawned under it, sorted by what needs the
/// user first, with a ⑂ chip on the session that spawned each one.
@MainActor
enum SidebarSubspacePresentation {
    /// Row status, in the order rows sort. Agent approval and error states
    /// always win; `ready` covers an unread finished turn.
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
        let panelID: UUID
        var agentLabel: String? = nil
        let statusKind: SessionStatusKind
        var showsUnreadSessionAccent = false
        let summary: String?
        var turnStartedAt: Date? = nil
    }

    struct Row: Equatable, Identifiable, Sendable {
        let id: UUID
        let title: String
        let status: RowStatus
        let annotations: [String: WorkspaceAnnotation]
        /// The first session's summary.
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
        /// Absolute path of where the subspace lives; see
        /// `path(sessionCWDs:workspace:)`.
        var path: String? = nil

        /// The `github-pr` annotation, the only chip a subspace row shows.
        var pullRequest: WorkspaceAnnotation? {
            annotations[SidebarSubspacePresentation.annotationKeyPullRequest]
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

    nonisolated static let annotationKeyPullRequest = "github-pr"
    static let groupTitle = "Subspaces"

    /// Combines a subspace's live sessions into one status.
    static func rowStatus(
        sessionStatuses: [(kind: SessionStatusKind, showsUnreadSessionAccent: Bool)]
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
        return status
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

    static let hoverTipSessionLimit = 3

    /// The hover card for a subspace row: its sessions as compact rows, then
    /// every annotation and where the subspace lives, since the row itself
    /// only has room for the first session's summary and the PR chip.
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
                    statusKind: session.statusKind,
                    isUnread: session.statusKind == .ready && session.showsUnreadSessionAccent,
                    railState: SidebarSessionPresentation.sessionRailState(
                        for: session.statusKind,
                        showsUnreadSessionAccent: session.showsUnreadSessionAccent
                    ),
                    badgeKind: session.statusKind == .needsApproval || session.statusKind == .error
                        ? session.statusKind
                        : nil,
                    turnStartedAt: session.turnStartedAt,
                    summary: session.summary
                )
            }
        return SubspaceHoverTipModel(
            name: row.title,
            statusDotColorKind: statusDotColorKind(row.status),
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

    private static func statusDotColorKind(_ status: RowStatus) -> SessionChildHoverTipModel.StatusDotColorKind {
        switch status {
        case .ready: return .ready
        case .needsApproval: return .needsApproval
        case .error: return .error
        case .working: return .working
        case .idle: return .idle
        }
    }
}
