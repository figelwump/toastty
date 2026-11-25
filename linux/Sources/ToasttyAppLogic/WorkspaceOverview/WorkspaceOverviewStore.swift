import CoreState
import Foundation

// Linux-first: the workspace page's saved state. The Mac app does not have
// it yet; docs/plans/workspace-overview.md describes the model and the UI
// flow for a later macOS implementation.

/// A Scratchpad kept by a top-level workspace. The workspace owns a copy of
/// the task's Scratchpad (`documentID`, a normal Scratchpad document). While
/// the source is linked, every change to the source is copied over; once the
/// task space closes, the link ends and the copy stays as it was last.
struct WorkspaceScratchpadEntry: Codable, Equatable, Sendable {
    struct Source: Codable, Equatable, Sendable {
        /// The task's Scratchpad document.
        var documentID: UUID
        /// The workspace whose tab held the source panel: a task space, or
        /// the top-level workspace itself.
        var workspaceID: UUID
        var taskID: UUID?
        var taskTitle: String?
        /// When the link ended: the source's workspace closed or its
        /// document went away. Nil while changes still copy over.
        var linkEndedAt: Date?
        /// The source revision the copy last took.
        var syncedRevision: Int?

        var isLinked: Bool { linkEndedAt == nil }
    }

    /// The workspace's own copy.
    var documentID: UUID
    /// The top-level workspace that keeps it.
    var workspaceID: UUID
    /// The workspace's project folder when it was kept, so the copy follows
    /// the project when its workspace is closed and opened again.
    var projectRoot: String?
    var source: Source?
    var keptAt: Date
    /// `user`, or the session ID of the agent that kept it.
    var keptBy: String?
}

/// What a workspace is about, as an agent last wrote it.
struct WorkspaceSynopsis: Codable, Equatable, Sendable {
    var text: String
    var updatedAt: Date
    var sessionID: String?
    var projectRoot: String?
}

/// The last thing a task's agent said, kept after its session ends, so the
/// workspace page can say what the task did.
struct WorkspaceTaskOutcome: Codable, Equatable, Sendable {
    var text: String
    var at: Date
}

/// `~/.toastty/workspace-overview.json`: kept Scratchpads, synopses and task
/// outcomes. Dates use Foundation's default encoding, so a reread equals
/// what was written. Written whole on every change; a file it cannot read starts
/// empty and is left in place until the next write.
final class WorkspaceOverviewStore {
    struct Contents: Codable, Equatable {
        var version = 1
        var scratchpads: [WorkspaceScratchpadEntry] = []
        /// By top-level workspace ID.
        var synopses: [String: WorkspaceSynopsis] = [:]
        /// By task ID.
        var outcomes: [String: WorkspaceTaskOutcome] = [:]
    }

    static let fileName = "workspace-overview.json"
    /// Outcomes keep at most this much text.
    static let maxOutcomeCharacters = 1_200
    static let maxSynopsisCharacters = 4_000

    let fileURL: URL
    private(set) var contents: Contents
    private let fileManager: FileManager

    convenience init(runtimePaths: ToasttyRuntimePaths) {
        self.init(fileURL: runtimePaths.configDirectoryURL.appendingPathComponent(Self.fileName))
    }

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        contents = Self.read(fileURL) ?? Contents()
    }

    private static func read(_ url: URL) -> Contents? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(Contents.self, from: data)
        } catch {
            ToasttyLog.warning(
                "Could not read the workspace overview file",
                category: .store,
                metadata: ["path": url.path, "error": error.localizedDescription]
            )
            return nil
        }
    }

    func update(_ change: (inout Contents) -> Void) throws {
        var next = contents
        change(&next)
        guard next != contents else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        contents = next
    }

    static func clipped(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }
}
