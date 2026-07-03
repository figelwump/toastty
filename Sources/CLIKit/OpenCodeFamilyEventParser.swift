import CoreState
import Foundation

enum OpenCodeFamilyEventParser {
    private static let maxPayloadBytes = 64 * 1024

    static func parse(
        source: AgentEventSource,
        sessionID: String,
        panelID: UUID?,
        payload: Data
    ) throws -> [CLICommand] {
        guard payload.count <= maxPayloadBytes else {
            throw OpenCodeFamilyEventParserError.payloadTooLarge
        }

        let object = try decodeJSONObject(from: payload)
        guard let event = normalizedEventObject(from: object),
              let eventType = normalizedString(event["type"], limit: 120) else {
            return []
        }
        let properties = event["properties"] as? [String: Any] ?? [:]

        if let commands = normalizedToasttyCommands(
            eventType: eventType,
            properties: properties,
            source: source,
            sessionID: sessionID,
            panelID: panelID
        ) {
            return commands
        }

        switch eventType {
        case "session.status":
            return statusCommands(
                sessionID: sessionID,
                panelID: panelID,
                status: properties["status"]
            )

        case "session.idle":
            return [
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .ready,
                    summary: "Ready",
                    detail: nil
                ),
            ]

        case "session.error":
            return [
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .error,
                    summary: "Error",
                    detail: errorDetail(from: properties)
                ),
            ]

        case "permission.asked", "permission.v2.asked":
            return [
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .needsApproval,
                    summary: "Needs approval",
                    detail: permissionDetail(from: properties) ?? "Agent is waiting for approval"
                ),
            ]

        case "permission.replied", "permission.v2.replied":
            return [
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .working,
                    summary: "Working",
                    detail: "Approval resolved"
                ),
            ]

        default:
            return []
        }
    }
}

enum OpenCodeFamilyEventParserError: LocalizedError, Equatable {
    case payloadTooLarge

    var errorDescription: String? {
        switch self {
        case .payloadTooLarge:
            return "OpenCode-family event payload is too large."
        }
    }
}

private extension OpenCodeFamilyEventParser {
    static func normalizedToasttyCommands(
        eventType: String,
        properties: [String: Any],
        source: AgentEventSource,
        sessionID: String,
        panelID: UUID?
    ) -> [CLICommand]? {
        switch eventType {
        case "toastty.status":
            return toasttyStatusCommands(
                sessionID: sessionID,
                panelID: panelID,
                properties: properties
            )

        case "toastty.final":
            return [
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .ready,
                    summary: normalizedString(properties["summary"], limit: 80) ?? "Ready",
                    detail: normalizedString(properties["text"], limit: 240)
                        ?? normalizedString(properties["detail"], limit: 240)
                ),
            ]

        case "toastty.native_session":
            return nativeSessionCommands(
                source: source,
                sessionID: sessionID,
                panelID: panelID,
                properties: properties
            )

        default:
            return nil
        }
    }

    static func nativeSessionCommands(
        source: AgentEventSource,
        sessionID: String,
        panelID: UUID?,
        properties: [String: Any]
    ) -> [CLICommand] {
        guard let panelID,
              let agent = agentKind(for: source),
              let nativeSessionID = normalizedString(properties["nativeSessionID"], limit: 240)
                ?? normalizedString(properties["native_session_id"], limit: 240)
                ?? normalizedString(properties["sessionID"], limit: 240)
                ?? normalizedString(properties["sessionId"], limit: 240),
              let sessionFilePath = normalizedString(properties["sessionFilePath"], limit: 4096)
                ?? normalizedString(properties["session_file_path"], limit: 4096)
                ?? normalizedString(properties["sentinelPath"], limit: 4096)
                ?? normalizedString(properties["markerPath"], limit: 4096),
              let cwd = normalizedString(properties["cwd"], limit: 4096) else {
            return []
        }

        return [
            .sessionUpdateResumeRecord(
                sessionID: sessionID,
                panelID: panelID,
                agent: agent,
                nativeSessionID: nativeSessionID,
                sessionFilePath: sessionFilePath,
                cwd: cwd
            ),
        ]
    }

    static func agentKind(for source: AgentEventSource) -> AgentKind? {
        switch source {
        case .opencodePlugin:
            return .opencode
        case .mimocodePlugin:
            return .mimocode
        default:
            return nil
        }
    }

    static func toasttyStatusCommands(
        sessionID: String,
        panelID: UUID?,
        properties: [String: Any]
    ) -> [CLICommand] {
        guard let rawKind = normalizedString(properties["kind"], limit: 80)
                ?? normalizedString(properties["status"], limit: 80),
              let kind = normalizedStatusKind(rawKind) else {
            return []
        }

        return [
            .sessionStatus(
                sessionID: sessionID,
                panelID: panelID,
                kind: kind,
                summary: normalizedString(properties["summary"], limit: 80) ?? defaultSummary(for: kind),
                detail: normalizedString(properties["detail"], limit: 240)
            ),
        ]
    }

    static func statusCommands(
        sessionID: String,
        panelID: UUID?,
        status: Any?
    ) -> [CLICommand] {
        guard let status = status as? [String: Any],
              let type = normalizedString(status["type"], limit: 80) else {
            return []
        }

        switch type {
        case "busy":
            return [
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .working,
                    summary: "Working",
                    detail: normalizedString(status["message"], limit: 160)
                ),
            ]

        case "retry":
            return [
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .working,
                    summary: "Retrying",
                    detail: normalizedString(status["message"], limit: 160)
                ),
            ]

        case "idle":
            return [
                .sessionStatus(
                    sessionID: sessionID,
                    panelID: panelID,
                    kind: .ready,
                    summary: "Ready",
                    detail: nil
                ),
            ]

        default:
            return []
        }
    }

    static func normalizedStatusKind(_ value: String) -> SessionStatusKind? {
        switch value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased() {
        case "idle":
            return .idle
        case "working", "busy", "running":
            return .working
        case "needs_approval", "needsapproval", "approval", "awaiting_approval":
            return .needsApproval
        case "ready", "complete", "completed", "done":
            return .ready
        case "error", "failed", "failure":
            return .error
        default:
            return nil
        }
    }

    static func defaultSummary(for kind: SessionStatusKind) -> String {
        switch kind {
        case .idle:
            return "Waiting"
        case .working:
            return "Working"
        case .needsApproval:
            return "Needs approval"
        case .ready:
            return "Ready"
        case .error:
            return "Error"
        }
    }

    static func normalizedEventObject(from object: [String: Any]) -> [String: Any]? {
        if let nested = object["event"] as? [String: Any] {
            return nested
        }
        return object
    }

    static func permissionDetail(from properties: [String: Any]) -> String? {
        let metadata = properties["metadata"] as? [String: Any] ?? [:]

        if let description = normalizedString(metadata["description"], limit: 160) {
            return description
        }
        if let command = commandPreview(from: metadata) {
            return "Approve \(command)"
        }
        if let tool = normalizedString(metadata["tool"], limit: 80) {
            return "Approve \(displayToolName(tool))"
        }
        if let tools = metadata["tools"] as? [Any],
           tools.isEmpty == false {
            if tools.count == 1,
               let tool = firstToolName(from: tools[0]) {
                return "Approve \(displayToolName(tool))"
            }
            return "Approve \(tools.count) tools"
        }
        if let permission = normalizedString(properties["permission"], limit: 80) {
            if let pattern = firstPattern(from: properties["patterns"]) {
                return "Approve \(permission) \(pattern)"
            }
            return "Approve \(permission)"
        }

        return nil
    }

    static func commandPreview(from metadata: [String: Any]) -> String? {
        if let command = normalizedString(metadata["command"], limit: 120) {
            return command
        }
        if let input = metadata["input"] as? [String: Any],
           let command = normalizedString(input["command"], limit: 120) {
            return command
        }
        return nil
    }

    static func firstToolName(from value: Any) -> String? {
        if let string = normalizedString(value, limit: 80) {
            return string
        }
        if let object = value as? [String: Any] {
            return normalizedString(object["name"], limit: 80)
                ?? normalizedString(object["tool"], limit: 80)
                ?? normalizedString(object["id"], limit: 80)
        }
        return nil
    }

    static func firstPattern(from value: Any?) -> String? {
        guard let values = value as? [Any] else {
            return nil
        }
        for value in values {
            if let pattern = normalizedString(value, limit: 80) {
                return pattern
            }
        }
        return nil
    }

    static func errorDetail(from properties: [String: Any]) -> String? {
        if let error = properties["error"] as? [String: Any] {
            return firstErrorMessage(in: error)
        }
        return normalizedString(properties["message"], limit: 240)
    }

    static func firstErrorMessage(in object: [String: Any]) -> String? {
        if let message = normalizedString(object["message"], limit: 240) {
            return message
        }
        if let data = object["data"] as? [String: Any],
           let message = firstErrorMessage(in: data) {
            return message
        }
        if let cause = object["cause"] as? [String: Any],
           let message = firstErrorMessage(in: cause) {
            return message
        }
        if let name = normalizedString(object["name"], limit: 240) {
            return name
        }
        return nil
    }

    static func decodeJSONObject(from payload: Data) throws -> [String: Any] {
        guard payload.isEmpty == false else { return [:] }
        let object = try JSONSerialization.jsonObject(with: payload)
        return object as? [String: Any] ?? [:]
    }

    static func normalizedString(_ value: Any?, limit: Int) -> String? {
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

    static func displayToolName(_ toolName: String) -> String {
        toolName
            .split(separator: "_")
            .flatMap { $0.split(separator: "-") }
            .map { component in
                component.prefix(1).uppercased() + component.dropFirst()
            }
            .joined(separator: " ")
    }
}
