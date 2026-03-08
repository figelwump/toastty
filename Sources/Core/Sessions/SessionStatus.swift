import Foundation

public enum SessionStatusKind: String, Codable, Equatable, Sendable {
    case working
    case needsApproval = "needs_approval"
    case ready
    case error

    var activeWorkspacePriority: Int {
        switch self {
        case .error:
            return 4
        case .needsApproval:
            return 3
        case .working:
            return 2
        case .ready:
            return 1
        }
    }
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
    public var cwd: String?
    public var updatedAt: Date
    public var isActive: Bool

    public init(
        sessionID: String,
        panelID: UUID,
        agent: AgentKind,
        status: SessionStatus,
        cwd: String?,
        updatedAt: Date,
        isActive: Bool
    ) {
        self.sessionID = sessionID
        self.panelID = panelID
        self.agent = agent
        self.status = status
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.isActive = isActive
    }
}
