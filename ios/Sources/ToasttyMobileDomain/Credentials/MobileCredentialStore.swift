import Foundation
import RemoteProtocol
import Security

public enum MobileCredentialStoreFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case keychainStatus(OSStatus)

    public var description: String { "<redacted credential store failure>" }
}

public enum MobileCredentialLoadResult: Equatable, Sendable {
    case missing
    case available(StoredMobileCredential)
    case locked
    case corrupt
    case incompatible(storedVersion: Int)
    case failed(MobileCredentialStoreFailure)
}

public protocol MobileCredentialStoring: Sendable {
    func load() -> MobileCredentialLoadResult
    func save(_ credential: StoredMobileCredential) throws
    func delete() throws
}

public enum KeychainSynchronizableMatch: Equatable, Sendable {
    case nonSynchronizable
    case any
}

public struct KeychainItemLocator: Equatable, Sendable {
    public var service: String
    public var account: String
    public var synchronizable: KeychainSynchronizableMatch

    public init(service: String, account: String, synchronizable: KeychainSynchronizableMatch) {
        self.service = service
        self.account = account
        self.synchronizable = synchronizable
    }
}

public struct KeychainItemToAdd: Equatable, Sendable {
    public var locator: KeychainItemLocator
    public var data: Data

    public init(locator: KeychainItemLocator, data: Data) {
        self.locator = locator
        self.data = data
    }
}

public enum KeychainCopyResult: Equatable, Sendable {
    case data(Data)
    case status(OSStatus)
}

/// Typed seam around Security.framework. Tests can assert policy without
/// passing non-Sendable CFDictionary values between concurrency domains.
public protocol MobileCredentialSecurityClient: Sendable {
    func copy(_ locator: KeychainItemLocator) -> KeychainCopyResult
    func add(_ item: KeychainItemToAdd) -> OSStatus
    func update(_ locator: KeychainItemLocator, data: Data) -> OSStatus
    func delete(_ locator: KeychainItemLocator) -> OSStatus
}

public struct SystemMobileCredentialSecurityClient: MobileCredentialSecurityClient {
    public init() {}

    public func copy(_ locator: KeychainItemLocator) -> KeychainCopyResult {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            Self.query(locator, returnsData: true) as CFDictionary,
            &result
        )
        guard status == errSecSuccess, let data = result as? Data else {
            return .status(status == errSecSuccess ? errSecDecode : status)
        }
        return .data(data)
    }

    public func add(_ item: KeychainItemToAdd) -> OSStatus {
        var attributes = Self.query(item.locator, returnsData: false)
        attributes[kSecValueData] = item.data
        attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    public func update(_ locator: KeychainItemLocator, data: Data) -> OSStatus {
        SecItemUpdate(
            Self.query(locator, returnsData: false) as CFDictionary,
            [
                kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ] as CFDictionary
        )
    }

    public func delete(_ locator: KeychainItemLocator) -> OSStatus {
        SecItemDelete(Self.query(locator, returnsData: false) as CFDictionary)
    }

    private static func query(
        _ locator: KeychainItemLocator,
        returnsData: Bool
    ) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: locator.service,
            kSecAttrAccount: locator.account,
            kSecUseDataProtectionKeychain: true,
        ]
        switch locator.synchronizable {
        case .nonSynchronizable:
            query[kSecAttrSynchronizable] = false
        case .any:
            query[kSecAttrSynchronizable] = kSecAttrSynchronizableAny
        }
        if returnsData {
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
        }
        return query
    }
}

public struct KeychainMobileCredentialStore: MobileCredentialStoring {
    public static let defaultService = "com.giantthings.toastty.mobile.native-credential"
    public static let defaultAccount = "paired-device-v1"

    private let securityClient: any MobileCredentialSecurityClient
    private let service: String
    private let account: String

    public init(
        service: String = Self.defaultService,
        account: String = Self.defaultAccount,
        securityClient: any MobileCredentialSecurityClient = SystemMobileCredentialSecurityClient()
    ) {
        self.service = service
        self.account = account
        self.securityClient = securityClient
    }

    public func load() -> MobileCredentialLoadResult {
        switch securityClient.copy(locator(synchronizable: .nonSynchronizable)) {
        case .status(errSecItemNotFound):
            return .missing
        case .status(let status) where Self.isLockedStatus(status):
            return .locked
        case .status(let status):
            return .failed(.keychainStatus(status))
        case .data(let data):
            return decode(data)
        }
    }

    public func save(_ credential: StoredMobileCredential) throws {
        let data: Data
        do {
            data = try ConversationEventCoding.makeEncoder().encode(credential)
        } catch {
            throw MobileCredentialStoreFailure.keychainStatus(errSecParam)
        }

        let locator = locator(synchronizable: .nonSynchronizable)
        let status: OSStatus
        switch securityClient.copy(locator) {
        case .data:
            status = securityClient.update(locator, data: data)
        case .status(errSecItemNotFound):
            let addStatus = securityClient.add(KeychainItemToAdd(locator: locator, data: data))
            status = addStatus == errSecDuplicateItem
                ? securityClient.update(locator, data: data)
                : addStatus
        case .status(let copyStatus):
            status = copyStatus
        }
        guard status == errSecSuccess else {
            throw MobileCredentialStoreFailure.keychainStatus(status)
        }
    }

    public func delete() throws {
        let status = securityClient.delete(locator(synchronizable: .any))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MobileCredentialStoreFailure.keychainStatus(status)
        }
    }

    private func decode(_ data: Data) -> MobileCredentialLoadResult {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let storedVersion = object["schemaVersion"] as? Int,
           storedVersion != StoredMobileCredential.currentSchemaVersion {
            return .incompatible(storedVersion: storedVersion)
        }
        do {
            return .available(try ConversationEventCoding.makeDecoder().decode(StoredMobileCredential.self, from: data))
        } catch StoredMobileCredentialError.incompatibleSchema(let version) {
            return .incompatible(storedVersion: version)
        } catch {
            return .corrupt
        }
    }

    private func locator(synchronizable: KeychainSynchronizableMatch) -> KeychainItemLocator {
        KeychainItemLocator(service: service, account: account, synchronizable: synchronizable)
    }

    private static func isLockedStatus(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed || status == errSecAuthFailed
    }

}
