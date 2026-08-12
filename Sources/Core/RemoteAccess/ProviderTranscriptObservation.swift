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

    public static func isSupported(_ provider: AgentKind) -> Bool {
        provider == .codex || provider == .claude
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
public struct ProviderInteractionObservation: Equatable, Sendable {
    public var kind: RemotePendingInteraction.Kind
    public var providerCallID: String?
    public var providerApprovalID: String?
    public var prompt: String
    public var options: [RemotePendingInteraction.Option]

    public init(
        kind: RemotePendingInteraction.Kind,
        providerCallID: String? = nil,
        providerApprovalID: String? = nil,
        prompt: String,
        options: [RemotePendingInteraction.Option] = []
    ) {
        self.kind = kind
        self.providerCallID = providerCallID
        self.providerApprovalID = providerApprovalID
        self.prompt = prompt
        self.options = options
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
    /// The root turn ended. `completed` is the authoritative signal that the
    /// provider composer is open again; `aborted` leaves input availability
    /// unknown (read-only) until a later provider transition.
    case turnEnded(turnID: String?, reason: ConversationTurnEndReason)
    /// Provider session identity observed (`session_meta` /
    /// `session_configured`). Runtime binding remains a host decision.
    case providerSessionObserved(providerSessionID: String)
    /// The provider compacted its context. Informational: replayed records are
    /// handled by fingerprint dedup, not by this marker.
    case contextCompacted
}

/// One normalized observation extracted from a provider session log.
///
/// Parsers are pure and provider-specific; the projector is provider-neutral
/// and consumes only this type. `fingerprint` is the deterministic identity
/// used both for within-run dedup (file re-reads, compaction replays) and as
/// the basis of provider-derived `ConversationEvent.eventID`s. Fingerprints
/// are stable only when parsing restarts from the start of the same provider
/// file with a fresh parser (or continues from a checkpoint of the same
/// parser value).
public struct ProviderTranscriptObservation: Equatable, Sendable {
    public var timestamp: Date
    public var turnID: String?
    public var providerIdentity: String?
    public var fingerprint: String
    public var payload: ProviderObservationPayload

    public init(
        timestamp: Date,
        turnID: String? = nil,
        providerIdentity: String? = nil,
        fingerprint: String,
        payload: ProviderObservationPayload
    ) {
        self.timestamp = timestamp
        self.turnID = turnID
        self.providerIdentity = providerIdentity
        self.fingerprint = fingerprint
        self.payload = payload
    }
}
