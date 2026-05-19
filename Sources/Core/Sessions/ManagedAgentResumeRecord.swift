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

    var resumeClaimKey: String? {
        let normalizedNativeSessionID = nativeSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedNativeSessionID.isEmpty == false {
            return "\(agent.rawValue)\u{0}native:\(normalizedNativeSessionID.lowercased())"
        }

        let normalizedSessionFilePath = sessionFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedSessionFilePath.isEmpty == false else { return nil }
        return "\(agent.rawValue)\u{0}file:\((normalizedSessionFilePath as NSString).standardizingPath)"
    }
}
