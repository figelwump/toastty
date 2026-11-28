import CoreState
import Foundation

/// The workspace and terminal panel the coordinator lives in, saved beside
/// the layout.
///
/// The layout marks the coordinator's workspace (`WorkspaceState.isCoordinator`).
/// A Toastty that does not know the coordinator, such as v0.9.2, reads that
/// layout and saves it again without the mark. The coordinator's workspace
/// is then an ordinary one, and its folder keeps Toastty from offering a new
/// coordinator. `CoordinatorController` writes this record at each change of
/// the coordinator's place, removes it when the coordinator closes, and puts
/// the mark back from it at launch.
struct CoordinatorWorkspaceRecord: Codable, Equatable {
    var version = 1
    var workspaceID: UUID
    /// `nil` while the coordinator's terminal is closed.
    var panelID: UUID?
    /// Set while the coordinator's agent is a direct session
    /// (`ClaudeDirectSession`): Claude's own ID of the conversation and its
    /// transcript file. After a relaunch Toastty resumes that conversation
    /// as a direct session again, and the terminal starts no agent. A
    /// Toastty without direct sessions does not read this, and resumes the
    /// conversation in the terminal.
    var directSession: DirectSession?

    struct DirectSession: Codable, Equatable {
        var nativeSessionID: String
        var transcriptPath: String
        /// The workspaces that the session was limited to, as its resume
        /// record has them. `nil` for no limit.
        var scopedWorkspaceIDs: Set<UUID>?
        /// The messages that the session's process got and whose turn had
        /// not ended, each saved before its line was written. After a quit
        /// or a crash, the next start of the conversation reads them
        /// against Claude's transcript file: the turn of a message that
        /// Claude took was cut off, and a message that it did not take
        /// never reached it. `nil` for none.
        var messagesInTurn: [UnfinishedMessage]?
        /// The message whose turn a quit or a crash cut off, while the
        /// chat says so. `nil` when there is none, or the user dismissed it.
        var cutOffMessage: UnfinishedMessage?

        init(
            nativeSessionID: String,
            transcriptPath: String,
            scopedWorkspaceIDs: Set<UUID>?,
            messagesInTurn: [UnfinishedMessage]? = nil,
            cutOffMessage: UnfinishedMessage? = nil
        ) {
            self.nativeSessionID = nativeSessionID
            self.transcriptPath = transcriptPath
            self.scopedWorkspaceIDs = scopedWorkspaceIDs
            self.messagesInTurn = messagesInTurn
            self.cutOffMessage = cutOffMessage
        }
    }

    /// A message that a direct session's process got, as the record keeps
    /// it until its turn ends.
    struct UnfinishedMessage: Codable, Equatable {
        /// The sender's ID of the message (its `clientRequestID`).
        var id: String
        /// The `uuid` of the message's line, which its record in Claude's
        /// transcript file has once Claude took it.
        var messageID: String
        /// The text as the process got it.
        var text: String
        /// A person sent it: in the Mac's chat or on a phone. `false` for
        /// Toastty's digest or a message from `coordinator send`.
        var byUser: Bool
        /// The folders of attached files that the entry owned, when this
        /// Mac sent it (`CoordinatorController.QueuedEntry.attachmentFolders`).
        var attachmentFolders: [String]?
    }

    init(workspaceID: UUID, panelID: UUID?, directSession: DirectSession? = nil) {
        self.workspaceID = workspaceID
        self.panelID = panelID
        self.directSession = directSession
    }

    /// `nil` when there is no file, or when it cannot be read.
    static func load(from url: URL) -> CoordinatorWorkspaceRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(CoordinatorWorkspaceRecord.self, from: data)
        } catch {
            ToasttyLog.warning("Could not read where the coordinator lives", category: .tasks, metadata: [
                "path": url.path, "error": error.localizedDescription,
            ])
            return nil
        }
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
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
