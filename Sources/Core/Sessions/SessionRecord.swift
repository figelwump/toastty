import Foundation

public struct HunkRef: Codable, Equatable, Hashable, Sendable {
    public var filePath: String
    public var oldStart: Int
    public var oldLength: Int
    public var newStart: Int
    public var newLength: Int

    public init(filePath: String, oldStart: Int, oldLength: Int, newStart: Int, newLength: Int) {
        self.filePath = filePath
        self.oldStart = oldStart
        self.oldLength = oldLength
        self.newStart = newStart
        self.newLength = newLength
    }
}

public struct SessionRecord: Codable, Equatable, Sendable {
    public var sessionID: String
    public var agent: AgentKind
    public var panelID: UUID
    public var windowID: UUID
    public var workspaceID: UUID
    public var isFlaggedForLater: Bool
    public var usesSessionStatusNotifications: Bool
    public var status: SessionStatus?
    public var repoRoot: String?
    public var cwd: String?
    public var touchedFiles: [String]
    public var touchedHunks: [HunkRef]
    public var startedAt: Date
    public var updatedAt: Date
    public var stoppedAt: Date?

    public init(
        sessionID: String,
        agent: AgentKind,
        panelID: UUID,
        windowID: UUID,
        workspaceID: UUID,
        isFlaggedForLater: Bool = false,
        usesSessionStatusNotifications: Bool = false,
        status: SessionStatus? = nil,
        repoRoot: String? = nil,
        cwd: String? = nil,
        touchedFiles: [String] = [],
        touchedHunks: [HunkRef] = [],
        startedAt: Date,
        updatedAt: Date,
        stoppedAt: Date? = nil
    ) {
        self.sessionID = sessionID
        self.agent = agent
        self.panelID = panelID
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.isFlaggedForLater = isFlaggedForLater
        self.usesSessionStatusNotifications = usesSessionStatusNotifications
        self.status = status
        self.repoRoot = repoRoot
        self.cwd = cwd
        self.touchedFiles = touchedFiles
        self.touchedHunks = touchedHunks
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.stoppedAt = stoppedAt
    }

    public var isActive: Bool {
        stoppedAt == nil
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        agent = try container.decode(AgentKind.self, forKey: .agent)
        panelID = try container.decode(UUID.self, forKey: .panelID)
        windowID = try container.decode(UUID.self, forKey: .windowID)
        workspaceID = try container.decode(UUID.self, forKey: .workspaceID)
        isFlaggedForLater = try container.decodeIfPresent(Bool.self, forKey: .isFlaggedForLater) ?? false
        usesSessionStatusNotifications = try container.decodeIfPresent(
            Bool.self,
            forKey: .usesSessionStatusNotifications
        ) ?? false
        status = try container.decodeIfPresent(SessionStatus.self, forKey: .status)
        repoRoot = try container.decodeIfPresent(String.self, forKey: .repoRoot)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        touchedFiles = try container.decodeIfPresent([String].self, forKey: .touchedFiles) ?? []
        touchedHunks = try container.decodeIfPresent([HunkRef].self, forKey: .touchedHunks) ?? []
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        stoppedAt = try container.decodeIfPresent(Date.self, forKey: .stoppedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(agent, forKey: .agent)
        try container.encode(panelID, forKey: .panelID)
        try container.encode(windowID, forKey: .windowID)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encode(isFlaggedForLater, forKey: .isFlaggedForLater)
        try container.encode(usesSessionStatusNotifications, forKey: .usesSessionStatusNotifications)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(repoRoot, forKey: .repoRoot)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encode(touchedFiles, forKey: .touchedFiles)
        try container.encode(touchedHunks, forKey: .touchedHunks)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(stoppedAt, forKey: .stoppedAt)
    }
}

private extension SessionRecord {
    enum CodingKeys: String, CodingKey {
        case sessionID
        case agent
        case panelID
        case windowID
        case workspaceID
        case isFlaggedForLater
        case usesSessionStatusNotifications
        case status
        case repoRoot
        case cwd
        case touchedFiles
        case touchedHunks
        case startedAt
        case updatedAt
        case stoppedAt
    }
}
