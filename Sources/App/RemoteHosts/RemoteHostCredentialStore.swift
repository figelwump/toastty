import Foundation
import Security
import ToasttyMobileDomain

/// Keeps a remote host's Bearer credential in the user's login keychain.
///
/// The shared `SystemMobileCredentialSecurityClient` uses the data protection
/// keychain, which on macOS needs an entitlement from a provisioning profile.
/// A Developer ID or ad-hoc signed Toastty has none, so the Mac uses the login
/// keychain. macOS limits the item to the app that created it; a build with a
/// different signature gets a system prompt before it can read the item.
struct LoginKeychainSecurityClient: MobileCredentialSecurityClient {
    func copy(_ locator: KeychainItemLocator) -> KeychainCopyResult {
        var query = Self.query(locator)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return .status(status == errSecSuccess ? errSecDecode : status)
        }
        return .data(data)
    }

    func add(_ item: KeychainItemToAdd) -> OSStatus {
        var attributes = Self.query(item.locator)
        attributes[kSecValueData] = item.data
        attributes[kSecAttrLabel] = "Toastty remote host credential"
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(_ locator: KeychainItemLocator, data: Data) -> OSStatus {
        SecItemUpdate(Self.query(locator) as CFDictionary, [kSecValueData: data] as CFDictionary)
    }

    func delete(_ locator: KeychainItemLocator) -> OSStatus {
        SecItemDelete(Self.query(locator) as CFDictionary)
    }

    private static func query(_ locator: KeychainItemLocator) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: locator.service,
            kSecAttrAccount: locator.account,
        ]
    }
}

enum RemoteHostCredentialStore {
    static let keychainService = "com.giantthings.toastty.remote-host-credential"

    /// The account names the gateway as well as the remote, so a table whose
    /// `gatewayURL` changes never finds the credential of the previous host.
    static func keychainAccount(for configuration: RemoteHostConfiguration) -> String {
        "\(configuration.id)@\(configuration.gatewayURL.host ?? "")"
    }

    static func keychain(for configuration: RemoteHostConfiguration) -> any MobileCredentialStoring {
        KeychainMobileCredentialStore(
            service: keychainService,
            account: keychainAccount(for: configuration),
            securityClient: LoginKeychainSecurityClient()
        )
    }
}
