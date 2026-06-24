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

    public init(
        sessionID: String,
        panelID: UUID,
        agent: AgentKind,
        status: SessionStatus,
        displayTitleOverride: String? = nil,
        cwd: String?,
        updatedAt: Date,
        isActive: Bool
    ) {
        self.sessionID = sessionID
        self.panelID = panelID
        self.agent = agent
        self.status = status
        self.displayTitleOverride = displayTitleOverride
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.isActive = isActive
    }

    public var displayTitle: String {
        displayTitleOverride ?? agent.displayName
    }
}

/// Summary of a workspace's live agent sessions, used for the sidebar/top-bar
/// "running/total" label (e.g. `1/3 running`). Process-watch monitors are not
/// counted as agents.
public struct WorkspaceAgentSummary: Equatable, Sendable {
    public var total: Int
    public var running: Int

    public init(total: Int, running: Int) {
        self.total = total
        self.running = running
    }

    public var hasAgents: Bool { total > 0 }
    public var hasRunning: Bool { running > 0 }

    public static func make(from statuses: [WorkspaceSessionStatus]) -> WorkspaceAgentSummary {
        let agents = statuses.filter { $0.agent != .processWatch }
        let running = agents.filter { $0.status.kind == .working }.count
        return WorkspaceAgentSummary(total: agents.count, running: running)
    }
}
