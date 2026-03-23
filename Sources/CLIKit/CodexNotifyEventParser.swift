import Foundation

enum CodexNotifyEventParser {
    static func parse(
        sessionID: String,
        panelID: UUID?,
        payload: Data
    ) throws -> [CLICommand] {
        let object = try decodeJSONObject(from: payload)
        let type = normalizedString(object["type"])
        guard type == "agent-turn-complete" || type == "task_complete" else {
            return []
        }

        return [
            .sessionStatus(
                sessionID: sessionID,
                panelID: panelID,
                kind: .ready,
                summary: "Ready",
                detail: normalizedSummaryText(object["last-assistant-message"])
                    ?? normalizedSummaryText(object["last_agent_message"])
                    ?? "Turn complete"
            )
        ]
    }
}

private extension CodexNotifyEventParser {
    static func decodeJSONObject(from payload: Data) throws -> [String: Any] {
        guard payload.isEmpty == false else { return [:] }
        let object = try JSONSerialization.jsonObject(with: payload)
        return object as? [String: Any] ?? [:]
    }

    static func normalizedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let collapsed = string
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    static func normalizedSummaryText(_ value: Any?, limit: Int = 160) -> String? {
        guard let string = normalizedString(value) else { return nil }
        guard string.count > limit else { return string }
        let endIndex = string.index(string.startIndex, offsetBy: limit - 3)
        return String(string[..<endIndex]) + "..."
    }
}
