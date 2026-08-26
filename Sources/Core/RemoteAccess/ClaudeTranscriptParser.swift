import RemoteProtocol
import Foundation
import CryptoKit

/// Pure line-oriented parser from a Claude Code transcript JSONL file to
/// normalized `ProviderTranscriptObservation`s, against the same event schema
/// and fidelity contract as the Codex parser.
///
/// Sourcing decisions (from auditing real transcripts):
/// - A "real" user turn is a `user` record that is not `isMeta` and not
///   `isSidechain`, and whose structured `origin.kind` is not
///   `task-notification`, with content that is a string or an array of
///   text/image blocks. `tool_result` blocks arriving as `user` records are
///   tool completions, not user turns. Missing or malformed `origin` values
///   preserve the normal user-record behavior.
/// - Assistant turns come from `assistant` records' `text` blocks; `tool_use`
///   blocks become tool starts, `thinking` blocks are dropped.
/// - Tool completion state comes from the matching `tool_result`'s `is_error`.
/// - `isSidechain` records belong to subagent sidechains and are not part of
///   the root transcript (full subagent transcripts are out of contract).
/// - Records the projection does not need (`system`, `queue-operation`,
///   `file-history-*`, `bridge-session`, titles, mode markers) are skipped.
///
/// Unlike Codex, a Claude transcript carries no authoritative "the composer is
/// open" record — that arrives out-of-band through Claude Code hooks. This
/// parser therefore never emits `turnEnded(.completed)`, so Claude
/// conversations remain read-only until a hook-based prompt signal exists.
/// Malformed lines are counted and skipped; they never throw.
public struct ClaudeTranscriptParser: Sendable {
    public private(set) var malformedLineCount: Int = 0
    private var currentTurnID: String?
    private var sawSessionIdentity = false
    private var occurrenceCounters: [String: Int] = [:]

    public init() {}

    public mutating func parseLine(_ line: String) -> [ProviderTranscriptObservation] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }
        guard let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let recordType = object["type"] as? String else {
            malformedLineCount += 1
            return []
        }

        // Records without a timestamp (mode markers, titles, bridge-session)
        // are structural and never carry transcript content we ingest.
        guard let timestamp = Self.parseTimestamp(object["timestamp"]) else {
            switch recordType {
            case "user", "assistant":
                malformedLineCount += 1
            default:
                break
            }
            return []
        }

        // Subagent sidechain records are not part of the root transcript.
        if object["isSidechain"] as? Bool == true {
            return []
        }

        var observations: [ProviderTranscriptObservation] = []
        observations.append(contentsOf: sessionIdentityObservation(object, timestamp: timestamp))

        if let promptID = Self.nonEmptyString(object["promptId"]) {
            currentTurnID = promptID
        }

        switch recordType {
        case "user":
            observations.append(contentsOf: parseUserRecord(object, timestamp: timestamp))
        case "assistant":
            observations.append(contentsOf: parseAssistantRecord(object, timestamp: timestamp))
        default:
            break
        }
        return observations
    }

    public static func parseContents(_ contents: String) -> (observations: [ProviderTranscriptObservation], malformedLineCount: Int) {
        var parser = ClaudeTranscriptParser()
        var observations: [ProviderTranscriptObservation] = []
        contents.enumerateLines { line, _ in
            observations.append(contentsOf: parser.parseLine(line))
        }
        return (observations, parser.malformedLineCount)
    }
}

private extension ClaudeTranscriptParser {
    mutating func sessionIdentityObservation(_ object: [String: Any], timestamp: Date) -> [ProviderTranscriptObservation] {
        guard sawSessionIdentity == false,
              let sessionID = Self.nonEmptyString(object["sessionId"]) else {
            return []
        }
        sawSessionIdentity = true
        return [ProviderTranscriptObservation(
            timestamp: timestamp,
            providerIdentity: sessionID,
            fingerprint: fingerprintWithOccurrence("session:\(sessionID)"),
            payload: .providerSessionObserved(providerSessionID: sessionID)
        )]
    }

    mutating func parseUserRecord(_ object: [String: Any], timestamp: Date) -> [ProviderTranscriptObservation] {
        if object["isMeta"] as? Bool == true {
            return []
        }
        if let origin = object["origin"] as? [String: Any],
           origin["kind"] as? String == "task-notification" {
            return []
        }
        guard let message = object["message"] as? [String: Any] else {
            malformedLineCount += 1
            return []
        }
        let recordUUID = Self.nonEmptyString(object["uuid"])

        // String content is always a real user turn.
        if let text = Self.nonEmptyString(message["content"]) {
            return [userMessageObservation(text: text, recordUUID: recordUUID, timestamp: timestamp)]
        }

        guard let blocks = message["content"] as? [[String: Any]] else {
            return []
        }

        var observations: [ProviderTranscriptObservation] = []
        var userText: [String] = []
        for block in blocks {
            switch block["type"] as? String {
            case "tool_result":
                observations.append(contentsOf: toolResultObservation(block, timestamp: timestamp))
            case "text":
                if let text = Self.nonEmptyString(block["text"]) {
                    userText.append(text)
                }
            default:
                break
            }
        }
        if userText.isEmpty == false {
            observations.append(userMessageObservation(
                text: userText.joined(separator: "\n"),
                recordUUID: recordUUID,
                timestamp: timestamp
            ))
        }
        return observations
    }

    mutating func userMessageObservation(text: String, recordUUID: String?, timestamp: Date) -> ProviderTranscriptObservation {
        let fingerprint = recordUUID.map { "user:\($0)" }
            ?? fingerprintWithOccurrence("user:\(Self.contentHash(text)):\(currentTurnID ?? "")")
        // A user turn closes the prompt; the projector treats userMessage as an
        // authoritative prompt-closed signal.
        return ProviderTranscriptObservation(
            timestamp: timestamp,
            turnID: currentTurnID,
            providerIdentity: recordUUID,
            fingerprint: fingerprint,
            payload: .transcript(.userMessage(ConversationUserMessagePayload(text: text)))
        )
    }

    mutating func toolResultObservation(_ block: [String: Any], timestamp: Date) -> [ProviderTranscriptObservation] {
        guard let callID = Self.nonEmptyString(block["tool_use_id"]) else { return [] }
        let isError = block["is_error"] as? Bool ?? false
        let detail = Self.truncated(Self.toolResultText(block["content"]).split(separator: "\n").first.map(String.init) ?? "", limit: 120)
        return [ProviderTranscriptObservation(
            timestamp: timestamp,
            turnID: currentTurnID,
            providerIdentity: callID,
            fingerprint: "call_out:\(callID)",
            payload: .transcript(.toolFinished(ConversationToolFinishedPayload(
                callID: callID,
                outcome: isError ? .failed : .succeeded,
                detail: detail
            )))
        )]
    }

    mutating func parseAssistantRecord(_ object: [String: Any], timestamp: Date) -> [ProviderTranscriptObservation] {
        guard let message = object["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else {
            return []
        }
        let stopReason = Self.nonEmptyString(message["stop_reason"])
        let phase: ConversationAssistantMessagePhase = stopReason == "end_turn" ? .final : .commentary
        let recordUUID = Self.nonEmptyString(object["uuid"])

        var observations: [ProviderTranscriptObservation] = []
        var textIndex = 0
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                guard let text = Self.nonEmptyString(block["text"]) else { continue }
                let fingerprint = recordUUID.map { "assistant:\($0):\(textIndex)" }
                    ?? fingerprintWithOccurrence("assistant:\(Self.contentHash(text))")
                textIndex += 1
                observations.append(ProviderTranscriptObservation(
                    timestamp: timestamp,
                    turnID: currentTurnID,
                    providerIdentity: recordUUID,
                    fingerprint: fingerprint,
                    payload: .transcript(.assistantMessage(
                        ConversationAssistantMessagePayload(text: text, phase: phase)
                    ))
                ))

            case "tool_use":
                guard let callID = Self.nonEmptyString(block["id"]),
                      let name = Self.nonEmptyString(block["name"]) else {
                    continue
                }
                observations.append(ProviderTranscriptObservation(
                    timestamp: timestamp,
                    turnID: currentTurnID,
                    providerIdentity: callID,
                    fingerprint: "call:\(callID)",
                    payload: .transcript(.toolStarted(ConversationToolStartedPayload(
                        callID: callID,
                        toolName: name,
                        detail: Self.toolInputPreview(name: name, input: block["input"])
                    )))
                ))

            default:
                // thinking, redacted_thinking, etc. are out of contract.
                break
            }
        }
        return observations
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

    static func toolResultText(_ value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        if let blocks = value as? [[String: Any]] {
            return blocks
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
        }
        return ""
    }

    static func toolInputPreview(name: String, input: Any?) -> String? {
        guard let input = input as? [String: Any] else { return nil }
        // Prefer the most human-meaningful field per tool.
        let candidateKeys = ["command", "file_path", "path", "pattern", "description", "url", "query"]
        for key in candidateKeys {
            if let value = nonEmptyString(input[key]) {
                return truncated(value, limit: 120)
            }
        }
        return nil
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
