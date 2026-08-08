import Foundation

/// Wire contract for the remote-access gateway (v0: pairing + read-only
/// session observation). REST bodies and stream messages all carry
/// `protocolVersion`; clients must ignore unknown message types.
public enum RemoteGatewayProtocol {
    public static let version = "1.0"
    /// HttpOnly session-credential cookie. Never appears in URLs or bodies.
    public static let credentialCookieName = "toastty_remote_session"
}

/// Client-facing device view. Never exposes credentials or hashes.
public struct RemoteGatewayDeviceSummary: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var scopes: [RemoteDeviceScope]

    public init(device: RemoteDeviceRecord) {
        self.id = device.id
        self.name = device.name
        self.scopes = device.scopes.sorted { $0.rawValue < $1.rawValue }
    }
}

public struct RemoteGatewayPairRequest: Codable, Equatable, Sendable {
    public var code: String
    public var deviceName: String

    public init(code: String, deviceName: String) {
        self.code = code
        self.deviceName = deviceName
    }
}

public struct RemoteGatewayPairResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var device: RemoteGatewayDeviceSummary

    public init(device: RemoteGatewayDeviceSummary) {
        self.protocolVersion = RemoteGatewayProtocol.version
        self.device = device
    }
}

public struct RemoteGatewayErrorResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.protocolVersion = RemoteGatewayProtocol.version
        self.code = code
        self.message = message
    }
}

public struct RemoteGatewaySessionListResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var snapshot: RemoteSessionListSnapshot

    public init(snapshot: RemoteSessionListSnapshot) {
        self.protocolVersion = RemoteGatewayProtocol.version
        self.snapshot = snapshot
    }
}

/// Server-to-client message on the v0 subscription stream. v0 rebroadcasts
/// full session-list snapshots; per-conversation ordered event streaming
/// arrives with the v0.5 transcript work.
public enum RemoteGatewayStreamMessage: Equatable, Sendable {
    case sessionList(RemoteSessionListSnapshot)

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case type
        case snapshot
    }

    private enum MessageType: String, Codable {
        case sessionList = "session_list"
    }
}

extension RemoteGatewayStreamMessage: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(MessageType.self, forKey: .type) {
        case .sessionList:
            self = .sessionList(try container.decode(RemoteSessionListSnapshot.self, forKey: .snapshot))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(RemoteGatewayProtocol.version, forKey: .protocolVersion)
        switch self {
        case .sessionList(let snapshot):
            try container.encode(MessageType.sessionList, forKey: .type)
            try container.encode(snapshot, forKey: .snapshot)
        }
    }
}
