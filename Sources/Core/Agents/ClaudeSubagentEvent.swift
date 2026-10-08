import Foundation

/// Child lifecycle events need app-side identity to distinguish a reusable
/// teammate from an ordinary subagent. Claude's Stop task IDs are unrelated.
public struct ClaudeSubagentEvent: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case spawned
        case started
        case finished
        case toolUse = "tool_use"
        case toolCompleted = "tool_completed"
        case permission
    }

    public var phase: Phase
    public var agentID: String
    public var toolUseID: String?
    public var displayName: String?
    public var command: String?
    public var summary: String?
    public var detail: String?
    public var executionProfile: SessionAgentExecutionProfile?

    public init(
        phase: Phase,
        agentID: String,
        toolUseID: String? = nil,
        displayName: String? = nil,
        command: String? = nil,
        summary: String? = nil,
        detail: String? = nil,
        executionProfile: SessionAgentExecutionProfile? = nil
    ) {
        self.phase = phase
        self.agentID = agentID
        self.toolUseID = toolUseID
        self.displayName = displayName
        self.command = command
        self.summary = summary
        self.detail = detail
        self.executionProfile = executionProfile
    }
}
