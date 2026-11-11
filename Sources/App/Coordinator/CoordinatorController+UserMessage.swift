import CoreState
import Foundation

/// The coordinator's message that the user's message answers.
struct CoordinatorReplyTarget: Equatable {
    /// The whole message.
    var text: String
    /// When the coordinator wrote it, as the chat shows a time: "14:05".
    var time: String?

    /// The text to type: Toastty's first line, this message as a quote,
    /// then the user's text and the paths of the attached files.
    func message(text userText: String, attachmentPaths: [String] = []) -> String {
        CoordinatorMessageHeader.replyMessage(quote: text, time: time, text: userText, attachmentPaths: attachmentPaths)
    }
}

/// The user's message for the coordinator, from the chat's composer or from
/// the quick entry panel, with the files attached to it.
struct CoordinatorUserMessage: Equatable {
    /// Names the message. One draft sends one message, so a second submit
    /// of the same draft cannot make a second one.
    var id = UUID()
    var text: String
    /// Files to copy into the coordinator's folder for this message.
    var files: [URL] = []
    /// Copies that a waiting message made, which the user took back into
    /// the chat's field with Edit. They stay where they are and come first.
    var stagedFiles: [URL] = []
    /// The choices the user made in the quick entry panel, and the project
    /// that was selected in Toastty when the panel opened. `nil` for a
    /// message from the chat, which has no header line.
    var quickEntry: CoordinatorMessageHeader.QuickEntry?
    /// The coordinator's message that this one answers, for a reply from
    /// the chat.
    var reply: CoordinatorReplyTarget?
}

extension CoordinatorController {
    /// Sends the user's message. Toastty copies the attached files into the
    /// coordinator's folder first, and the message names the copies. With
    /// `steering`, a message from the chat goes into the coordinator's
    /// running turn when that turn can take it, as `sendUserText` sends it.
    /// Otherwise the message waits, saved, until the coordinator's prompt
    /// takes it. A quick entry message never goes into a running turn.
    func sendUserMessage(_ message: CoordinatorUserMessage, steering: Bool = false) async throws -> SendResult {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false || message.files.isEmpty == false || message.stagedFiles.isEmpty == false else {
            throw CoordinatorError("The message is empty.")
        }
        guard let workspaceID = location?.workspaceID else {
            throw CoordinatorError("There is no coordinator. Open it first.")
        }
        guard message.files.count + message.stagedFiles.count <= TaskRecord.maximumAttachmentCount else {
            throw CoordinatorError("Attach at most \(TaskRecord.maximumAttachmentCount) files.")
        }
        let attachments = attachments
        try attachments.checkStaged(message.stagedFiles)
        let files = message.files
        let id = message.id
        let copies = try await Task.detached(priority: .userInitiated) {
            try attachments.stage(files, messageID: id)
        }.value
        do {
            // The copy took time. The message is for the coordinator that
            // was there when the user sent it, not for one opened since.
            guard location?.workspaceID == workspaceID else {
                throw CoordinatorError("The coordinator closed. Nothing was sent.")
            }
            let paths = (message.stagedFiles + copies).map { $0.path(percentEncoded: false) }
            let delivered = if let choices = message.quickEntry {
                CoordinatorMessageHeader.quickEntryMessage(choices, text: text, attachmentPaths: paths)
            } else if let reply = message.reply {
                reply.message(text: text, attachmentPaths: paths)
            } else {
                RemoteMessageAttachmentStore.Staged.deliveryText(text: text, paths: paths)
            }
            return try sendUserText(delivered, steering: steering && message.quickEntry == nil, id: id.uuidString)
        } catch {
            // Not taken: the copies have no message. The staged files stay
            // with the folder of the message they came from.
            attachments.discard(messageID: id.uuidString)
            throw error
        }
    }
}
