import Foundation

public struct SessionRegistry: Codable, Equatable, Sendable {
    public private(set) var sessionsByID: [String: SessionRecord]
    public private(set) var activeSessionIDByPanelID: [UUID: String]

    public init(
        sessionsByID: [String: SessionRecord] = [:],
        activeSessionIDByPanelID: [UUID: String] = [:]
    ) {
        self.sessionsByID = sessionsByID
        self.activeSessionIDByPanelID = activeSessionIDByPanelID
    }

    public mutating func startSession(
        sessionID: String,
        agent: AgentKind,
        panelID: UUID,
        windowID: UUID,
        workspaceID: UUID,
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
            repoRoot: repoRoot,
            cwd: cwd,
            startedAt: now,
            updatedAt: now
        )

        sessionsByID[sessionID] = record
        activeSessionIDByPanelID[panelID] = sessionID
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
        sessionsByID.values
            .filter { record in
                record.workspaceID == workspaceID &&
                record.status != nil &&
                record.isActive
            }
            .sorted(by: activeWorkspaceStatusSort)
            .compactMap(Self.workspaceSessionStatus(from:))
    }

    public mutating func pruneStoppedSessions(olderThan cutoff: Date) {
        for (sessionID, record) in sessionsByID where record.stoppedAt.map({ $0 < cutoff }) == true {
            sessionsByID.removeValue(forKey: sessionID)
        }

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

    private func activeWorkspaceStatusSort(_ lhs: SessionRecord, _ rhs: SessionRecord) -> Bool {
        let lhsStatus = Self.requiredWorkspaceStatus(from: lhs)
        let rhsStatus = Self.requiredWorkspaceStatus(from: rhs)
        if lhsStatus.kind.activeWorkspacePriority != rhsStatus.kind.activeWorkspacePriority {
            return lhsStatus.kind.activeWorkspacePriority > rhsStatus.kind.activeWorkspacePriority
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.startedAt > rhs.startedAt
    }

    private func stoppedWorkspaceStatusSort(_ lhs: SessionRecord, _ rhs: SessionRecord) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.startedAt > rhs.startedAt
    }

    private static func requiredWorkspaceStatus(from record: SessionRecord) -> SessionStatus {
        guard let status = record.status else {
            preconditionFailure("workspace status sort requires a record with status")
        }
        return status
    }

    private static func shouldPresentStoppedPanelStatus(for record: SessionRecord) -> Bool {
        guard record.isActive == false,
              let status = record.status else {
            return false
        }
        return status.kind != .idle
    }
}
