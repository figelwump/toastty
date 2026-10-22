import CoreState
import Foundation

/// A top-level workspace that was closed, with what it takes to open it
/// again.
struct RecentWorkspace: Codable, Equatable, Identifiable, Sendable {
    /// The closed workspace's ID. A reopened workspace gets a new one.
    var id: UUID
    var title: String
    var rootDirectory: String
    var closedAt: Date
}

/// Where the user placed a task.
enum TaskWorkspaceChoice: Hashable, Sendable {
    /// An open workspace, by ID.
    case open(UUID)
    /// A recently closed workspace, by its `RecentWorkspace` ID. Toastty
    /// opens it again, unless its project is open already.
    case recent(UUID)
    /// A project directory that is not open, such as a root from tasks.toml
    /// that triage suggested. Toastty opens a workspace there, unless the
    /// project is open already.
    case directory(String)
}

/// What the workspace picker offers for a task.
struct TaskWorkspaceChoices: Equatable {
    struct Open: Equatable, Identifiable {
        var id: UUID
        var title: String
        var rootDirectory: String?
    }

    /// The project triage suggested, and how to choose it now: it may have
    /// been opened, or closed again, since triage ran.
    struct Suggested: Equatable {
        var title: String
        var rootDirectory: String
        var choice: TaskWorkspaceChoice

        var isOpen: Bool {
            if case .open = choice { return true }
            return false
        }
    }

    var open: [Open]
    /// Recently closed workspaces whose project is not open, newest first.
    var recent: [RecentWorkspace]
    var suggested: Suggested? = nil

    /// The title the picker shows for a choice.
    func title(of choice: TaskWorkspaceChoice) -> String? {
        if let suggested, suggested.choice == choice { return suggested.title }
        switch choice {
        case .open(let id): return open.first { $0.id == id }?.title
        case .recent(let id): return recent.first { $0.id == id }?.title
        case .directory(let path): return URL(filePath: path).lastPathComponent
        }
    }
}

/// The last closed top-level workspaces, newest first, one per root
/// directory, saved to `recent-workspaces.json` in the runtime config
/// directory. The task workspace picker lists them under "Recent", so a
/// task can go to a project that is not open.
@MainActor
final class RecentWorkspacesStore: ObservableObject {
    static let defaultMaxItems = 20
    private nonisolated static let currentSnapshotVersion = 1

    @Published private(set) var items: [RecentWorkspace]

    private let fileURL: URL?
    private let maxItems: Int
    private let persistDebounceInterval: TimeInterval
    private let persistQueue = DispatchQueue(label: "toastty.recent-workspaces.persist")
    private var pendingPersistWorkItem: DispatchWorkItem?
    private var storeObserverToken: UUID?

    static func inMemory(maxItems: Int = defaultMaxItems) -> RecentWorkspacesStore {
        RecentWorkspacesStore(fileURL: nil, maxItems: maxItems)
    }

    convenience init(runtimePaths: ToasttyRuntimePaths) {
        self.init(fileURL: runtimePaths.recentWorkspacesFileURL)
    }

    init(fileURL: URL?, maxItems: Int = defaultMaxItems, persistDebounceInterval: TimeInterval = 0.25) {
        self.fileURL = fileURL
        self.maxItems = maxItems
        self.persistDebounceInterval = persistDebounceInterval
        items = Self.load(from: fileURL, maxItems: maxItems)
    }

    func item(id: UUID) -> RecentWorkspace? {
        items.first { $0.id == id }
    }

    /// Records every top-level workspace that an action removes, unless it
    /// has no directory to reopen. A quit does not close workspaces, so it
    /// records nothing.
    func observe(_ store: AppStore, now: @escaping () -> Date = Date.init) {
        if let storeObserverToken {
            store.removeActionAppliedObserver(storeObserverToken)
        }
        // Closing a workspace, its window, or its last tab or panel all
        // remove it, so any action that shrinks the workspace list counts.
        storeObserverToken = store.addActionAppliedObserver { [weak self] _, previousState, nextState in
            guard nextState.workspacesByID.count < previousState.workspacesByID.count else { return }
            self?.recordClosedWorkspaces(previousState: previousState, nextState: nextState, at: now())
        }
    }

    func recordClosedWorkspaces(previousState: AppState, nextState: AppState, at date: Date) {
        let closed = previousState.workspacesByID.values.filter {
            $0.parentWorkspaceID == nil && nextState.workspacesByID[$0.id] == nil
        }
        for workspace in closed {
            guard let root = TaskCoordinator.rootDirectory(of: workspace) else { continue }
            record(RecentWorkspace(id: workspace.id, title: workspace.title, rootDirectory: root, closedAt: date))
        }
    }

    /// Adds an entry, replacing an older one for the same root directory.
    func record(_ item: RecentWorkspace) {
        let root = TasksConfigFile.normalizedPath(item.rootDirectory)
        var next = items.filter { TasksConfigFile.normalizedPath($0.rootDirectory) != root && $0.id != item.id }
        next.insert(item, at: 0)
        items = Array(next.prefix(maxItems))
        schedulePersist()
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var version: Int
        var items: [RecentWorkspace]
    }

    func flushForTesting() {
        pendingPersistWorkItem?.cancel()
        pendingPersistWorkItem = nil
        persist(items)
        persistQueue.sync {}
    }

    private func schedulePersist() {
        guard fileURL != nil else { return }
        pendingPersistWorkItem?.cancel()
        let workItem = Self.writeWorkItem(items, to: fileURL)
        pendingPersistWorkItem = workItem
        persistQueue.asyncAfter(deadline: .now() + persistDebounceInterval, execute: workItem)
    }

    private func persist(_ items: [RecentWorkspace]) {
        persistQueue.async(execute: Self.writeWorkItem(items, to: fileURL))
    }

    /// Made outside the main actor: a closure formed in a main-actor method
    /// is main-actor isolated, and running it on the persist queue traps.
    private nonisolated static func writeWorkItem(_ items: [RecentWorkspace], to fileURL: URL?) -> DispatchWorkItem {
        DispatchWorkItem { write(items, to: fileURL) }
    }

    private nonisolated static func write(_ items: [RecentWorkspace], to fileURL: URL?) {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Snapshot(version: currentSnapshotVersion, items: items))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            ToasttyLog.warning("Failed saving recent workspaces", category: .tasks, metadata: [
                "error": error.localizedDescription,
            ])
        }
    }

    private static func load(from fileURL: URL?, maxItems: Int) -> [RecentWorkspace] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data) else {
            ToasttyLog.warning("Ignoring an unreadable recent-workspaces file", category: .tasks, metadata: [
                "path": fileURL.path,
            ])
            return []
        }
        return Array(snapshot.items.prefix(maxItems))
    }
}
