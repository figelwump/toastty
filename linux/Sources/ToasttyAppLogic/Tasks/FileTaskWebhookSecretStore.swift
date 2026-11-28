import CoreState
import Foundation

/// The Linux secret store for task webhooks, in place of the macOS Keychain
/// (`KeychainTaskWebhookSecretStore`).
///
/// One JSON file, `task-webhook-secrets.json`, sits beside
/// `task-webhooks.json`, readable by the user only (0600). An edit of
/// `task-webhooks.json` still cannot approve a webhook by itself, since the
/// approved digest lives here. Unlike the Keychain, another process of the
/// same user can read this file. The Secret Service (GNOME Keyring) gives no
/// per-app isolation either, so a file costs no protection that Linux
/// offers. See docs/linux.md "Task webhooks".
final class FileTaskWebhookSecretStore: TaskWebhookSecretStoring, @unchecked Sendable {
    let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func fileURL(runtimePaths: ToasttyRuntimePaths) -> URL {
        runtimePaths.taskWebhooksFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("task-webhook-secrets.json")
    }

    func item(for webhookID: UUID) throws -> TaskWebhookKeychainItem? {
        try lock.withLock { try load()[webhookID.uuidString] }
    }

    func setItem(_ item: TaskWebhookKeychainItem, for webhookID: UUID) throws {
        try lock.withLock {
            var items = try load()
            items[webhookID.uuidString] = item
            try save(items)
        }
    }

    func removeItem(for webhookID: UUID) throws {
        try lock.withLock {
            var items = try load()
            guard items.removeValue(forKey: webhookID.uuidString) != nil else { return }
            try save(items)
        }
    }

    private func load() throws -> [String: TaskWebhookKeychainItem] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return try JSONDecoder().decode([String: TaskWebhookKeychainItem].self, from: data)
    }

    private func save(_ items: [String: TaskWebhookKeychainItem]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(items)
        // Written private from the start: a temporary file made 0600 before
        // any secret goes in, then renamed over the old one.
        let temporaryURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.write(contentsOf: data)
            try handle.close()
            if rename(temporaryURL.path, fileURL.path) != 0 {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}
