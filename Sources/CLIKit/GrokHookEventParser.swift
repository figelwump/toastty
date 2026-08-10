import Foundation

enum GrokHookEventParser {
    static func parse(
        sessionID: String,
        panelID: UUID?,
        payload: Data
    ) throws -> [CLICommand] {
        let object = try decodeJSONObject(from: payload)
        guard let eventName = normalizedEventName(field(object, "hookEventName", "hook_event_name")) else {
            return []
        }

        switch eventName {
        case "user_prompt_submit":
            return [
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .working,
                    summary: "Working",
                    detail: submittedPromptDetail(from: object) ?? "Responding to your prompt"
                ),
            ]

        case "pre_tool_use":
            return [
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .working,
                    summary: "Working",
                    detail: toolProgressDetail(from: object) ?? "Working inside Grok"
                ),
            ]

        case "post_tool_use", "post_tool_use_failure":
            return []

        case "stop":
            return stopCommands(sessionID: sessionID, panelID: panelID, from: object)

        case "stop_failure":
            return [
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .error,
                    summary: "Error",
                    detail: normalizedSummaryText(field(object, "lastAssistantMessage", "last_assistant_message"))
                        ?? normalizedSummaryText(field(object, "message", "message"))
                        ?? "Grok stopped with an error"
                ),
            ]

        case "notification":
            return notificationCommands(sessionID: sessionID, panelID: panelID, from: object)

        case "subagent_start":
            guard let activityID = normalizedString(field(object, "subagentId", "subagent_id")) else {
                return []
            }
            return [
                .sessionBackgroundActivity(
                    sessionID: sessionID,
                    panelID: panelID,
                    phase: .start,
                    activityID: activityID,
                    kind: .subagent,
                    displayName: normalizedString(field(object, "subagentType", "subagent_type")),
                    command: normalizedString(field(object, "description", "description")),
                    processID: nil,
                    preserveWhenUnlisted: false
                ),
            ]

        case "subagent_stop":
            guard let activityID = normalizedString(field(object, "subagentId", "subagent_id")) else {
                return []
            }
            return [
                .sessionBackgroundActivity(
                    sessionID: sessionID,
                    panelID: panelID,
                    phase: .finish,
                    activityID: activityID,
                    kind: .subagent,
                    displayName: nil,
                    command: nil,
                    processID: nil,
                    preserveWhenUnlisted: false
                ),
            ]

        case "session_start":
            return resumeRecordCommands(
                sessionID: sessionID,
                panelID: panelID,
                from: object
            )

        case "permission_denied", "session_end":
            return []

        default:
            return []
        }
    }

    /// Percent-encodes an absolute cwd so `/` becomes `%2F`, matching Grok's
    /// `$GROK_HOME/sessions/<encoded-cwd>/<sessionId>/` layout.
    static func encodedSessionCwdFolderName(_ cwd: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return cwd.addingPercentEncoding(withAllowedCharacters: allowed) ?? cwd
    }

    /// Resolves the Grok home directory, honoring `GROK_HOME` when set.
    static func resolveGrokHomeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let grokHomePath = environment["GROK_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           grokHomePath.isEmpty == false {
            return URL(
                fileURLWithPath: (grokHomePath as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)
    }

    /// Derives `summary.json` under `$GROK_HOME/sessions/...` (not always `~/.grok`).
    static func derivedSessionFilePath(
        sessionId: String,
        cwd: String,
        grokHome: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String {
        let resolvedGrokHome = grokHome ?? resolveGrokHomeURL(
            environment: environment,
            fileManager: fileManager
        )
        return resolvedGrokHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(encodedSessionCwdFolderName(cwd), isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("summary.json", isDirectory: false)
            .path
    }
}

private extension GrokHookEventParser {
    static func resumeRecordCommands(
        sessionID: String,
        panelID: UUID?,
        from object: [String: Any]
    ) -> [CLICommand] {
        guard let panelID,
              let nativeSessionID = normalizedString(field(object, "sessionId", "session_id")) else {
            return []
        }

        let cwd = normalizedPathString(field(object, "cwd", "cwd"))
            ?? normalizedPathString(field(object, "workspaceRoot", "workspace_root"))

        let sessionFilePath: String?
        if let transcriptPath = normalizedPathString(field(object, "transcriptPath", "transcript_path")) {
            sessionFilePath = transcriptPath
        } else if let cwd {
            // Prefer GROK_HOME from the hook/CLI process env so custom homes match launch.
            sessionFilePath = derivedSessionFilePath(sessionId: nativeSessionID, cwd: cwd)
        } else {
            sessionFilePath = nil
        }

        guard let sessionFilePath else {
            return []
        }

        return [
            .sessionUpdateResumeRecord(
                sessionID: sessionID,
                panelID: panelID,
                agent: .grok,
                nativeSessionID: nativeSessionID,
                sessionFilePath: sessionFilePath,
                cwd: cwd
            ),
        ]
    }

    static func stopCommands(
        sessionID: String,
        panelID: UUID?,
        from object: [String: Any]
    ) -> [CLICommand] {
        let reason = normalizedString(field(object, "reason", "reason"))?.lowercased()
        // Only genuine turn completion maps to Ready. Shutdown / channel_closed
        // are session teardown observes and must not flip status to Ready.
        guard reason == "end_turn" else {
            return []
        }

        var commands: [CLICommand] = []
        if object.keys.contains("backgroundTasks") || object.keys.contains("background_tasks") {
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
                detail: normalizedSummaryText(field(object, "lastAssistantMessage", "last_assistant_message"))
                    ?? "Turn complete"
            )
        )
        return commands
    }

    static func stopBackgroundActivitySyncCommand(
        sessionID: String,
        panelID: UUID?,
        from object: [String: Any]
    ) -> CLICommand {
        let backgroundTasks = (field(object, "backgroundTasks", "background_tasks") as? [[String: Any]]) ?? []
        var entries: [SessionBackgroundActivitySyncEntry] = []
        var pendingBackgroundTaskCount = 0
        var preserveUnlistedActivities = false

        for task in backgroundTasks {
            let taskType = normalizedString(field(task, "type", "type"))
            if taskType == "subagent" {
                guard let id = normalizedString(field(task, "id", "id")) else { continue }
                entries.append(
                    SessionBackgroundActivitySyncEntry(
                        id: id,
                        displayName: normalizedString(field(task, "agentType", "agent_type")) ?? "Sub-agent",
                        command: normalizedString(field(task, "description", "description"))
                    )
                )
            } else {
                pendingBackgroundTaskCount += 1
                if taskType == "workflow" {
                    preserveUnlistedActivities = true
                }
            }
        }

        return .sessionBackgroundActivitySync(
            sessionID: sessionID,
            panelID: panelID,
            kind: .subagent,
            entries: entries,
            pendingBackgroundTaskCount: pendingBackgroundTaskCount,
            preserveUnlistedActivities: preserveUnlistedActivities
        )
    }

    static func notificationCommands(
        sessionID: String,
        panelID: UUID?,
        from object: [String: Any]
    ) -> [CLICommand] {
        switch normalizedString(field(object, "notificationType", "notification_type")) {
        case "permission_prompt":
            return [
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .needsApproval,
                    summary: "Needs approval",
                    detail: normalizedSummaryText(field(object, "message", "message"))
                        ?? "Grok is waiting for approval"
                ),
            ]

        case "task_complete":
            // Background work finished; not a Ready / Needs approval signal.
            return []

        default:
            return []
        }
    }

    static func submittedPromptDetail(from object: [String: Any]) -> String? {
        guard let raw = normalizedString(field(object, "prompt", "prompt")) else {
            return nil
        }
        let stripped = stripUserQueryWrapper(raw)
        return normalizedSummaryText(stripped, limit: 140)
    }

    static func stripUserQueryWrapper(_ prompt: String) -> String {
        let open = "<user_query>"
        let close = "</user_query>"
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(open), trimmed.hasSuffix(close), trimmed.count >= open.count + close.count else {
            return prompt
        }
        let start = trimmed.index(trimmed.startIndex, offsetBy: open.count)
        let end = trimmed.index(trimmed.endIndex, offsetBy: -close.count)
        let inner = String(trimmed[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? prompt : inner
    }

    static func toolProgressDetail(from object: [String: Any]) -> String? {
        toolDescription(from: object)
    }

    static func toolDescription(from object: [String: Any]) -> String? {
        guard let toolName = normalizedString(field(object, "toolName", "tool_name")) else {
            return nil
        }
        let input = (field(object, "toolInput", "tool_input") as? [String: Any]) ?? [:]

        switch toolName.lowercased() {
        case "write", "edit", "multiedit":
            if let path = firstPathValue(in: input) {
                return "Editing \(path)"
            }
            return "Editing files"

        case "read", "read_file":
            if let path = firstPathValue(in: input) {
                return "Reading \(path)"
            }
            return "Reading files"

        case "glob", "grep":
            return "Searching the workspace"

        case "bash", "run_terminal_command":
            if let command = normalizedSummaryText(field(input, "command", "command"), limit: 100) {
                return "Running \(command)"
            }
            return "Running a shell command"

        default:
            return "Using \(toolName)"
        }
    }

    static func firstPathValue(in input: [String: Any]) -> String? {
        for key in ["target_file", "file_path", "path", "filePath", "targetFile"] {
            if let path = normalizedString(input[key]) {
                return lastPathComponent(path)
            }
        }
        if let paths = input["paths"] as? [String] {
            return paths.first.map(lastPathComponent(_:))
        }
        return nil
    }
}

private extension GrokHookEventParser {
    static func decodeJSONObject(from payload: Data) throws -> [String: Any] {
        guard payload.isEmpty == false else { return [:] }
        let object = try JSONSerialization.jsonObject(with: payload)
        return object as? [String: Any] ?? [:]
    }

    /// Prefer camelCase (Grok wire), fall back to snake_case.
    static func field(_ object: [String: Any], _ camelCase: String, _ snakeCase: String) -> Any? {
        if let value = object[camelCase] {
            return value
        }
        if camelCase != snakeCase, let value = object[snakeCase] {
            return value
        }
        return nil
    }

    static func normalizedEventName(_ value: Any?) -> String? {
        guard let raw = normalizedString(value) else { return nil }
        if raw.contains("_") || raw == raw.lowercased() {
            return raw.lowercased()
        }
        return pascalCaseToSnakeCase(raw)
    }

    static func pascalCaseToSnakeCase(_ value: String) -> String {
        var result = ""
        for (index, character) in value.enumerated() {
            if character.isUppercase, index > 0 {
                result.append("_")
            }
            result.append(contentsOf: character.lowercased())
        }
        return result
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
        let string: String?
        if let asString = value as? String {
            string = normalizeWhitespace(in: asString)
        } else {
            string = normalizedString(value)
        }
        guard let string else { return nil }
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
