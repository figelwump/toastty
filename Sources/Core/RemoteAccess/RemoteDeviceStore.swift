import CryptoKit
import Darwin
import Foundation
import RemoteProtocol

/// Persisted device/credential state for the remote-access gateway.
///
/// Storage is one JSON file (0600) under the Toastty runtime home. Mutations
/// are serialized so a native offer has exactly one redemption winner even
/// when concurrent gateway requests reach the store. Security-relevant state
/// is written durably before the corresponding in-memory transition.
public final class RemoteDeviceStore: @unchecked Sendable {
    public static let maximumDeviceCount = 128
    public static let maximumCredentialCount = 256
    public static let maximumDeviceNameByteCount = 320
    public static let maximumTailscaleLoginByteCount = 320
    public static let maximumCredentialTokenByteCount = 43
    public static let maximumNativePairingProofByteCount = 256
    public static let maximumNativeFailureIdentityCount = 128
    public static let maximumPersistedStateByteCount = 2 * 1_024 * 1_024

    public enum PairingOutcome: Equatable, Sendable {
        case paired(device: RemoteDeviceRecord, credentialToken: String)
        case invalidCode
        case deviceLimitReached
    }

    public enum NativePairingOutcome: Equatable, Sendable {
        case paired(device: RemoteDeviceRecord, credentialToken: String)
        /// Unknown, malformed, expired, consumed, and wrong proofs all share
        /// this outcome so callers cannot use the endpoint as an oracle.
        case invalidOffer
        case lockedOut(until: Date)
        case invalidDeviceName
        case deviceLimitReached
    }

    public enum NativeAuthenticationOutcome: Equatable, Sendable {
        case authenticated(RemoteDeviceRecord)
        case invalidCredential
        case identityMismatch
    }

    typealias PersistenceWriter = @Sendable (State, URL) throws -> Void

    static let maximumNativePairingFailureTimes = 6
    static let maximumQuarantinedRecordCount = 128
    private static let nativePairingFailureWindow: TimeInterval = 60
    private static let nativePairingLockoutDuration: TimeInterval = 300
    private static let nativePairingMaximumFailures = 5
    private static let nativeFailureRetention: TimeInterval = 86_400
    private static let lastSeenPersistenceInterval: TimeInterval = 60

    private var storedState: State
    private let hasUnreadablePersistentSource: Bool
    private var activePairingCode: RemotePairingCode?
    private var activeNativeOffer: RemoteNativePairingOffer?
    private let fileURL: URL?
    private let persistenceWriter: PersistenceWriter
    private let persistenceQueue = DispatchQueue(label: "toastty.remote-access.device-store.persistence")
    private let stateLock = NSLock()
    private var lastPersistedLastSeenAtByDeviceID: [UUID: Date]

    /// Loads valid records individually. A malformed native record is ignored
    /// without discarding valid legacy/browser neighbors or rewriting the
    /// source file merely because the store was opened.
    public convenience init(fileURL: URL?) {
        self.init(fileURL: fileURL, persistenceWriter: Self.writeState)
    }

    init(fileURL: URL?, persistenceWriter: @escaping PersistenceWriter) {
        self.fileURL = fileURL
        self.persistenceWriter = persistenceWriter
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize,
               size <= Self.maximumPersistedStateByteCount,
               let data = try? Data(contentsOf: fileURL),
               let decoded = try? JSONDecoder().decode(State.self, from: data) {
                storedState = decoded
                hasUnreadablePersistentSource = false
            } else {
                storedState = State()
                hasUnreadablePersistentSource = true
            }
        } else {
            storedState = State()
            hasUnreadablePersistentSource = false
        }
        lastPersistedLastSeenAtByDeviceID = storedState.devices.reduce(into: [:]) { result, device in
            if result[device.id] == nil, let lastSeenAt = device.lastSeenAt {
                result[device.id] = lastSeenAt
            }
        }
    }

    var state: State {
        withStateLock { storedState }
    }

    // MARK: - Browser pairing

    public func issuePairingCode(at date: Date) -> RemotePairingCode {
        withStateLock {
            let code = RemotePairingCode(code: Self.generatePairingCode(), createdAt: date)
            activePairingCode = code
            return code
        }
    }

    public func invalidatePairingCode() {
        withStateLock { activePairingCode = nil }
    }

    public var hasActivePairingCode: Bool {
        withStateLock { activePairingCode != nil }
    }

    public func redeemPairingCode(
        _ presented: String,
        deviceName: String,
        at date: Date
    ) throws -> PairingOutcome {
        try withStateLock {
            guard let active = activePairingCode,
                  active.isValid(at: date),
                  Self.constantTimeEquals(active.code, Self.normalizePairingCode(presented)) else {
                return .invalidCode
            }
            guard let nextBaseState = statePreparedForNewDevice(from: storedState) else {
                return .deviceLimitReached
            }

            let device = RemoteDeviceRecord(
                name: Self.normalizedBrowserDeviceName(deviceName),
                scopes: [.read, .send],
                authKind: .browser,
                createdAt: date,
                lastSeenAt: date
            )
            let token = Self.generateCredentialToken()
            var nextState = nextBaseState
            nextState.devices.append(device)
            nextState.credentials.append(RemoteDeviceCredentialRecord(
                credentialHash: Self.hashToken(token),
                deviceID: device.id,
                issuedAt: date
            ))
            try persistSynchronously(nextState)
            storedState = nextState
            lastPersistedLastSeenAtByDeviceID[device.id] = date
            activePairingCode = nil
            return .paired(device: device, credentialToken: token)
        }
    }

    // MARK: - Native pairing

    /// Creates a new native offer, atomically replacing any earlier native
    /// offer. Browser pairing is a separate flow and remains untouched.
    public func issueNativePairingOffer(gatewayURL: URL, at date: Date) throws -> RemoteNativePairingOffer {
        guard Self.isValidGatewayOrigin(gatewayURL) else {
            throw RemoteNativePairingOfferError.invalidGatewayURL
        }
        let offerID = UUID()
        let expiresAt = date.addingTimeInterval(RemoteNativePairingOffer.timeToLive)
        let payload = RemoteNativePairingQRPayload(
            gatewayURL: gatewayURL,
            offerID: offerID,
            secret: Self.generateCredentialToken(),
            expiresAt: expiresAt
        )
        guard (try? payload.encodedString()) != nil else {
            throw RemoteNativePairingOfferError.invalidGatewayURL
        }
        let offer = RemoteNativePairingOffer(
            id: offerID,
            qrPayload: payload,
            fallbackCode: Self.generateNativeFallbackCode(),
            createdAt: date,
            expiresAt: expiresAt
        )
        return withStateLock {
            activeNativeOffer = offer
            return offer
        }
    }

    public func cancelNativePairingOffer() {
        withStateLock { activeNativeOffer = nil }
    }

    /// The returned expiry is advisory UI state. Redemption rechecks the
    /// authoritative in-memory offer and current server time.
    public func activeNativePairingOffer(at date: Date) -> RemoteNativePairingOffer? {
        withStateLock {
            currentNativePairingOffer(at: date)
        }
    }

    public func redeemNativePairingOffer(
        using proof: RemoteNativePairingProof,
        deviceName: String,
        tailscaleLogin: String,
        at date: Date
    ) throws -> NativePairingOutcome {
        guard RemoteDeviceRecord.isValidTailscaleLogin(tailscaleLogin) else {
            return .invalidOffer
        }
        guard let normalizedName = Self.validatedNativeDeviceName(deviceName) else {
            return .invalidDeviceName
        }

        return try withStateLock {
            let offer = currentNativePairingOffer(at: date)
            if let lockedOutUntil = nativeLockoutDate(for: tailscaleLogin, at: date) {
                return .lockedOut(until: lockedOutUntil)
            }

            guard let offer, Self.nativeProof(proof, matches: offer) else {
                let outcome = try recordNativePairingFailure(for: tailscaleLogin, at: date)
                return outcome
            }
            guard let nextBaseState = statePreparedForNewDevice(from: storedState) else {
                return .deviceLimitReached
            }

            let device = RemoteDeviceRecord(
                name: normalizedName,
                scopes: [.read, .send],
                authKind: .native,
                tailscaleLogin: tailscaleLogin,
                createdAt: date,
                lastSeenAt: date
            )
            let token = Self.generateCredentialToken()
            var nextState = nextBaseState
            nextState.devices.append(device)
            nextState.credentials.append(RemoteDeviceCredentialRecord(
                credentialHash: Self.hashToken(token),
                deviceID: device.id,
                issuedAt: date
            ))
            nextState.nativePairingFailures.removeAll {
                Self.constantTimeEquals($0.tailscaleLogin, tailscaleLogin)
            }

            // The offer remains redeemable if this write throws. Only the
            // durable success consumes both the QR and fallback proof paths.
            try persistSynchronously(nextState)
            storedState = nextState
            lastPersistedLastSeenAtByDeviceID[device.id] = date
            activeNativeOffer = nil
            return .paired(device: device, credentialToken: token)
        }
    }

    // MARK: - Authentication

    /// Browser-cookie authentication. Native bearer credentials always fail
    /// this API even if a caller accidentally presents one as a cookie.
    public func authenticateBrowserCredential(_ credentialToken: String, at date: Date) -> RemoteDeviceRecord? {
        authenticateCredential(credentialToken, requiredAuthKind: .browser, at: date)
    }

    /// Compatibility alias for the existing browser gateway.
    public func authenticate(credentialToken: String, at date: Date) -> RemoteDeviceRecord? {
        authenticateBrowserCredential(credentialToken, at: date)
    }

    /// Native bearer authentication enforces both the credential and the exact
    /// case-sensitive Tailscale login recorded at pairing.
    public func authenticateNativeBearer(
        _ credentialToken: String,
        tailscaleLogin: String,
        at date: Date
    ) -> NativeAuthenticationOutcome {
        guard Self.isBoundedCredentialToken(credentialToken),
              RemoteDeviceRecord.isValidTailscaleLogin(tailscaleLogin) else {
            return .invalidCredential
        }
        let hash = Self.hashToken(credentialToken)
        var persistenceError: Error?
        let outcome: NativeAuthenticationOutcome = withStateLock {
            guard let credential = storedState.credentials.first(where: {
                Self.constantTimeEquals($0.credentialHash, hash)
            }),
            let deviceIndex = storedState.devices.firstIndex(where: {
                $0.id == credential.deviceID && $0.authKind == .native
            }),
            storedState.devices[deviceIndex].isRevoked == false else {
                return .invalidCredential
            }
            guard let expectedLogin = storedState.devices[deviceIndex].tailscaleLogin,
                  Self.constantTimeEquals(expectedLogin, tailscaleLogin) else {
                return .identityMismatch
            }
            updateLastSeen(deviceIndex: deviceIndex, at: date, persistenceError: &persistenceError)
            return .authenticated(storedState.devices[deviceIndex])
        }
        if let persistenceError {
            logLastSeenPersistenceError(persistenceError)
        }
        return outcome
    }

    // MARK: - Management

    public var devices: [RemoteDeviceRecord] {
        withStateLock { storedState.devices }
    }

    @discardableResult
    public func setScopes(_ scopes: Set<RemoteDeviceScope>, forDevice deviceID: UUID) throws -> Bool {
        try withStateLock {
            guard let index = storedState.devices.firstIndex(where: { $0.id == deviceID }) else { return false }
            let normalizedScopes = scopes.union([.read])
            guard storedState.devices[index].scopes != normalizedScopes else { return false }
            var nextState = storedState
            nextState.devices[index].scopes = normalizedScopes
            try persistSynchronously(nextState)
            storedState = nextState
            return true
        }
    }

    @discardableResult
    public func revokeDevice(_ deviceID: UUID, at date: Date) throws -> Bool {
        try withStateLock {
            guard let index = storedState.devices.firstIndex(where: { $0.id == deviceID }),
                  storedState.devices[index].isRevoked == false else {
                return false
            }
            var nextState = storedState
            nextState.devices[index].revokedAt = date
            nextState.credentials.removeAll { $0.deviceID == deviceID }
            try persistSynchronously(nextState)
            storedState = nextState
            lastPersistedLastSeenAtByDeviceID.removeValue(forKey: deviceID)
            return true
        }
    }

    public func revokeAllDevices(at date: Date) throws {
        try withStateLock {
            var nextState = storedState
            for index in nextState.devices.indices where nextState.devices[index].isRevoked == false {
                nextState.devices[index].revokedAt = date
            }
            nextState.credentials.removeAll()
            try persistSynchronously(nextState)
            storedState = nextState
            activePairingCode = nil
            activeNativeOffer = nil
            lastPersistedLastSeenAtByDeviceID.removeAll()
        }
    }

    // MARK: - Internals

    private func authenticateCredential(
        _ credentialToken: String,
        requiredAuthKind: RemoteDeviceAuthKind,
        at date: Date
    ) -> RemoteDeviceRecord? {
        guard Self.isBoundedCredentialToken(credentialToken) else { return nil }
        let hash = Self.hashToken(credentialToken)
        var persistenceError: Error?
        let device: RemoteDeviceRecord? = withStateLock {
            guard let credential = storedState.credentials.first(where: {
                Self.constantTimeEquals($0.credentialHash, hash)
            }),
            let deviceIndex = storedState.devices.firstIndex(where: {
                $0.id == credential.deviceID && $0.authKind == requiredAuthKind
            }),
            storedState.devices[deviceIndex].isRevoked == false else {
                return nil
            }
            updateLastSeen(deviceIndex: deviceIndex, at: date, persistenceError: &persistenceError)
            return storedState.devices[deviceIndex]
        }
        if let persistenceError {
            logLastSeenPersistenceError(persistenceError)
        }
        return device
    }

    private func updateLastSeen(deviceIndex: Int, at date: Date, persistenceError: inout Error?) {
        let deviceID = storedState.devices[deviceIndex].id
        let lastPersistedAt = lastPersistedLastSeenAtByDeviceID[deviceID] ?? .distantPast
        guard date.timeIntervalSince(lastPersistedAt) >= Self.lastSeenPersistenceInterval else {
            storedState.devices[deviceIndex].lastSeenAt = date
            return
        }

        var nextState = storedState
        nextState.devices[deviceIndex].lastSeenAt = date
        do {
            try persistSynchronously(nextState)
            storedState = nextState
            lastPersistedLastSeenAtByDeviceID[deviceID] = date
        } catch {
            persistenceError = error
        }
    }

    private func logLastSeenPersistenceError(_ error: Error) {
        ToasttyLog.error(
            "Failed to persist remote device last-seen state",
            category: .automation,
            // Error descriptions may embed the private runtime-home path.
            // Keep routine diagnostics categorical and path-free.
            metadata: ["error_type": String(reflecting: type(of: error))]
        )
    }

    private func nativeLockoutDate(for tailscaleLogin: String, at date: Date) -> Date? {
        storedState.nativePairingFailures.first(where: {
            Self.constantTimeEquals($0.tailscaleLogin, tailscaleLogin)
        })?.lockedOutUntil.flatMap { date < $0 ? $0 : nil }
    }

    private func recordNativePairingFailure(
        for tailscaleLogin: String,
        at date: Date
    ) throws -> NativePairingOutcome {
        var nextState = storedState
        Self.pruneNativeFailures(in: &nextState, at: date)
        let windowStart = date.addingTimeInterval(-Self.nativePairingFailureWindow)
        let index: Int
        if let existing = nextState.nativePairingFailures.firstIndex(where: {
            Self.constantTimeEquals($0.tailscaleLogin, tailscaleLogin)
        }) {
            index = existing
        } else {
            if nextState.nativePairingFailures.count >= Self.maximumNativeFailureIdentityCount {
                if let evictionIndex = nextState.nativePairingFailures.firstIndex(where: {
                    $0.lockedOutUntil == nil || $0.lockedOutUntil! <= date
                }) {
                    nextState.nativePairingFailures.remove(at: evictionIndex)
                } else {
                    let activeLockoutDates = nextState.nativePairingFailures
                        .compactMap(\.lockedOutUntil)
                        .filter { $0 > date }
                    guard let earliestActiveLockout = activeLockoutDates.min() else {
                        return .lockedOut(until: .distantFuture)
                    }
                    return .lockedOut(until: earliestActiveLockout)
                }
            }
            nextState.nativePairingFailures.append(RemoteNativePairingFailureRecord(
                tailscaleLogin: tailscaleLogin,
                updatedAt: date
            ))
            index = nextState.nativePairingFailures.index(before: nextState.nativePairingFailures.endIndex)
        }

        nextState.nativePairingFailures[index].failureTimes.removeAll { $0 < windowStart }
        nextState.nativePairingFailures[index].failureTimes.append(date)
        nextState.nativePairingFailures[index].failureTimes = Array(
            nextState.nativePairingFailures[index].failureTimes.suffix(Self.maximumNativePairingFailureTimes)
        )
        nextState.nativePairingFailures[index].updatedAt = date
        var outcome: NativePairingOutcome = .invalidOffer
        if nextState.nativePairingFailures[index].failureTimes.count >= Self.nativePairingMaximumFailures {
            let lockedUntil = date.addingTimeInterval(Self.nativePairingLockoutDuration)
            nextState.nativePairingFailures[index].lockedOutUntil = lockedUntil
            outcome = .lockedOut(until: lockedUntil)
        }
        try persistSynchronously(nextState)
        storedState = nextState
        return outcome
    }

    private static func pruneNativeFailures(in state: inout State, at date: Date) {
        let retentionStart = date.addingTimeInterval(-nativeFailureRetention)
        state.nativePairingFailures.removeAll { record in
            record.updatedAt < retentionStart
                && (record.lockedOutUntil == nil || record.lockedOutUntil! <= date)
        }
        state.nativePairingFailures.sort {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
            return $0.tailscaleLogin < $1.tailscaleLogin
        }
    }

    private func statePreparedForNewDevice(from state: State) -> State? {
        var nextState = state
        while nextState.devices.count >= Self.maximumDeviceCount,
              let oldestRevokedIndex = nextState.devices.enumerated()
                .filter({ $0.element.isRevoked })
                .min(by: { $0.element.createdAt < $1.element.createdAt })?.offset {
            let removedID = nextState.devices.remove(at: oldestRevokedIndex).id
            nextState.credentials.removeAll { $0.deviceID == removedID }
        }
        guard nextState.devices.count < Self.maximumDeviceCount,
              nextState.credentials.count < Self.maximumCredentialCount else {
            return nil
        }
        return nextState
    }

    private func persistSynchronously(_ state: State) throws {
        guard let fileURL else { return }
        guard hasUnreadablePersistentSource == false else {
            throw RemoteDeviceStorePersistenceError.unreadableSource
        }
        try Self.validateEncodedStateSize(state)
        let persistenceWriter = persistenceWriter
        try persistenceQueue.sync {
            try persistenceWriter(state, fileURL)
        }
    }

    private static func writeState(_ state: State, to fileURL: URL) throws {
        let data = try encodedStateData(state)
        let fileManager = FileManager.default
        let parentDirectory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: parentDirectory.path
        )

        let temporaryURL = parentDirectory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        var descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            try? fileManager.removeItem(at: temporaryURL)
        }

        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw currentPOSIXError()
        }
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw currentPOSIXError()
                }
                guard result > 0 else {
                    throw POSIXError(.EIO)
                }
                offset += result
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw currentPOSIXError() }
        guard Darwin.close(descriptor) == 0 else {
            descriptor = -1
            throw currentPOSIXError()
        }
        descriptor = -1

        guard Darwin.rename(temporaryURL.path, fileURL.path) == 0 else {
            throw currentPOSIXError()
        }
    }

    private static func encodedStateData(_ state: State) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(state)
        guard data.count <= maximumPersistedStateByteCount else {
            throw RemoteDeviceStorePersistenceError.encodedStateTooLarge
        }
        return data
    }

    private static func validateEncodedStateSize(_ state: State) throws {
        _ = try encodedStateData(state)
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func withStateLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    /// Must be called while `stateLock` is held. Expiry removes the proof from
    /// memory so a later call with an earlier wall-clock value cannot revive it.
    private func currentNativePairingOffer(at date: Date) -> RemoteNativePairingOffer? {
        guard let offer = activeNativeOffer else { return nil }
        guard offer.isValid(at: date) else {
            activeNativeOffer = nil
            return nil
        }
        return offer
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

    /// Existing browser code alphabet and format, retained for compatibility.
    static func generatePairingCode() -> String {
        let alphabet = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")
        var generator = SystemRandomNumberGenerator()
        let characters = (0..<8).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] }
        return String(characters[0..<4]) + "-" + String(characters[4..<8])
    }

    /// Twelve characters from the unambiguous Crockford subset provide more
    /// than 58 bits of fallback entropy (30^12 possibilities).
    static func generateNativeFallbackCode() -> String {
        let alphabet = Array("23456789ABCDEFGHJKMNPQRSTVWXYZ")
        var generator = SystemRandomNumberGenerator()
        let characters = (0..<12).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] }
        return String(characters[0..<4]) + "-" + String(characters[4..<8]) + "-" + String(characters[8..<12])
    }

    static func normalizePairingCode(_ presented: String) -> String {
        let stripped = presented.uppercased().filter { $0.isLetter || $0.isNumber }
        guard stripped.count == 8 else { return presented.uppercased() }
        let characters = Array(stripped)
        return String(characters[0..<4]) + "-" + String(characters[4..<8])
    }

    static func normalizeNativeFallbackCode(_ presented: String) -> String {
        let stripped = presented.uppercased().filter { $0.isLetter || $0.isNumber }
        guard stripped.count == 12 else { return presented.uppercased() }
        let characters = Array(stripped)
        return String(characters[0..<4]) + "-" + String(characters[4..<8]) + "-" + String(characters[8..<12])
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        let count = max(lhsBytes.count, rhsBytes.count)
        var difference = UInt(lhsBytes.count ^ rhsBytes.count)
        for index in 0..<count {
            let lhsByte = index < lhsBytes.count ? lhsBytes[index] : 0
            let rhsByte = index < rhsBytes.count ? rhsBytes[index] : 0
            difference |= UInt(lhsByte ^ rhsByte)
        }
        return difference == 0
    }

    private static func nativeProof(_ proof: RemoteNativePairingProof, matches offer: RemoteNativePairingOffer) -> Bool {
        switch proof {
        case .qr(let offerID, let secret):
            guard secret.utf8.count <= maximumNativePairingProofByteCount else { return false }
            let idMatches = constantTimeEquals(offerID.uuidString.lowercased(), offer.id.uuidString.lowercased())
            let secretMatches = constantTimeEquals(secret, offer.qrPayload.secret)
            return idMatches && secretMatches
        case .fallbackCode(let presented):
            guard presented.utf8.count <= maximumNativePairingProofByteCount else { return false }
            return constantTimeEquals(normalizeNativeFallbackCode(presented), offer.fallbackCode)
        }
    }

    private static func normalizedBrowserDeviceName(_ value: String) -> String {
        let withoutControls = value.filter { character in
            character.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) == false }
        }
        let trimmed = withoutControls.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? "Unnamed device" : trimmed
        var result = ""
        for character in source.prefix(RemoteGatewayProtocol.maximumDeviceNameLength) {
            let candidate = result + String(character)
            guard candidate.utf8.count <= maximumDeviceNameByteCount else { break }
            result = candidate
        }
        return result.isEmpty ? "Unnamed device" : result
    }

    private static func validatedNativeDeviceName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              trimmed == value,
              trimmed.count <= RemoteGatewayProtocol.maximumDeviceNameLength,
              trimmed.utf8.count <= maximumDeviceNameByteCount,
              trimmed.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) == false }) else {
            return nil
        }
        return trimmed
    }

    private static func isBoundedCredentialToken(_ token: String) -> Bool {
        guard token.utf8.count == 43,
              token.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 45, 48...57, 65...90, 95, 97...122: true
                  default: false
                  }
              }) else {
            return false
        }
        var base64 = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append("=")
        return Data(base64Encoded: base64)?.count == 32
    }

    private static func isValidGatewayOrigin(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
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
