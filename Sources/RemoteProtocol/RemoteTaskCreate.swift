import Foundation

/// Wire contract for creating a task from a remote device, as the Mac's
/// quick entry panel does.
///
/// The device names an open top-level workspace and an agent profile. It
/// never sends a path or a command: the Mac saves the task and runs its
/// setup, which makes the task space and starts the agent.
public enum RemoteTaskCreatePolicy {
    public static let optionsPath = "/api/task.create.options"
    public static let createPath = "/api/task.create"
    public static let createWithAttachmentsPath = "/api/task.create-with-attachments"
    public static let maximumOptionsBodyBytes = 1024
    /// How many workspaces the options list at most.
    public static let maximumWorkspaceCount = 200
    public static let maximumWorkspaceTitleLength = 200
    /// How many Frequent presets the options list at most.
    public static let maximumFrequentPresetCount = 5
    /// How many model suggestions the options list per agent at most.
    public static let maximumModelCount = 20
    /// The longest explanation the Mac sends with `createFailed`.
    public static let maximumFailureMessageLength = 300

    /// A request ID follows the session-start rules. The Mac keeps it with
    /// the task, so a repeat with the same ID returns the first task for as
    /// long as that task exists.
    public static func isValidClientRequestID(_ value: String) -> Bool {
        RemoteSessionStartPolicy.isValidClientRequestID(value)
    }
}

// MARK: - Options

public struct RemoteTaskCreateOptionsRequest: Codable, Equatable, Sendable {
    public var protocolVersion: String

    public init(protocolVersion: String = RemoteGatewayProtocol.version) {
        self.protocolVersion = protocolVersion
    }
}

/// An open top-level workspace a task can go to.
public struct RemoteTaskCreateWorkspace: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String

    public init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }
}

/// An agent with its model and effort, as quick entry's Agent picker
/// offers it. A missing model or effort means the profile's own default.
public struct RemoteTaskPreset: Codable, Equatable, Hashable, Sendable {
    public var profileID: String
    public var model: String?
    public var effort: String?

    public init(profileID: String, model: String? = nil, effort: String? = nil) {
        self.profileID = profileID
        self.model = model
        self.effort = effort
    }
}

public struct RemoteTaskCreateOptionsResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String
    /// Creating a task starts an agent, so it uses the device's session
    /// start permission.
    public var permission: RemoteSessionStartPermission
    /// Top-level workspaces in the Mac's sidebar order.
    public var workspaces: [RemoteTaskCreateWorkspace]
    /// The workspace the Mac's quick entry would start on, while it is open.
    public var defaultWorkspaceID: UUID?
    /// The agents a task can start with. Each one is available.
    public var agents: [RemoteSessionStartAgent]
    /// The presets used most, as quick entry's Frequent list shows them;
    /// `[defaults]` from tasks.toml before the first task.
    public var frequentPresets: [RemoteTaskPreset]
    /// The preset quick entry would start on: the last one used, else the
    /// first Frequent preset.
    public var defaultPreset: RemoteTaskPreset?
    /// The Mac can store uploaded files and attach them to the task.
    public var supportsAttachments: Bool

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        permission: RemoteSessionStartPermission,
        workspaces: [RemoteTaskCreateWorkspace] = [],
        defaultWorkspaceID: UUID? = nil,
        agents: [RemoteSessionStartAgent] = [],
        frequentPresets: [RemoteTaskPreset] = [],
        defaultPreset: RemoteTaskPreset? = nil,
        supportsAttachments: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.permission = permission
        self.workspaces = workspaces
        self.defaultWorkspaceID = defaultWorkspaceID
        self.agents = agents
        self.frequentPresets = frequentPresets
        self.defaultPreset = defaultPreset
        self.supportsAttachments = supportsAttachments
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, permission, workspaces, defaultWorkspaceID, agents
        case frequentPresets, defaultPreset, supportsAttachments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
        permission = try container.decode(RemoteSessionStartPermission.self, forKey: .permission)
        workspaces = try container.decodeIfPresent([RemoteTaskCreateWorkspace].self, forKey: .workspaces) ?? []
        defaultWorkspaceID = try container.decodeIfPresent(UUID.self, forKey: .defaultWorkspaceID)
        agents = try container.decodeIfPresent([RemoteSessionStartAgent].self, forKey: .agents) ?? []
        frequentPresets = try container.decodeIfPresent([RemoteTaskPreset].self, forKey: .frequentPresets) ?? []
        defaultPreset = try container.decodeIfPresent(RemoteTaskPreset.self, forKey: .defaultPreset)
        supportsAttachments = try container.decodeIfPresent(Bool.self, forKey: .supportsAttachments) ?? false
    }
}

// MARK: - Create

public struct RemoteTaskCreateRequest: Codable, Equatable, Sendable {
    public var protocolVersion: String
    /// Client-generated key that the Mac stores as the task's request ID.
    /// A repeat with the same key returns the first task and never makes a
    /// second one.
    public var clientRequestID: String
    /// An open top-level workspace.
    public var workspaceID: UUID
    /// Absent means `[defaults]` from tasks.toml, as for `toastty task create`.
    public var profileID: String?
    /// Absent means the profile's own default.
    public var model: String?
    /// Absent means the profile's own default.
    public var effort: String?
    /// The task text, which also gives the task its title. Required, with
    /// or without files.
    public var text: String
    public var attachments: [RemoteMessageAttachment]

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        clientRequestID: String,
        workspaceID: UUID,
        profileID: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        text: String,
        attachments: [RemoteMessageAttachment] = []
    ) {
        self.protocolVersion = protocolVersion
        self.clientRequestID = clientRequestID
        self.workspaceID = workspaceID
        self.profileID = profileID
        self.model = model
        self.effort = effort
        self.text = text
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, clientRequestID, workspaceID, profileID, model, effort, text, attachments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
        clientRequestID = try container.decode(String.self, forKey: .clientRequestID)
        workspaceID = try container.decode(UUID.self, forKey: .workspaceID)
        profileID = try container.decodeIfPresent(String.self, forKey: .profileID)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        text = try container.decode(String.self, forKey: .text)
        attachments = try container.decodeIfPresent([RemoteMessageAttachment].self, forKey: .attachments) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(clientRequestID, forKey: .clientRequestID)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encodeIfPresent(profileID, forKey: .profileID)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(effort, forKey: .effort)
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

/// Why the Mac did not create a task. No task was saved for any of these,
/// so the device may send a new request.
public enum RemoteTaskCreateRejectionReason: String, Codable, Equatable, Sendable {
    /// "Start sessions" is off for this device, or it cannot send messages.
    case permissionDenied = "permission_denied"
    /// The workspace is not an open top-level workspace.
    case workspaceNotFound = "workspace_not_found"
    /// The profile is unknown, not installed, or cannot take a first message.
    case agentUnavailable = "agent_unavailable"
    /// A field was missing, empty, or outside its limits.
    case invalidRequest = "invalid_request"
    case invalidAttachments = "invalid_attachments"
    case attachmentStorageUnavailable = "attachment_storage_unavailable"
    /// The Mac refused the task for a reason the response's message gives,
    /// such as an error in tasks.toml.
    case createFailed = "create_failed"
    /// This device already has a create in progress.
    case busy
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

public enum RemoteTaskCreateResult: Equatable, Sendable {
    /// The Mac saved the task and started its setup.
    case created(taskID: UUID)
    /// `message` is the Mac's own explanation, set for `createFailed`.
    case rejected(reason: RemoteTaskCreateRejectionReason, message: String?)
    /// The Mac answered with a status this client does not know. Whether a
    /// task was saved is not known, so the client must not send a request
    /// with a new ID as if nothing had happened.
    case unrecognized
}

public struct RemoteTaskCreateResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var result: RemoteTaskCreateResult

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        result: RemoteTaskCreateResult
    ) {
        self.protocolVersion = protocolVersion
        self.result = result
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, status, taskID, reason, message
    }

    private enum Status: String {
        case created
        case rejected
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
        switch Status(rawValue: try container.decode(String.self, forKey: .status)) {
        case .created:
            result = .created(taskID: try container.decode(UUID.self, forKey: .taskID))
        case .rejected:
            result = .rejected(
                reason: try container.decodeIfPresent(
                    RemoteTaskCreateRejectionReason.self,
                    forKey: .reason
                ) ?? .unknown,
                message: try container.decodeIfPresent(String.self, forKey: .message)
            )
        case nil:
            result = .unrecognized
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        switch result {
        case .created(let taskID):
            try container.encode(Status.created.rawValue, forKey: .status)
            try container.encode(taskID, forKey: .taskID)
        case .rejected(let reason, let message):
            try container.encode(Status.rejected.rawValue, forKey: .status)
            try container.encode(reason, forKey: .reason)
            try container.encodeIfPresent(message, forKey: .message)
        case .unrecognized:
            try container.encode("unrecognized", forKey: .status)
        }
    }
}
