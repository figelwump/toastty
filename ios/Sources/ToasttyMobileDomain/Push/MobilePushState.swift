import Foundation
import RemoteProtocol
import Security

public struct MobilePushRegistration: Codable, Equatable, Sendable, CustomStringConvertible {
    public enum Stage: String, Codable, Sendable { case pending, relayActive, enabled }

    public var registrationID: UUID
    public var pairingID: UUID
    public var gatewayURL: URL
    public var relayURL: URL
    public var relayID: String
    public var deviceToken: String
    public var managementToken: String
    public var sendToken: String
    public var stage: Stage
    public var expiresAt: Date?
    public var nonce: String?
    public var createdAt: Date

    public init(registrationID: UUID = UUID(), pairingID: UUID, gatewayURL: URL,
                relayURL: URL, relayID: String, deviceToken: String,
                managementToken: String, sendToken: String, stage: Stage = .pending,
                expiresAt: Date? = nil, nonce: String? = nil, createdAt: Date = Date()) {
        self.registrationID = registrationID
        self.pairingID = pairingID
        self.gatewayURL = gatewayURL
        self.relayURL = relayURL
        self.relayID = relayID
        self.deviceToken = deviceToken
        self.managementToken = managementToken
        self.sendToken = sendToken
        self.stage = stage
        self.expiresAt = expiresAt
        self.nonce = nonce
        self.createdAt = createdAt
    }

    public var description: String { "<redacted push registration>" }
}

public struct MobilePushState: Codable, Equatable, Sendable, CustomStringConvertible {
    public var schemaVersion = 1
    public var installationID: UUID
    public var desired = false
    public var introHandled = false
    public var active: MobilePushRegistration?
    public var pending: MobilePushRegistration?
    public var cleanup: [MobilePushRegistration] = []
    public var needsMacClear = false
    public var blockedDeviceToken: String?
    public var blockedBuildID: String?
    public var retryAfter: Date?
    public var cleanupRetryAfter: Date?

    public init(installationID: UUID = UUID()) { self.installationID = installationID }
    public var description: String { "<redacted push state>" }

    public mutating func queueCleanup() {
        for registration in [active, pending].compactMap({ $0 }) {
            if !cleanup.contains(where: { $0.registrationID == registration.registrationID }) {
                var cleanupRegistration = registration
                cleanupRegistration.nonce = nil
                cleanup.append(cleanupRegistration)
            }
        }
        active = nil
        pending = nil
    }
}

public enum MobilePushStoreFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case locked
    case unavailable
    case corrupt
    public var description: String { "<redacted push store failure>" }
}

public protocol MobilePushStateStoring: Sendable {
    func load() throws -> MobilePushState?
    func save(_ state: MobilePushState) throws
}

/// A separate device-only record keeps cleanup alive after pairing removal.
public struct KeychainMobilePushStateStore: MobilePushStateStoring {
    public static let defaultService = "com.giantthings.toastty.mobile.push-state"
    public static let defaultAccount = "push-state-v1"
    private let securityClient: any MobileCredentialSecurityClient
    private let locator: KeychainItemLocator

    public init(service: String = Self.defaultService, account: String = Self.defaultAccount,
                securityClient: any MobileCredentialSecurityClient = SystemMobileCredentialSecurityClient()) {
        self.securityClient = securityClient
        locator = KeychainItemLocator(service: service, account: account, synchronizable: .nonSynchronizable)
    }

    public func load() throws -> MobilePushState? {
        switch securityClient.copy(locator) {
        case .status(errSecItemNotFound): return nil
        case .status(let status): throw Self.failure(status)
        case .data(let data):
            guard let state = try? JSONDecoder().decode(MobilePushState.self, from: data),
                  state.schemaVersion == 1,
                  state.cleanup.count <= 128,
                  ([state.active, state.pending].compactMap({ $0 }) + state.cleanup)
                    .allSatisfy(Self.isValid) else { throw MobilePushStoreFailure.corrupt }
            return state
        }
    }

    public func save(_ state: MobilePushState) throws {
        guard state.schemaVersion == 1, state.cleanup.count <= 128,
              ([state.active, state.pending].compactMap({ $0 }) + state.cleanup)
                .allSatisfy(Self.isValid),
              let data = try? JSONEncoder().encode(state) else { throw MobilePushStoreFailure.corrupt }
        let status: OSStatus
        switch securityClient.copy(locator) {
        case .data: status = securityClient.update(locator, data: data)
        case .status(errSecItemNotFound):
            let added = securityClient.add(KeychainItemToAdd(locator: locator, data: data))
            status = added == errSecDuplicateItem ? securityClient.update(locator, data: data) : added
        case .status(let failure): throw Self.failure(failure)
        }
        guard status == errSecSuccess else { throw Self.failure(status) }
    }

    private static func failure(_ status: OSStatus) -> MobilePushStoreFailure {
        status == errSecInteractionNotAllowed || status == errSecAuthFailed ? .locked : .unavailable
    }

    private static func isValid(_ value: MobilePushRegistration) -> Bool {
        isCapability(value.managementToken) && isCapability(value.sendToken)
            && (value.nonce.map(isCapability) ?? true)
            && !value.relayID.isEmpty && value.relayID.utf8.count <= 128
            && PushRelayClient.isValidOrigin(value.relayURL)
            && (try? PairingInputParser.canonicalGatewayURL(value.gatewayURL.absoluteString)) == value.gatewayURL
            && isDeviceToken(value.deviceToken)
    }

    public static func isCapability(_ value: String) -> Bool {
        RemotePushPolicy.isValidCapabilityToken(value)
    }

    public static func isDeviceToken(_ value: String) -> Bool {
        (64...512).contains(value.utf8.count) && value.utf8.count.isMultiple(of: 2)
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func randomCapability() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MobilePushStoreFailure.unavailable
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
