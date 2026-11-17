import Foundation

/// A durable host fact describing a modal provider interaction (permission
/// request, question, or structured choice) that is blocking the root session.
///
/// A response path is allowed only when the provider supplies a semantic action
/// channel addressed to the same interaction identity. Other interactions are
/// read-only; answers are never converted into terminal keystrokes.
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
        public var preview: String?

        public init(id: String, label: String, detail: String? = nil, preview: String? = nil) {
            self.id = id
            self.label = label
            self.detail = detail
            self.preview = preview
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
    /// Present only for a provider question with a semantic response channel.
    public var questions: [RemoteInteractionQuestion]?
    public var responseID: String?
    public var responseExpiresAt: Date?
    public var answers: [RemoteInteractionAnswer]?
    /// Present only for a provider permission request a client can answer.
    public var permission: RemotePermissionRequestDetail?

    public init(
        id: ID,
        kind: Kind,
        providerCallID: String? = nil,
        providerApprovalID: String? = nil,
        prompt: String,
        options: [Option] = [],
        inputEpoch: RemoteInputEpoch,
        presentedAt: Date,
        state: State = .pending,
        questions: [RemoteInteractionQuestion]? = nil,
        responseID: String? = nil,
        responseExpiresAt: Date? = nil,
        answers: [RemoteInteractionAnswer]? = nil,
        permission: RemotePermissionRequestDetail? = nil
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
        self.questions = questions
        self.responseID = responseID
        self.responseExpiresAt = responseExpiresAt
        self.answers = answers
        self.permission = permission
    }
}

/// What the provider asks permission to do, as a client shows it before the
/// user decides. The decision itself travels as the interaction's single
/// question, so the provider input never has to leave the Mac in full.
public struct RemotePermissionRequestDetail: Codable, Equatable, Sendable {
    /// The provider's tool name, such as `Bash`, `Edit`, or `mcp__server__tool`.
    public var toolName: String
    /// The provider's own reason for the request, when it gives one.
    public var description: String?
    /// The command, file change, or tool arguments the request would use.
    public var preview: String
    /// True when `preview` was shortened to fit the protocol bound.
    public var previewTruncated: Bool

    public init(toolName: String, description: String? = nil, preview: String, previewTruncated: Bool = false) {
        self.toolName = toolName
        self.description = description
        self.preview = preview
        self.previewTruncated = previewTruncated
    }
}
