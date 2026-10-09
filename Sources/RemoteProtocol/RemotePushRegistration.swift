import Foundation

public enum RemotePushAPNsEnvironment: String, Codable, Equatable, Sendable {
    case development
    case production
}

public enum RemotePushPolicy {
    public static let maximumBodyBytes = 4 * 1024
    public static let maximumTitleBytes = 512
    public static let developmentRelayID = "toastty-push-dev-v1"
    public static let configurationPath = "/v1/native-device/push-configuration"
    public static let registrationPath = "/v1/native-device/push"

    public static func isValidCapabilityToken(_ token: String) -> Bool {
        guard token.utf8.count == 43,
              let bytes = Data(base64URLString: token), bytes.count == 32 else { return false }
        return bytes.base64URLEncodedString() == token
    }

    /// Keep complete characters in the alert and omit characters that can
    /// change how notification text is displayed.
    public static func notificationTitle(_ title: String) -> String {
        let clean = String(String.UnicodeScalarView(title.unicodeScalars.filter {
            switch $0.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: false
            default: true
            }
        }))
        var result = ""
        for character in clean {
            guard result.utf8.count + String(character).utf8.count <= maximumTitleBytes else { break }
            result.append(character)
        }
        return result.isEmpty ? "Toastty session" : result
    }
}

public struct RemoteGatewayPushConfigurationResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var relayID: String?
    public var apnsEnvironment: RemotePushAPNsEnvironment?
    public var registrationID: UUID?

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        relayID: String? = nil,
        apnsEnvironment: RemotePushAPNsEnvironment? = nil,
        registrationID: UUID? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.relayID = relayID
        self.apnsEnvironment = apnsEnvironment
        self.registrationID = registrationID
    }

    private enum CodingKeys: String, CodingKey { case protocolVersion, relayID, apnsEnvironment, registrationID }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encodeIfPresent(relayID, forKey: .relayID)
        try container.encodeIfPresent(apnsEnvironment, forKey: .apnsEnvironment)
        try container.encode(registrationID, forKey: .registrationID)
    }
}

/// Returned by the phone only after its relay delivery proof is complete.
/// The host derives the paired device identity from native authentication.
public struct RemoteGatewayPushRegistration: Codable, Equatable, Sendable {
    public var registrationID: UUID
    public var sendToken: String
    public var relayID: String

    public init(registrationID: UUID, sendToken: String, relayID: String) {
        self.registrationID = registrationID
        self.sendToken = sendToken
        self.relayID = relayID
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case registrationID, sendToken, relayID }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownPushFields(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        registrationID = try container.decode(UUID.self, forKey: .registrationID)
        sendToken = try container.decode(String.self, forKey: .sendToken)
        relayID = try container.decode(String.self, forKey: .relayID)
    }
}

public struct RemoteGatewayPushRegistrationRequest: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var registration: RemoteGatewayPushRegistration?

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        registration: RemoteGatewayPushRegistration?
    ) {
        self.protocolVersion = protocolVersion
        self.registration = registration
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case protocolVersion, registration }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownPushFields(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
        guard container.contains(.registration) else {
            throw DecodingError.keyNotFound(CodingKeys.registration, .init(codingPath: decoder.codingPath, debugDescription: "Missing registration"))
        }
        registration = try container.decodeIfPresent(RemoteGatewayPushRegistration.self, forKey: .registration)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(registration, forKey: .registration)
    }
}

public struct RemoteGatewayPushRegistrationResponse: Codable, Equatable, Sendable {
    public var protocolVersion: String
    public var registrationID: UUID?

    public init(
        protocolVersion: String = RemoteGatewayProtocol.version,
        registrationID: UUID?
    ) {
        self.protocolVersion = protocolVersion
        self.registrationID = registrationID
    }

    private enum CodingKeys: String, CodingKey { case protocolVersion, registrationID }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(registrationID, forKey: .registrationID)
    }
}

public enum RemotePushSessionStatus: String, Codable, Equatable, Sendable {
    case ready
    case needsApproval = "needs_approval"
}

public struct RemotePushSessionNotification: Codable, Equatable, Sendable {
    public var eventID: UUID
    public var conversationID: RemoteConversationID
    public var sessionTitle: String
    public var status: RemotePushSessionStatus

    public init(eventID: UUID, conversationID: RemoteConversationID, sessionTitle: String, status: RemotePushSessionStatus) {
        self.eventID = eventID
        self.conversationID = conversationID
        self.sessionTitle = RemotePushPolicy.notificationTitle(sessionTitle)
        self.status = status
    }
}

public enum RemotePushPayloadKind: String, Codable, Equatable, Sendable {
    case verification
    case session
}

/// The bounded `toastty` object inside an APNs alert. Notification taps use
/// pairing identity; a token renewal does not invalidate older session alerts.
public struct RemotePushPayload: Codable, Equatable, Sendable {
    public var version: Int
    public var kind: RemotePushPayloadKind
    public var registrationID: UUID
    public var pairingID: UUID
    public var nonce: String?
    public var conversationID: RemoteConversationID?
    public var eventID: UUID?

    public init(
        version: Int = 1,
        kind: RemotePushPayloadKind,
        registrationID: UUID,
        pairingID: UUID,
        nonce: String? = nil,
        conversationID: RemoteConversationID? = nil,
        eventID: UUID? = nil
    ) {
        self.version = version
        self.kind = kind
        self.registrationID = registrationID
        self.pairingID = pairingID
        self.nonce = nonce
        self.conversationID = conversationID
        self.eventID = eventID
    }

    public var isValid: Bool {
        guard version == 1 else { return false }
        switch kind {
        case .verification:
            return nonce.map(RemotePushPolicy.isValidCapabilityToken) == true && conversationID == nil && eventID == nil
        case .session:
            return nonce == nil && conversationID != nil && eventID != nil
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, kind, registrationID, pairingID, nonce, conversationID, eventID
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownPushFields(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        kind = try container.decode(RemotePushPayloadKind.self, forKey: .kind)
        registrationID = try container.decode(UUID.self, forKey: .registrationID)
        pairingID = try container.decode(UUID.self, forKey: .pairingID)
        nonce = try container.decodeIfPresent(String.self, forKey: .nonce)
        conversationID = try container.decodeIfPresent(RemoteConversationID.self, forKey: .conversationID)
        eventID = try container.decodeIfPresent(UUID.self, forKey: .eventID)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid push payload"))
        }
    }
}

private struct PushCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectUnknownPushFields(_ decoder: any Decoder, allowed: [String]) throws {
    let container = try decoder.container(keyedBy: PushCodingKey.self)
    guard container.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown push field"))
    }
}
