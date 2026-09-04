import CoreState
import Foundation

enum CursorHookEventPayloadDecoder {
    private static let maximumIdentifierUTF8Count = 512
    private static let maximumStatusSummaryCharacterCount = 80
    private static let maximumStatusDetailCharacterCount = 240

    static func decode(
        _ payload: [String: AutomationJSONValue]
    ) throws -> CursorHookEvent {
        guard let hookEventName = normalizedOptionalText(payload.string("hookEventName")) else {
            throw AutomationSocketError.invalidPayload("hookEventName is required")
        }

        let status: SessionStatus?
        if payload["kind"] != nil || payload["summary"] != nil || payload["detail"] != nil {
            guard let kindRaw = payload.string("kind"),
                  let kind = SessionStatusKind(rawValue: kindRaw) else {
                throw AutomationSocketError.invalidPayload(
                    "kind must be one of: idle, working, needs_approval, ready, error"
                )
            }
            guard let summary = normalizedStatusText(
                payload.string("summary"),
                limit: maximumStatusSummaryCharacterCount
            ) else {
                throw AutomationSocketError.invalidPayload("summary is required when kind is present")
            }
            status = SessionStatus(
                kind: kind,
                summary: summary,
                detail: normalizedStatusText(
                    payload.string("detail"),
                    limit: maximumStatusDetailCharacterCount
                )
            )
        } else {
            status = nil
        }

        let cloudHandoff: Bool
        if payload["cloudHandoff"] != nil {
            guard let value = payload.bool("cloudHandoff") else {
                throw AutomationSocketError.invalidPayload("cloudHandoff must be a boolean")
            }
            cloudHandoff = value
        } else {
            cloudHandoff = false
        }

        return CursorHookEvent(
            hookEventName: hookEventName,
            conversationID: try normalizedIdentifier(
                payload.string("conversationID"),
                fieldName: "conversationID"
            ),
            generationID: try normalizedIdentifier(
                payload.string("generationID"),
                fieldName: "generationID"
            ),
            cloudHandoff: cloudHandoff,
            status: status
        )
    }

    private static func normalizedIdentifier(
        _ value: String?,
        fieldName: String
    ) throws -> String? {
        guard let value = normalizedOptionalText(value) else { return nil }
        guard value.utf8.count <= maximumIdentifierUTF8Count else {
            throw AutomationSocketError.invalidPayload(
                "\(fieldName) exceeds \(maximumIdentifierUTF8Count) UTF-8 bytes"
            )
        }
        return value
    }

    private static func normalizedOptionalText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedStatusText(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let withoutControls = value
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
        let collapsed = withoutControls
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        guard collapsed.isEmpty == false else { return nil }
        guard collapsed.count > limit else { return collapsed }
        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: limit - 3)
        return String(collapsed[..<endIndex]) + "..."
    }
}
