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

    public func workspaceStatus(for workspaceID: UUID) -> WorkspaceSessionStatus? {
        let candidates = sessionsByID.values.filter { record in
            record.workspaceID == workspaceID && record.status != nil
        }
        let activeSessionExists = sessionsByID.values.contains { record in
            record.workspaceID == workspaceID && record.isActive
        }
        let activeCandidates = candidates.filter(\.isActive)
        if activeSessionExists && activeCandidates.isEmpty {
            return nil
        }
        guard candidates.isEmpty == false else { return nil }

        let selectedRecord: SessionRecord
        if let bestActiveRecord = activeCandidates.max(by: activeWorkspaceStatusSort) {
            selectedRecord = bestActiveRecord
        } else if let latestStoppedRecord = candidates.max(by: stoppedWorkspaceStatusSort) {
            selectedRecord = latestStoppedRecord
        } else {
            return nil
        }

        guard let status = selectedRecord.status else { return nil }
        return WorkspaceSessionStatus(
            sessionID: selectedRecord.sessionID,
            panelID: selectedRecord.panelID,
            agent: selectedRecord.agent,
            status: status,
            cwd: selectedRecord.cwd,
            updatedAt: selectedRecord.updatedAt,
            isActive: selectedRecord.isActive
        )
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

    private func activeWorkspaceStatusSort(_ lhs: SessionRecord, _ rhs: SessionRecord) -> Bool {
        guard let lhsStatus = lhs.status, let rhsStatus = rhs.status else {
            return lhs.updatedAt < rhs.updatedAt
        }
        if lhsStatus.kind.activeWorkspacePriority != rhsStatus.kind.activeWorkspacePriority {
            return lhsStatus.kind.activeWorkspacePriority < rhsStatus.kind.activeWorkspacePriority
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt < rhs.updatedAt
        }
        return lhs.startedAt < rhs.startedAt
    }

    private func stoppedWorkspaceStatusSort(_ lhs: SessionRecord, _ rhs: SessionRecord) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt < rhs.updatedAt
        }
        return lhs.startedAt < rhs.startedAt
    }
}
