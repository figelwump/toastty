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
                ),
            ]

        case "PermissionRequest":
            return [
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .needsApproval,
                    summary: "Needs approval",
                    detail: approvalDetail(from: object) ?? "Claude Code is waiting for approval"
                ),
            ]

        case "PreToolUse":
            return [
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .working,
                    summary: "Working",
                    detail: toolProgressDetail(from: object) ?? "Working inside Claude Code"
                ),
            ]

        case "PostToolUse":
            return postToolUseCommands(sessionID: sessionID, panelID: panelID, from: object)

        case "PostToolUseFailure":
            return []

        case "Stop":
            var commands: [CLICommand] = []
            if object.keys.contains("background_tasks") {
                commands.append(
                    stopBackgroundActivitySyncCommand(
                        sessionID: sessionID,
                        panelID: panelID,
                        from: object
                    )
                )
            }
            commands.append(
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .ready,
                    summary: "Ready",
                    detail: normalizedSummaryText(object["last_assistant_message"]) ?? "Turn complete"
                )
            )
            return commands

        case "SubagentStop":
            guard let agentID = normalizedString(object["agent_id"]) else {
                return []
            }
            return [
                .sessionBackgroundActivity(
                    sessionID: sessionID,
                    panelID: panelID,
                    phase: .finish,
                    activityID: agentID,
                    kind: .subagent,
                    displayName: nil,
                    command: nil,
                    processID: nil
                ),
            ]

        case "Notification":
            return notificationCommands(sessionID: sessionID, panelID: panelID, from: object)

        case "SessionStart":
            return resumeRecordCommands(
                sessionID: sessionID,
                panelID: panelID,
                from: object
            )

        default:
            return []
        }
    }

    private static func resumeRecordCommands(
        sessionID: String,
        panelID: UUID?,
        from object: [String: Any]
    ) -> [CLICommand] {
        guard let panelID,
              let nativeSessionID = normalizedString(object["session_id"]),
              let sessionFilePath = normalizedPathString(object["transcript_path"]) else {
            return []
        }

        return [
            .sessionUpdateResumeRecord(
                sessionID: sessionID,
                panelID: panelID,
                agent: .claude,
                nativeSessionID: nativeSessionID,
                sessionFilePath: sessionFilePath,
                cwd: normalizedPathString(object["cwd"])
            ),
        ]
    }

    private static func postToolUseCommands(
        sessionID: String,
        panelID: UUID?,
        from object: [String: Any]
    ) -> [CLICommand] {
        guard let toolName = normalizedString(object["tool_name"]),
              ["agent", "task"].contains(toolName.lowercased()),
              let toolResponse = object["tool_response"] as? [String: Any],
              normalizedString(toolResponse["status"]) == "async_launched",
              let agentID = normalizedString(toolResponse["agentId"]) else {
            return []
        }
        let toolInput = object["tool_input"] as? [String: Any] ?? [:]
        let displayName = normalizedString(toolInput["subagent_type"]) ?? "Sub-agent"
        let command = normalizedString(toolResponse["description"])
            ?? normalizedString(toolInput["description"])

        return [
            .sessionBackgroundActivity(
                sessionID: sessionID,
                panelID: panelID,
                phase: .start,
                activityID: agentID,
                kind: .subagent,
                displayName: displayName,
                command: command,
                processID: nil
            ),
        ]
    }

    private static func stopBackgroundActivitySyncCommand(
        sessionID: String,
        panelID: UUID?,
        from object: [String: Any]
    ) -> CLICommand {
        let backgroundTasks = object["background_tasks"] as? [[String: Any]] ?? []
        var entries: [SessionBackgroundActivitySyncEntry] = []
        var pendingBackgroundTaskCount = 0

        for task in backgroundTasks {
            if normalizedString(task["type"]) == "subagent" {
                guard let id = normalizedString(task["id"]) else { continue }
                entries.append(
                    SessionBackgroundActivitySyncEntry(
                        id: id,
                        displayName: normalizedString(task["agent_type"]) ?? "Sub-agent",
                        command: normalizedString(task["description"])
                    )
                )
            } else {
                pendingBackgroundTaskCount += 1
            }
        }

        return .sessionBackgroundActivitySync(
            sessionID: sessionID,
            panelID: panelID,
            kind: .subagent,
            entries: entries,
            pendingBackgroundTaskCount: pendingBackgroundTaskCount
        )
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

    static func lastPathComponent(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}
