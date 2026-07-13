import CoreState
import Foundation

enum CodexHookEventParser {
    static func parse(
        sessionID: String,
        panelID: UUID?,
        payload: Data
    ) throws -> [CLICommand] {
        let object = try decodeJSONObject(from: payload)
        guard let eventName = normalizedString(object["hook_event_name"]) else {
            return []
        }
        guard ["PostToolUse", "PostToolUseFailure"].contains(eventName) == false else {
            return []
        }

        var commands: [CLICommand] = []
        let source = normalizedString(object["source"])
        let permissionMode = normalizedString(object["permission_mode"])
        let threadID = normalizedString(object["session_id"])
        let turnID = normalizedString(object["turn_id"])
        let prompt = normalizedString(object["prompt"])
        let promptFingerprint = CodexInputFingerprint.fingerprint(for: prompt)
        let status = status(for: eventName, object: object)
        let transcriptPath = normalizedPathString(object["transcript_path"])
        let cwd = normalizedPathString(object["cwd"])
        let subagentID = normalizedString(object["agent_id"])
        let subagentType = normalizedString(object["agent_type"])
        let spawnMetadata = spawnMetadata(eventName: eventName, object: object)

        let event = CodexHookEvent(
            hookEventName: eventName,
            source: source,
            permissionMode: permissionMode,
            threadID: threadID,
            turnID: turnID,
            promptFingerprint: promptFingerprint,
            status: status,
            nativeSessionID: threadID,
            sessionFilePath: transcriptPath,
            cwd: cwd,
            subagentID: subagentID,
            subagentType: subagentType,
            spawnMetadata: spawnMetadata
        )
        commands.append(.sessionCodexHookEvent(sessionID: sessionID, panelID: panelID, event: event))

        return commands
    }
}

private extension CodexHookEventParser {
    static func spawnMetadata(
        eventName: String,
        object: [String: Any]
    ) -> CodexSpawnHookMetadata? {
        guard eventName == "PreToolUse",
              let toolName = normalizedString(object["tool_name"]),
              isSpawnAgentToolName(toolName),
              let toolUseID = normalizedString(object["tool_use_id"]),
              let toolInput = object["tool_input"] as? [String: Any] else {
            return nil
        }

        let taskName = normalizedSummaryText(toolInput["task_name"], limit: 80)
        let message = normalizedSummaryText(toolInput["message"], limit: 512)
        guard taskName != nil || message != nil else {
            return nil
        }
        return CodexSpawnHookMetadata(
            toolUseID: toolUseID,
            taskName: taskName,
            message: message
        )
    }

    static func isSpawnAgentToolName(_ toolName: String) -> Bool {
        switch toolName {
        case "spawn_agent",
             "collaborationspawn_agent",
             "collaboration.spawn_agent",
             "multi_agent_v1.spawn_agent":
            return true
        default:
            return false
        }
    }

    static func status(for eventName: String, object: [String: Any]) -> SessionStatus? {
        switch eventName {
        case "UserPromptSubmit":
            return SessionStatus(
                kind: .working,
                summary: "Working",
                detail: normalizedSummaryText(object["prompt"], limit: 140) ?? "Responding to your prompt"
            )

        case "PreToolUse":
            return SessionStatus(
                kind: .working,
                summary: "Working",
                detail: toolProgressDetail(from: object) ?? "Working inside Codex"
            )

        case "PermissionRequest":
            return SessionStatus(
                kind: .needsApproval,
                summary: "Needs approval",
                detail: approvalDetail(from: object) ?? "Codex is waiting for approval"
            )

        case "Stop":
            return SessionStatus(
                kind: .ready,
                summary: "Ready",
                detail: normalizedSummaryText(object["last_assistant_message"], limit: 240) ?? "Turn complete"
            )

        case "SessionStart":
            return nil

        default:
            return nil
        }
    }

    static func approvalDetail(from object: [String: Any]) -> String? {
        let input = object["tool_input"] as? [String: Any] ?? [:]
        if let description = normalizedSummaryText(input["description"], limit: 140) {
            return description
        }
        if let command = normalizedSummaryText(commandPreview(from: input), limit: 100) {
            return "Approve \(command)"
        }
        if let toolName = normalizedString(object["tool_name"]) {
            return "Approve \(displayToolName(toolName))"
        }
        return nil
    }

    static func toolProgressDetail(from object: [String: Any]) -> String? {
        guard let toolName = normalizedString(object["tool_name"]) else {
            return nil
        }
        let input = object["tool_input"] as? [String: Any] ?? [:]

        switch toolName {
        case "Bash":
            if let command = normalizedSummaryText(commandPreview(from: input), limit: 100) {
                return "Running \(command)"
            }
            return "Running a shell command"

        case "apply_patch":
            if let path = firstPathValue(in: input) {
                return "Editing \(path)"
            }
            return "Editing files"

        default:
            return "Using \(displayToolName(toolName))"
        }
    }

    static func commandPreview(from input: [String: Any]) -> String? {
        if let command = normalizedString(input["command"]) {
            return command
        }
        if let command = input["command"] as? [Any] {
            return command.compactMap(normalizedString).joined(separator: " ")
        }
        return nil
    }

    static func firstPathValue(in input: [String: Any]) -> String? {
        for key in ["file_path", "path"] {
            if let path = normalizedString(input[key]) {
                return URL(fileURLWithPath: path).lastPathComponent
            }
        }
        if let paths = input["paths"] as? [Any] {
            return paths.compactMap(normalizedString).first.map {
                URL(fileURLWithPath: $0).lastPathComponent
            }
        }
        return nil
    }

    static func displayToolName(_ toolName: String) -> String {
        switch toolName {
        case "apply_patch":
            return "file edits"
        default:
            return toolName
        }
    }

    static func decodeJSONObject(from payload: Data) throws -> [String: Any] {
        guard payload.isEmpty == false else { return [:] }
        let object = try JSONSerialization.jsonObject(with: payload)
        return object as? [String: Any] ?? [:]
    }

    static func normalizedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        return normalizeWhitespace(in: string)
    }

    static func normalizedPathString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
}
