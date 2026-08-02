import CoreState
import Foundation

enum CodexHookEventPayloadDecoder {
    static func decode(
        _ payload: [String: AutomationJSONValue]
    ) throws -> CodexHookEvent {
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
            guard let summary = normalizedOptionalText(payload.string("summary")) else {
                throw AutomationSocketError.invalidPayload("summary is required when kind is present")
            }
            status = SessionStatus(
                kind: kind,
                summary: summary,
                detail: normalizedOptionalText(payload.string("detail"))
            )
        } else {
            status = nil
        }

        let spawnToolUseID = normalizedOptionalText(payload.string("spawnToolUseID"))
        let spawnTaskName = normalizedOptionalText(payload.string("spawnTaskName"), limit: 80)
        let spawnMessage = normalizedOptionalText(payload.string("spawnMessage"), limit: 512)
        if spawnToolUseID == nil,
           spawnTaskName != nil || spawnMessage != nil {
            throw AutomationSocketError.invalidPayload(
                "spawnToolUseID is required when spawn metadata is present"
            )
        }
        let spawnMetadata = spawnToolUseID.map {
            CodexSpawnHookMetadata(
                toolUseID: $0,
                taskName: spawnTaskName,
                message: spawnMessage
            )
        }

        return CodexHookEvent(
            hookEventName: hookEventName,
            source: normalizedOptionalText(payload.string("source")),
            permissionMode: normalizedOptionalText(payload.string("permissionMode")),
            toolUseID: normalizedOptionalText(payload.string("toolUseID")),
            callID: normalizedOptionalText(payload.string("callID")),
            approvalID: normalizedOptionalText(payload.string("approvalID")),
            threadID: normalizedOptionalText(payload.string("threadID")),
            turnID: normalizedOptionalText(payload.string("turnID")),
            promptFingerprint: normalizedOptionalText(payload.string("promptFingerprint")),
            status: status,
            nativeSessionID: normalizedOptionalText(payload.string("nativeSessionID")),
            sessionFilePath: normalizedOptionalText(payload.string("sessionFilePath")),
            cwd: normalizedOptionalText(payload.string("cwd")),
            subagentID: normalizedOptionalText(payload.string("subagentID")),
            subagentType: normalizedOptionalText(payload.string("subagentType")),
            spawnMetadata: spawnMetadata
        )
    }

    private static func normalizedOptionalText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedOptionalText(_ value: String?, limit: Int) -> String? {
        normalizedOptionalText(value).map { String($0.prefix(limit)) }
    }
}
