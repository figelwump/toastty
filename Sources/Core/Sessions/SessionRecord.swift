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
}
