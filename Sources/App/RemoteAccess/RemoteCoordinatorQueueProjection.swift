import CryptoKit
import Foundation
import RemoteProtocol

/// The coordinator's own queue as a paired device reads it
/// (`RemoteCoordinatorQueue`): the entries that a Stop set aside, then those
/// that wait, each as the Mac chat's waiting bubble shows it. Display text
/// only: an attached file goes by its name, never its path.
enum RemoteCoordinatorQueueProjection {
    static func queue(
        held: [CoordinatorController.QueuedEntry],
        waiting: [CoordinatorController.QueuedEntry],
        conversationID: RemoteConversationID?,
        heldSetToken: String?
    ) -> RemoteCoordinatorQueue {
        let entries = held.map { entry($0, isHeld: true) } + waiting.map { entry($0, isHeld: false) }
        return RemoteCoordinatorQueue(
            revision: revision(held: held, waiting: waiting, conversationID: conversationID, heldSetToken: heldSetToken),
            conversationID: conversationID,
            heldSetToken: heldSetToken,
            entries: entries
        )
    }

    static func entry(_ entry: CoordinatorController.QueuedEntry, isHeld: Bool) -> RemoteCoordinatorQueueEntry {
        var sender: String?
        var quote: String?
        var quoteTime: String?
        var text: String
        switch CoordinatorMessageHeader.kind(of: entry.text) {
        case .fromSender(let name):
            // Toastty's first line names the sender. The text after it is
            // the sender's own.
            sender = name
            text = entry.text.firstIndex(where: \.isNewline).map { String(entry.text[entry.text.index(after: $0)...]) } ?? ""
        case .reply(let replyQuote, let time, _, _):
            quote = replyQuote
            quoteTime = time
            text = CoordinatorMessageHeader.displayText(of: entry.text)
        case .digest, .quickEntry, .plain:
            text = CoordinatorMessageHeader.displayText(of: entry.text)
        }
        // Toastty's list of attached files names each copy by its path. A
        // message whose first line is any of Toastty's shows the names in
        // its place, as `displayText` does for the user's own.
        if let (rest, paths) = CoordinatorMessageHeader.attachedFiles(in: text) {
            let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
            text = [rest, names].filter { $0.isEmpty == false }.joined(separator: "\n\n")
        }
        let (shortText, isShortened) = shortened(text, to: RemoteCoordinatorQueuePolicy.maximumTextLength)
        return RemoteCoordinatorQueueEntry(
            id: entry.id,
            text: shortText,
            isTextShortened: isShortened,
            sender: sender,
            quote: quote.map { shortened($0, to: RemoteCoordinatorQueuePolicy.maximumQuoteLength).text },
            quoteTime: quoteTime,
            fileNames: fileNames(of: entry.text),
            isHeld: isHeld,
            typingWasInterrupted: entry.typingWasInterrupted
        )
    }

    /// The names of the files that Toastty listed on the message, as the
    /// Mac chat counts them (`CoordinatorChatModel.attachmentCount`).
    static func fileNames(of text: String) -> [String] {
        (CoordinatorMessageHeader.attachedFiles(in: text)?.paths ?? []).map {
            URL(fileURLWithPath: $0).lastPathComponent
        }
    }

    /// The first 16 hex digits of the SHA-256 of what a device shows and
    /// acts on: the conversation, the Stop's token, and each entry's ID,
    /// hold and interrupted mark. An entry's text never changes under its
    /// ID. Each session list carries it, so it reads only IDs and marks.
    static func revision(
        held: [CoordinatorController.QueuedEntry],
        waiting: [CoordinatorController.QueuedEntry],
        conversationID: RemoteConversationID?,
        heldSetToken: String?
    ) -> String {
        func line(_ state: String, _ entry: CoordinatorController.QueuedEntry) -> String {
            entry.typingWasInterrupted ? "\(state) \(entry.id) interrupted" : "\(state) \(entry.id)"
        }
        var lines = [conversationID?.rawValue.uuidString ?? "-", heldSetToken ?? "-"]
        lines += held.map { line("held", $0) } + waiting.map { line("waiting", $0) }
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func shortened(_ text: String, to limit: Int) -> (text: String, isShortened: Bool) {
        guard text.count > limit else { return (text, false) }
        return (String(text.prefix(limit - 1)) + "…", true)
    }
}
