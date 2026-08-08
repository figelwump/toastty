import Foundation

enum AgentEventSource: String, Equatable {
    case claudeHooks = "claude-hooks"
    case codexHooks = "codex-hooks"
    case codexNotify = "codex-notify"
    case grokHooks = "grok-hooks"
    case mimocodePlugin = "mimocode-plugin"
    case opencodePlugin = "opencode-plugin"
    case piExtension = "pi-extension"
}
