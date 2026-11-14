import ConversationUI
import Foundation

/// Which of the coordinator's rows the user has not seen yet.
enum CoordinatorChatReadPoint {
    /// The new messages' line for the rows after `readThrough`, or `nil`
    /// when none of them is a message from the coordinator.
    ///
    /// The user's own messages are never new, and the line never goes
    /// above one. A wake turn that the coordinator marked quiet is not new
    /// either: it folds under one line because it has nothing for the
    /// user. The count is the coordinator's responses below the line.
    static func marker(in rows: [ToasttyTranscriptRow], after readThrough: Date?) -> ToasttyNewMessagesMarker? {
        guard let readThrough else { return nil }
        var firstRowID: ToasttyTranscriptRowID?
        var count = 0
        var isInQuietTurn = false
        for row in rows {
            switch row.content {
            case .userMessage:
                isInQuietTurn = false
            case .hostMessage(let message):
                isInQuietTurn = message.foldsTurn
            default:
                break
            }
            guard row.timestamp > readThrough, isInQuietTurn == false else { continue }
            if case .userMessage = row.content { continue }
            if firstRowID == nil { firstRowID = row.id }
            if case .assistantMessage(_, let phase) = row.content, phase != .commentary {
                count += 1
            }
        }
        guard let firstRowID, count > 0 else { return nil }
        return ToasttyNewMessagesMarker(firstRowID: firstRowID, count: count)
    }
}
