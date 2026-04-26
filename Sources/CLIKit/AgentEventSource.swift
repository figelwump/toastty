import Foundation

enum AgentEventSource: String, Equatable {
    case claudeHooks = "claude-hooks"
    case codexNotify = "codex-notify"
    case piExtension = "pi-extension"
}
