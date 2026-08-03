import CoreState
import Foundation

struct RecentRightPanelItem: Codable, Equatable, Identifiable, Sendable {
    var id: RecentRightPanelItemID
    var title: String
    var detail: String?
    var updatedAt: Date

    init(
        id: RecentRightPanelItemID,
        title: String,
        detail: String? = nil,
        updatedAt: Date
    ) {
        self.id = id
        self.title = Self.normalizedDisplayValue(title) ?? id.fallbackTitle
        self.detail = Self.normalizedDisplayValue(detail)
        self.updatedAt = updatedAt
    }

    var systemImageName: String {
        id.systemImageName
    }

    var menuTitle: String {
        guard let detail else { return title }
        return "\(title) - \(detail)"
    }

    private static func normalizedDisplayValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum RecentRightPanelItemID: Codable, Equatable, Hashable, Sendable {
    case localDocument(path: String)
    case scratchpad(documentID: UUID)
    case browser(url: String)

    private enum ItemType: String, Codable {
        case localDocument
        case scratchpad
        case browser
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case path
        case documentID
        case url
    }

    var fallbackTitle: String {
        switch self {
        case .localDocument(let path):
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            return fileName.isEmpty ? WebPanelDefinition.localDocument.defaultTitle : fileName
        case .scratchpad:
            return WebPanelDefinition.scratchpad.defaultTitle
        case .browser(let url):
            return Self.browserFallbackTitle(url: url)
        }
    }

    var systemImageName: String {
        switch self {
        case .localDocument:
            return "doc.text"
        case .scratchpad:
            return "square.and.pencil"
        case .browser:
            return "globe"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ItemType.self, forKey: .type)
        switch type {
        case .localDocument:
            self = .localDocument(path: try container.decode(String.self, forKey: .path))
        case .scratchpad:
            self = .scratchpad(documentID: try container.decode(UUID.self, forKey: .documentID))
        case .browser:
            self = .browser(url: try container.decode(String.self, forKey: .url))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .localDocument(let path):
            try container.encode(ItemType.localDocument, forKey: .type)
            try container.encode(path, forKey: .path)
        case .scratchpad(let documentID):
            try container.encode(ItemType.scratchpad, forKey: .type)
            try container.encode(documentID, forKey: .documentID)
        case .browser(let url):
            try container.encode(ItemType.browser, forKey: .type)
            try container.encode(url, forKey: .url)
        }
    }

    private static func browserFallbackTitle(url: String) -> String {
        guard let parsedURL = URL(string: url) else {
            return WebPanelDefinition.browser.defaultTitle
        }
        if parsedURL.isFileURL {
            let fileName = parsedURL.deletingPathExtension().lastPathComponent
            return fileName.isEmpty ? WebPanelDefinition.browser.defaultTitle : fileName
        }
        return parsedURL.host(percentEncoded: false) ?? WebPanelDefinition.browser.defaultTitle
    }
}

struct RightPanelRecentItemsList: Equatable, Sendable {
    private(set) var items: [RecentRightPanelItem]

    init(items: [RecentRightPanelItem] = [], maxItems: Int = RightPanelRecentItemsStore.defaultMaxItems) {
        self.items = Self.normalizedItems(items, maxItems: maxItems)
    }

    @discardableResult
    mutating func record(
        _ item: RecentRightPanelItem,
        replacingID: RecentRightPanelItemID? = nil,
        maxItems: Int = RightPanelRecentItemsStore.defaultMaxItems
    ) -> [RecentRightPanelItem] {
        let idsToRemove = Set([item.id, replacingID].compactMap { $0 })
        items.removeAll { idsToRemove.contains($0.id) }
        items.insert(item, at: 0)
        items = Self.normalizedItems(items, maxItems: maxItems)
        return items
    }

    @discardableResult
    mutating func remove(
        id: RecentRightPanelItemID,
        maxItems: Int = RightPanelRecentItemsStore.defaultMaxItems
    ) -> [RecentRightPanelItem] {
        items.removeAll { $0.id == id }
        items = Self.normalizedItems(items, maxItems: maxItems)
        return items
    }

    private static func normalizedItems(
        _ items: [RecentRightPanelItem],
        maxItems: Int
    ) -> [RecentRightPanelItem] {
        var newestByID: [RecentRightPanelItemID: RecentRightPanelItem] = [:]
        for item in items {
            if let existing = newestByID[item.id],
               existing.updatedAt >= item.updatedAt {
                continue
            }
            newestByID[item.id] = item
        }

        return newestByID.values
            .sorted {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            .prefix(max(0, maxItems))
            .map { $0 }
    }
}

@MainActor
final class RightPanelRecentItemsStore {
    nonisolated static let defaultMaxItems = 20
    nonisolated static let defaultMenuItemLimit = 10
    private static let currentSnapshotVersion = 1

    private let fileURL: URL?
    private let maxItems: Int
    private let persistDebounceInterval: TimeInterval
    private let persistQueue = DispatchQueue(label: "toastty.right-panel-recents.persist")

    private var list: RightPanelRecentItemsList
    private var pendingPersistWorkItem: DispatchWorkItem?

    static func inMemory(maxItems: Int = defaultMaxItems) -> RightPanelRecentItemsStore {
        RightPanelRecentItemsStore(fileURL: nil, maxItems: maxItems)
    }

    convenience init(
        runtimePaths: ToasttyRuntimePaths,
        maxItems: Int = defaultMaxItems,
        persistDebounceInterval: TimeInterval = 0.25
    ) {
        self.init(
            fileURL: runtimePaths.recentRightPanelItemsFileURL,
            maxItems: maxItems,
            persistDebounceInterval: persistDebounceInterval
        )
    }

    init(
        fileURL: URL?,
        maxItems: Int = defaultMaxItems,
        persistDebounceInterval: TimeInterval = 0.25
    ) {
        self.fileURL = fileURL
        self.maxItems = maxItems
        self.persistDebounceInterval = persistDebounceInterval
        list = RightPanelRecentItemsList(
            items: Self.loadItems(from: fileURL, maxItems: maxItems),
            maxItems: maxItems
        )
    }

    var items: [RecentRightPanelItem] {
        list.items
    }

    @discardableResult
    func record(
        _ item: RecentRightPanelItem,
        replacingID: RecentRightPanelItemID? = nil
    ) -> [RecentRightPanelItem] {
        let nextItems = list.record(item, replacingID: replacingID, maxItems: maxItems)
        schedulePersist(items: nextItems)
        return nextItems
    }

    @discardableResult
    func remove(id: RecentRightPanelItemID) -> [RecentRightPanelItem] {
        let nextItems = list.remove(id: id, maxItems: maxItems)
        schedulePersist(items: nextItems)
        return nextItems
    }

    func flushForTesting() {
        pendingPersistWorkItem?.cancel()
        pendingPersistWorkItem = nil
        persist(items: list.items)
        persistQueue.sync {}
    }

    private func schedulePersist(items: [RecentRightPanelItem]) {
        guard fileURL != nil else { return }

        pendingPersistWorkItem?.cancel()
        if persistDebounceInterval <= 0 {
            persist(items: items)
            return
        }

        let workItem = makePersistWorkItem(items: items)
        pendingPersistWorkItem = workItem
        persistQueue.asyncAfter(
            deadline: .now() + persistDebounceInterval,
            execute: workItem
        )
    }

    private func persist(items: [RecentRightPanelItem]) {
        guard fileURL != nil else { return }
        persistQueue.async(execute: makePersistWorkItem(items: items))
    }

    private func makePersistWorkItem(items: [RecentRightPanelItem]) -> DispatchWorkItem {
        let fileURL = fileURL
        let data: Data
        do {
            data = try Self.encodeSnapshot(items: items)
        } catch {
            ToasttyLog.warning(
                "Failed encoding recent right-panel items",
                category: .state,
                metadata: ["error": error.localizedDescription]
            )
            return Self.persistWorkItem(fileURL: nil, data: Data())
        }

        return Self.persistWorkItem(fileURL: fileURL, data: data)
    }

    private nonisolated static func persistWorkItem(fileURL: URL?, data: Data) -> DispatchWorkItem {
        return DispatchWorkItem {
            guard let fileURL else { return }
            Self.writeSnapshotData(data, to: fileURL)
        }
    }

    private static func loadItems(from fileURL: URL?, maxItems: Int) -> [RecentRightPanelItem] {
        guard let fileURL,
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder().decode(RecentRightPanelItemsSnapshot.self, from: data)
            guard snapshot.version == currentSnapshotVersion else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: [],
                        debugDescription: "Unsupported recent right-panel items version: \(snapshot.version)"
                    )
                )
            }
            return RightPanelRecentItemsList(items: snapshot.items, maxItems: maxItems).items
        } catch {
            let backupURL = backupCorruptFile(at: fileURL)
            ToasttyLog.warning(
                "Failed loading recent right-panel items",
                category: .state,
                metadata: [
                    "path": fileURL.path,
                    "backup_path": backupURL?.path ?? "none",
                    "error": error.localizedDescription,
                ]
            )
            return []
        }
    }

    private static func encodeSnapshot(items: [RecentRightPanelItem]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(
            RecentRightPanelItemsSnapshot(
                version: currentSnapshotVersion,
                items: items
            )
        )
    }

    private nonisolated static func writeSnapshotData(_ data: Data, to fileURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            ToasttyLog.warning(
                "Failed persisting recent right-panel items",
                category: .state,
                metadata: [
                    "path": fileURL.path,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    private static func backupCorruptFile(at fileURL: URL) -> URL? {
        let directoryURL = fileURL.deletingLastPathComponent()
        let timestamp = Int(Date().timeIntervalSince1970)
        let backupURL = directoryURL.appending(
            path: "\(fileURL.lastPathComponent).corrupt-\(timestamp)-\(UUID().uuidString)",
            directoryHint: .notDirectory
        )

        do {
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
            return backupURL
        } catch {
            ToasttyLog.warning(
                "Failed backing up corrupt recent right-panel items file",
                category: .state,
                metadata: [
                    "path": fileURL.path,
                    "backup_path": backupURL.path,
                    "error": error.localizedDescription,
                ]
            )
            return nil
        }
    }
}

private struct RecentRightPanelItemsSnapshot: Codable {
    var version: Int
    var items: [RecentRightPanelItem]
}
