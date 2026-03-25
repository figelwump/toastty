import Foundation

enum ClaudeHookEventParser {
    static func parse(
        sessionID: String,
        panelID: UUID?,
        payload: Data
    ) throws -> [CLICommand] {
        let object = try decodeJSONObject(from: payload)
        guard let eventName = normalizedString(object["hook_event_name"]) else {
            return []
        }

        switch eventName {
        case "UserPromptSubmit":
            return [
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .working,
                    summary: "Working",
                    detail: submittedPromptDetail(from: object) ?? "Responding to your prompt"
                )
            ]

        case "PermissionRequest":
            return [
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .needsApproval,
                    summary: "Needs approval",
                    detail: approvalDetail(from: object) ?? "Claude Code is waiting for approval"
                )
            ]

        case "PostToolUse":
            return [
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .working,
                    summary: "Working",
                    detail: toolProgressDetail(from: object) ?? "Working inside Claude Code"
                )
            ]

        case "PostToolUseFailure":
            return [
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .working,
                    summary: "Working",
                    detail: toolFailureDetail(from: object) ?? "Retrying after a tool error"
                )
            ]

        case "Stop":
            return [
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .ready,
                    summary: "Ready",
                    detail: normalizedSummaryText(object["last_assistant_message"]) ?? "Turn complete"
                )
            ]

        case "Notification":
            return notificationCommands(sessionID: sessionID, panelID: panelID, from: object)

        default:
            return []
        }
    }

    private static func notificationCommands(
        sessionID: String,
        panelID: UUID?,
        from object: [String: Any]
    ) -> [CLICommand] {
        switch normalizedString(object["notification_type"]) {
        case "idle_prompt":
            return [
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .ready,
                    summary: "Ready",
                    detail: normalizedSummaryText(object["message"]) ?? "Waiting for input"
                )
            ]

        case "permission_prompt":
            return [
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .needsApproval,
                    summary: "Needs approval",
                    detail: normalizedSummaryText(object["message"]) ?? "Claude Code is waiting for approval"
                )
            ]

        case "elicitation_dialog":
            return [
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .needsApproval,
                    summary: "Needs input",
                    detail: normalizedSummaryText(object["message"]) ?? "Claude Code is waiting for input"
                )
            ]

        case "auth_success":
            // Authentication success is informative but not a session status change.
            return []

        default:
            return []
        }
    }

    private static func approvalDetail(from object: [String: Any]) -> String? {
        if let message = normalizedSummaryText(object["message"]) {
            return message
        }
        if let description = toolDescription(from: object) {
            return "Approve \(description)"
        }
        return nil
    }

    private static func toolProgressDetail(from object: [String: Any]) -> String? {
        toolDescription(from: object)
    }

    private static func toolFailureDetail(from object: [String: Any]) -> String? {
        guard let toolName = normalizedString(object["tool_name"]) else {
            return nil
        }
        return "Retrying after \(displayToolName(toolName)) failed"
    }

    private static func submittedPromptDetail(from object: [String: Any]) -> String? {
        normalizedSummaryText(object["prompt"], limit: 140)
    }

    private static func toolDescription(from object: [String: Any]) -> String? {
        guard let toolName = normalizedString(object["tool_name"]) else {
            return nil
        }
        let input = object["tool_input"] as? [String: Any] ?? [:]

        switch toolName.lowercased() {
        case "write", "edit", "multiedit":
            if let path = firstPathValue(in: input) {
                return "Editing \(path)"
            }
            return "Editing files"

        case "read":
            if let path = firstPathValue(in: input) {
                return "Reading \(path)"
            }
            return "Reading files"

        case "glob", "grep":
            return "Searching the workspace"

        case "bash":
            if let command = normalizedSummaryText(input["command"], limit: 100) {
                return "Running \(command)"
            }
            return "Running a shell command"

        default:
            return "Using \(displayToolName(toolName))"
        }
    }

    private static func firstPathValue(in input: [String: Any]) -> String? {
        for key in ["file_path", "path"] {
            if let path = normalizedString(input[key]) {
                return lastPathComponent(path)
            }
        }
        if let paths = input["paths"] as? [String] {
            return paths.first.map(lastPathComponent(_:))
        }
        return nil
    }

    private static func displayToolName(_ toolName: String) -> String {
        switch toolName.lowercased() {
        case "multiedit":
            return "MultiEdit"
        default:
            return toolName
        }
    }
}

private extension ClaudeHookEventParser {
    static func decodeJSONObject(from payload: Data) throws -> [String: Any] {
        guard payload.isEmpty == false else { return [:] }
        let object = try JSONSerialization.jsonObject(with: payload)
        return object as? [String: Any] ?? [:]
    }

    static func normalizedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        return normalizeWhitespace(in: string)
    }

    static func normalizedSummaryText(_ value: Any?, limit: Int = 160) -> String? {
        guard let string = normalizedString(value) else { return nil }
        guard string.count > limit else { return string }
        let endIndex = string.index(string.startIndex, offsetBy: limit - 3)
        return String(string[..<endIndex]) + "..."
    }

    static func normalizeWhitespace(in string: String) -> String? {
        let collapsed = string
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    static func lastPathComponent(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}
