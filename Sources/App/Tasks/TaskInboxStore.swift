import CoreState
import Foundation

/// The quick-task Inbox, shared by every window and saved after each
/// change. `TaskInboxCoordinator` owns the changes; views only read.
@MainActor
final class TaskInboxStore: ObservableObject {
    @Published private(set) var items: [TaskInboxItem]

    private let fileURL: URL?

    init(fileURL: URL) {
        self.fileURL = fileURL
        items = Self.load(from: fileURL)
    }

    private init(items: [TaskInboxItem]) {
        fileURL = nil
        self.items = items
    }

    /// A store that saves nothing, for tests and previews.
    static func inMemory(_ items: [TaskInboxItem] = []) -> TaskInboxStore {
        TaskInboxStore(items: items)
    }

    func item(id: UUID) -> TaskInboxItem? {
        items.first { $0.id == id }
    }

    func add(_ item: TaskInboxItem) {
        items.append(item)
        persist()
    }

    /// Applies `change` to the item and saves. Returns the changed item, or
    /// `nil` when it is no longer in the Inbox.
    @discardableResult
    func update(id: UUID, _ change: (inout TaskInboxItem) -> Void) -> TaskInboxItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        var item = items[index]
        change(&item)
        guard item != items[index] else { return item }
        items[index] = item
        persist()
        return item
    }

    @discardableResult
    func remove(id: UUID) -> TaskInboxItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = items.remove(at: index)
        persist()
        return removed
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        static let currentVersion = 1
        var version: Int
        var items: [TaskInboxItem]
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(Snapshot(version: Snapshot.currentVersion, items: items))
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            ToasttyLog.warning(
                "Failed saving the task Inbox",
                category: .state,
                metadata: ["path": fileURL.path, "error": error.localizedDescription]
            )
        }
    }

    private static func load(from fileURL: URL) -> [TaskInboxItem] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            guard snapshot.version == Snapshot.currentVersion else {
                throw CocoaError(.coderReadCorrupt)
            }
            return snapshot.items
        } catch {
            let backupURL = fileURL.deletingLastPathComponent().appending(
                path: "\(fileURL.lastPathComponent).corrupt-\(Int(Date().timeIntervalSince1970))",
                directoryHint: .notDirectory
            )
            try? FileManager.default.moveItem(at: fileURL, to: backupURL)
            ToasttyLog.warning(
                "Moved an unreadable task Inbox file aside",
                category: .state,
                metadata: ["path": fileURL.path, "backup_path": backupURL.path, "error": error.localizedDescription]
            )
            return []
        }
    }
}
