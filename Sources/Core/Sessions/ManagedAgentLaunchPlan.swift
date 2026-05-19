import Foundation

public struct ManagedAgentLaunchRequest: Codable, Equatable, Sendable {
    public let agent: AgentKind
    public let panelID: UUID
    public let argv: [String]
    public let cwd: String?
    public let preflightPolicy: ManagedAgentLaunchPreflightPolicy

    private enum CodingKeys: String, CodingKey {
        case agent
        case panelID
        case argv
        case cwd
        case preflightPolicy
    }

    public init(
        agent: AgentKind,
        panelID: UUID,
        argv: [String],
        cwd: String?,
        preflightPolicy: ManagedAgentLaunchPreflightPolicy = .skip
    ) {
        self.agent = agent
        self.panelID = panelID
        self.argv = argv
        self.cwd = cwd
        self.preflightPolicy = preflightPolicy
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = try container.decode(AgentKind.self, forKey: .agent)
        panelID = try container.decode(UUID.self, forKey: .panelID)
        argv = try container.decode([String].self, forKey: .argv)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        preflightPolicy = try container.decodeIfPresent(
            ManagedAgentLaunchPreflightPolicy.self,
            forKey: .preflightPolicy
        ) ?? .skip
    }
}

public enum ManagedAgentLaunchPreflightPolicy: String, Codable, Equatable, Sendable {
    case skip
    case interactive
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

public enum ManagedAgentLaunchPreparationKind: String, Codable, Equatable, Sendable {
    case plan
    case preflightRequired
}

public struct ManagedAgentLaunchPreparation: Codable, Equatable, Sendable {
    public let kind: ManagedAgentLaunchPreparationKind
    public let plan: ManagedAgentLaunchPlan?
    public let preflight: ManagedAgentLaunchPreflight?

    public init(plan: ManagedAgentLaunchPlan) {
        self.kind = .plan
        self.plan = plan
        self.preflight = nil
    }

    public init(preflight: ManagedAgentLaunchPreflight) {
        self.kind = .preflightRequired
        self.plan = nil
        self.preflight = preflight
    }
}

public struct ManagedAgentLaunchPreflight: Codable, Equatable, Sendable {
    public let token: String
    public let agent: AgentKind
    public let panelID: UUID
    public let windowID: UUID?
    public let title: String
    public let message: String
    public let canOpenSetup: Bool
    public let pollIntervalMilliseconds: Int

    public init(
        token: String,
        agent: AgentKind,
        panelID: UUID,
        windowID: UUID?,
        title: String,
        message: String,
        canOpenSetup: Bool,
        pollIntervalMilliseconds: Int
    ) {
        self.token = token
        self.agent = agent
        self.panelID = panelID
        self.windowID = windowID
        self.title = title
        self.message = message
        self.canOpenSetup = canOpenSetup
        self.pollIntervalMilliseconds = pollIntervalMilliseconds
    }
}

public enum ManagedAgentLaunchPreflightDecisionKind: String, Codable, Equatable, Sendable {
    case pending
    case runAnyway
    case setUpHooks
    case cancel
    case expired
    case notFound
}

public struct ManagedAgentLaunchPreflightDecision: Codable, Equatable, Sendable {
    public let kind: ManagedAgentLaunchPreflightDecisionKind
    public let message: String?

    public init(kind: ManagedAgentLaunchPreflightDecisionKind, message: String? = nil) {
        self.kind = kind
        self.message = message
    }
}
