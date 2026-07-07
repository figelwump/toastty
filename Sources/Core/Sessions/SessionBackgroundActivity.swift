import Foundation

public enum SessionBackgroundActivityKind: String, Codable, Equatable, Sendable {
    case childAgent = "child_agent"
}

public enum SessionBackgroundActivityPhase: String, Codable, Equatable, Sendable {
    case start
    case finish
}

public struct SessionBackgroundActivity: Codable, Equatable, Sendable {
    public var id: String
    public var kind: SessionBackgroundActivityKind
    public var displayName: String?
    public var command: String?
    public var processID: Int32?
    public var startedAt: Date
    public var lastUpdatedAt: Date

    public init(
        id: String,
        kind: SessionBackgroundActivityKind,
        displayName: String? = nil,
        command: String? = nil,
        processID: Int32? = nil,
        startedAt: Date,
        lastUpdatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.displayName = Self.normalizedOptionalText(displayName)
        self.command = Self.normalizedOptionalText(command)
        self.processID = processID
        self.startedAt = startedAt
        self.lastUpdatedAt = lastUpdatedAt
    }
}

private extension SessionBackgroundActivity {
    static func normalizedOptionalText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }
}
