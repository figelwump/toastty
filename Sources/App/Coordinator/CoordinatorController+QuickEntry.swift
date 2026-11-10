import CoreState
import Foundation

/// A message from the quick entry panel for the coordinator.
struct QuickEntryCoordinatorMessage: Equatable {
    /// Names the message. One panel sends one message, so a second submit
    /// of the same draft cannot make a second one.
    var id = UUID()
    var text: String
    /// Toastty's staged copies of the attached files.
    var files: [URL] = []
    /// The choices the user made in the panel, and the project that was
    /// selected in Toastty when the panel opened.
    var choices = CoordinatorMessageHeader.QuickEntry()
}

extension CoordinatorController {
    /// Sends the user's message from the quick entry panel. Toastty copies
    /// the attached files into the coordinator's folder first, and the
    /// message names the copies. The message then waits, saved, until the
    /// coordinator's prompt takes it.
    func sendQuickEntry(_ message: QuickEntryCoordinatorMessage) async throws -> SendResult {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else {
            throw CoordinatorError("The message is empty.")
        }
        guard let workspaceID = location?.workspaceID else {
            throw CoordinatorError("There is no coordinator. Open it first.")
        }
        let attachments = attachments
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
            return try send(
                CoordinatorMessageHeader.quickEntryMessage(
                    message.choices,
                    text: text,
                    attachmentPaths: copies.map { $0.path(percentEncoded: false) }
                ),
                byUser: true,
                id: id.uuidString
            )
        } catch {
            // Not taken: the copies have no message.
            attachments.discard(messageID: id.uuidString)
            throw error
        }
    }
}
