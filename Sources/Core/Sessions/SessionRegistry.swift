import Foundation

public struct SessionRegistry: Codable, Equatable, Sendable {
    public static let resumeProjectionGraceInterval: TimeInterval = 15

    public private(set) var sessionsByID: [String: SessionRecord]
    public private(set) var activeSessionIDByPanelID: [UUID: String]
    public private(set) var sessionOrder: [String]

    public init(
        sessionsByID: [String: SessionRecord] = [:],
        activeSessionIDByPanelID: [UUID: String] = [:],
        sessionOrder: [String] = []
    ) {
        self.sessionsByID = sessionsByID
        self.activeSessionIDByPanelID = activeSessionIDByPanelID
        self.sessionOrder = Self.normalizedSessionOrder(
            sessionOrder,
            sessionsByID: sessionsByID
        )
    }

    public mutating func startSession(
        sessionID: String,
        agent: AgentKind,
        panelID: UUID,
        windowID: UUID,
        workspaceID: UUID,
        parentSessionID: String? = nil,
        usesSessionStatusNotifications: Bool = false,
        displayTitleOverride: String? = nil,
        cwd: String?,
        repoRoot: String?,
        scopedWorkspaceIDs: Set<UUID>? = nil,
        at now: Date
    ) {
        if let existingRecord = sessionsByID[sessionID],
           activeSessionIDByPanelID[existingRecord.panelID] == sessionID {
            activeSessionIDByPanelID.removeValue(forKey: existingRecord.panelID)
        }

        if let existingActiveSessionID = activeSessionIDByPanelID[panelID],
           var existingRecord = sessionsByID[existingActiveSessionID],
           existingRecord.isActive {
            existingRecord.stoppedAt = now
            existingRecord.updatedAt = now
            sessionsByID[existingActiveSessionID] = existingRecord
        }

        let record = SessionRecord(
            sessionID: sessionID,
            agent: agent,
            panelID: panelID,
            windowID: windowID,
            workspaceID: workspaceID,
            parentSessionID: parentSessionID,
            usesSessionStatusNotifications: usesSessionStatusNotifications,
            displayTitleOverride: displayTitleOverride,
            repoRoot: repoRoot,
            cwd: cwd,
            scopedWorkspaceIDs: scopedWorkspaceIDs,
            startedAt: now,
            updatedAt: now
        )

        if let existingOrderIndex = sessionOrder.firstIndex(of: sessionID) {
            sessionOrder.remove(at: existingOrderIndex)
        }
        sessionsByID[sessionID] = record
        activeSessionIDByPanelID[panelID] = sessionID
        sessionOrder.append(sessionID)
    }

    public mutating func updateFiles(
        sessionID: String,
        files: [String],
        cwd: String?,
        repoRoot: String?,
        at now: Date
    ) {
        guard var record = sessionsByID[sessionID], record.isActive else { return }

        if let cwd {
            record.cwd = cwd
        }
        if let repoRoot {
            record.repoRoot = repoRoot
        }

        for file in files where record.touchedFiles.contains(file) == false {
            record.touchedFiles.append(file)
        }
        record.updatedAt = now
        sessionsByID[sessionID] = record
    }

    public mutating func updateStatus(
        sessionID: String,
        status: SessionStatus,
        at now: Date
    ) {
        guard var record = sessionsByID[sessionID], record.isActive else { return }
        record.status = status
        record.statusUpdatedAt = now
        record.updatedAt = now
        sessionsByID[sessionID] = record
    }

    @discardableResult
    public mutating func updateBackgroundActivity(
        sessionID: String,
        activity: SessionBackgroundActivity,
        at now: Date
    ) -> Bool {
        guard var record = activeSession(sessionID: sessionID) else { return false }
        if let existingActivity = record.backgroundActivitiesByID[activity.id] {
            guard existingActivity.kind == .subagent,
                  activity.kind == .subagent else {
                return false
            }
            let mergedActivity = Self.mergedBackgroundActivity(
                existing: existingActivity,
                incoming: activity
            )
            guard mergedActivity != existingActivity else { return false }
            record.backgroundActivitiesByID[activity.id] = mergedActivity
        } else {
            record.backgroundActivitiesByID[activity.id] = activity
        }
        record.updatedAt = now
        sessionsByID[sessionID] = record
        return true
    }

    @discardableResult
    public mutating func finishBackgroundActivity(
        sessionID: String,
        activityID: String,
        at now: Date
    ) -> Bool {
        guard var record = activeSession(sessionID: sessionID),
              record.backgroundActivitiesByID.removeValue(forKey: activityID) != nil else {
            return false
        }
        record.lastActivityFinishedAt = now
        record.updatedAt = now
        sessionsByID[sessionID] = record
        return true
    }

    @discardableResult
    public mutating func syncBackgroundActivities(
        sessionID: String,
        kind: SessionBackgroundActivityKind,
        entries: [SessionBackgroundActivity],
        pendingBackgroundTaskCount: Int,
        preserveUnlistedActivities: Bool = false,
        at now: Date
    ) -> Bool {
        guard var record = activeSession(sessionID: sessionID) else { return false }
        var nextActivities = record.backgroundActivitiesByID.filter { _, activity in
            activity.kind != kind ||
                (preserveUnlistedActivities && activity.preserveWhenUnlisted)
        }

        for entry in entries where entry.kind == kind {
            // Do not allow a sync for one source kind to displace another
            // source's row when activity IDs collide.
            if let retainedActivity = nextActivities[entry.id], retainedActivity.kind != kind {
                continue
            }
            if let existingActivity = record.backgroundActivitiesByID[entry.id],
               existingActivity.kind == kind {
                nextActivities[entry.id] = Self.mergedBackgroundActivity(
                    existing: existingActivity,
                    incoming: entry
                )
            } else {
                nextActivities[entry.id] = entry
            }
        }

        let nextPendingBackgroundTaskCount = max(0, pendingBackgroundTaskCount)
        let removedActivity = record.backgroundActivitiesByID.contains { id, activity in
            activity.kind == kind && nextActivities[id] == nil
        }
        let clearedPendingBackgroundTasks = record.pendingBackgroundTaskCount > 0 &&
            nextPendingBackgroundTaskCount == 0
        guard record.backgroundActivitiesByID != nextActivities ||
            record.pendingBackgroundTaskCount != nextPendingBackgroundTaskCount else {
            return false
        }
        record.backgroundActivitiesByID = nextActivities
        record.pendingBackgroundTaskCount = nextPendingBackgroundTaskCount
        if removedActivity || clearedPendingBackgroundTasks {
            record.lastActivityFinishedAt = now
        }
        record.updatedAt = now
        sessionsByID[sessionID] = record
        return true
    }

    @discardableResult
    public mutating func pruneBackgroundActivities(
        at now: Date,
        shouldRemove: (SessionBackgroundActivity) -> Bool
    ) -> Bool {
        pruneBackgroundActivities(at: now) { _, activity in
            shouldRemove(activity)
        }
    }

    @discardableResult
    public mutating func pruneBackgroundActivities(
        at now: Date,
        shouldRemove: (String, SessionBackgroundActivity) -> Bool
    ) -> Bool {
        var didMutate = false
        for sessionID in Array(sessionsByID.keys) {
            guard var record = activeSession(sessionID: sessionID) else { continue }
            let previousCount = record.backgroundActivitiesByID.count
            record.backgroundActivitiesByID = record.backgroundActivitiesByID.filter { _, activity in
                shouldRemove(sessionID, activity) == false
            }
            guard record.backgroundActivitiesByID.count != previousCount else { continue }
            record.lastActivityFinishedAt = now
            record.updatedAt = now
            sessionsByID[sessionID] = record
            didMutate = true
        }
        return didMutate
    }

    public mutating func setLaterFlag(sessionID: String, isFlagged: Bool) {
        guard var record = sessionsByID[sessionID], record.isActive else { return }
        // Watched processes already act as their own "remind me later" signal via the
        // sidebar bell, so flagging them would be redundant. Silently no-op instead
        // of mutating state; the sidebar also hides the menu affordance for them.
        guard record.agent != .processWatch else { return }
        guard record.isFlaggedForLater != isFlagged else { return }
        record.isFlaggedForLater = isFlagged
        sessionsByID[sessionID] = record
    }

    public mutating func toggleLaterFlag(sessionID: String) {
        guard let record = sessionsByID[sessionID], record.isActive else { return }
        setLaterFlag(sessionID: sessionID, isFlagged: record.isFlaggedForLater == false)
    }

    public func isLaterFlagged(sessionID: String) -> Bool {
        activeSession(sessionID: sessionID)?.isFlaggedForLater == true
    }

    public func scope(ofSessionID sessionID: String) -> Set<UUID>? {
        activeSession(sessionID: sessionID)?.scopedWorkspaceIDs
    }

    public func effectiveWorkspaceScope(sessionID: String) -> Set<UUID>? {
        guard let record = activeSession(sessionID: sessionID),
              let explicitScope = record.scopedWorkspaceIDs else {
            return nil
        }
        // Invariant: nil scope is unrestricted; an empty non-nil scope is still
        // workspace-scoped and allows only the session's live own workspace.
        return explicitScope.union([record.workspaceID])
    }

    public func isWorkspaceScoped(sessionID: String) -> Bool {
        activeSession(sessionID: sessionID)?.scopedWorkspaceIDs != nil
    }

    @discardableResult
    public mutating func setScope(sessionID: String, workspaceIDs: Set<UUID>) -> Bool {
        guard var record = activeSession(sessionID: sessionID) else { return false }
        guard record.scopedWorkspaceIDs != workspaceIDs else { return false }
        record.scopedWorkspaceIDs = workspaceIDs
        sessionsByID[sessionID] = record
        return true
    }

    @discardableResult
    public mutating func addScope(sessionID: String, workspaceIDs: Set<UUID>) -> Bool {
        guard var record = activeSession(sessionID: sessionID) else { return false }
        let nextScope = (record.scopedWorkspaceIDs ?? []).union(workspaceIDs)
        guard record.scopedWorkspaceIDs != nextScope else { return false }
        record.scopedWorkspaceIDs = nextScope
        sessionsByID[sessionID] = record
        return true
    }

    @discardableResult
    public mutating func clearScope(sessionID: String) -> Bool {
        guard var record = activeSession(sessionID: sessionID),
              record.scopedWorkspaceIDs != nil else {
            return false
        }
        record.scopedWorkspaceIDs = nil
        sessionsByID[sessionID] = record
        return true
    }

    public func allowsWorkspaceAutomation(callerSessionID: String?, of workspaceID: UUID) -> Bool {
        guard let callerSessionID,
              callerSessionID.isEmpty == false else {
            return true
        }
        return effectiveWorkspaceScope(sessionID: callerSessionID)?.contains(workspaceID) ?? true
    }

    public mutating func updatePanelLocation(
        panelID: UUID,
        windowID: UUID,
        workspaceID: UUID,
        at now: Date
    ) {
        guard let activeSessionID = activeSessionIDByPanelID[panelID],
              var record = sessionsByID[activeSessionID] else {
            return
        }

        record.windowID = windowID
        record.workspaceID = workspaceID
        record.updatedAt = now
        sessionsByID[activeSessionID] = record
    }

    public mutating func stopSession(sessionID: String, at now: Date) {
        guard var record = sessionsByID[sessionID] else { return }
        record.backgroundActivitiesByID.removeAll()
        record.pendingBackgroundTaskCount = 0
        record.stoppedAt = now
        record.updatedAt = now
        sessionsByID[sessionID] = record

        if activeSessionIDByPanelID[record.panelID] == sessionID {
            activeSessionIDByPanelID.removeValue(forKey: record.panelID)
        }
    }

    public mutating func removeSession(sessionID: String) {
        guard var record = sessionsByID.removeValue(forKey: sessionID) else { return }
        record.backgroundActivitiesByID.removeAll()
        record.pendingBackgroundTaskCount = 0
        if activeSessionIDByPanelID[record.panelID] == sessionID {
            activeSessionIDByPanelID.removeValue(forKey: record.panelID)
        }
        sessionOrder.removeAll { $0 == sessionID }
    }

    public mutating func stopSessionForPanel(panelID: UUID, at now: Date) {
        guard let activeSessionID = activeSessionIDByPanelID[panelID] else { return }
        stopSession(sessionID: activeSessionID, at: now)
    }

    public func activeSession(for panelID: UUID) -> SessionRecord? {
        guard let sessionID = activeSessionIDByPanelID[panelID],
              let record = sessionsByID[sessionID],
              record.isActive else {
            return nil
        }
        return record
    }

    public func activeSession(sessionID: String) -> SessionRecord? {
        guard let record = sessionsByID[sessionID], record.isActive else {
            return nil
        }
        guard activeSessionIDByPanelID[record.panelID] == sessionID else {
            return nil
        }
        return record
    }

    public func panelStatus(for panelID: UUID, at now: Date = Date()) -> WorkspaceSessionStatus? {
        let activeRecordsByID = activeRecordsByID()
        if let activeRecord = activeSession(for: panelID) {
            return workspaceSessionStatus(
                from: activeRecord,
                activeRecordsByID: activeRecordsByID,
                at: now
            )
        }

        return sessionsByID.values
            .filter { record in
                record.panelID == panelID && Self.shouldPresentStoppedPanelStatus(for: record)
            }
            .sorted(by: stoppedWorkspaceStatusSort)
            .compactMap { record in
                workspaceSessionStatus(
                    from: record,
                    activeRecordsByID: activeRecordsByID,
                    at: now
                )
            }
            .first
    }

    public func workspaceStatuses(for workspaceID: UUID, at now: Date = Date()) -> [WorkspaceSessionStatus] {
        let activeRecordsByID = activeRecordsByID()
        let orderBySessionID = Dictionary(
            uniqueKeysWithValues: sessionOrder.enumerated().map { offset, sessionID in
                (sessionID, offset)
            }
        )
        return sessionsByID.values
            .filter { record in
                record.workspaceID == workspaceID &&
                Self.projectedStatus(from: record, at: now) != nil &&
                record.isActive &&
                shouldSuppressTopLevelStatus(
                    for: record,
                    activeRecordsByID: activeRecordsByID
                ) == false
            }
            // Keep sidebar session rows stable as tabs switch or session
            // statuses change. New sessions append by creation time.
            .sorted { lhs, rhs in
                Self.stableWorkspaceStatusSort(
                    lhs,
                    rhs,
                    orderBySessionID: orderBySessionID
                )
            }
            .compactMap { record in
                workspaceSessionStatus(
                    from: record,
                    activeRecordsByID: activeRecordsByID,
                    at: now
                )
            }
    }

    public mutating func pruneStoppedSessions(olderThan cutoff: Date) {
        for (sessionID, record) in sessionsByID where record.stoppedAt.map({ $0 < cutoff }) == true {
            sessionsByID.removeValue(forKey: sessionID)
        }
        sessionOrder = Self.normalizedSessionOrder(sessionOrder, sessionsByID: sessionsByID)

        activeSessionIDByPanelID = activeSessionIDByPanelID.filter { panelID, sessionID in
            guard let record = sessionsByID[sessionID], record.isActive else {
                return false
            }
            return record.panelID == panelID
        }
    }

    private func workspaceSessionStatus(
        from record: SessionRecord,
        activeRecordsByID: [String: SessionRecord],
        at now: Date
    ) -> WorkspaceSessionStatus? {
        guard let projected = Self.projectedStatus(from: record, at: now) else { return nil }
        return WorkspaceSessionStatus(
            sessionID: record.sessionID,
            panelID: record.panelID,
            workspaceID: record.workspaceID,
            parentSessionID: record.parentSessionID,
            agent: record.agent,
            status: projected.status,
            projection: projected.projection,
            children: record.isActive
                ? childRows(for: record, activeRecordsByID: activeRecordsByID, at: now)
                : [],
            displayTitleOverride: record.displayTitleOverride,
            cwd: record.cwd,
            updatedAt: record.updatedAt,
            isActive: record.isActive,
            scopedWorkspaceIDs: record.scopedWorkspaceIDs,
            effectiveScopedWorkspaceIDs: record.scopedWorkspaceIDs.map { $0.union([record.workspaceID]) }
        )
    }

    private func childRows(
        for record: SessionRecord,
        activeRecordsByID: [String: SessionRecord],
        at now: Date
    ) -> [SessionChildRow] {
        let ancestorIDs = Self.ancestorSessionIDs(
            of: record.sessionID,
            activeRecordsByID: activeRecordsByID
        )
        let activityRows = record.backgroundActivitiesByID.values.map { activity in
            SessionChildRow(
                id: activity.id,
                source: .activity,
                displayName: activity.displayName ?? Self.defaultActivityDisplayName(for: activity.kind),
                context: activity.command,
                startedAt: activity.startedAt
            )
        }

        let sessionRows = activeRecordsByID.values.compactMap { candidate -> SessionChildRow? in
            guard candidate.parentSessionID == record.sessionID,
                  candidate.sessionID != record.sessionID,
                  ancestorIDs.contains(candidate.sessionID) == false else {
                return nil
            }
            return SessionChildRow(
                id: candidate.sessionID,
                source: .session,
                displayName: candidate.displayTitleOverride ?? candidate.agent.displayName,
                context: candidate.status?.detail,
                startedAt: candidate.startedAt,
                statusKind: Self.projectedStatus(from: candidate, at: now)?.status.kind,
                panelID: candidate.panelID,
                workspaceID: candidate.workspaceID,
                sessionID: candidate.sessionID
            )
        }

        return (activityRows + sessionRows).sorted { lhs, rhs in
            if lhs.startedAt != rhs.startedAt {
                return lhs.startedAt < rhs.startedAt
            }
            return lhs.id < rhs.id
        }
    }

    private func shouldSuppressTopLevelStatus(
        for record: SessionRecord,
        activeRecordsByID: [String: SessionRecord]
    ) -> Bool {
        guard let parentSessionID = record.parentSessionID,
              let parent = activeRecordsByID[parentSessionID],
              parent.workspaceID == record.workspaceID,
              Self.parentChainHasCycle(
                  startingAt: record.sessionID,
                  activeRecordsByID: activeRecordsByID
              ) == false else {
            return false
        }
        return true
    }

    private func activeRecordsByID() -> [String: SessionRecord] {
        Dictionary(uniqueKeysWithValues: sessionsByID.compactMap { element -> (String, SessionRecord)? in
            let (sessionID, record) = element
            return record.isActive && activeSessionIDByPanelID[record.panelID] == sessionID
                ? (sessionID, record)
                : nil
        })
    }

    private static func stableWorkspaceStatusSort(
        _ lhs: SessionRecord,
        _ rhs: SessionRecord,
        orderBySessionID: [String: Int]
    ) -> Bool {
        let lhsOrder = orderBySessionID[lhs.sessionID] ?? Int.max
        let rhsOrder = orderBySessionID[rhs.sessionID] ?? Int.max
        if lhsOrder != rhsOrder {
            return lhsOrder < rhsOrder
        }
        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt < rhs.startedAt
        }
        return lhs.sessionID < rhs.sessionID
    }

    private func stoppedWorkspaceStatusSort(_ lhs: SessionRecord, _ rhs: SessionRecord) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.startedAt > rhs.startedAt
    }

    private static func shouldPresentStoppedPanelStatus(for record: SessionRecord) -> Bool {
        guard record.isActive == false,
              let status = record.status else {
            return false
        }
        // Stopped sessions should not keep rendering a live working spinner in
        // the panel header after the active sidebar entry disappears.
        return status.kind != .idle && status.kind != .working
    }

    private static func projectedStatus(
        from record: SessionRecord,
        at now: Date
    ) -> (status: SessionStatus, projection: SessionStatusProjection)? {
        guard record.isActive else {
            return record.status.map { ($0, .none) }
        }

        let outstandingCount = record.backgroundActivitiesByID.count
        let pendingBackgroundTaskCount = record.pendingBackgroundTaskCount

        switch record.status?.kind {
        case .needsApproval, .error, .working:
            return record.status.map { ($0, .none) }
        case .idle, .ready, nil:
            if outstandingCount > 0 || pendingBackgroundTaskCount > 0 {
                return (
                    SessionStatus(
                        kind: .working,
                        summary: "Working",
                        detail: record.status?.detail
                    ),
                    .waitingOnChildren(
                        childCount: outstandingCount,
                        pendingBackgroundTaskCount: pendingBackgroundTaskCount
                    )
                )
            }

            guard let rawStatus = record.status else {
                return nil
            }
            if shouldProjectResuming(record: record, now: now) {
                return (
                    SessionStatus(
                        kind: .working,
                        summary: "Working",
                        detail: "Resuming…"
                    ),
                    .resuming
                )
            }
            return (rawStatus, .none)
        }
    }

    private static func shouldProjectResuming(
        record: SessionRecord,
        now: Date
    ) -> Bool {
        guard record.backgroundActivitiesByID.isEmpty,
              record.pendingBackgroundTaskCount == 0,
              let rawStatusKind = record.status?.kind,
              rawStatusKind == .idle || rawStatusKind == .ready,
              let lastActivityFinishedAt = record.lastActivityFinishedAt,
              record.statusUpdatedAt.map({ $0 < lastActivityFinishedAt }) ?? true else {
            return false
        }
        return now < lastActivityFinishedAt.addingTimeInterval(Self.resumeProjectionGraceInterval)
    }
}

private extension SessionRegistry {
    enum CodingKeys: String, CodingKey {
        case sessionsByID
        case activeSessionIDByPanelID
        case sessionOrder
    }

    static func normalizedSessionOrder(
        _ sessionOrder: [String],
        sessionsByID: [String: SessionRecord]
    ) -> [String] {
        let knownSessionIDs = Set(sessionsByID.keys)
        var seenSessionIDs = Set<String>()
        var normalizedOrder = sessionOrder.filter { sessionID in
            guard knownSessionIDs.contains(sessionID) else {
                return false
            }
            return seenSessionIDs.insert(sessionID).inserted
        }

        let missingSessionIDs = sessionsByID.values
            .sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt {
                    return lhs.startedAt < rhs.startedAt
                }
                return lhs.sessionID < rhs.sessionID
            }
            .map(\.sessionID)
            .filter { seenSessionIDs.contains($0) == false }
        normalizedOrder.append(contentsOf: missingSessionIDs)
        return normalizedOrder
    }

    static func mergedBackgroundActivity(
        existing: SessionBackgroundActivity,
        incoming: SessionBackgroundActivity
    ) -> SessionBackgroundActivity {
        SessionBackgroundActivity(
            id: existing.id,
            kind: existing.kind,
            displayName: incoming.displayName ?? existing.displayName,
            command: incoming.command ?? existing.command,
            processID: incoming.processID ?? existing.processID,
            preserveWhenUnlisted: existing.preserveWhenUnlisted || incoming.preserveWhenUnlisted,
            startedAt: existing.startedAt,
            lastUpdatedAt: incoming.lastUpdatedAt
        )
    }

    static func defaultActivityDisplayName(for kind: SessionBackgroundActivityKind) -> String {
        switch kind {
        case .childAgent:
            return "Child agent"
        case .subagent:
            return "Sub-agent"
        }
    }

    static func ancestorSessionIDs(
        of sessionID: String,
        activeRecordsByID: [String: SessionRecord]
    ) -> Set<String> {
        var ancestors = Set<String>()
        var visited = Set<String>([sessionID])
        var nextParentID = activeRecordsByID[sessionID]?.parentSessionID

        while let parentID = nextParentID {
            ancestors.insert(parentID)
            guard visited.insert(parentID).inserted else {
                break
            }
            nextParentID = activeRecordsByID[parentID]?.parentSessionID
        }

        return ancestors
    }

    static func parentChainHasCycle(
        startingAt sessionID: String,
        activeRecordsByID: [String: SessionRecord]
    ) -> Bool {
        var visited = Set<String>([sessionID])
        var nextParentID = activeRecordsByID[sessionID]?.parentSessionID

        while let parentID = nextParentID {
            guard visited.insert(parentID).inserted else {
                return true
            }
            nextParentID = activeRecordsByID[parentID]?.parentSessionID
        }

        return false
    }
}

extension SessionRegistry {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sessionsByID = try container.decodeIfPresent([String: SessionRecord].self, forKey: .sessionsByID) ?? [:]
        let activeSessionIDByPanelID = try container.decodeIfPresent(
            [UUID: String].self,
            forKey: .activeSessionIDByPanelID
        ) ?? [:]
        let sessionOrder = try container.decodeIfPresent([String].self, forKey: .sessionOrder) ?? []
        self.init(
            sessionsByID: sessionsByID,
            activeSessionIDByPanelID: activeSessionIDByPanelID,
            sessionOrder: sessionOrder
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionsByID, forKey: .sessionsByID)
        try container.encode(activeSessionIDByPanelID, forKey: .activeSessionIDByPanelID)
        try container.encode(sessionOrder, forKey: .sessionOrder)
    }
}
