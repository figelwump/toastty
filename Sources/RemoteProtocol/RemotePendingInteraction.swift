import Foundation

/// A durable host fact describing a modal provider interaction (permission
/// request, question, or structured choice) that is blocking the root session.
///
/// Early mobile slices render these read-only. A response path is allowed only
/// when the provider supplies a semantic action channel addressed to the same
/// interaction identity — never by converting an interaction into keystrokes.
public struct RemotePendingInteraction: Codable, Equatable, Sendable, Identifiable {
    /// Deterministic identity, derived from provider identifiers (approval ID,
    /// call ID) when available, otherwise from a stable content fingerprint.
    /// Never a random value: rebuilding the projection from unchanged provider
    /// facts must reproduce the same interaction ID.
    public struct ID: RawRepresentable, Codable, Hashable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.rawValue = try container.decode(String.self)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public enum Kind: String, Codable, Equatable, Sendable {
        case permission
        case question
        case structuredChoice = "structured_choice"
        case freeForm = "free_form"
    }

    public enum State: String, Codable, Equatable, Sendable {
        case pending
        case resolved
        case superseded
    }

    public struct Option: Codable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var detail: String?

        public init(id: String, label: String, detail: String? = nil) {
            self.id = id
            self.label = label
            self.detail = detail
        }
    }

    public var id: ID
    public var kind: Kind
    public var providerCallID: String?
    public var providerApprovalID: String?
    public var prompt: String
    public var options: [Option]
    /// The prompt epoch the interaction was presented under. A resolution or
    /// supersession observed under a later epoch invalidates any client answer
    /// composed against this value.
    public var inputEpoch: RemoteInputEpoch
    public var presentedAt: Date
    public var state: State

    public init(
        id: ID,
        kind: Kind,
        providerCallID: String? = nil,
        providerApprovalID: String? = nil,
        prompt: String,
        options: [Option] = [],
        inputEpoch: RemoteInputEpoch,
        presentedAt: Date,
        state: State = .pending
    ) {
        self.id = id
        self.kind = kind
        self.providerCallID = providerCallID
        self.providerApprovalID = providerApprovalID
        self.prompt = prompt
        self.options = options
        self.inputEpoch = inputEpoch
        self.presentedAt = presentedAt
        self.state = state
    }
}
