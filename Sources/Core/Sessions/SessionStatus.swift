import Foundation

public enum SessionStatusKind: String, Codable, Equatable, Sendable {
    case idle
    case working
    case needsApproval = "needs_approval"
    case ready
    case error
}

public struct SessionStatus: Codable, Equatable, Sendable {
    public var kind: SessionStatusKind
    public var summary: String
    public var detail: String?

    public init(kind: SessionStatusKind, summary: String, detail: String? = nil) {
        self.kind = kind
        self.summary = summary
        self.detail = detail
    }
}

public enum SessionStatusProjection: Equatable, Sendable {
    case none
    case waitingOnChildren(childCount: Int, pendingBackgroundTaskCount: Int)
    case resuming
}

public enum SessionChildRowSource: Equatable, Sendable {
    case activity
    case session
}

public struct SessionChildRow: Equatable, Sendable {
    public var id: String
    public var source: SessionChildRowSource
    public var displayName: String
    public var context: String?
    public var startedAt: Date
    public var statusKind: SessionStatusKind?
    public var panelID: UUID?
    public var workspaceID: UUID?
    public var sessionID: String?

    public init(
        id: String,
        source: SessionChildRowSource,
        displayName: String,
        context: String? = nil,
        startedAt: Date,
        statusKind: SessionStatusKind? = nil,
        panelID: UUID? = nil,
        workspaceID: UUID? = nil,
        sessionID: String? = nil
    ) {
        self.id = id
        self.source = source
        self.displayName = displayName
        self.context = Self.normalizedOptionalText(context)
        self.startedAt = startedAt
        self.statusKind = statusKind
        self.panelID = panelID
        self.workspaceID = workspaceID
        self.sessionID = sessionID
    }
}

public struct WorkspaceSessionStatus: Equatable, Sendable {
    public var sessionID: String
    public var panelID: UUID
    public var workspaceID: UUID
    public var parentSessionID: String?
    public var agent: AgentKind
    public var status: SessionStatus
    public var projection: SessionStatusProjection
    public var children: [SessionChildRow]
    public var displayTitleOverride: String?
    public var cwd: String?
    public var updatedAt: Date
    public var isActive: Bool
    public var scopedWorkspaceIDs: Set<UUID>?
    public var effectiveScopedWorkspaceIDs: Set<UUID>?

    public var isWorkspaceScoped: Bool {
        scopedWorkspaceIDs != nil
    }

    public init(
        sessionID: String,
        panelID: UUID,
        workspaceID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        parentSessionID: String? = nil,
        agent: AgentKind,
        status: SessionStatus,
        projection: SessionStatusProjection = .none,
        children: [SessionChildRow] = [],
        displayTitleOverride: String? = nil,
        cwd: String?,
        updatedAt: Date,
        isActive: Bool,
        scopedWorkspaceIDs: Set<UUID>? = nil,
        effectiveScopedWorkspaceIDs: Set<UUID>? = nil
    ) {
        self.sessionID = sessionID
        self.panelID = panelID
        self.workspaceID = workspaceID
        self.parentSessionID = Self.normalizedOptionalText(parentSessionID)
        self.agent = agent
        self.status = status
        self.projection = projection
        self.children = children
        self.displayTitleOverride = displayTitleOverride
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.isActive = isActive
        self.scopedWorkspaceIDs = scopedWorkspaceIDs
        self.effectiveScopedWorkspaceIDs = effectiveScopedWorkspaceIDs
    }

    public var displayTitle: String {
        displayTitleOverride ?? agent.displayName
    }
}

/// Summary of a workspace's live agent sessions, used for the sidebar/top-bar
/// status labels. Process-watch monitors are not counted as agents.
public struct WorkspaceAgentSummary: Equatable, Sendable {
    public var running: Int
    public var active: Int

    public init(running: Int, active: Int) {
        self.running = running
        self.active = active
    }

    public var hasRunning: Bool { running > 0 }
    public var hasActive: Bool { active > 0 }

    public static func make(
        from statuses: [WorkspaceSessionStatus],
        workspaceID: UUID? = nil
    ) -> WorkspaceAgentSummary {
        // `isActive` is session liveness, not the working/active status bucket.
        let agents = statuses.filter { $0.agent != .processWatch && $0.isActive }
        let nestedSessionChildren = statuses.flatMap(\.children).filter { child in
            guard child.source == .session else { return false }
            guard let workspaceID else { return true }
            return child.workspaceID == workspaceID
        }
        let active = agents.filter { $0.status.kind == .working }.count +
            nestedSessionChildren.filter { $0.statusKind == .working }.count
        return WorkspaceAgentSummary(
            running: agents.count + nestedSessionChildren.count,
            active: active
        )
    }
}

private extension SessionChildRow {
    static func normalizedOptionalText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}

private extension WorkspaceSessionStatus {
    static func normalizedOptionalText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}
