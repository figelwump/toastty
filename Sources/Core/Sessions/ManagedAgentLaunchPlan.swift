import Foundation

public struct ManagedAgentLaunchRequest: Codable, Equatable, Sendable {
    public let agent: AgentKind
    public let panelID: UUID
    public let argv: [String]
    public let cwd: String?

    public init(
        agent: AgentKind,
        panelID: UUID,
        argv: [String],
        cwd: String?
    ) {
        self.agent = agent
        self.panelID = panelID
        self.argv = argv
        self.cwd = cwd
    }
}

public struct ManagedAgentLaunchPlan: Codable, Equatable, Sendable {
    public let sessionID: String
    public let agent: AgentKind
    public let panelID: UUID
    public let windowID: UUID
    public let workspaceID: UUID
    public let cwd: String?
    public let repoRoot: String?
    public let argv: [String]
    public let environment: [String: String]

    public init(
        sessionID: String,
        agent: AgentKind,
        panelID: UUID,
        windowID: UUID,
        workspaceID: UUID,
        cwd: String?,
        repoRoot: String?,
        argv: [String],
        environment: [String: String]
    ) {
        self.sessionID = sessionID
        self.agent = agent
        self.panelID = panelID
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.cwd = cwd
        self.repoRoot = repoRoot
        self.argv = argv
        self.environment = environment
    }
}
