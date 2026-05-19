import Foundation

enum AgentEventSource: String, Equatable {
    case claudeHooks = "claude-hooks"
    case codexHooks = "codex-hooks"
    case codexNotify = "codex-notify"
    case piExtension = "pi-extension"
}
