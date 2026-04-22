import Foundation

public struct SessionRegistry: Codable, Equatable, Sendable {
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
        usesSessionStatusNotifications: Bool = false,
        cwd: String?,
        repoRoot: String?,
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
            usesSessionStatusNotifications: usesSessionStatusNotifications,
            repoRoot: repoRoot,
            cwd: cwd,
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
        record.updatedAt = now
        sessionsByID[sessionID] = record
    }

    public mutating func setLaterFlag(sessionID: String, isFlagged: Bool) {
        guard var record = sessionsByID[sessionID], record.isActive else { return }
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
        record.stoppedAt = now
        record.updatedAt = now
        sessionsByID[sessionID] = record

        if activeSessionIDByPanelID[record.panelID] == sessionID {
            activeSessionIDByPanelID.removeValue(forKey: record.panelID)
        }
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

    public func panelStatus(for panelID: UUID) -> WorkspaceSessionStatus? {
        if let activeRecord = activeSession(for: panelID) {
            return Self.workspaceSessionStatus(from: activeRecord)
        }

        return sessionsByID.values
            .filter { record in
                record.panelID == panelID && Self.shouldPresentStoppedPanelStatus(for: record)
            }
            .sorted(by: stoppedWorkspaceStatusSort)
            .compactMap(Self.workspaceSessionStatus(from:))
            .first
    }

    public func workspaceStatuses(for workspaceID: UUID) -> [WorkspaceSessionStatus] {
        let orderBySessionID = Dictionary(
            uniqueKeysWithValues: sessionOrder.enumerated().map { offset, sessionID in
                (sessionID, offset)
            }
        )
        return sessionsByID.values
            .filter { record in
                record.workspaceID == workspaceID &&
                record.status != nil &&
                record.isActive
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
            .compactMap(Self.workspaceSessionStatus(from:))
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

    private static func workspaceSessionStatus(from record: SessionRecord) -> WorkspaceSessionStatus? {
        guard let status = record.status else { return nil }
        return WorkspaceSessionStatus(
            sessionID: record.sessionID,
            panelID: record.panelID,
            agent: record.agent,
            status: status,
            cwd: record.cwd,
            updatedAt: record.updatedAt,
            isActive: record.isActive
        )
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
