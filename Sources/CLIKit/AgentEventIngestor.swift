import Foundation

enum AgentEventIngestor {
    static func commands(
        for source: AgentEventSource,
        sessionID: String,
        panelID: UUID?,
        payload: Data
    ) throws -> [CLICommand] {
        switch source {
        case .claudeHooks:
            try ClaudeHookEventParser.parse(
                sessionID: sessionID,
                panelID: panelID,
                payload: payload
            )
        case .codexNotify:
            try CodexNotifyEventParser.parse(
                sessionID: sessionID,
                panelID: panelID,
                payload: payload
            )
        case .piExtension:
            try PiExtensionEventParser.parse(
                sessionID: sessionID,
                panelID: panelID,
                payload: payload
            )
        }
    }
}
