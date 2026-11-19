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
        /// The folders of attached files that the entry owns, by name
        /// (`CoordinatorController.QueuedEntry.attachmentFolders`). `nil` in
        /// a file of a build before the list.
        var attachmentFolders: [String]?

        /// What the entry owns: an entry from an older file owns only its
        /// own folder. Its text never adds one.
        var ownedAttachmentFolders: [String] {
            attachmentFolders ?? [id]
        }
    }

    var version = 1
    /// The coordinator's workspace the messages were sent to.
    var workspaceID: UUID
    /// In the order they are typed.
    var queued: [Entry]
    /// Set aside by the user's Stop, or by an interrupted typing.
    var paused: [Entry]
    /// The waiting entry that Toastty was typing when it saved this: the
    /// first queued one, or any one that "Steer now" types into a running
    /// turn. After a relaunch nobody knows whether the terminal took it.
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
    /// The new content is written whole, with the user's permissions, beside
    /// the file and then takes its place in one step: a save that throws
    /// leaves the file as it was. Remove relies on that.
    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)", directoryHint: .notDirectory)
        do {
            try data.write(to: temporary, options: [.withoutOverwriting])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            guard rename(temporary.path, url.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
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
