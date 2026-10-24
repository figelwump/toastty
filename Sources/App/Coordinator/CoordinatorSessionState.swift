import CoreState
import Foundation

enum CoordinatorSessionStatus: Equatable, Sendable {
    case unavailable(String)
    case stopped
    case starting
    /// The terminal runtime owns the resume. Do not issue a second launch.
    case waitingForRestore
    case running
    case error(String)
}

struct CoordinatorSessionConfiguration: Codable, Equatable {
    var profileID: String?
    var model: String?
    var reasoningEffort: String?
    /// Pauses automatic inputs and starts. It does not interrupt a provider turn.
    var automaticWorkEnabled = true
}

struct CoordinatorSessionIdentity: Codable, Equatable {
    var workspaceID: UUID
    var panelID: UUID
}

/// Separate from provider history and durable review records. Workspace layouts
/// retain the actual native resume record; this file only locates that terminal.
struct CoordinatorSessionState: Codable {
    var version = 1
    var configuration: CoordinatorSessionConfiguration
    var identity: CoordinatorSessionIdentity?
    var lastManagedSessionID: String?
    /// Written before dispatch. A crash or uncertain delivery must not replay it.
    var launchNeedsInspection = false

    static func load(from url: URL) throws -> Self? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let state = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard state.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return state
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
