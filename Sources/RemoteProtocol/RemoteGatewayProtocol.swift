import Foundation

/// Wire contract for the remote-access gateway. REST bodies and stream
/// messages all carry `protocolVersion`; clients must ignore unknown message
/// types.
public enum RemoteGatewayProtocol {
    public static let version = "1.0"
    public static let minimumSupportedVersion = "1.0"
    /// HttpOnly session-credential cookie. Never appears in URLs or bodies.
    public static let credentialCookieName = "toastty_remote_session"
    /// Maximum native-client device name accepted by the shared contract.
    public static let maximumDeviceNameLength = 80
    /// Maximum encoded HTTP request body accepted by the gateway, including
    /// JSON field names, identifiers, and escaped text.
    public static let maximumRequestBodyBytes = 64 * 1024
}

/// Implemented unauthenticated capability hints. Keep this list narrow: the
/// native client must not infer that a future authentication mechanism exists
/// until the host actually implements and advertises it.
public enum RemoteGatewayCapability: String, Codable, Equatable, Hashable, Sendable {
    /// The existing web flow exchanges a short pairing code for an HttpOnly
    /// browser session cookie. This does not imply native Bearer support.
    case browserCookiePairing = "browser_cookie_pairing"
    /// A native client may exchange a Mac-created, short-lived offer for an
    /// opaque Bearer credential bound to its Tailscale login.
    case nativeBearerPairing = "native_bearer_pairing"
    /// Conversation history can be opened at the retained tail and paged
    /// backward without eagerly downloading the whole retained journal.
    case conversationBackwardPaging = "conversation_backward_paging"
    /// A client that has actually displayed the current live edge may clear
    /// the host panel's unread notification state without focusing the Mac.
    case conversationReadAcknowledgement = "conversation_read_acknowledgement"
}

/// Public compatibility probe used before a client has credentials.
public struct RemoteGatewayHelloResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var minimumSupportedProtocolVersion: String
    public var capabilities: [RemoteGatewayCapability]

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        minimumSupportedProtocolVersion: String = RemoteGatewayProtocol.minimumSupportedVersion,
        capabilities: [RemoteGatewayCapability] = [
            .browserCookiePairing,
            .nativeBearerPairing,
            .conversationBackwardPaging,
            .conversationReadAcknowledgement,
        ]
    ) {
        self.protocolVersion = protocolVersion
        self.minimumSupportedProtocolVersion = minimumSupportedProtocolVersion
        self.capabilities = capabilities
    }
}

/// Scanner-safe native pairing data. The long-lived device credential is
/// never part of this payload; `secret` proves only possession of the current
/// two-minute offer.
public struct RemoteNativePairingQRPayload: Codable, Equatable, Sendable {
    public static let formatVersion = 1
    public static let encodedPrefix = "toastty-pairing:v1:"
    public static let maximumEncodedByteCount = 300

    public var formatVersion: Int
    public var gatewayURL: URL
    public var offerID: UUID
    public var secret: String
    public var expiresAt: Date
    public var protocolVersion: String

    public init(
        formatVersion: Int = Self.formatVersion,
        gatewayURL: URL,
        offerID: UUID,
        secret: String,
        expiresAt: Date,
        protocolVersion: String = RemoteGatewayProtocol.version
    ) {
        self.formatVersion = formatVersion
        self.gatewayURL = gatewayURL
        self.offerID = offerID
        self.secret = secret
        self.expiresAt = expiresAt
        self.protocolVersion = protocolVersion
    }

    /// Canonical text placed in the QR image. This is deliberately not an
    /// HTTP URL, keeping the secret out of browser history and access logs.
    public func encodedString() throws -> String {
        let compactFields = [
            String(formatVersion),
            gatewayURL.absoluteString,
            offerID.uuidString.lowercased(),
            secret,
            String(expiresAt.timeIntervalSince1970),
            protocolVersion,
        ]
        let data = try JSONEncoder().encode(compactFields)
        let encoded = Self.encodedPrefix + data.base64URLEncodedString()
        guard encoded.utf8.count <= Self.maximumEncodedByteCount,
              formatVersion == Self.formatVersion,
              protocolVersion == RemoteGatewayProtocol.version,
              Self.isValidGatewayURL(gatewayURL),
              secret.utf8.count == 43,
              Data(base64URLString: secret)?.count == 32 else {
            throw RemoteNativePairingQRPayloadError.invalidPayload
        }
        return encoded
    }

    public init(encodedString: String) throws {
        guard encodedString.utf8.count <= Self.maximumEncodedByteCount,
              encodedString.hasPrefix(Self.encodedPrefix),
              let data = Data(base64URLString: String(encodedString.dropFirst(Self.encodedPrefix.count))) else {
            throw RemoteNativePairingQRPayloadError.invalidEncoding
        }
        let fields = try JSONDecoder().decode([String].self, from: data)
        guard fields.count == 6,
              let formatVersion = Int(fields[0]),
              let gatewayURL = URL(string: fields[1]),
              let offerID = UUID(uuidString: fields[2]),
              let expiresAtInterval = TimeInterval(fields[4]) else {
            throw RemoteNativePairingQRPayloadError.invalidEncoding
        }
        guard formatVersion == Self.formatVersion,
              fields[5] == RemoteGatewayProtocol.version else {
            throw RemoteNativePairingQRPayloadError.unsupportedVersion
        }
        guard Self.isValidGatewayURL(gatewayURL),
              fields[3].utf8.count == 43,
              Data(base64URLString: fields[3])?.count == 32,
              (0...4_102_444_800).contains(expiresAtInterval) else {
            throw RemoteNativePairingQRPayloadError.invalidPayload
        }
        self.init(
            formatVersion: formatVersion,
            gatewayURL: gatewayURL,
            offerID: offerID,
            secret: fields[3],
            expiresAt: Date(timeIntervalSince1970: expiresAtInterval),
            protocolVersion: fields[5]
        )
    }

    private static func isValidGatewayURL(_ url: URL) -> Bool {
        guard url.absoluteString.utf8.count <= 255,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host.hasSuffix(".ts.net"),
              host.count > ".ts.net".count,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.port == nil else {
            return false
        }
        return url.path.isEmpty || url.path == "/"
    }
}

public enum RemoteNativePairingQRPayloadError: Error, Equatable, Sendable {
    case invalidEncoding
    case unsupportedVersion
    case invalidPayload
}

public struct RemoteGatewayNativePairingExchangeRequest: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var deviceName: String
    public var offerID: UUID?
    public var secret: String?
    public var fallbackCode: String?

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        deviceName: String,
        offerID: UUID? = nil,
        secret: String? = nil,
        fallbackCode: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.deviceName = deviceName
        self.offerID = offerID
        self.secret = secret
        self.fallbackCode = fallbackCode
    }

    /// True only for `offerID + secret` xor `fallbackCode`. Callers must still
    /// validate the bounded contents and the active offer server-side.
    public var hasValidProofShape: Bool {
        let hasQRProof = offerID != nil && secret != nil && fallbackCode == nil
        let hasFallbackProof = offerID == nil && secret == nil && fallbackCode != nil
        return hasQRProof != hasFallbackProof
    }
}

public struct RemoteGatewayNativePairingExchangeResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var device: RemoteGatewayDeviceSummary
    public var credentialCreatedAt: Date
    /// Returned exactly once. The host persists only its SHA-256 hash.
    public var credential: String

    public init(device: RemoteGatewayDeviceSummary, credentialCreatedAt: Date, credential: String) {
        self.protocolVersion = RemoteGatewayProtocol.version
        self.device = device
        self.credentialCreatedAt = credentialCreatedAt
        self.credential = credential
    }
}

public struct RemoteGatewayCurrentDeviceResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var device: RemoteGatewayDeviceSummary
    public var credentialCreatedAt: Date

    public init(device: RemoteGatewayDeviceSummary, credentialCreatedAt: Date) {
        self.protocolVersion = RemoteGatewayProtocol.version
        self.device = device
        self.credentialCreatedAt = credentialCreatedAt
    }
}

public struct RemoteGatewayRevokeCurrentDeviceRequest: Codable, Equatable, Sendable {
    public var protocolVersion: String

    public init(protocolVersion: String = RemoteGatewayProtocol.version) {
        self.protocolVersion = protocolVersion
    }
}

public struct RemoteGatewayRevokeCurrentDeviceResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var revokedDeviceID: UUID

    public init(revokedDeviceID: UUID) {
        self.protocolVersion = RemoteGatewayProtocol.version
        self.revokedDeviceID = revokedDeviceID
    }
}

/// Client-facing device view. Never exposes credentials or hashes.
public struct RemoteGatewayDeviceSummary: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var scopes: [RemoteDeviceScope]

    public init(id: UUID, name: String, scopes: [RemoteDeviceScope]) {
        self.id = id
        self.name = name
        self.scopes = scopes.sorted { $0.rawValue < $1.rawValue }
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

/// The exact projection boundary a remote client has displayed. The host
/// accepts this only when it still covers the conversation's current live
/// edge, so a delayed acknowledgement cannot clear newly arrived work.
public struct RemoteConversationReadAcknowledgementRequest: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var conversationID: RemoteConversationID
    public var projectionRunID: RemoteProjectionRunID
    public var projectionGeneration: UInt64
    public var observedThroughSequence: UInt64

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        conversationID: RemoteConversationID,
        projectionRunID: RemoteProjectionRunID,
        projectionGeneration: UInt64,
        observedThroughSequence: UInt64
    ) {
        self.protocolVersion = protocolVersion
        self.conversationID = conversationID
        self.projectionRunID = projectionRunID
        self.projectionGeneration = projectionGeneration
        self.observedThroughSequence = observedThroughSequence
    }
}

public enum RemoteConversationReadAcknowledgementResult: String, Codable, Equatable, Sendable {
    case acknowledged
    case alreadyRead = "already_read"
    case staleBoundary = "stale_boundary"
    case conversationNotFound = "conversation_not_found"
}

public struct RemoteConversationReadAcknowledgementResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var result: RemoteConversationReadAcknowledgementResult

    public init(result: RemoteConversationReadAcknowledgementResult) {
        self.protocolVersion = RemoteGatewayProtocol.version
        self.result = result
    }
}

/// Identity and exclusive upper sequence boundary for backward event paging.
/// This is intentionally distinct from `ConversationEventCursor`: calling a
/// field `afterSequence` while using it as a before-boundary is too easy to
/// apply with the wrong inequality.
public struct ConversationEventBackwardCursor: Codable, Equatable, Sendable {
    public var projectionRunID: RemoteProjectionRunID
    public var projectionGeneration: UInt64
    public var beforeSequence: UInt64

    public init(
        projectionRunID: RemoteProjectionRunID,
        projectionGeneration: UInt64,
        beforeSequence: UInt64
    ) {
        self.projectionRunID = projectionRunID
        self.projectionGeneration = projectionGeneration
        self.beforeSequence = beforeSequence
    }
}

/// Explicit backward-page anchor. Every valid wire object names its intent;
/// a missing cursor can never accidentally turn a load-older request into a
/// tail request.
public enum RemoteGatewayEventsBackwardAnchor: Equatable, Sendable {
    case latest
    case before(ConversationEventBackwardCursor)

    private enum CodingKeys: String, CodingKey {
        case anchor
        case cursor
    }

    private enum Anchor: String, Codable {
        case latest
        case before
    }
}

extension RemoteGatewayEventsBackwardAnchor: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Anchor.self, forKey: .anchor) {
        case .latest:
            guard container.contains(.cursor) == false else {
                throw DecodingError.dataCorruptedError(
                    forKey: .cursor,
                    in: container,
                    debugDescription: "A latest backward anchor cannot include a cursor"
                )
            }
            self = .latest
        case .before:
            self = .before(try container.decode(ConversationEventBackwardCursor.self, forKey: .cursor))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .latest:
            try container.encode(Anchor.latest, forKey: .anchor)
        case .before(let cursor):
            try container.encode(Anchor.before, forKey: .anchor)
            try container.encode(cursor, forKey: .cursor)
        }
    }
}

/// Body of `POST /api/conversation.events.get`.
///
/// Omitting `backward` preserves the original forward-cursor behavior.
/// Backward requests require an explicit bounded `limit`; their events remain
/// ascending on the wire so every consumer has one ordering contract.
public struct RemoteGatewayEventsRequest: Codable, Equatable, Sendable {
    public var conversationID: RemoteConversationID
    public var cursor: ConversationEventCursor?
    public var limit: Int?
    public var backward: RemoteGatewayEventsBackwardAnchor?

    public init(
        conversationID: RemoteConversationID,
        cursor: ConversationEventCursor? = nil,
        limit: Int? = nil,
        backward: RemoteGatewayEventsBackwardAnchor? = nil
    ) {
        self.conversationID = conversationID
        self.cursor = cursor
        self.limit = limit
        self.backward = backward
    }

    private enum CodingKeys: String, CodingKey {
        case conversationID
        case cursor
        case limit
        case backward
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = try container.decode(RemoteConversationID.self, forKey: .conversationID)
        cursor = try container.decodeIfPresent(ConversationEventCursor.self, forKey: .cursor)
        limit = try container.decodeIfPresent(Int.self, forKey: .limit)
        if container.contains(.backward) {
            // Explicit null is invalid rather than silently becoming a forward
            // request on a client encoding bug.
            backward = try container.decode(RemoteGatewayEventsBackwardAnchor.self, forKey: .backward)
            guard container.contains(.cursor) == false else {
                throw DecodingError.dataCorruptedError(
                    forKey: .cursor,
                    in: container,
                    debugDescription: "Forward and backward cursors are mutually exclusive"
                )
            }
        } else {
            backward = nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(conversationID, forKey: .conversationID)
        try container.encodeIfPresent(cursor, forKey: .cursor)
        try container.encodeIfPresent(limit, forKey: .limit)
        try container.encodeIfPresent(backward, forKey: .backward)
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
