import Foundation

/// Wire contract for the remote-access gateway. REST bodies and stream
/// messages all carry `protocolVersion`; clients must ignore unknown message
/// types.
public enum RemoteGatewayProtocol {
    public static let version = "1.0"
    public static let minimumSupportedVersion = "1.0"
    /// HttpOnly session-credential cookie. Never appears in URLs or bodies.
    public static let credentialCookieName = "toastty_remote_session"
}

/// Implemented unauthenticated capability hints. Keep this list narrow: the
/// native client must not infer that a future authentication mechanism exists
/// until the host actually implements and advertises it.
public enum RemoteGatewayCapability: String, Codable, Equatable, Sendable {
    /// The existing web flow exchanges a short pairing code for an HttpOnly
    /// browser session cookie. This does not imply native Bearer support.
    case browserCookiePairing = "browser_cookie_pairing"
}

/// Public compatibility probe used before a client has credentials.
public struct RemoteGatewayHelloResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var minimumSupportedProtocolVersion: String
    public var capabilities: [RemoteGatewayCapability]

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        minimumSupportedProtocolVersion: String = RemoteGatewayProtocol.minimumSupportedVersion,
        capabilities: [RemoteGatewayCapability] = [.browserCookiePairing]
    ) {
        self.protocolVersion = protocolVersion
        self.minimumSupportedProtocolVersion = minimumSupportedProtocolVersion
        self.capabilities = capabilities
    }
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

/// Body of `POST /api/conversation.events.get`.
public struct RemoteGatewayEventsRequest: Codable, Equatable, Sendable {
    public var conversationID: RemoteConversationID
    public var cursor: ConversationEventCursor?
    public var limit: Int?

    public init(conversationID: RemoteConversationID, cursor: ConversationEventCursor? = nil, limit: Int? = nil) {
        self.conversationID = conversationID
        self.cursor = cursor
        self.limit = limit
    }
}

/// Response for `conversation.events.get`. `resnapshot_required` tells the
/// client its cursor belongs to a discarded sequence space: drop the rendered
/// transcript and reload from the start of the current run/generation.
public enum RemoteGatewayEventsResponse: Equatable, Sendable {
    case page(ConversationEventPage)
    case resnapshotRequired
    case conversationNotFound

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case outcome
        case page
    }

    private enum Outcome: String, Codable {
        case page
        case resnapshotRequired = "resnapshot_required"
        case conversationNotFound = "not_found"
    }
}

extension RemoteGatewayEventsResponse: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Outcome.self, forKey: .outcome) {
        case .page:
            self = .page(try container.decode(ConversationEventPage.self, forKey: .page))
        case .resnapshotRequired:
            self = .resnapshotRequired
        case .conversationNotFound:
            self = .conversationNotFound
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(RemoteGatewayProtocol.version, forKey: .protocolVersion)
        switch self {
        case .page(let page):
            try container.encode(Outcome.page, forKey: .outcome)
            try container.encode(page, forKey: .page)
        case .resnapshotRequired:
            try container.encode(Outcome.resnapshotRequired, forKey: .outcome)
        case .conversationNotFound:
            try container.encode(Outcome.conversationNotFound, forKey: .outcome)
        }
    }
}

/// Server-to-client message on the subscription stream.
///
/// `session_list` rebroadcasts full list snapshots. `conversation_events`
/// carries newly appended ordered events for one conversation (page-shaped,
/// same sequence space as `conversation.events.get`); a client that sees a
/// sequence gap re-pages from its last confirmed cursor.
/// `resnapshot_required` tells subscribers one conversation's sequence space
/// was discarded mid-run. Clients must ignore unknown message types.
public enum RemoteGatewayStreamMessage: Equatable, Sendable {
    case sessionList(RemoteSessionListSnapshot)
    case conversationEvents(ConversationEventPage)
    case resnapshotRequired(conversationID: RemoteConversationID)

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case type
        case snapshot
        case page
        case conversationID
    }

    private enum MessageType: String, Codable {
        case sessionList = "session_list"
        case conversationEvents = "conversation_events"
        case resnapshotRequired = "resnapshot_required"
    }
}

extension RemoteGatewayStreamMessage: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(MessageType.self, forKey: .type) {
        case .sessionList:
            self = .sessionList(try container.decode(RemoteSessionListSnapshot.self, forKey: .snapshot))
        case .conversationEvents:
            self = .conversationEvents(try container.decode(ConversationEventPage.self, forKey: .page))
        case .resnapshotRequired:
            self = .resnapshotRequired(conversationID: try container.decode(RemoteConversationID.self, forKey: .conversationID))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(RemoteGatewayProtocol.version, forKey: .protocolVersion)
        switch self {
        case .sessionList(let snapshot):
            try container.encode(MessageType.sessionList, forKey: .type)
            try container.encode(snapshot, forKey: .snapshot)
        case .conversationEvents(let page):
            try container.encode(MessageType.conversationEvents, forKey: .type)
            try container.encode(page, forKey: .page)
        case .resnapshotRequired(let conversationID):
            try container.encode(MessageType.resnapshotRequired, forKey: .type)
            try container.encode(conversationID, forKey: .conversationID)
        }
    }
}
