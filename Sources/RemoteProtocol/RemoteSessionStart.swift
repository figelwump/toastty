import Foundation

/// Wire contract for starting a new agent session from a remote device.
///
/// The device names an existing workspace and a configured agent profile. It
/// never sends a path, a command, or environment values: the Mac decides the
/// directory and the command line.
public enum RemoteSessionStartPolicy {
    public static let optionsPath = "/api/session.start.options"
    public static let startPath = "/api/session.start"
    public static let startWithAttachmentsPath = "/api/session.start-with-attachments"
    public static let maximumOptionsBodyBytes = 1024
    public static let maximumClientRequestIDLength = 64
    public static let maximumModelLength = 200
    public static let maximumReasoningEffortLength = 40
    /// How many models the Mac suggests per agent.
    public static let maximumRecentModelCount = 5
    /// How long the Mac remembers a finished request, so that a repeat with
    /// the same `clientRequestID` returns the first answer and starts
    /// nothing. A client must use a new ID after this window.
    public static let duplicateRequestWindow: TimeInterval = 600

    /// A model or effort value the Mac will pass to a provider CLI: one
    /// printable token, bounded, with no leading dash.
    public static func isValidSelectionValue(_ value: String, maximumLength: Int) -> Bool {
        value.isEmpty == false
            && value.count <= maximumLength
            && value.hasPrefix("-") == false
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII && scalar.value > 0x20 && scalar.value < 0x7F
            }
    }

    public static func isValidClientRequestID(_ value: String) -> Bool {
        value.isEmpty == false
            && value.count <= maximumClientRequestIDLength
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
            }
    }
}

// MARK: - Options

public struct RemoteSessionStartOptionsRequest: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var workspaceID: UUID

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        workspaceID: UUID
    ) {
        self.protocolVersion = protocolVersion
        self.workspaceID = workspaceID
    }
}

/// Whether this device may start sessions. The permission is set per device
/// on the Mac and is granted by default.
public enum RemoteSessionStartPermission: String, Codable, Equatable, Sendable {
    case allowed
    /// "Start sessions" is turned off for this device on the Mac.
    case startDisabled = "start_disabled"
    /// The device cannot send messages, and a first message is a send.
    case sendDisabled = "send_disabled"
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

public enum RemoteSessionStartWorkspaceState: String, Codable, Equatable, Sendable {
    case available
    case notFound = "not_found"
    /// The workspace has no terminal whose directory the Mac knows.
    case noDirectory = "no_directory"
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

public enum RemoteSessionStartAgentAvailability: String, Codable, Equatable, Sendable {
    case available
    /// The profile's command is not installed on the Mac.
    case notInstalled = "not_installed"
    /// The profile cannot take a first message on its command line.
    case firstMessageUnsupported = "first_message_unsupported"
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

/// One agent profile the device can choose.
public struct RemoteSessionStartAgent: Codable, Equatable, Sendable, Identifiable {
    public var profileID: String
    public var displayName: String
    public var availability: RemoteSessionStartAgentAvailability
    /// Whether the Mac can pass a model choice to this agent.
    public var supportsModel: Bool
    /// Models that sessions of this agent on the Mac report now, most recent
    /// first. Suggestions only; the device may send any valid value.
    public var recentModels: [String]
    /// The effort values the Mac accepts for this agent. Empty when the agent
    /// has no effort setting.
    public var reasoningEfforts: [String]

    public var id: String { profileID }

    public init(
        profileID: String,
        displayName: String,
        availability: RemoteSessionStartAgentAvailability,
        supportsModel: Bool,
        recentModels: [String] = [],
        reasoningEfforts: [String] = []
    ) {
        self.profileID = profileID
        self.displayName = displayName
        self.availability = availability
        self.supportsModel = supportsModel
        self.recentModels = recentModels
        self.reasoningEfforts = reasoningEfforts
    }

    private enum CodingKeys: String, CodingKey {
        case profileID, displayName, availability, supportsModel, recentModels, reasoningEfforts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try container.decode(String.self, forKey: .profileID)
        displayName = try container.decode(String.self, forKey: .displayName)
        availability = try container.decode(RemoteSessionStartAgentAvailability.self, forKey: .availability)
        supportsModel = try container.decodeIfPresent(Bool.self, forKey: .supportsModel) ?? false
        recentModels = try container.decodeIfPresent([String].self, forKey: .recentModels) ?? []
        reasoningEfforts = try container.decodeIfPresent([String].self, forKey: .reasoningEfforts) ?? []
    }
}

public struct RemoteSessionStartOptionsResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var permission: RemoteSessionStartPermission
    public var workspace: RemoteSessionStartWorkspaceState
    /// The directory a new session would start in. For display only.
    public var launchDirectory: String?
    public var agents: [RemoteSessionStartAgent]
    /// The Mac can store files and include their paths in the first message.
    public var supportsAttachments: Bool

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        permission: RemoteSessionStartPermission,
        workspace: RemoteSessionStartWorkspaceState,
        launchDirectory: String? = nil,
        agents: [RemoteSessionStartAgent] = [],
        supportsAttachments: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.permission = permission
        self.workspace = workspace
        self.launchDirectory = launchDirectory
        self.agents = agents
        self.supportsAttachments = supportsAttachments
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, permission, workspace, launchDirectory, agents, supportsAttachments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
        permission = try container.decode(RemoteSessionStartPermission.self, forKey: .permission)
        workspace = try container.decode(RemoteSessionStartWorkspaceState.self, forKey: .workspace)
        launchDirectory = try container.decodeIfPresent(String.self, forKey: .launchDirectory)
        agents = try container.decodeIfPresent([RemoteSessionStartAgent].self, forKey: .agents) ?? []
        supportsAttachments = try container.decodeIfPresent(Bool.self, forKey: .supportsAttachments) ?? false
    }
}

// MARK: - Start

public struct RemoteSessionStartRequest: Codable, Equatable, Sendable {
    public var protocolVersion: String
    /// Client-generated key. A repeat with the same key inside
    /// `RemoteSessionStartPolicy.duplicateRequestWindow` returns the first
    /// answer and never starts a second session.
    public var clientRequestID: String
    public var workspaceID: UUID
    public var profileID: String
    /// Absent means the profile's own default.
    public var model: String?
    /// Absent means the profile's own default.
    public var reasoningEffort: String?
    /// The first message. May be empty when files are attached.
    public var text: String
    public var attachments: [RemoteMessageAttachment]

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        clientRequestID: String,
        workspaceID: UUID,
        profileID: String,
        model: String? = nil,
        reasoningEffort: String? = nil,
        text: String,
        attachments: [RemoteMessageAttachment] = []
    ) {
        self.protocolVersion = protocolVersion
        self.clientRequestID = clientRequestID
        self.workspaceID = workspaceID
        self.profileID = profileID
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.text = text
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, clientRequestID, workspaceID, profileID, model, reasoningEffort, text, attachments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
        clientRequestID = try container.decode(String.self, forKey: .clientRequestID)
        workspaceID = try container.decode(UUID.self, forKey: .workspaceID)
        profileID = try container.decode(String.self, forKey: .profileID)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        text = try container.decode(String.self, forKey: .text)
        attachments = try container.decodeIfPresent([RemoteMessageAttachment].self, forKey: .attachments) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(clientRequestID, forKey: .clientRequestID)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encode(profileID, forKey: .profileID)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try container.encode(text, forKey: .text)
        if !attachments.isEmpty { try container.encode(attachments, forKey: .attachments) }
    }

    /// Admission and delivery use the same bytes. Escaping base64 slashes
    /// would inflate valid uploads beyond their encoded-size limit.
    public func encodedForTransport() throws -> Data {
        let encoder = ConversationEventCoding.makeEncoder()
        if !attachments.isEmpty { encoder.outputFormatting.insert(.withoutEscapingSlashes) }
        return try encoder.encode(self)
    }
}

/// Why the Mac did not start a session. Nothing was launched for any of
/// these, so the device may send a new request.
public enum RemoteSessionStartRejectionReason: String, Codable, Equatable, Sendable {
    /// "Start sessions" is off for this device, or it cannot send messages.
    case permissionDenied = "permission_denied"
    case workspaceNotFound = "workspace_not_found"
    /// The workspace has no terminal whose directory the Mac knows.
    case workspaceUnavailable = "workspace_unavailable"
    /// The profile is unknown, not installed, or cannot take a first message.
    case agentUnavailable = "agent_unavailable"
    /// A field was missing, empty, or outside its limits.
    case invalidRequest = "invalid_request"
    case invalidAttachments = "invalid_attachments"
    case attachmentStorageUnavailable = "attachment_storage_unavailable"
    /// The Mac opened a terminal but the agent command could not be sent.
    case launchFailed = "launch_failed"
    /// This device already has a start in progress.
    case busy
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

public enum RemoteSessionStartResult: Equatable, Sendable {
    /// The agent command was sent to a new terminal. The conversation enters
    /// the session list under this ID once the agent reports itself.
    case started(conversationID: RemoteConversationID)
    case rejected(reason: RemoteSessionStartRejectionReason)
    /// The Mac answered with a status this client does not know. Whether a
    /// session started is not known, so the client must not send a request
    /// with a new ID as if nothing had launched.
    case unrecognized
}

public struct RemoteSessionStartResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var result: RemoteSessionStartResult

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        result: RemoteSessionStartResult
    ) {
        self.protocolVersion = protocolVersion
        self.result = result
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, status, conversationID, reason
    }

    private enum Status: String {
        case started
        case rejected
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
        switch Status(rawValue: try container.decode(String.self, forKey: .status)) {
        case .started:
            result = .started(
                conversationID: try container.decode(RemoteConversationID.self, forKey: .conversationID)
            )
        case .rejected:
            result = .rejected(
                reason: try container.decodeIfPresent(
                    RemoteSessionStartRejectionReason.self,
                    forKey: .reason
                ) ?? .unknown
            )
        case nil:
            result = .unrecognized
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        switch result {
        case .started(let conversationID):
            try container.encode(Status.started.rawValue, forKey: .status)
            try container.encode(conversationID, forKey: .conversationID)
        case .rejected(let reason):
            try container.encode(Status.rejected.rawValue, forKey: .status)
            try container.encode(reason, forKey: .reason)
        case .unrecognized:
            try container.encode("unrecognized", forKey: .status)
        }
    }
}
