import CoreState
import Foundation

enum CursorHookEventParser {
    static let maximumPayloadByteCount = 64 * 1024

    static func parse(
        sessionID: String,
        panelID: UUID?,
        payload: Data
    ) throws -> [CLICommand] {
        guard payload.count <= maximumPayloadByteCount else {
            throw CursorHookEventParserError.payloadTooLarge
        }

        let object = try decodeJSONObject(from: payload)
        guard let eventName = normalizedString(object["hook_event_name"]) else {
            return []
        }

        let status: SessionStatus?
        let cloudHandoff: Bool
        switch eventName {
        case "sessionStart":
            cloudHandoff = false
            status = SessionStatus(
                kind: .idle,
                summary: "Waiting",
                detail: "Cursor is ready"
            )

        case "beforeSubmitPrompt":
            if isCloudHandoffPrompt(object["prompt"]) {
                cloudHandoff = true
                status = SessionStatus(
                    kind: .working,
                    summary: "Handing off",
                    detail: "Cursor Cloud handoff requested"
                )
            } else {
                cloudHandoff = false
                status = SessionStatus(
                    kind: .working,
                    summary: "Working",
                    detail: "Responding to your prompt"
                )
            }

        case "preToolUse":
            cloudHandoff = false
            status = SessionStatus(
                kind: .working,
                summary: "Working",
                detail: toolProgressDetail(from: object) ?? "Cursor is using a tool"
            )

        case "postToolUseFailure":
            cloudHandoff = false
            status = SessionStatus(
                kind: .working,
                summary: "Working",
                detail: toolFailureDetail(from: object) ?? "A tool failed"
            )

        case "stop":
            cloudHandoff = false
            status = stopStatus(from: object)

        case "sessionEnd":
            cloudHandoff = false
            status = sessionEndStatus(from: object)

        default:
            return []
        }

        if eventName == "stop", status == nil {
            return []
        }

        return [
            .sessionCursorHookEvent(
                sessionID: sessionID,
                panelID: panelID,
                event: CursorHookEvent(
                    hookEventName: eventName,
                    conversationID: normalizedString(object["conversation_id"]),
                    generationID: normalizedString(object["generation_id"]),
                    cloudHandoff: cloudHandoff,
                    status: status
                )
            ),
        ]
    }
}

enum CursorHookEventParserError: LocalizedError, Equatable {
    case malformedPayload
    case payloadTooLarge

    var errorDescription: String? {
        switch self {
        case .malformedPayload:
            return "Cursor hook event payload is malformed."
        case .payloadTooLarge:
            return "Cursor hook event payload is too large."
        }
    }
}

private extension CursorHookEventParser {
    static func stopStatus(from object: [String: Any]) -> SessionStatus? {
        switch normalizedString(object["status"])?.lowercased() {
        case "completed":
            return SessionStatus(
                kind: .ready,
                summary: "Ready",
                detail: "Turn complete"
            )

        case "aborted":
            return SessionStatus(
                kind: .idle,
                summary: "Stopped",
                detail: "Cursor stopped the turn"
            )

        case "error":
            return SessionStatus(
                kind: .error,
                summary: "Error",
                detail: normalizedSummaryText(object["error_message"], limit: 200)
                    ?? "Cursor could not complete the turn"
            )

        default:
            return nil
        }
    }

    static func sessionEndStatus(from object: [String: Any]) -> SessionStatus? {
        guard normalizedString(object["reason"])?.lowercased() == "error" else {
            return nil
        }
        return SessionStatus(
            kind: .error,
            summary: "Error",
            detail: normalizedSummaryText(object["error_message"], limit: 200)
                ?? "Cursor session ended with an error"
        )
    }

    static func isCloudHandoffPrompt(_ value: Any?) -> Bool {
        guard let prompt = value as? String else { return false }
        return prompt.first(where: { $0.isWhitespace == false }) == "&"
    }

    static func toolProgressDetail(from object: [String: Any]) -> String? {
        guard let toolName = normalizedString(object["tool_name"]) else {
            return nil
        }
        let input = object["tool_input"] as? [String: Any] ?? [:]

        switch toolName.lowercased() {
        case "shell":
            return "Running a shell command"
        case "read":
            return firstPathValue(in: input).map { "Reading \($0)" } ?? "Reading files"
        case "write":
            return firstPathValue(in: input).map { "Editing \($0)" } ?? "Editing files"
        case "grep":
            return "Searching the workspace"
        case "delete":
            return firstPathValue(in: input).map { "Deleting \($0)" } ?? "Deleting a file"
        case "task":
            return "Starting a subagent"
        default:
            return "Using \(displayToolName(toolName))"
        }
    }

    static func toolFailureDetail(from object: [String: Any]) -> String? {
        let toolName = normalizedString(object["tool_name"])
            .map(displayToolName(_:))
            ?? "Tool"
        if object["is_interrupt"] as? Bool == true {
            return "\(toolName) was interrupted"
        }

        switch normalizedString(object["failure_type"])?.lowercased() {
        case "timeout":
            return "\(toolName) timed out"
        case "permission_denied":
            return "\(toolName) was denied"
        default:
            if let message = normalizedSummaryText(object["error_message"], limit: 160) {
                return "\(toolName) failed: \(message)"
            }
            return "\(toolName) failed"
        }
    }

    static func firstPathValue(in input: [String: Any]) -> String? {
        for key in ["file_path", "path"] {
            if let path = normalizedString(input[key]) {
                return URL(fileURLWithPath: path).lastPathComponent
            }
        }
        return nil
    }

    static func displayToolName(_ toolName: String) -> String {
        if toolName.hasPrefix("MCP:") {
            return String(toolName.dropFirst("MCP:".count))
        }
        return toolName
    }

    static func decodeJSONObject(from payload: Data) throws -> [String: Any] {
        guard payload.isEmpty == false else { return [:] }
        do {
            guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                throw CursorHookEventParserError.malformedPayload
            }
            return object
        } catch is CursorHookEventParserError {
            throw CursorHookEventParserError.malformedPayload
        } catch {
            throw CursorHookEventParserError.malformedPayload
        }
    }

    static func normalizedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let collapsed = string
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    static func normalizedSummaryText(_ value: Any?, limit: Int) -> String? {
        guard let string = normalizedString(value) else { return nil }
        guard string.count > limit else { return string }
        let endIndex = string.index(string.startIndex, offsetBy: limit - 3)
        return String(string[..<endIndex]) + "..."
    }
}
