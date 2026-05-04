import CoreState
import Foundation

enum CodexNotifyEventParser {
    static func parse(
        sessionID: String,
        panelID: UUID?,
        payload: Data
    ) throws -> [CLICommand] {
        let object = try decodeJSONObject(from: payload)
        guard let type = normalizedString(object["type"]),
              type == "agent-turn-complete" || type == "task_complete" else {
            return []
        }

        return [
            .sessionCodexNotifyCompletion(
                sessionID: sessionID,
                panelID: panelID,
                completion: CodexNotifyCompletion(
                    notificationType: type,
                    threadID: normalizedString(object["thread-id"]) ?? normalizedString(object["thread_id"]),
                    turnID: normalizedString(object["turn-id"]) ?? normalizedString(object["turn_id"]),
                    lastInputMessageFingerprint: lastInputMessageFingerprint(from: object),
                    inputMessageCount: inputMessages(from: object).count,
                    detail: normalizedSummaryText(object["last-assistant-message"])
                        ?? normalizedSummaryText(object["last_agent_message"])
                        ?? "Turn complete"
                )
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

    static func lastInputMessageFingerprint(from object: [String: Any]) -> String? {
        guard let message = inputMessages(from: object).last else {
            return nil
        }
        return CodexInputFingerprint.fingerprint(for: message)
    }

    static func inputMessages(from object: [String: Any]) -> [String] {
        let value = object["input-messages"] ?? object["input_messages"]
        if let messages = value as? [Any] {
            return messages.compactMap(normalizedString)
        }
        if let message = normalizedString(value) {
            return [message]
        }
        return []
    }
}
