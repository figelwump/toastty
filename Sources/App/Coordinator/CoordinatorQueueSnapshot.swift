import CoreState
import Foundation

/// The user's messages that wait for the coordinator's prompt, as Toastty
/// saves them. `CoordinatorController` writes the file at every change of
/// its queue and reads it once, at launch.
///
/// Only messages that a person sent are saved. A message from
/// `coordinator send` waits in memory, and a wake digest is saved with the
/// task changes it is made from.
struct CoordinatorQueueSnapshot: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var id: String
        /// The text as it is typed, with Toastty's first line and the
        /// paths of the attached files.
        var text: String
        /// Set on a paused entry whose typing a quit interrupted.
        var typingWasInterrupted: Bool?
    }

    var version = 1
    /// The coordinator's workspace the messages were sent to.
    var workspaceID: UUID
    /// In the order they are typed.
    var queued: [Entry]
    /// Set aside by the user's Stop, or by an interrupted typing.
    var paused: [Entry]
    /// The queued entry that Toastty was typing when it saved this. After
    /// a relaunch nobody knows whether the terminal took it.
    var typingEntryID: String?

    static func load(from url: URL) -> CoordinatorQueueSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(CoordinatorQueueSnapshot.self, from: data)
        } catch {
            ToasttyLog.warning("Could not read the messages that waited for the coordinator", category: .tasks, metadata: [
                "path": url.path, "error": error.localizedDescription,
            ])
            return nil
        }
    }

    /// The messages are the user's words, so the file is the user's only.
    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Removes the file. A file that is not there is removed already.
    static func remove(at url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}
