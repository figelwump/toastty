import CoreState
import Foundation

enum GrokHookEventPayloadDecoder {
    static func decode(_ payload: [String: AutomationJSONValue]) throws -> GrokHookEvent {
        guard let rawKind = payload.string("kind"), let kind = GrokHookEvent.Kind(rawValue: rawKind),
              let nativeID = payload.uuid("nativeSessionID") else {
            throw AutomationSocketError.invalidPayload("Grok hook kind and nativeSessionID are required")
        }
        let timestamp: Double
        switch payload["timestamp"] {
        case .double(let value): timestamp = value
        case .int(let value): timestamp = Double(value)
        default: throw AutomationSocketError.invalidPayload("Grok hook timestamp is required")
        }
        guard timestamp.isFinite, abs(timestamp) < 253_402_300_800 else {
            throw AutomationSocketError.invalidPayload("Grok hook timestamp is invalid")
        }
        let promptID: String?
        if payload["promptID"] != nil {
            guard let id = payload.uuid("promptID") else {
                throw AutomationSocketError.invalidPayload("Grok hook promptID must be a UUID")
            }
            promptID = id.uuidString.lowercased()
        } else {
            promptID = nil
        }
        guard let isSubagent = payload.bool("isSubagent") else {
            throw AutomationSocketError.invalidPayload("Grok hook isSubagent must be a boolean")
        }
        return GrokHookEvent(
            kind: kind,
            nativeSessionID: nativeID.uuidString.lowercased(),
            promptID: promptID,
            timestamp: Date(timeIntervalSince1970: timestamp),
            notificationType: try text(payload, key: "notificationType", limit: 128),
            isSubagent: isSubagent,
            sessionFilePath: try text(payload, key: "sessionFilePath", limit: 4096, trimWhitespace: false),
            cwd: try text(payload, key: "cwd", limit: 4096, trimWhitespace: false)
        )
    }

    private static func text(_ payload: [String: AutomationJSONValue], key: String, limit: Int, trimWhitespace: Bool = true) throws -> String? {
        guard payload[key] != nil else { return nil }
        guard let value = payload.string(key), value.utf8.count <= limit,
              !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw AutomationSocketError.invalidPayload("Grok hook \(key) is invalid")
        }
        let trimmed = trimWhitespace ? value.trimmingCharacters(in: .whitespacesAndNewlines) : value
        return trimmed.isEmpty ? nil : trimmed
    }
}
