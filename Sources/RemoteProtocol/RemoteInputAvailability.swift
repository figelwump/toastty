import Foundation

/// Identity of one specific "the root prompt is open and untouched" window.
///
/// An epoch is scoped to one runtime binding: `bindingID` is minted fresh every
/// time a managed runtime binds to the conversation (launch, native resume, or
/// projection rebuild), and `counter` advances within that binding on any local
/// keyboard, paste, or menu input and on provider turn transitions. Because a
/// new binding gets a new random `bindingID`, an epoch captured before a
/// Toastty relaunch or resume can never exact-match one issued afterwards —
/// counters restarting at zero cannot be replayed across runs.
///
/// A remote send is valid only when it presents the exact epoch (both fields)
/// the host currently exposes via `RemoteInputAvailability.openPrompt`. Epochs
/// are deliberately not ordered across bindings; only exact match is meaningful.
public struct RemoteInputEpoch: Codable, Hashable, Sendable {
    public var bindingID: UUID
    public var counter: UInt64

    public init(bindingID: UUID, counter: UInt64 = 0) {
        self.bindingID = bindingID
        self.counter = counter
    }

    /// The next epoch within the same runtime binding.
    public func next() -> RemoteInputEpoch {
        RemoteInputEpoch(bindingID: bindingID, counter: counter &+ 1)
    }
}

/// Why remote input is currently rejected for a conversation.
///
/// Reasons intentionally mirror several `RemoteSessionState` cases; the pairing
/// is informational, not an enforced invariant — availability is authoritative
/// for input, state is authoritative for display.
public enum RemoteInputUnavailableReason: String, Codable, Equatable, Sendable {
    case starting
    case working
    case interrupted
    case ended
    case error
    case offline
    case surfaceUnavailable = "surface_unavailable"
    /// The provider adapter cannot prove the root prompt is open and safe.
    /// Unknown always means read-only.
    case unknownProviderState = "unknown_provider_state"
}

/// Whether a conversation can accept remote input right now, and under which
/// prompt generation.
///
/// Display status never authorizes input: `openPrompt` may be published only
/// from an authoritative provider lifecycle signal for the root session, never
/// inferred from presentation status like "idle" or "ready".
public enum RemoteInputAvailability: Equatable, Sendable {
    case unavailable(reason: RemoteInputUnavailableReason)
    /// The root prompt is open, no local draft exists, and a remote send that
    /// presents exactly this epoch may be delivered.
    case openPrompt(epoch: RemoteInputEpoch)
    /// The provider is waiting on one or more modal interactions (permission,
    /// question, or structured choice). Free-form remote input stays disabled
    /// unless a provider-specific adapter explicitly allows it. Carries IDs
    /// only; the interaction content lives in the conversation snapshot's
    /// `pendingInteractions`, which is the single mutable source of truth.
    case pendingInteraction(interactionIDs: [RemotePendingInteraction.ID])
    /// Local input has touched the prompt. The associated epoch is the current
    /// (already advanced) draft-window epoch, published for observability only:
    /// remote sends are rejected in this state regardless of the epoch they
    /// present. Remote input resumes only when a later provider transition
    /// establishes a new `openPrompt` epoch.
    case localDraft(epoch: RemoteInputEpoch)

    public var allowsRemoteSend: Bool {
        if case .openPrompt = self { return true }
        return false
    }
}

extension RemoteInputAvailability: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case reason
        case epoch
        case interactionIDs
    }

    private enum Kind: String, Codable {
        case unavailable
        case openPrompt = "open_prompt"
        case pendingInteraction = "pending_interaction"
        case localDraft = "local_draft"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .unavailable:
            self = .unavailable(reason: try container.decode(RemoteInputUnavailableReason.self, forKey: .reason))
        case .openPrompt:
            self = .openPrompt(epoch: try container.decode(RemoteInputEpoch.self, forKey: .epoch))
        case .pendingInteraction:
            self = .pendingInteraction(
                interactionIDs: try container.decode([RemotePendingInteraction.ID].self, forKey: .interactionIDs)
            )
        case .localDraft:
            self = .localDraft(epoch: try container.decode(RemoteInputEpoch.self, forKey: .epoch))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unavailable(let reason):
            try container.encode(Kind.unavailable, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .openPrompt(let epoch):
            try container.encode(Kind.openPrompt, forKey: .kind)
            try container.encode(epoch, forKey: .epoch)
        case .pendingInteraction(let interactionIDs):
            try container.encode(Kind.pendingInteraction, forKey: .kind)
            try container.encode(interactionIDs, forKey: .interactionIDs)
        case .localDraft(let epoch):
            try container.encode(Kind.localDraft, forKey: .kind)
            try container.encode(epoch, forKey: .epoch)
        }
    }
}
