import Foundation

public enum SessionBackgroundActivityKind: String, Codable, Equatable, Sendable {
    case childAgent = "child_agent"
    case subagent
}

public enum SessionBackgroundActivityPhase: String, Codable, Equatable, Sendable {
    case start
    case finish
    case sync
}

public struct SessionAgentExecutionProfile: Codable, Equatable, Sendable {
    public var modelIdentifier: String?
    public var reasoningEffort: String?

    public init(
        modelIdentifier: String? = nil,
        reasoningEffort: String? = nil
    ) {
        self.modelIdentifier = Self.normalizedOptionalText(modelIdentifier)
        self.reasoningEffort = Self.normalizedOptionalText(reasoningEffort)
    }

    public var isEmpty: Bool {
        modelIdentifier == nil && reasoningEffort == nil
    }
}

public struct SessionBackgroundActivity: Codable, Equatable, Sendable {
    public var id: String
    public var kind: SessionBackgroundActivityKind
    public var displayName: String?
    public var command: String?
    public var executionProfile: SessionAgentExecutionProfile?
    public var processID: Int32?
    public var preserveWhenUnlisted: Bool
    public var startedAt: Date
    public var lastUpdatedAt: Date

    public init(
        id: String,
        kind: SessionBackgroundActivityKind,
        displayName: String? = nil,
        command: String? = nil,
        executionProfile: SessionAgentExecutionProfile? = nil,
        processID: Int32? = nil,
        preserveWhenUnlisted: Bool = false,
        startedAt: Date,
        lastUpdatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.displayName = Self.normalizedOptionalText(displayName)
        self.command = Self.normalizedOptionalText(command)
        self.executionProfile = executionProfile?.isEmpty == false ? executionProfile : nil
        self.processID = processID
        self.preserveWhenUnlisted = preserveWhenUnlisted
        self.startedAt = startedAt
        self.lastUpdatedAt = lastUpdatedAt
    }
}

private extension SessionAgentExecutionProfile {
    static func normalizedOptionalText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
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
