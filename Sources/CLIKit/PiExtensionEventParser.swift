import Foundation

enum PiExtensionEventParser {
    private static let maxPayloadBytes = 64 * 1024

    static func parse(
        sessionID: String,
        panelID: UUID?,
        payload: Data
    ) throws -> [CLICommand] {
        guard payload.count <= maxPayloadBytes else {
            throw PiExtensionEventParserError.payloadTooLarge
        }

        let object = try decodeJSONObject(from: payload)
        guard normalizedString(object["source"]) == "pi-extension",
              integerValue(object["version"]) == 1,
              normalizedString(object["toasttySessionID"]) == sessionID else {
            return []
        }
        guard let event = normalizedString(object["event"]) else {
            return []
        }

        var commands: [CLICommand] = []
        switch event {
        case "session_start":
            commands.append(
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .idle,
                    summary: "Waiting",
                    detail: "Pi is ready"
                )
            )

        case "before_agent_start":
            commands.append(
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .working,
                    summary: "Working",
                    detail: normalizedString(object["prompt"], limit: 160) ?? "Responding to your prompt"
                )
            )

        case "agent_start":
            commands.append(
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .working,
                    summary: "Working",
                    detail: normalizedString(object["detail"], limit: 160) ?? "Pi is responding"
                )
            )

        case "tool_call", "tool_execution_start", "tool_execution_update":
            commands.append(
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .working,
                    summary: "Working",
                    detail: normalizedString(object["detail"], limit: 160)
                        ?? toolDetail(from: object)
                        ?? "Pi is using a tool"
                )
            )

        case "tool_result", "tool_execution_end":
            if boolValue(object["isError"]) == true {
                commands.append(
                    .sessionStatus(
                        sessionID: sessionID,
                        panelID: panelID,
                        kind: .working,
                        summary: "Working",
                        detail: toolFailureDetail(from: object) ?? "Tool failed"
                    )
                )
            }

        case "agent_end":
            commands.append(
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .ready,
                    summary: "Ready",
                    detail: normalizedString(object["summary"], limit: 160)
                )
            )

        case "session_shutdown":
            commands.append(
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .ready,
                    summary: "Ready",
                    detail: "Pi session ended"
                )
            )

        default:
            break
        }

        let files = normalizedStringArray(object["files"])
        if files.isEmpty == false {
            commands.append(
                .sessionUpdateFiles(
                    sessionID: sessionID,
                    panelID: panelID,
                    files: files,
                    cwd: nil,
                    repoRoot: nil
                )
            )
        }

        return commands
    }
}

enum PiExtensionEventParserError: LocalizedError, Equatable {
    case payloadTooLarge

    var errorDescription: String? {
        switch self {
        case .payloadTooLarge:
            return "Pi extension event payload is too large."
        }
    }
}

private extension PiExtensionEventParser {
    static func decodeJSONObject(from payload: Data) throws -> [String: Any] {
        guard payload.isEmpty == false else { return [:] }
        let object = try JSONSerialization.jsonObject(with: payload)
        return object as? [String: Any] ?? [:]
    }

    static func normalizedString(_ value: Any?, limit: Int = 160) -> String? {
        guard let string = value as? String else { return nil }
        let collapsed = string
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        guard collapsed.isEmpty == false else { return nil }
        guard collapsed.count > limit else { return collapsed }
        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: limit - 3)
        return String(collapsed[..<endIndex]) + "..."
    }

    static func normalizedStringArray(_ value: Any?) -> [String] {
        guard let values = value as? [Any] else { return [] }
        var result: [String] = []
        var seen = Set<String>()
        for value in values {
            guard let string = normalizedString(value, limit: 500),
                  seen.insert(string).inserted else {
                continue
            }
            result.append(string)
            if result.count >= 50 {
                break
            }
        }
        return result
    }

    static func integerValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    static func toolDetail(from object: [String: Any]) -> String? {
        guard let toolName = normalizedString(object["toolName"], limit: 80) else {
            return nil
        }
        return "Using \(displayToolName(toolName))"
    }

    static func toolFailureDetail(from object: [String: Any]) -> String? {
        guard let toolName = normalizedString(object["toolName"], limit: 80) else {
            return nil
        }
        return "\(displayToolName(toolName)) failed"
    }

    static func boolValue(_ value: Any?) -> Bool {
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return false
    }

    static func displayToolName(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}
