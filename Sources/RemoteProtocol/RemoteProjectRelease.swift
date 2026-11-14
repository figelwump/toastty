import Foundation

/// Wire contract for starting a release of a project from a remote device.
///
/// The Mac decides which projects can release and sends each To ship lane's
/// `releaseWorkspaceID`. A client asks for a release of that workspace; the
/// Mac checks the device, the project's release settings and any release
/// under way again, then starts the same release task as its own Release
/// button. A host advertises the route with `project_release`.
public enum RemoteProjectReleasePolicy {
    public static let releasePath = "/api/project.release"
    public static let maximumBodyBytes = 1024

    public static func isValidClientRequestID(_ value: String) -> Bool {
        RemoteSessionStartPolicy.isValidClientRequestID(value)
    }
}

public struct RemoteProjectReleaseRequest: Codable, Equatable, Sendable {
    public var protocolVersion: String
    /// The lane's `releaseWorkspaceID`.
    public var workspaceID: UUID
    /// Chosen by the client for one user intent. A retry after an unknown
    /// outcome repeats it, and the Mac answers with the release that the
    /// first request started instead of starting another.
    public var clientRequestID: String

    public init(protocolVersion: String = RemoteGatewayProtocol.version, workspaceID: UUID, clientRequestID: String) {
        self.protocolVersion = protocolVersion
        self.workspaceID = workspaceID
        self.clientRequestID = clientRequestID
    }
}

/// Why the Mac did not start a release.
public enum RemoteProjectReleaseRejectionReason: String, Codable, Equatable, Sendable {
    /// The device lacks send access, its Task actions switch, or its session
    /// start permission. A release needs all three.
    case permissionDenied = "permission_denied"
    /// No open workspace has the ID.
    case projectNotFound = "project_not_found"
    /// The project has no release skill or release prompt in tasks.toml.
    case notReleasable = "not_releasable"
    /// A release of the project is already under way. The message names it.
    case releaseUnderWay = "release_under_way"
    /// The Mac tried and failed. The message says why.
    case failed
    case invalidRequest = "invalid_request"
    /// The Mac's task system is off.
    case tasksUnavailable = "tasks_unavailable"
    /// A reason this client does not know.
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

public enum RemoteProjectReleaseResult: Equatable, Sendable {
    /// The Mac made the release task, which now sets up its worktree and
    /// starts its agent. The board lists it like any other task.
    case started(taskID: UUID)
    case rejected(reason: RemoteProjectReleaseRejectionReason, message: String?)
    /// The Mac answered with a status this client does not know. Whether a
    /// release started is not known, so the client must not repeat the
    /// request under a new ID as if nothing had started.
    case unrecognized
}

public struct RemoteProjectReleaseResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var result: RemoteProjectReleaseResult

    public init(protocolVersion: String = RemoteGatewayProtocol.version, result: RemoteProjectReleaseResult) {
        self.protocolVersion = protocolVersion
        self.result = result
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, status, taskID, reason, message
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
            result = .started(taskID: try container.decode(UUID.self, forKey: .taskID))
        case .rejected:
            result = .rejected(
                reason: try container.decodeIfPresent(RemoteProjectReleaseRejectionReason.self, forKey: .reason) ?? .unknown,
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
        case .started(let taskID):
            try container.encode(Status.started.rawValue, forKey: .status)
            try container.encode(taskID, forKey: .taskID)
        case .rejected(let reason, let message):
            try container.encode(Status.rejected.rawValue, forKey: .status)
            try container.encode(reason, forKey: .reason)
            try container.encodeIfPresent(message.map(RemoteTaskActionPolicy.boundedMessage), forKey: .message)
        case .unrecognized:
            try container.encode("unrecognized", forKey: .status)
        }
    }
}
