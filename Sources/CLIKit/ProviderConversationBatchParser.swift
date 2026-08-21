import CoreState
import Foundation
import RemoteProtocol

/// Normalizes the versioned conversation batches emitted by managed provider
/// instrumentation. Provider scripts remain responsible for translating their
/// SDK-specific objects into this deliberately small schema.
enum ProviderConversationBatchParser {
    private static let maximumRecordCount = 256
    private static let maximumTextLength = 48 * 1024

    static func commands(
        provider: AgentKind,
        sessionID: String,
        panelID: UUID?,
        object: [String: Any]
    ) -> [CLICommand] {
        guard ProviderTranscriptSupport.isManagedProvider(provider),
              let nativeSessionID = normalizedString(object["nativeSessionID"], limit: 500),
              let snapshotID = normalizedString(object["snapshotID"], limit: 500),
              let records = object["records"] as? [[String: Any]],
              records.count <= maximumRecordCount else {
            return []
        }

        let batchDate = dateValue(object["timestamp"]) ?? Date()
        var commands: [CLICommand] = []
        if boolValue(object["reset"]) == true {
            commands.append(
                .sessionProviderConversationReset(
                    sessionID: sessionID,
                    panelID: panelID,
                    provider: provider,
                    nativeSessionID: nativeSessionID,
                    snapshotID: snapshotID,
                    at: batchDate
                )
            )
        }

        for record in records {
            guard let observation = observation(
                provider: provider,
                nativeSessionID: nativeSessionID,
                record: record,
                fallbackDate: batchDate
            ) else {
                continue
            }
            commands.append(
                .sessionProviderConversationObservation(
                    sessionID: sessionID,
                    panelID: panelID,
                    provider: provider,
                    nativeSessionID: nativeSessionID,
                    snapshotID: snapshotID,
                    observation: observation
                )
            )
        }
        return commands
    }
}

private extension ProviderConversationBatchParser {
    static func observation(
        provider: AgentKind,
        nativeSessionID: String,
        record: [String: Any],
        fallbackDate: Date
    ) -> ProviderTranscriptObservation? {
        guard let kind = normalizedString(record["kind"], limit: 80),
              let eventID = normalizedString(record["eventID"], limit: 500) else {
            return nil
        }
        let date = dateValue(record["timestamp"]) ?? fallbackDate
        let turnID = normalizedString(record["turnID"], limit: 500)
        let providerIdentity = normalizedString(record["providerIdentity"], limit: 500)
            ?? nativeSessionID
        let payload: ProviderObservationPayload

        switch kind {
        case "user_message":
            guard let text = messageText(record["text"]) else { return nil }
            payload = .transcript(
                .userMessage(
                    ConversationUserMessagePayload(
                        text: text,
                        origin: ConversationMessageOrigin(
                            rawValue: normalizedString(record["origin"], limit: 40) ?? ""
                        ) ?? .unknown
                    )
                )
            )

        case "assistant_message":
            guard let text = messageText(record["text"]) else { return nil }
            payload = .transcript(
                .assistantMessage(
                    ConversationAssistantMessagePayload(
                        text: text,
                        phase: ConversationAssistantMessagePhase(
                            rawValue: normalizedString(record["phase"], limit: 40) ?? ""
                        ) ?? .unknown
                    )
                )
            )

        case "tool_started":
            guard let callID = normalizedString(record["callID"], limit: 500),
                  let toolName = normalizedString(record["toolName"], limit: 200) else {
                return nil
            }
            payload = .transcript(
                .toolStarted(
                    ConversationToolStartedPayload(
                        callID: callID,
                        toolName: toolName,
                        detail: normalizedString(record["detail"], limit: 1_000)
                    )
                )
            )

        case "tool_finished":
            guard let callID = normalizedString(record["callID"], limit: 500) else { return nil }
            payload = .transcript(
                .toolFinished(
                    ConversationToolFinishedPayload(
                        callID: callID,
                        toolName: normalizedString(record["toolName"], limit: 200),
                        outcome: ConversationToolOutcome(
                            rawValue: normalizedString(record["outcome"], limit: 40) ?? ""
                        ) ?? .unknown,
                        detail: normalizedString(record["detail"], limit: 1_000)
                    )
                )
            )

        case "interaction_presented":
            guard let interactionKind = RemotePendingInteraction.Kind(
                rawValue: normalizedString(record["interactionKind"], limit: 80) ?? ""
            ), let prompt = messageText(record["prompt"]) else {
                return nil
            }
            payload = .interactionPresented(
                ProviderInteractionObservation(
                    kind: interactionKind,
                    providerCallID: normalizedString(record["providerCallID"], limit: 500),
                    providerApprovalID: normalizedString(record["providerApprovalID"], limit: 500),
                    prompt: prompt
                )
            )

        case "turn_started":
            payload = .turnStarted(turnID: turnID)
        case "prompt_open", "turn_completed":
            payload = .turnEnded(turnID: turnID, reason: .completed)
        case "turn_aborted":
            payload = .turnEnded(turnID: turnID, reason: .aborted)
        case "turn_failed":
            payload = .turnEnded(turnID: turnID, reason: .aborted)
        case "context_compacted":
            payload = .contextCompacted
        default:
            return nil
        }

        return ProviderTranscriptObservation(
            timestamp: date,
            turnID: turnID,
            providerIdentity: providerIdentity,
            fingerprint: "managed:\(provider.rawValue):\(eventID)",
            payload: payload,
            mayAuthorizeCurrentRuntime: boolValue(record["live"]) == true
        )
    }

    static func messageText(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        if trimmed.count <= maximumTextLength { return trimmed }
        return String(trimmed.prefix(maximumTextLength))
    }

    static func normalizedString(_ value: Any?, limit: Int) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return String(trimmed.prefix(limit))
    }

    static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    static func dateValue(_ value: Any?) -> Date? {
        if let string = value as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) { return date }
            return ISO8601DateFormatter().date(from: string)
        }
        guard let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
    }
}
