import CoreState
import Foundation

enum GrokHookEventParser {
    // Native hooks include prompt and tool content even though only metadata is forwarded.
    static let maximumPayloadByteCount = 16 * 1024 * 1024

    static func parse(sessionID: String, panelID: UUID?, payload: Data) throws -> [CLICommand] {
        guard payload.count <= maximumPayloadByteCount else {
            throw GrokHookEventParserError.payloadTooLarge
        }
        guard !payload.isEmpty else { return [] }
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                throw GrokHookEventParserError.malformedPayload
            }
            object = decoded
        } catch {
            throw GrokHookEventParserError.malformedPayload
        }

        guard let eventName = object["hookEventName"] as? String,
              let kind = GrokHookEvent.Kind(rawValue: eventName) else { return [] }
        // Nested agents inherit the managed launch environment but cannot
        // change their parent's status or bind its native conversation.
        if let subagentType = object["subagentType"], !(subagentType is NSNull) {
            guard let string = subagentType as? String else {
                throw GrokHookEventParserError.malformedPayload
            }
            guard string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        }

        guard let nativeSessionID = try uuidString(object["sessionId"]),
              let timestampString = object["timestamp"] as? String,
              let timestamp = parseTimestamp(timestampString) else {
            throw GrokHookEventParserError.malformedPayload
        }
        let event = GrokHookEvent(
            kind: kind,
            nativeSessionID: nativeSessionID,
            promptID: try uuidString(object["promptId"]),
            timestamp: timestamp,
            notificationType: try boundedString(object["notificationType"], maximumUTF8Count: 128),
            isSubagent: false,
            sessionFilePath: try boundedString(object["transcriptPath"], maximumUTF8Count: 4096, trimWhitespace: false),
            cwd: try boundedString(object["cwd"], maximumUTF8Count: 4096, trimWhitespace: false)
        )
        return [.sessionGrokHookEvent(sessionID: sessionID, panelID: panelID, event: event)]
    }

    private static func uuidString(_ value: Any?) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let string = value as? String,
              let uuid = UUID(uuidString: string) else {
            throw GrokHookEventParserError.malformedPayload
        }
        return uuid.uuidString.lowercased()
    }

    private static func boundedString(_ value: Any?, maximumUTF8Count: Int, trimWhitespace: Bool = true) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let string = value as? String,
              string.utf8.count <= maximumUTF8Count,
              !string.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw GrokHookEventParserError.malformedPayload
        }
        let trimmed = trimWhitespace ? string.trimmingCharacters(in: .whitespacesAndNewlines) : string
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        // FormatStyle's parser accepts a valid prefix followed by arbitrary
        // text. Require a complete RFC3339 value before preserving its precision.
        guard value.utf8.count <= 64,
              value.range(
                of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})\z"#,
                options: .regularExpression
              ) != nil else { return nil }
        let normalizedValue = value.uppercased()
        guard let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(normalizedValue))
            ?? (try? Date.ISO8601FormatStyle().parse(normalizedValue)),
              date.timeIntervalSince1970.isFinite else { return nil }
        return date
    }
}

enum GrokHookEventParserError: LocalizedError, Equatable {
    case malformedPayload
    case payloadTooLarge

    var errorDescription: String? {
        switch self {
        case .malformedPayload:
            return "Grok hook event payload is malformed."
        case .payloadTooLarge:
            return "Grok hook event payload is too large."
        }
    }
}
