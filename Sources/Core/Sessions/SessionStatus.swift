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

public struct WorkspaceSessionStatus: Equatable, Sendable {
    public var sessionID: String
    public var panelID: UUID
    public var agent: AgentKind
    public var status: SessionStatus
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
        agent: AgentKind,
        status: SessionStatus,
        displayTitleOverride: String? = nil,
        cwd: String?,
        updatedAt: Date,
        isActive: Bool,
        scopedWorkspaceIDs: Set<UUID>? = nil,
        effectiveScopedWorkspaceIDs: Set<UUID>? = nil
    ) {
        self.sessionID = sessionID
        self.panelID = panelID
        self.agent = agent
        self.status = status
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

    public static func make(from statuses: [WorkspaceSessionStatus]) -> WorkspaceAgentSummary {
        // `isActive` is session liveness, not the working/active status bucket.
        let agents = statuses.filter { $0.agent != .processWatch && $0.isActive }
        let active = agents.filter { $0.status.kind == .working }.count
        return WorkspaceAgentSummary(running: agents.count, active: active)
    }
}
