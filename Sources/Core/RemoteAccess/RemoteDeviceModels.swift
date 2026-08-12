import Foundation
import RemoteProtocol

public enum RemoteDeviceAuthKind: String, Codable, Equatable, Sendable {
    case browser
    case native
}

public struct RemoteDeviceRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var scopes: Set<RemoteDeviceScope>
    public var authKind: RemoteDeviceAuthKind
    /// Exact Tailscale identity for a native credential. It is confined to the
    /// protected 0600 store and must never enter client responses, routine
    /// logs, audit details, or diagnostics. Legacy/browser devices use nil.
    public var tailscaleLogin: String?
    public var createdAt: Date
    public var lastSeenAt: Date?
    public var revokedAt: Date?

    public var isRevoked: Bool { revokedAt != nil }

    public init(
        id: UUID = UUID(),
        name: String,
        scopes: Set<RemoteDeviceScope> = [.read],
        authKind: RemoteDeviceAuthKind = .browser,
        tailscaleLogin: String? = nil,
        createdAt: Date,
        lastSeenAt: Date? = nil,
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.scopes = scopes
        self.authKind = authKind
        self.tailscaleLogin = tailscaleLogin
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.revokedAt = revokedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, scopes, authKind, tailscaleLogin, createdAt, lastSeenAt, revokedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        scopes = try container.decode(Set<RemoteDeviceScope>.self, forKey: .scopes)
        authKind = try container.decodeIfPresent(RemoteDeviceAuthKind.self, forKey: .authKind) ?? .browser
        tailscaleLogin = try container.decodeIfPresent(String.self, forKey: .tailscaleLogin)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastSeenAt = try container.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        revokedAt = try container.decodeIfPresent(Date.self, forKey: .revokedAt)

        guard Self.isValidPersistedName(name), scopes.count <= RemoteDeviceScope.allCases.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .name,
                in: container,
                debugDescription: "Remote device record exceeds its storage bounds"
            )
        }
        if authKind == .native {
            guard let tailscaleLogin, Self.isValidTailscaleLogin(tailscaleLogin) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .tailscaleLogin,
                    in: container,
                    debugDescription: "Native device record requires a bounded Tailscale login"
                )
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(scopes, forKey: .scopes)
        try container.encode(authKind, forKey: .authKind)
        try container.encodeIfPresent(tailscaleLogin, forKey: .tailscaleLogin)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastSeenAt, forKey: .lastSeenAt)
        try container.encodeIfPresent(revokedAt, forKey: .revokedAt)
    }

    static func isValidTailscaleLogin(_ value: String) -> Bool {
        value.isEmpty == false
            && value.utf8.count <= RemoteDeviceStore.maximumTailscaleLoginByteCount
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) == false }
    }

    private static func isValidPersistedName(_ value: String) -> Bool {
        value.isEmpty == false
            && value.count <= RemoteGatewayProtocol.maximumDeviceNameLength
            && value.utf8.count <= RemoteDeviceStore.maximumDeviceNameByteCount
            && value.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) == false }
    }
}

/// Only the SHA-256 hash of the 32-byte token is persisted; the token itself
/// is returned exactly once when the device pairs.
public struct RemoteDeviceCredentialRecord: Codable, Equatable, Sendable {
    public var credentialHash: String
    public var deviceID: UUID
    public var issuedAt: Date

    public init(credentialHash: String, deviceID: UUID, issuedAt: Date) {
        self.credentialHash = credentialHash
        self.deviceID = deviceID
        self.issuedAt = issuedAt
    }

    private enum CodingKeys: String, CodingKey { case credentialHash, deviceID, issuedAt }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        credentialHash = try container.decode(String.self, forKey: .credentialHash)
        deviceID = try container.decode(UUID.self, forKey: .deviceID)
        issuedAt = try container.decode(Date.self, forKey: .issuedAt)
        guard credentialHash.count == 64,
              credentialHash.unicodeScalars.allSatisfy({
                  ("0"..."9").contains(Character($0)) || ("a"..."f").contains(Character($0))
              }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .credentialHash,
                in: container,
                debugDescription: "Invalid credential hash"
            )
        }
    }
}

public struct RemotePairingCode: Codable, Equatable, Sendable {
    public static let timeToLive: TimeInterval = 300
    public var code: String
    public var createdAt: Date
    public var expiresAt: Date

    public init(code: String, createdAt: Date) {
        self.code = code
        self.createdAt = createdAt
        self.expiresAt = createdAt.addingTimeInterval(Self.timeToLive)
    }

    public func isValid(at date: Date) -> Bool { date < expiresAt }
}

public struct RemoteNativePairingOffer: Equatable, Sendable, Identifiable {
    public static let timeToLive: TimeInterval = 120
    public var id: UUID
    public var qrPayload: RemoteNativePairingQRPayload
    public var fallbackCode: String
    public var createdAt: Date
    public var expiresAt: Date

    public func isValid(at date: Date) -> Bool { date < expiresAt }
}

public enum RemoteNativePairingProof: Equatable, Sendable {
    case qr(offerID: UUID, secret: String)
    case fallbackCode(String)
}

public enum RemoteNativePairingOfferError: Error, Equatable, Sendable {
    case invalidGatewayURL
}

/// Identity-scoped brute-force state in the same protected store as native
/// device identity. It never contains pairing or credential material.
public struct RemoteNativePairingFailureRecord: Codable, Equatable, Sendable {
    public var tailscaleLogin: String
    public var failureTimes: [Date]
    public var lockedOutUntil: Date?
    public var updatedAt: Date

    public init(
        tailscaleLogin: String,
        failureTimes: [Date] = [],
        lockedOutUntil: Date? = nil,
        updatedAt: Date
    ) {
        self.tailscaleLogin = tailscaleLogin
        self.failureTimes = failureTimes
        self.lockedOutUntil = lockedOutUntil
        self.updatedAt = updatedAt
    }
}

public enum RemoteDeviceStorePersistenceError: Error, Equatable, Sendable {
    case unreadableSource
    case encodedStateTooLarge
}
