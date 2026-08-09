import Foundation
import CryptoKit

/// Pure line-oriented parser from Codex rollout JSONL to normalized
/// `ProviderTranscriptObservation`s.
///
/// Sourcing decisions (from auditing real rollout files):
/// - User turns come from clean event records: legacy
///   `event_msg`/`user_message` records and modern
///   `event_msg`/`item_completed` records whose item is a `UserMessage`.
///   `response_item` user messages are skipped because they interleave actual
///   input with injected instruction and environment-context blocks.
/// - Assistant turns come from `response_item`/`message` with role
///   `assistant` — they carry stable `msg_…` IDs and a phase, unlike
///   `event_msg`/`agent_message`.
/// - `compacted` records are skipped entirely; their `replacement_history`
///   replays earlier messages and would otherwise duplicate the transcript.
/// - Records the projection does not need (reasoning, token counts, world
///   state, huge `session_meta` tool schemas) are skipped without error.
///
/// Malformed lines are counted and skipped; they never throw and never corrupt
/// later parsing. The parser is a value type: checkpointing it alongside a file
/// cursor (as `CodexSessionLogWatcher` does with its parser state) preserves
/// fingerprint stability across watcher restarts.
public struct CodexRolloutTranscriptParser: Sendable {
    public private(set) var malformedLineCount: Int = 0
    private var currentTurnID: String?
    /// Occurrence counters keyed by content hash, so identical un-identified
    /// records (for example the user typing "yes" twice) fingerprint uniquely
    /// by position while replayed bytes fingerprint identically.
    private var occurrenceCounters: [String: Int] = [:]

    public init() {}

    public mutating func parseLine(_ line: String) -> [ProviderTranscriptObservation] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }
        guard let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let recordType = object["type"] as? String,
              let timestamp = Self.parseTimestamp(object["timestamp"]) else {
            malformedLineCount += 1
            return []
        }

        switch recordType {
        case "session_meta":
            return parseSessionMeta(object, timestamp: timestamp)
        case "turn_context":
            if let payload = object["payload"] as? [String: Any],
               let turnID = Self.nonEmptyString(payload["turn_id"]) {
                currentTurnID = turnID
            }
            return []
        case "response_item":
            return parseResponseItem(object, timestamp: timestamp)
        case "event_msg":
            return parseEventMessage(object, timestamp: timestamp)
        case "compacted":
            return [makeObservation(
                timestamp: timestamp,
                fingerprint: fingerprintWithOccurrence("compacted"),
                payload: .contextCompacted
            )]
        default:
            return []
        }
    }

    /// Convenience for fixtures and rebuild paths: parse a whole file's
    /// contents from the beginning.
    public static func parseContents(_ contents: String) -> (observations: [ProviderTranscriptObservation], malformedLineCount: Int) {
        var parser = CodexRolloutTranscriptParser()
        var observations: [ProviderTranscriptObservation] = []
        contents.enumerateLines { line, _ in
            observations.append(contentsOf: parser.parseLine(line))
        }
        return (observations, parser.malformedLineCount)
    }
}

private extension CodexRolloutTranscriptParser {
    mutating func parseSessionMeta(_ object: [String: Any], timestamp: Date) -> [ProviderTranscriptObservation] {
        guard let payload = object["payload"] as? [String: Any],
              let sessionID = Self.nonEmptyString(payload["id"]) ?? Self.nonEmptyString(payload["session_id"]) else {
            malformedLineCount += 1
            return []
        }
        // Subagent rollout files carry agent_role/parent_thread_id; the root
        // projection must not ingest them as root session identity.
        if Self.nonEmptyString(payload["agent_role"]) != nil {
            return []
        }
        return [makeObservation(
            timestamp: timestamp,
            providerIdentity: sessionID,
            fingerprint: fingerprintWithOccurrence("session_meta:\(sessionID)"),
            payload: .providerSessionObserved(providerSessionID: sessionID)
        )]
    }

    mutating func parseResponseItem(_ object: [String: Any], timestamp: Date) -> [ProviderTranscriptObservation] {
        guard let payload = object["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String else {
            return []
        }
        let turnID = Self.passthroughTurnID(payload) ?? currentTurnID

        switch payloadType {
        case "message":
            guard Self.nonEmptyString(payload["role"]) == "assistant" else { return [] }
            let text = Self.joinedContentText(payload["content"])
            guard text.isEmpty == false else { return [] }
            let phase = Self.assistantPhase(payload["phase"])
            let messageID = Self.nonEmptyString(payload["id"])
            let fingerprint: String
            if let messageID {
                fingerprint = "msg:\(messageID)"
            } else {
                fingerprint = fingerprintWithOccurrence("assistant:\(turnID ?? ""):\(Self.contentHash(text))")
            }
            return [makeObservation(
                timestamp: timestamp,
                turnID: turnID,
                providerIdentity: messageID,
                fingerprint: fingerprint,
                payload: .transcript(.assistantMessage(
                    ConversationAssistantMessagePayload(text: text, phase: phase)
                ))
            )]

        case "function_call", "custom_tool_call":
            guard let callID = Self.nonEmptyString(payload["call_id"]),
                  let name = Self.nonEmptyString(payload["name"]) else {
                return []
            }
            let detail = Self.toolArgumentsPreview(payload["arguments"] ?? payload["input"])
            return [makeObservation(
                timestamp: timestamp,
                turnID: turnID,
                providerIdentity: callID,
                fingerprint: "call:\(callID)",
                payload: .transcript(.toolStarted(
                    ConversationToolStartedPayload(callID: callID, toolName: name, detail: detail)
                ))
            )]

        case "function_call_output", "custom_tool_call_output":
            guard let callID = Self.nonEmptyString(payload["call_id"]) else { return [] }
            let outputText = Self.outputText(payload["output"])
            return [makeObservation(
                timestamp: timestamp,
                turnID: turnID,
                providerIdentity: callID,
                fingerprint: "call_out:\(callID)",
                payload: .transcript(.toolFinished(
                    ConversationToolFinishedPayload(
                        callID: callID,
                        outcome: Self.toolOutcome(from: outputText),
                        detail: Self.truncated(outputText.split(separator: "\n").first.map(String.init) ?? "", limit: 120)
                    )
                ))
            )]

        default:
            return []
        }
    }

    mutating func parseEventMessage(_ object: [String: Any], timestamp: Date) -> [ProviderTranscriptObservation] {
        guard let payload = object["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String else {
            return []
        }

        switch payloadType {
        case "user_message":
            guard let text = Self.nonEmptyString(payload["message"]) else { return [] }
            return [makeObservation(
                timestamp: timestamp,
                turnID: currentTurnID,
                fingerprint: fingerprintWithOccurrence("user:\(Self.contentHash(text))"),
                payload: .transcript(.userMessage(ConversationUserMessagePayload(text: text)))
            )]

        case "item_completed":
            guard let item = payload["item"] as? [String: Any],
                  Self.nonEmptyString(item["type"]) == "UserMessage" else {
                return []
            }
            let text = Self.joinedContentText(item["content"])
            guard text.isEmpty == false else { return [] }
            let turnID = Self.nonEmptyString(payload["turn_id"]) ?? currentTurnID
            let contentHash = Self.contentHash(text)
            let itemID = Self.nonEmptyString(item["id"])
            let fingerprint = itemID.map { "user_item:\($0)" }
                ?? fingerprintWithOccurrence("user_item:\(turnID ?? ""):\(contentHash)")
            return [makeObservation(
                timestamp: timestamp,
                turnID: turnID,
                providerIdentity: itemID,
                fingerprint: fingerprint,
                payload: .transcript(.userMessage(ConversationUserMessagePayload(text: text)))
            )]

        case "task_started":
            let turnID = Self.nonEmptyString(payload["turn_id"])
            if let turnID {
                currentTurnID = turnID
            }
            return [makeObservation(
                timestamp: timestamp,
                turnID: turnID ?? currentTurnID,
                fingerprint: fingerprintWithOccurrence("task_started:\(turnID ?? "")"),
                payload: .turnStarted(turnID: turnID ?? currentTurnID)
            )]

        case "task_complete":
            let turnID = Self.nonEmptyString(payload["turn_id"]) ?? currentTurnID
            return [makeObservation(
                timestamp: timestamp,
                turnID: turnID,
                fingerprint: fingerprintWithOccurrence("task_complete:\(turnID ?? "")"),
                payload: .turnEnded(turnID: turnID, reason: .completed)
            )]

        case "turn_aborted":
            let turnID = Self.nonEmptyString(payload["turn_id"]) ?? currentTurnID
            return [makeObservation(
                timestamp: timestamp,
                turnID: turnID,
                fingerprint: fingerprintWithOccurrence("turn_aborted:\(turnID ?? "")"),
                payload: .turnEnded(turnID: turnID, reason: .aborted)
            )]

        case "session_configured":
            guard let sessionID = Self.nonEmptyString(payload["session_id"]) else { return [] }
            return [makeObservation(
                timestamp: timestamp,
                providerIdentity: sessionID,
                fingerprint: fingerprintWithOccurrence("session_configured:\(sessionID)"),
                payload: .providerSessionObserved(providerSessionID: sessionID)
            )]

        case "sub_agent_activity":
            guard let threadID = Self.nonEmptyString(payload["agent_thread_id"]) else { return [] }
            let activityKind = Self.nonEmptyString(payload["kind"]) ?? ""
            let eventID = Self.nonEmptyString(payload["event_id"]) ?? threadID
            let path = Self.nonEmptyString(payload["agent_path"])
            let displayName = path.map { ($0 as NSString).lastPathComponent } ?? threadID
            return [makeObservation(
                timestamp: timestamp,
                turnID: currentTurnID,
                providerIdentity: threadID,
                fingerprint: "subagent:\(eventID):\(activityKind)",
                payload: .transcript(.subagentSummary(
                    ConversationSubagentSummaryPayload(
                        subagentID: threadID,
                        displayName: displayName,
                        phase: Self.subagentPhase(activityKind),
                        detail: path
                    )
                ))
            )]

        case "context_compacted":
            return [makeObservation(
                timestamp: timestamp,
                fingerprint: fingerprintWithOccurrence("context_compacted"),
                payload: .contextCompacted
            )]

        case "request_user_input":
            let callID = Self.nonEmptyString(payload["call_id"])
            let prompt = Self.nonEmptyString(payload["question"]) ?? "Codex is waiting for input"
            return [makeInteractionObservation(
                kind: .question,
                callID: callID,
                approvalID: Self.nonEmptyString(payload["approval_id"]),
                prompt: prompt,
                timestamp: timestamp
            )]

        default:
            if payloadType.hasSuffix("_approval_request") {
                let prompt = Self.approvalPrompt(payloadType: payloadType, payload: payload)
                return [makeInteractionObservation(
                    kind: .permission,
                    callID: Self.nonEmptyString(payload["call_id"]),
                    approvalID: Self.nonEmptyString(payload["approval_id"]),
                    prompt: prompt,
                    timestamp: timestamp
                )]
            }
            return []
        }
    }

    mutating func makeInteractionObservation(
        kind: RemotePendingInteraction.Kind,
        callID: String?,
        approvalID: String?,
        prompt: String,
        timestamp: Date
    ) -> ProviderTranscriptObservation {
        let fingerprint: String
        if let approvalID {
            fingerprint = "approval:\(approvalID)"
        } else if let callID {
            fingerprint = "approval_call:\(callID)"
        } else {
            fingerprint = fingerprintWithOccurrence("approval:\(Self.contentHash(prompt))")
        }
        return makeObservation(
            timestamp: timestamp,
            turnID: currentTurnID,
            providerIdentity: approvalID ?? callID,
            fingerprint: fingerprint,
            payload: .interactionPresented(ProviderInteractionObservation(
                kind: kind,
                providerCallID: callID,
                providerApprovalID: approvalID,
                prompt: prompt
            ))
        )
    }

    func makeObservation(
        timestamp: Date,
        turnID: String? = nil,
        providerIdentity: String? = nil,
        fingerprint: String,
        payload: ProviderObservationPayload
    ) -> ProviderTranscriptObservation {
        ProviderTranscriptObservation(
            timestamp: timestamp,
            turnID: turnID,
            providerIdentity: providerIdentity,
            fingerprint: fingerprint,
            payload: payload
        )
    }

    mutating func fingerprintWithOccurrence(_ base: String) -> String {
        let occurrence = occurrenceCounters[base, default: 0]
        occurrenceCounters[base] = occurrence + 1
        return occurrence == 0 ? base : "\(base):\(occurrence)"
    }

    static func parseTimestamp(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        if let date = try? Date(string, strategy: fractionalSecondsStyle) {
            return date
        }
        return try? Date(string, strategy: wholeSecondsStyle)
    }

    static let fractionalSecondsStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    static let wholeSecondsStyle = Date.ISO8601FormatStyle()

    static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func passthroughTurnID(_ payload: [String: Any]) -> String? {
        guard let passthrough = payload["internal_chat_message_metadata_passthrough"] as? [String: Any] else {
            return nil
        }
        return nonEmptyString(passthrough["turn_id"])
    }

    static func joinedContentText(_ value: Any?) -> String {
        guard let blocks = value as? [[String: Any]] else { return "" }
        return blocks
            .filter { block in
                let type = block["type"] as? String
                return type == "output_text" || type == "input_text" || type == "text"
            }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func assistantPhase(_ value: Any?) -> ConversationAssistantMessagePhase {
        switch value as? String {
        case "commentary":
            return .commentary
        case "final":
            return .final
        default:
            return .unknown
        }
    }

    static func subagentPhase(_ kind: String) -> ConversationSubagentPhase {
        switch kind {
        case "started", "spawned":
            return .started
        case "finished", "completed", "closed", "exited":
            return .finished
        case "":
            return .unknown
        default:
            return .updated
        }
    }

    static func toolOutcome(from output: String) -> ConversationToolOutcome {
        guard let range = output.range(of: "Process exited with code ") else {
            return .unknown
        }
        let tail = output[range.upperBound...]
        let digits = tail.prefix(while: \.isNumber)
        guard digits.isEmpty == false else { return .unknown }
        return digits == "0" ? .succeeded : .failed
    }

    static func toolArgumentsPreview(_ value: Any?) -> String? {
        guard let raw = value as? String, raw.isEmpty == false else { return nil }
        if let data = raw.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let command = nonEmptyString(object["cmd"]) ?? nonEmptyString(object["command"]) {
                return truncated(command, limit: 120)
            }
        }
        return truncated(raw, limit: 120)
    }

    static func outputText(_ value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        if let object = value as? [String: Any], let nested = object["output"] as? String {
            return nested
        }
        if let blocks = value as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    static func approvalPrompt(payloadType: String, payload: [String: Any]) -> String {
        if let command = nonEmptyString(payload["command"]) ?? nonEmptyString(payload["cmd"]) {
            return "Approve \(truncated(command, limit: 100))"
        }
        if payloadType == "apply_patch_approval_request" {
            return "Approve applying changes"
        }
        return "Codex is waiting for approval"
    }

    static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    static func contentHash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
