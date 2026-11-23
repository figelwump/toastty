import Foundation

/// Wire contract for sending a quick entry message to the coordinator from
/// a remote device, as the Mac's quick entry panel does while a coordinator
/// exists.
///
/// The device sends the text, its files, and the Workspace and Agent
/// choices that the user made. The Mac writes the message as quick entry
/// does: Toastty's first line with the choices, then the text and the
/// paths of the files that it copied into the coordinator's folder. The
/// message waits, saved, until the coordinator's prompt takes it; it never
/// goes into a running turn.
public enum RemoteCoordinatorSendPolicy {
    public static let sendPath = "/api/coordinator.send"
    public static let sendWithAttachmentsPath = "/api/coordinator.send-with-attachments"
    /// The longest explanation the Mac sends with `sendFailed`.
    public static let maximumFailureMessageLength = 300

    /// A request ID follows the session-start rules. The Mac answers a
    /// repeat with the first result and sends nothing new.
    public static func isValidClientRequestID(_ value: String) -> Bool {
        RemoteSessionStartPolicy.isValidClientRequestID(value)
    }
}

// MARK: - State

/// Whether the coordinator's agent runs, as the Mac's quick entry panel
/// says before a send.
public enum RemoteCoordinatorAgentState: String, Codable, Equatable, Sendable {
    case running
    /// Toastty is starting the agent. A message waits for it.
    case starting
    /// No agent runs in the coordinator's terminal. A message waits until
    /// one starts on the Mac.
    case notRunning = "not_running"
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

/// The coordinator as a new message would find it. The Mac sends it in the
/// task-create options while it has a coordinator workspace and can take
/// a send from this device's capability.
public struct RemoteCoordinatorSendState: Codable, Equatable, Sendable {
    public var agent: RemoteCoordinatorAgentState
    /// Messages that wait for the coordinator's prompt.
    public var waitingCount: Int

    public init(agent: RemoteCoordinatorAgentState, waitingCount: Int = 0) {
        self.agent = agent
        self.waitingCount = waitingCount
    }

    private enum CodingKeys: String, CodingKey {
        case agent, waitingCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = try container.decodeIfPresent(RemoteCoordinatorAgentState.self, forKey: .agent) ?? .unknown
        waitingCount = max(0, try container.decodeIfPresent(Int.self, forKey: .waitingCount) ?? 0)
    }
}

// MARK: - Send

public struct RemoteCoordinatorSendRequest: Codable, Equatable, Sendable {
    public var protocolVersion: String
    /// Client-generated key. A repeat with the same key gets the first
    /// result and sends nothing new.
    public var clientRequestID: String
    /// The project the user chose with the Workspace pill: an open
    /// top-level workspace. Absent means Auto: the coordinator chooses.
    public var workspaceID: UUID?
    /// The agent the user chose with the Agent pill. Absent means Auto.
    public var profileID: String?
    /// Absent means the profile's own default.
    public var model: String?
    /// Absent means the profile's own default.
    public var effort: String?
    /// The user's text. Required, with or without files.
    public var text: String
    public var attachments: [RemoteMessageAttachment]

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        clientRequestID: String,
        workspaceID: UUID? = nil,
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
        workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
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
        try container.encodeIfPresent(workspaceID, forKey: .workspaceID)
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

/// Why a message waits for the coordinator's prompt, as the Mac's quick
/// entry toast says it.
public enum RemoteCoordinatorWaitReason: String, Codable, Equatable, Sendable {
    /// No agent runs in the coordinator's terminal.
    case notRunning = "not_running"
    /// Toastty is starting the coordinator's agent.
    case starting
    /// The coordinator works on a turn. A quick entry message waits for
    /// the turn's end.
    case working
    /// Text that the user typed is in the coordinator's terminal.
    case userDraft = "user_draft"
    /// The coordinator's prompt is not open, for example after a stop.
    case promptNotOpen = "prompt_not_open"
    /// Toastty could not save the message to disk. It waits in memory.
    case notSaved = "not_saved"
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

/// Why the Mac did not take the message. Nothing was sent for any of
/// these, so the device may send the message again.
public enum RemoteCoordinatorSendRejectionReason: String, Codable, Equatable, Sendable {
    /// "Start sessions" is off for this device, or it cannot send messages.
    case permissionDenied = "permission_denied"
    /// The Mac has no coordinator workspace now.
    case noCoordinator = "no_coordinator"
    /// The chosen workspace is not an open top-level workspace.
    case workspaceNotFound = "workspace_not_found"
    /// The chosen profile is unknown, not installed, or cannot take a task.
    case agentUnavailable = "agent_unavailable"
    /// A field was missing, empty, or outside its limits.
    case invalidRequest = "invalid_request"
    case invalidAttachments = "invalid_attachments"
    case attachmentStorageUnavailable = "attachment_storage_unavailable"
    /// The coordinator refused the message for a reason the response's
    /// message gives, such as a full queue.
    case sendFailed = "send_failed"
    /// This device already has a send in progress.
    case busy
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

public enum RemoteCoordinatorSendResult: Equatable, Sendable {
    /// Typed at the coordinator's open prompt.
    case sent
    /// Saved on the Mac until the coordinator's prompt takes it.
    case waiting(reason: RemoteCoordinatorWaitReason)
    /// `message` is the Mac's own explanation, set for `sendFailed`.
    case rejected(reason: RemoteCoordinatorSendRejectionReason, message: String?)
    /// The Mac answered with a status this client does not know. Whether
    /// the message was sent is not known, so the client must not send it
    /// with a new ID as if nothing had happened.
    case unrecognized
}

public struct RemoteCoordinatorSendResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var result: RemoteCoordinatorSendResult

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        result: RemoteCoordinatorSendResult
    ) {
        self.protocolVersion = protocolVersion
        self.result = result
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, status, reason, message
    }

    private enum Status: String {
        case sent
        case waiting
        case rejected
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
        switch Status(rawValue: try container.decode(String.self, forKey: .status)) {
        case .sent:
            result = .sent
        case .waiting:
            result = .waiting(
                reason: try container.decodeIfPresent(RemoteCoordinatorWaitReason.self, forKey: .reason) ?? .unknown
            )
        case .rejected:
            result = .rejected(
                reason: try container.decodeIfPresent(
                    RemoteCoordinatorSendRejectionReason.self,
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
        case .sent:
            try container.encode(Status.sent.rawValue, forKey: .status)
        case .waiting(let reason):
            try container.encode(Status.waiting.rawValue, forKey: .status)
            try container.encode(reason, forKey: .reason)
        case .rejected(let reason, let message):
            try container.encode(Status.rejected.rawValue, forKey: .status)
            try container.encode(reason, forKey: .reason)
            try container.encodeIfPresent(message, forKey: .message)
        case .unrecognized:
            try container.encode("unrecognized", forKey: .status)
        }
    }
}
