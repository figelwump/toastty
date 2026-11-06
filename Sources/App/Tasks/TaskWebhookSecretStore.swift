import Foundation
import Security

/// What the Keychain holds for one webhook: its secret, and the settings
/// digest the user approved. Keeping the approval here means an edit of
/// `task-webhooks.json` cannot approve a webhook by itself.
struct TaskWebhookKeychainItem: Codable, Equatable, Sendable {
    var secret: String?
    var approvedDigest: String?
}

protocol TaskWebhookSecretStoring: Sendable {
    func item(for webhookID: UUID) throws -> TaskWebhookKeychainItem?
    func setItem(_ item: TaskWebhookKeychainItem, for webhookID: UUID) throws
    func removeItem(for webhookID: UUID) throws
}

struct TaskWebhookSecretStoreError: Error, LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return "The Keychain refused the request: \(reason)"
    }
}

/// Generic-password items in the login Keychain. The service is
/// `<bundle id>.task-webhooks`, with a suffix for a runtime-isolated home
/// so a dev run never reads production items. The account is the
/// webhook's ID.
struct KeychainTaskWebhookSecretStore: TaskWebhookSecretStoring {
    let service: String

    static func service(bundleIdentifier: String?, runtimeHomeURL: URL?) -> String {
        let base = (bundleIdentifier ?? "com.GiantThings.toastty") + ".task-webhooks"
        guard let runtimeHomeURL else { return base }
        return base + "." + ToasttyRuntimeHashing.shortHash(runtimeHomeURL.path)
    }

    private func query(for webhookID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: webhookID.uuidString,
        ]
    }

    func item(for webhookID: UUID) throws -> TaskWebhookKeychainItem? {
        var query = query(for: webhookID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw TaskWebhookSecretStoreError(status: status)
        }
        return try? JSONDecoder().decode(TaskWebhookKeychainItem.self, from: data)
    }

    func setItem(_ item: TaskWebhookKeychainItem, for webhookID: UUID) throws {
        let data = try JSONEncoder().encode(item)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query(for: webhookID) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw TaskWebhookSecretStoreError(status: status) }
        var add = query(for: webhookID)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Toastty task webhook"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw TaskWebhookSecretStoreError(status: addStatus) }
    }

    func removeItem(for webhookID: UUID) throws {
        let status = SecItemDelete(query(for: webhookID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TaskWebhookSecretStoreError(status: status)
        }
    }
}

/// For tests and runs without a Keychain.
final class InMemoryTaskWebhookSecretStore: TaskWebhookSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UUID: TaskWebhookKeychainItem] = [:]

    func item(for webhookID: UUID) throws -> TaskWebhookKeychainItem? {
        lock.withLock { items[webhookID] }
    }

    func setItem(_ item: TaskWebhookKeychainItem, for webhookID: UUID) throws {
        lock.withLock { items[webhookID] = item }
    }

    func removeItem(for webhookID: UUID) throws {
        lock.withLock { items[webhookID] = nil }
    }
}

enum ToasttyRuntimeHashing {
    /// A short, stable FNV-1a hash, for names that must differ per runtime
    /// home without showing its path.
    static func shortHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
