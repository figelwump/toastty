import Foundation
import CryptoKit
import RemoteProtocol

public struct RemoteDeviceRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var scopes: Set<RemoteDeviceScope>
    public var createdAt: Date
    public var lastSeenAt: Date?
    public var revokedAt: Date?

    public var isRevoked: Bool {
        revokedAt != nil
    }

    public init(
        id: UUID = UUID(),
        name: String,
        scopes: Set<RemoteDeviceScope> = [.read],
        createdAt: Date,
        lastSeenAt: Date? = nil,
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.scopes = scopes
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.revokedAt = revokedAt
    }
}

/// A stored session credential. Only the SHA-256 hash of the token is
/// persisted; the token itself exists once, in the HttpOnly cookie handed to
/// the device at pairing time.
public struct RemoteDeviceCredentialRecord: Codable, Equatable, Sendable {
    public var credentialHash: String
    public var deviceID: UUID
    public var issuedAt: Date

    public init(credentialHash: String, deviceID: UUID, issuedAt: Date) {
        self.credentialHash = credentialHash
        self.deviceID = deviceID
        self.issuedAt = issuedAt
    }
}

/// A short-lived, single-use pairing code displayed on the Mac.
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

    public func isValid(at date: Date) -> Bool {
        date < expiresAt
    }
}

/// Persisted device/credential state for the remote-access gateway.
///
/// Storage is a single JSON file (0600) under the Toastty runtime home. The
/// store is deliberately not thread-safe; the App hosts it on the main actor
/// behind the gateway's request handling.
public final class RemoteDeviceStore {
    public struct State: Codable, Equatable, Sendable {
        public var devices: [RemoteDeviceRecord]
        public var credentials: [RemoteDeviceCredentialRecord]

        public init(devices: [RemoteDeviceRecord] = [], credentials: [RemoteDeviceCredentialRecord] = []) {
            self.devices = devices
            self.credentials = credentials
        }
    }

    public enum PairingOutcome: Equatable, Sendable {
        case paired(device: RemoteDeviceRecord, credentialToken: String)
        case invalidCode
    }

    typealias PersistenceWriter = @Sendable (State, URL) throws -> Void

    private(set) var state: State
    private var activePairingCode: RemotePairingCode?
    private let fileURL: URL?
    private let persistenceWriter: PersistenceWriter
    private let persistenceQueue = DispatchQueue(label: "toastty.remote-access.device-store")
    private var lastPersistedLastSeenAtByDeviceID: [UUID: Date]
    private static let lastSeenPersistenceInterval: TimeInterval = 60

    /// Loads persisted state from `fileURL`, starting empty when the file does
    /// not exist or cannot be decoded (corrupt state must never brick the
    /// gateway — devices can re-pair). Pass nil for an in-memory store (tests).
    public convenience init(fileURL: URL?) {
        self.init(fileURL: fileURL, persistenceWriter: Self.writeState)
    }

    init(fileURL: URL?, persistenceWriter: @escaping PersistenceWriter) {
        self.fileURL = fileURL
        self.persistenceWriter = persistenceWriter
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(State.self, from: data) {
            self.state = decoded
        } else {
            self.state = State()
        }
        self.lastPersistedLastSeenAtByDeviceID = Dictionary(
            uniqueKeysWithValues: state.devices.compactMap { device in
                device.lastSeenAt.map { (device.id, $0) }
            }
        )
    }

    // MARK: - Pairing

    /// Creates (and displays) a fresh pairing code, replacing any outstanding
    /// one — at most one code is redeemable at a time.
    public func issuePairingCode(at date: Date) -> RemotePairingCode {
        let code = RemotePairingCode(code: Self.generatePairingCode(), createdAt: date)
        activePairingCode = code
        return code
    }

    public func invalidatePairingCode() {
        activePairingCode = nil
    }

    public var hasActivePairingCode: Bool {
        activePairingCode != nil
    }

    /// Redeems a pairing code for a new read-and-send device and its credential
    /// token. The code is single-use: it is consumed on success and on any
    /// failed attempt it stays valid until expiry (rate limiting is the
    /// caller's responsibility).
    public func redeemPairingCode(
        _ presented: String,
        deviceName: String,
        at date: Date
    ) throws -> PairingOutcome {
        guard let active = activePairingCode,
              active.isValid(at: date),
              Self.constantTimeEquals(active.code, Self.normalizePairingCode(presented)) else {
            return .invalidCode
        }

        let trimmedName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = RemoteDeviceRecord(
            name: trimmedName.isEmpty ? "Unnamed device" : String(trimmedName.prefix(80)),
            scopes: [.read, .send],
            createdAt: date,
            lastSeenAt: date
        )
        let token = Self.generateCredentialToken()
        var nextState = state
        nextState.devices.append(device)
        nextState.credentials.append(RemoteDeviceCredentialRecord(
            credentialHash: Self.hashToken(token),
            deviceID: device.id,
            issuedAt: date
        ))
        try persistSynchronously(nextState)
        state = nextState
        lastPersistedLastSeenAtByDeviceID[device.id] = date
        activePairingCode = nil
        return .paired(device: device, credentialToken: token)
    }

    // MARK: - Authentication

    /// Resolves a presented credential token to its non-revoked device,
    /// updating last-seen. Returns nil for unknown tokens and revoked devices.
    public func authenticate(credentialToken: String, at date: Date) -> RemoteDeviceRecord? {
        let hash = Self.hashToken(credentialToken)
        guard let credential = state.credentials.first(where: { Self.constantTimeEquals($0.credentialHash, hash) }),
              let deviceIndex = state.devices.firstIndex(where: { $0.id == credential.deviceID }),
              state.devices[deviceIndex].isRevoked == false else {
            return nil
        }
        state.devices[deviceIndex].lastSeenAt = date
        let deviceID = state.devices[deviceIndex].id
        let lastPersistedAt = lastPersistedLastSeenAtByDeviceID[deviceID] ?? .distantPast
        if date.timeIntervalSince(lastPersistedAt) >= Self.lastSeenPersistenceInterval {
            lastPersistedLastSeenAtByDeviceID[deviceID] = date
            persistEventually(state)
        }
        return state.devices[deviceIndex]
    }

    // MARK: - Management

    public var devices: [RemoteDeviceRecord] {
        state.devices
    }

    @discardableResult
    public func setScopes(_ scopes: Set<RemoteDeviceScope>, forDevice deviceID: UUID) throws -> Bool {
        guard let index = state.devices.firstIndex(where: { $0.id == deviceID }) else { return false }
        // Read scope is not removable; a device without read is a revocation.
        let normalizedScopes = scopes.union([.read])
        guard state.devices[index].scopes != normalizedScopes else { return false }
        var nextState = state
        nextState.devices[index].scopes = normalizedScopes
        try persistSynchronously(nextState)
        state = nextState
        return true
    }

    @discardableResult
    public func revokeDevice(_ deviceID: UUID, at date: Date) throws -> Bool {
        guard let index = state.devices.firstIndex(where: { $0.id == deviceID }),
              state.devices[index].isRevoked == false else {
            return false
        }
        var nextState = state
        nextState.devices[index].revokedAt = date
        nextState.credentials.removeAll { $0.deviceID == deviceID }
        try persistSynchronously(nextState)
        state = nextState
        lastPersistedLastSeenAtByDeviceID.removeValue(forKey: deviceID)
        return true
    }

    public func revokeAllDevices(at date: Date) throws {
        var nextState = state
        for index in nextState.devices.indices where nextState.devices[index].isRevoked == false {
            nextState.devices[index].revokedAt = date
        }
        nextState.credentials.removeAll()
        try persistSynchronously(nextState)
        state = nextState
        activePairingCode = nil
        lastPersistedLastSeenAtByDeviceID.removeAll()
    }

    // MARK: - Internals

    private func persistSynchronously(_ state: State) throws {
        guard let fileURL else { return }
        let persistenceWriter = persistenceWriter
        try persistenceQueue.sync {
            try persistenceWriter(state, fileURL)
        }
    }

    private func persistEventually(_ state: State) {
        guard let fileURL else { return }
        let persistenceWriter = persistenceWriter
        persistenceQueue.async {
            do {
                try persistenceWriter(state, fileURL)
            } catch {
                ToasttyLog.error(
                    "Failed to persist remote device last-seen state",
                    category: .automation,
                    metadata: ["error": "\(error)"]
                )
            }
        }
    }

    private static func writeState(_ state: State, to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    static func hashToken(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func generateCredentialToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Unambiguous uppercase alphabet (no 0/O/1/I/L), grouped for readability.
    static func generatePairingCode() -> String {
        let alphabet = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")
        var generator = SystemRandomNumberGenerator()
        let characters = (0..<8).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] }
        return String(characters[0..<4]) + "-" + String(characters[4..<8])
    }

    static func normalizePairingCode(_ presented: String) -> String {
        let stripped = presented
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
        guard stripped.count == 8 else { return presented.uppercased() }
        let characters = Array(stripped)
        return String(characters[0..<4]) + "-" + String(characters[4..<8])
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else { return false }
        var difference: UInt8 = 0
        for index in lhsBytes.indices {
            difference |= lhsBytes[index] ^ rhsBytes[index]
        }
        return difference == 0
    }
}
