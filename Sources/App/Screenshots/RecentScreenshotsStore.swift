import Foundation
import CoreState
import UniformTypeIdentifiers

struct RecentScreenshotItem: Identifiable, Equatable, Sendable {
    let fileURL: URL
    let capturedAt: Date

    var id: String {
        fileURL.standardizedFileURL.path(percentEncoded: false)
    }

    var displayName: String {
        fileURL.lastPathComponent
    }
}

enum RecentScreenshotsStatus: Equatable, Sendable {
    case idle
    case loading
    case ready
    case missingDirectory(path: String)
    case unreadableDirectory(path: String)
}

@MainActor
final class RecentScreenshotsStore: ObservableObject {
    @Published private(set) var items: [RecentScreenshotItem] = []
    @Published private(set) var status: RecentScreenshotsStatus = .idle

    private enum DirectoryScanResult {
        case success([RecentScreenshotItem])
        case missingDirectory
        case unreadableDirectory
    }

    private static let locationRefreshIntervalNanoseconds: UInt64 = 5_000_000_000
    private static let reloadDebounceNanoseconds: UInt64 = 220_000_000

    private let resolver: any SystemScreenshotLocationResolving
    private let maxItemCount: Int
    private let watcherQueue = DispatchQueue(label: "toastty.screenshots.directory-watcher")

    private var directoryWatcher: DirectoryWatcher?
    private var watchedDirectoryURL: URL?
    private var locationRefreshTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var reloadGeneration: UInt64 = 0
    private var started = false

    init(
        resolver: any SystemScreenshotLocationResolving = SystemScreenshotLocationResolver(),
        maxItemCount: Int = 6
    ) {
        self.resolver = resolver
        self.maxItemCount = max(1, maxItemCount)
    }

    func start() {
        guard started == false else { return }
        started = true
        refreshWatchedDirectory(force: true)

        locationRefreshTask = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: Self.locationRefreshIntervalNanoseconds)
                guard Task.isCancelled == false else { return }
                guard let self else { return }
                self.refreshWatchedDirectory(force: false)
            }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        locationRefreshTask?.cancel()
        locationRefreshTask = nil
        reloadTask?.cancel()
        reloadTask = nil
        reloadGeneration &+= 1
        directoryWatcher?.invalidate()
        directoryWatcher = nil
        watchedDirectoryURL = nil
        items = []
        status = .idle
    }

    private func refreshWatchedDirectory(force: Bool) {
        let resolvedDirectory = resolver.resolveScreenshotDirectory().standardizedFileURL
        let shouldResetWatcher = force || watchedDirectoryURL != resolvedDirectory
        if shouldResetWatcher {
            watchedDirectoryURL = resolvedDirectory
            installWatcher(for: resolvedDirectory)
        }
        scheduleReload()
    }

    private func installWatcher(for directoryURL: URL) {
        directoryWatcher?.invalidate()
        do {
            directoryWatcher = try DirectoryWatcher(
                directoryURL: directoryURL,
                queue: watcherQueue
            ) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleReload()
                }
            }
        } catch {
            directoryWatcher = nil
            ToasttyLog.warning(
                "Failed to install screenshot directory watcher",
                category: .state,
                metadata: [
                    "path": directoryURL.path(percentEncoded: false),
                    "error": String(describing: error),
                ]
            )
        }
    }

    private func scheduleReload() {
        guard started else { return }
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: Self.reloadDebounceNanoseconds)
            guard Task.isCancelled == false else { return }
            self.reloadItems()
        }
    }

    private func reloadItems() {
        guard started else { return }
        guard let directoryURL = watchedDirectoryURL else {
            items = []
            status = .idle
            return
        }

        status = .loading
        let maxItemCount = self.maxItemCount
        reloadGeneration &+= 1
        let generation = reloadGeneration

        Task { @MainActor [weak self] in
            let scanResult = await Task.detached(priority: .utility) {
                Self.scanDirectory(directoryURL, maxItemCount: maxItemCount)
            }.value

            guard let self else { return }
            guard self.started else { return }
            guard self.reloadGeneration == generation else { return }
            guard self.watchedDirectoryURL == directoryURL else { return }

            switch scanResult {
            case .success(let scannedItems):
                self.items = scannedItems
                self.status = .ready

            case .missingDirectory:
                self.items = []
                self.status = .missingDirectory(path: directoryURL.path(percentEncoded: false))

            case .unreadableDirectory:
                self.items = []
                self.status = .unreadableDirectory(path: directoryURL.path(percentEncoded: false))
            }
        }
    }

    nonisolated private static func scanDirectory(
        _ directoryURL: URL,
        maxItemCount: Int
    ) -> DirectoryScanResult {
        var isDirectory = ObjCBool(false)
        let directoryPath = directoryURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: directoryPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .missingDirectory
        }

        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .contentTypeKey,
            .creationDateKey,
            .contentModificationDateKey,
        ]

        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants, .skipsHiddenFiles]
            )
        } catch {
            return .unreadableDirectory
        }

        var collectedItems: [RecentScreenshotItem] = []
        collectedItems.reserveCapacity(min(entries.count, maxItemCount))

        for entry in entries {
            guard let resourceValues = try? entry.resourceValues(forKeys: resourceKeys),
                  resourceValues.isRegularFile == true else {
                continue
            }
            guard Self.isImageFile(entry, resourceValues: resourceValues) else {
                continue
            }

            let capturedAt = resourceValues.creationDate
                ?? resourceValues.contentModificationDate
                ?? Date.distantPast

            collectedItems.append(
                RecentScreenshotItem(
                    fileURL: entry.standardizedFileURL,
                    capturedAt: capturedAt
                )
            )
        }

        collectedItems.sort { lhs, rhs in
            if lhs.capturedAt != rhs.capturedAt {
                return lhs.capturedAt > rhs.capturedAt
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        if collectedItems.count > maxItemCount {
            collectedItems.removeSubrange(maxItemCount...)
        }

        return .success(collectedItems)
    }

    nonisolated private static func isImageFile(_ fileURL: URL, resourceValues: URLResourceValues) -> Bool {
        if let contentType = resourceValues.contentType {
            return contentType.conforms(to: .image)
        }

        if let inferredType = UTType(filenameExtension: fileURL.pathExtension) {
            return inferredType.conforms(to: .image)
        }

        return false
    }
}
