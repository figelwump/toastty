import Foundation

/// A bounded Grok hook observation. The app derives status after validating
/// the native conversation and prompt identities against the managed session.
public struct GrokHookEvent: Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case sessionStart = "session_start"
        case userPromptSubmit = "user_prompt_submit"
        case preToolUse = "pre_tool_use"
        case postToolUse = "post_tool_use"
        case postToolUseFailure = "post_tool_use_failure"
        case permissionRequest = "permission_request"
        case notification
        case stop
        case stopFailure = "stop_failure"
        case stopCancelled = "stop_cancelled"
        case sessionEnd = "session_end"
    }

    public var kind: Kind
    public var nativeSessionID: String
    public var promptID: String?
    public var timestamp: Date
    public var notificationType: String?
    public var toolName: String?
    public var toolUseID: String?
    public var isSubagent: Bool
    public var sessionFilePath: String?
    public var cwd: String?

    public init(
        kind: Kind,
        nativeSessionID: String,
        promptID: String? = nil,
        timestamp: Date,
        notificationType: String? = nil,
        toolName: String? = nil,
        toolUseID: String? = nil,
        isSubagent: Bool = false,
        sessionFilePath: String? = nil,
        cwd: String? = nil
    ) {
        self.kind = kind
        self.nativeSessionID = nativeSessionID
        self.promptID = promptID
        self.timestamp = timestamp
        self.notificationType = notificationType
        self.toolName = toolName
        self.toolUseID = toolUseID
        self.isSubagent = isSubagent
        self.sessionFilePath = sessionFilePath
        self.cwd = cwd
    }
}
