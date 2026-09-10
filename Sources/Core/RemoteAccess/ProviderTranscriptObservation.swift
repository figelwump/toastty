import RemoteProtocol
import Foundation

/// A pure, incremental parser from one provider's session-log lines to
/// normalized observations. Value-type parsers keep per-line state (turn
/// tracking, occurrence counters) so a resumed tail continues seamlessly.
public protocol ProviderTranscriptLineParser: Sendable {
    mutating func parseLine(_ line: String) -> [ProviderTranscriptObservation]
    var malformedLineCount: Int { get }
}

extension CodexRolloutTranscriptParser: ProviderTranscriptLineParser {}
extension ClaudeTranscriptParser: ProviderTranscriptLineParser {}

/// The parser and rollout/transcript path for a provider whose conversations
/// feed the projection today.
public enum ProviderTranscriptSupport {
    /// A fresh line parser for `provider`, or nil when the provider has no
    /// transcript parser yet.
    public static func makeParser(for provider: AgentKind) -> (any ProviderTranscriptLineParser)? {
        switch provider {
        case .codex:
            return CodexRolloutTranscriptParser()
        case .claude:
            return ClaudeTranscriptParser()
        default:
            return nil
        }
    }

    /// Providers whose native resume path is itself a line-oriented transcript.
    public static func hasFileTranscript(_ provider: AgentKind) -> Bool {
        provider == .codex || provider == .claude
    }

    /// Managed providers that can participate in the remote conversation
    /// projection. Providers without native transcript files publish bounded
    /// observations through their launch-scoped instrumentation instead.
    public static func isManagedProvider(_ provider: AgentKind) -> Bool {
        provider == .codex
            || provider == .claude
            || provider == .opencode
            || provider == .mimocode
            || provider == .pi
    }
}

/// How a root provider turn ended.
public enum ConversationTurnEndReason: String, Codable, Equatable, Sendable {
    case completed
    case aborted
}

/// A modal interaction observed in provider output, before the host has bound
/// it to an input epoch. The projector converts this into a
/// `RemotePendingInteraction` using the conversation's current epoch.
public struct ProviderInteractionObservation: Codable, Equatable, Sendable {
    public var kind: RemotePendingInteraction.Kind
    public var providerCallID: String?
    public var providerApprovalID: String?
    public var prompt: String
    public var options: [RemotePendingInteraction.Option]
    public var questions: [RemoteInteractionQuestion]?
    public var responseID: String?
    public var responseExpiresAt: Date?

    public init(
        kind: RemotePendingInteraction.Kind,
        providerCallID: String? = nil,
        providerApprovalID: String? = nil,
        prompt: String,
        options: [RemotePendingInteraction.Option] = [],
        questions: [RemoteInteractionQuestion]? = nil,
        responseID: String? = nil,
        responseExpiresAt: Date? = nil
    ) {
        self.kind = kind
        self.providerCallID = providerCallID
        self.providerApprovalID = providerApprovalID
        self.prompt = prompt
        self.options = options
        self.questions = questions
        self.responseID = responseID
        self.responseExpiresAt = responseExpiresAt
    }
}

/// What one normalized provider-log observation means to the projection.
public enum ProviderObservationPayload: Equatable, Sendable {
    /// A provider-derived transcript fact to append verbatim. Only
    /// provider-derived `ConversationEventKind`s are valid here.
    case transcript(ConversationEventPayload)
    /// A modal interaction was presented and is now blocking the root prompt.
    case interactionPresented(ProviderInteractionObservation)
    /// The root turn began; the prompt is closed.
    case turnStarted(turnID: String?)
    /// The root turn ended. `completed` authorizes the next prompt transition,
    /// subject to any provider-specific host stabilization; `aborted` leaves
    /// input availability unknown (read-only) until a later provider transition.
    case turnEnded(turnID: String?, reason: ConversationTurnEndReason)
    /// Provider session identity observed (`session_meta` /
    /// `session_configured`). Runtime binding remains a host decision.
    case providerSessionObserved(providerSessionID: String)
    /// A complete report of the root session's current execution metadata.
    /// Missing fields replace earlier values; this never opens a prompt.
    case executionProfileReported(RemoteSessionExecutionProfile)
    /// The provider compacted its context. Informational: replayed records are
    /// handled by fingerprint dedup, not by this marker.
    case contextCompacted
}

/// One normalized observation extracted from a provider session log.
///
/// Parsers are pure and provider-specific; the projector consumes only this
/// normalized type and applies any narrow host safety policy by provider.
/// `fingerprint` is the deterministic identity
/// used both for within-run dedup (file re-reads, compaction replays) and as
/// the basis of provider-derived `ConversationEvent.eventID`s. Fingerprints
/// are stable only when parsing restarts from the start of the same provider
/// file with a fresh parser (or continues from a checkpoint of the same
/// parser value).
public struct ProviderTranscriptObservation: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var turnID: String?
    public var providerIdentity: String?
    public var fingerprint: String
    public var payload: ProviderObservationPayload
    /// Historical provider snapshots are readable but must never reopen a live
    /// prompt. Only launch-bound lifecycle observations set this to true.
    public var mayAuthorizeCurrentRuntime: Bool

    public init(
        timestamp: Date,
        turnID: String? = nil,
        providerIdentity: String? = nil,
        fingerprint: String,
        payload: ProviderObservationPayload,
        mayAuthorizeCurrentRuntime: Bool = true
    ) {
        self.timestamp = timestamp
        self.turnID = turnID
        self.providerIdentity = providerIdentity
        self.fingerprint = fingerprint
        self.payload = payload
        self.mayAuthorizeCurrentRuntime = mayAuthorizeCurrentRuntime
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case turnID
        case providerIdentity
        case fingerprint
        case payloadKind
        case payload
        case mayAuthorizeCurrentRuntime
    }

    private enum PayloadKind: String, Codable {
        case transcript
        case interactionPresented
        case turnStarted
        case turnEnded
        case providerSessionObserved
        case executionProfileReported
        case contextCompacted
    }

    private struct TurnPayload: Codable {
        var turnID: String?
        var reason: ConversationTurnEndReason?
    }

    private struct ProviderSessionPayload: Codable {
        var providerSessionID: String
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
        providerIdentity = try container.decodeIfPresent(String.self, forKey: .providerIdentity)
        fingerprint = try container.decode(String.self, forKey: .fingerprint)
        mayAuthorizeCurrentRuntime = try container.decodeIfPresent(
            Bool.self,
            forKey: .mayAuthorizeCurrentRuntime
        ) ?? true

        switch try container.decode(PayloadKind.self, forKey: .payloadKind) {
        case .transcript:
            payload = .transcript(try container.decode(ConversationEventPayload.self, forKey: .payload))
        case .interactionPresented:
            payload = .interactionPresented(
                try container.decode(ProviderInteractionObservation.self, forKey: .payload)
            )
        case .turnStarted:
            payload = .turnStarted(
                turnID: try container.decode(TurnPayload.self, forKey: .payload).turnID
            )
        case .turnEnded:
            let value = try container.decode(TurnPayload.self, forKey: .payload)
            guard let reason = value.reason else {
                throw DecodingError.dataCorruptedError(
                    forKey: .payload,
                    in: container,
                    debugDescription: "turnEnded payload is missing a reason"
                )
            }
            payload = .turnEnded(turnID: value.turnID, reason: reason)
        case .providerSessionObserved:
            payload = .providerSessionObserved(
                providerSessionID: try container.decode(
                    ProviderSessionPayload.self,
                    forKey: .payload
                ).providerSessionID
            )
        case .contextCompacted:
            payload = .contextCompacted
        case .executionProfileReported:
            payload = .executionProfileReported(
                try container.decode(RemoteSessionExecutionProfile.self, forKey: .payload)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(turnID, forKey: .turnID)
        try container.encodeIfPresent(providerIdentity, forKey: .providerIdentity)
        try container.encode(fingerprint, forKey: .fingerprint)
        try container.encode(mayAuthorizeCurrentRuntime, forKey: .mayAuthorizeCurrentRuntime)

        switch payload {
        case .transcript(let value):
            try container.encode(PayloadKind.transcript, forKey: .payloadKind)
            try container.encode(value, forKey: .payload)
        case .interactionPresented(let value):
            try container.encode(PayloadKind.interactionPresented, forKey: .payloadKind)
            try container.encode(value, forKey: .payload)
        case .turnStarted(let turnID):
            try container.encode(PayloadKind.turnStarted, forKey: .payloadKind)
            try container.encode(TurnPayload(turnID: turnID), forKey: .payload)
        case .turnEnded(let turnID, let reason):
            try container.encode(PayloadKind.turnEnded, forKey: .payloadKind)
            try container.encode(TurnPayload(turnID: turnID, reason: reason), forKey: .payload)
        case .providerSessionObserved(let providerSessionID):
            try container.encode(PayloadKind.providerSessionObserved, forKey: .payloadKind)
            try container.encode(
                ProviderSessionPayload(providerSessionID: providerSessionID),
                forKey: .payload
            )
        case .contextCompacted:
            try container.encode(PayloadKind.contextCompacted, forKey: .payloadKind)
            try container.encodeNil(forKey: .payload)
        case .executionProfileReported(let profile):
            try container.encode(PayloadKind.executionProfileReported, forKey: .payloadKind)
            try container.encode(profile, forKey: .payload)
        }
    }
}
