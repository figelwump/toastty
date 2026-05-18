import Foundation

public struct ManagedAgentResumeRecord: Codable, Equatable, Sendable {
    public var agent: AgentKind
    public var nativeSessionID: String
    public var sessionFilePath: String
    public var cwd: String
    public var capturedAt: Date

    public init(
        agent: AgentKind,
        nativeSessionID: String,
        sessionFilePath: String,
        cwd: String,
        capturedAt: Date
    ) {
        self.agent = agent
        self.nativeSessionID = nativeSessionID
        self.sessionFilePath = sessionFilePath
        self.cwd = cwd
        self.capturedAt = capturedAt
    }
}
