import CoreState
import Foundation
import RemoteProtocol

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
            var commands: [CLICommand] = [
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .working,
                    summary: "Working",
                    detail: submittedPromptDetail(from: object) ?? "Responding to your prompt"
                ),
            ]
            if let command = lifecycleObservationCommand(
                sessionID: sessionID,
                panelID: panelID,
                object: object,
                eventID: "turn-start:\(normalizedString(object["turn_id"]) ?? UUID().uuidString)",
                payload: .turnStarted(turnID: normalizedString(object["turn_id"]))
            ) {
                commands.append(command)
            }
            return commands

        case "PermissionRequest":
            let detail = approvalDetail(from: object) ?? "Claude Code is waiting for approval"
            let statusCommand: CLICommand
            if let agentID = normalizedString(object["agent_id"]) {
                statusCommand = .sessionClaudeSubagentEvent(
                    sessionID: sessionID, panelID: panelID,
                    event: ClaudeSubagentEvent(
                        phase: .permission, agentID: agentID,
                        toolUseID: normalizedString(object["tool_use_id"]),
                        detail: detail
                    )
                )
            } else {
                statusCommand = .sessionStatus(
                    sessionID: sessionID, panelID: panelID,
                    kind: .needsApproval, summary: "Needs approval", detail: detail
                )
            }
            var commands = [statusCommand]
            let callID = normalizedString(object["tool_use_id"])
            if let command = lifecycleObservationCommand(
                sessionID: sessionID,
                panelID: panelID,
                object: object,
                eventID: "interaction:\(callID ?? UUID().uuidString)",
                payload: .interactionPresented(
                    ProviderInteractionObservation(
                        kind: .permission,
                        providerCallID: callID,
                        providerApprovalID: nil,
                        prompt: detail
                    )
                )
            ) {
                commands.append(command)
            }
            return commands

        case "PreToolUse":
            if let agentID = normalizedString(object["agent_id"]) {
                return [.sessionClaudeSubagentEvent(
                    sessionID: sessionID, panelID: panelID,
                    event: ClaudeSubagentEvent(
                        phase: .toolUse, agentID: agentID,
                        toolUseID: normalizedString(object["tool_use_id"]),
                        detail: toolProgressDetail(from: object) ?? "Working inside Claude Code"
                    )
                )]
            }
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
            var commands: [CLICommand] = []
            if let agentID = normalizedString(object["agent_id"]) {
                commands.append(.sessionClaudeSubagentEvent(
                    sessionID: sessionID, panelID: panelID,
                    event: ClaudeSubagentEvent(
                        phase: .toolCompleted, agentID: agentID,
                        toolUseID: normalizedString(object["tool_use_id"])
                    )
                ))
            }
            return commands + postToolUseCommands(sessionID: sessionID, panelID: panelID, from: object)

        case "PostToolUseFailure":
            guard let agentID = normalizedString(object["agent_id"]) else { return [] }
            return [.sessionClaudeSubagentEvent(
                sessionID: sessionID, panelID: panelID,
                event: ClaudeSubagentEvent(
                    phase: .toolCompleted, agentID: agentID,
                    toolUseID: normalizedString(object["tool_use_id"])
                )
            )]

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
            if object["stop_hook_active"] as? Bool != true,
               let command = lifecycleObservationCommand(
                sessionID: sessionID,
                panelID: panelID,
                object: object,
                eventID: "prompt-open:\(normalizedString(object["turn_id"]) ?? UUID().uuidString)",
                payload: .turnEnded(
                    turnID: normalizedString(object["turn_id"]),
                    reason: .completed
                )
               ) {
                commands.append(command)
            }
            return commands

        case "SubagentStart":
            guard let agentID = normalizedString(object["agent_id"]) else { return [] }
            // Workflow children retain their existing one-shot lifecycle. Only
            // a registered teammate can reopen on a later SubagentStart.
            guard normalizedString(object["agent_type"])?.lowercased() == "workflow-subagent" else {
                return [.sessionClaudeSubagentEvent(
                    sessionID: sessionID, panelID: panelID,
                    event: ClaudeSubagentEvent(phase: .started, agentID: agentID)
                )]
            }
            return [
                .sessionBackgroundActivity(
                    sessionID: sessionID,
                    panelID: panelID,
                    phase: .start,
                    activityID: agentID,
                    kind: .subagent,
                    displayName: nil,
                    command: nil,
                    processID: nil,
                    preserveWhenUnlisted: true,
                    executionProfile: nil
                ),
            ]

        case "SubagentStop", "TeammateIdle":
            guard let agentID = normalizedString(object["agent_id"]) else { return [] }
            return [.sessionClaudeSubagentEvent(
                sessionID: sessionID, panelID: panelID,
                event: ClaudeSubagentEvent(phase: .finished, agentID: agentID)
            )]

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
            .sessionProviderConversationReset(
                sessionID: sessionID,
                panelID: panelID,
                provider: .claude,
                nativeSessionID: nativeSessionID,
                snapshotID: "claude:\(nativeSessionID)",
                at: Date()
            ),
        ]
    }

    private static func lifecycleObservationCommand(
        sessionID: String,
        panelID: UUID?,
        object: [String: Any],
        eventID: String,
        payload: ProviderObservationPayload
    ) -> CLICommand? {
        // Claude's lifecycle hook contract carries `session_id`. Without that
        // exact provider identity the status update remains useful, but the
        // event must not participate in remote send authorization.
        guard let nativeSessionID = normalizedString(object["session_id"]) else { return nil }
        return .sessionProviderConversationObservation(
            sessionID: sessionID,
            panelID: panelID,
            provider: .claude,
            nativeSessionID: nativeSessionID,
            snapshotID: "claude:\(nativeSessionID)",
            observation: ProviderTranscriptObservation(
                timestamp: Date(),
                turnID: normalizedString(object["turn_id"]),
                providerIdentity: nativeSessionID,
                fingerprint: "managed:claude:\(eventID)",
                payload: payload,
                mayAuthorizeCurrentRuntime: true
            )
        )
    }

    private static func postToolUseCommands(
        sessionID: String,
        panelID: UUID?,
        from object: [String: Any]
    ) -> [CLICommand] {
        guard let toolName = normalizedString(object["tool_name"]),
              ["agent", "task"].contains(toolName.lowercased()),
              let toolResponse = object["tool_response"] as? [String: Any],
              let agentID = normalizedString(toolResponse["agentId"]) ?? normalizedString(toolResponse["agent_id"]) else {
            return []
        }
        let toolInput = object["tool_input"] as? [String: Any] ?? [:]
        if normalizedString(toolResponse["status"]) == "teammate_spawned" {
            return [.sessionClaudeSubagentEvent(
                sessionID: sessionID, panelID: panelID,
                event: ClaudeSubagentEvent(
                    phase: .spawned, agentID: agentID,
                    displayName: normalizedString(toolResponse["name"]) ?? normalizedString(toolInput["name"]),
                    command: normalizedString(toolInput["description"]),
                    executionProfile: SessionAgentExecutionProfile(
                        modelIdentifier: normalizedString(toolResponse["resolvedModel"])
                            ?? normalizedString(toolResponse["resolved_model"])
                    )
                )
            )]
        }
        guard normalizedString(toolResponse["status"]) == "async_launched" else { return [] }
        let displayName = normalizedString(toolInput["subagent_type"]) ?? "Sub-agent"
        let command = normalizedString(toolResponse["description"])
            ?? normalizedString(toolInput["description"])
        let modelIdentifier = normalizedString(toolResponse["resolvedModel"])
            ?? normalizedString(toolResponse["resolved_model"])
        let executionProfile = SessionAgentExecutionProfile(
            modelIdentifier: modelIdentifier
        )

        return [
            .sessionBackgroundActivity(
                sessionID: sessionID,
                panelID: panelID,
                phase: .start,
                activityID: agentID,
                kind: .subagent,
                displayName: displayName,
                command: command,
                processID: nil,
                preserveWhenUnlisted: false,
                executionProfile: executionProfile.isEmpty ? nil : executionProfile
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
        var preserveUnlistedActivities = false

        for task in backgroundTasks {
            let taskType = normalizedString(task["type"])
            if taskType == "monitor" {
                // Claude Code 2.1.239 reports an Artifact watch as a running
                // monitor after the root session has returned to its prompt.
                continue
            }
            if taskType == "teammate" {
                // This is a lifetime record, including idle teammates. Active
                // work is tracked by agent ID through the child hooks instead.
                if normalizedString(task["status"]) == "running" {
                    preserveUnlistedActivities = true
                }
                continue
            }
            if taskType == "subagent" {
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
                if taskType == "workflow" {
                    // Workflow children are reported through SubagentStart/Stop rather
                    // than as individual entries in Claude's root Stop snapshot.
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

    private static func notificationCommands(
        sessionID: String,
        panelID: UUID?,
        from object: [String: Any]
    ) -> [CLICommand] {
        if let agentID = normalizedString(object["agent_id"]) {
            let notificationType = normalizedString(object["notification_type"])
            guard notificationType == "permission_prompt" || notificationType == "elicitation_dialog" else {
                // A child's idle reminder must not replace the main turn's
                // status. Its lifecycle hooks own its activity instead.
                return []
            }
            let needsInput = notificationType == "elicitation_dialog"
            return [.sessionClaudeSubagentEvent(
                sessionID: sessionID, panelID: panelID,
                event: ClaudeSubagentEvent(
                    phase: .permission, agentID: agentID,
                    toolUseID: normalizedString(object["tool_use_id"]),
                    summary: needsInput ? "Needs input" : "Needs approval",
                    detail: normalizedSummaryText(object["message"])
                        ?? (needsInput ? "Claude Code is waiting for input" : "Claude Code is waiting for approval")
                )
            )]
        }
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
