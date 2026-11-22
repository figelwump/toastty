import Foundation
import RemoteProtocol

/// Which of the coordinator chat's rows the user has not seen yet, and
/// which read is newer. The Mac's chat and the iPhone's use the same rule,
/// with the read point that the Mac keeps for both.
///
/// A read point names its row by the row's transcript event. When the
/// rows have that row, the rows after it are the ones after the read
/// point. When they do not, because the row is older than the rows read so
/// far or the read point has no event, the rows later than its time are.
public enum CoordinatorChatReadPoint {
    /// The most older pages a chat reads, after it opens, to reach back to
    /// the read point.
    public static let maximumOlderPages = 5

    /// The read point at the newest of `rows`, or `nil` without rows.
    public static func readPoint(through rows: [ToasttyTranscriptRow]) -> RemoteCoordinatorChatReadPoint? {
        rows.last.map { RemoteCoordinatorChatReadPoint(eventID: $0.eventID, timestamp: $0.timestamp) }
    }

    /// Where `readPoint`'s row is in `rows`, or `nil` when `rows` does not
    /// have it.
    public static func index(of readPoint: RemoteCoordinatorChatReadPoint, in rows: [ToasttyTranscriptRow]) -> Int? {
        guard let eventID = readPoint.eventID else { return nil }
        return rows.lastIndex { $0.eventID == eventID }
    }

    /// The new messages' line for the rows after `readPoint`, or `nil`
    /// when none of them is a message from the coordinator.
    ///
    /// The user's own messages are never new, and the line never goes
    /// above one. A wake turn that the coordinator marked quiet is not new
    /// either: it folds under one line because it has nothing for the
    /// user. The count is the coordinator's responses below the line.
    public static func marker(
        in rows: [ToasttyTranscriptRow],
        after readPoint: RemoteCoordinatorChatReadPoint?
    ) -> ToasttyNewMessagesMarker? {
        guard let readPoint else { return nil }
        let readIndex = index(of: readPoint, in: rows)
        var firstRowID: ToasttyTranscriptRowID?
        var count = 0
        var isInQuietTurn = false
        for (index, row) in rows.enumerated() {
            switch row.content {
            case .userMessage:
                isInQuietTurn = false
            case .hostMessage(let message):
                isInQuietTurn = message.foldsTurn
            default:
                break
            }
            let isAfterReadPoint = readIndex.map { index > $0 } ?? (row.timestamp > readPoint.timestamp)
            guard isAfterReadPoint, isInQuietTurn == false else { continue }
            if case .userMessage = row.content { continue }
            if firstRowID == nil { firstRowID = row.id }
            if case .assistantMessage(_, let phase) = row.content, phase != .commentary {
                count += 1
            }
        }
        guard let firstRowID, count > 0 else { return nil }
        return ToasttyNewMessagesMarker(firstRowID: firstRowID, count: count)
    }

    /// Whether a chat that has `rows` should read an older page before it
    /// places the line: its rows do not reach back to the read point yet.
    public static func needsOlderRows(
        _ rows: [ToasttyTranscriptRow],
        toReach readPoint: RemoteCoordinatorChatReadPoint
    ) -> Bool {
        guard let oldest = rows.first, index(of: readPoint, in: rows) == nil else { return false }
        return oldest.timestamp > readPoint.timestamp
    }

    /// Whether `candidate` is a later read than `current`. `position`
    /// gives a read point's place in the conversation when the caller has
    /// its row; otherwise the times decide.
    public static func isNewer(
        _ candidate: RemoteCoordinatorChatReadPoint,
        than current: RemoteCoordinatorChatReadPoint?,
        position: (RemoteCoordinatorChatReadPoint) -> Int?
    ) -> Bool {
        guard let current else { return true }
        if let candidateID = candidate.eventID, candidateID == current.eventID { return false }
        if let candidatePosition = position(candidate), let currentPosition = position(current) {
            return candidatePosition > currentPosition
        }
        return candidate.timestamp > current.timestamp
    }

    /// `isNewer` for a chat that has `rows`.
    public static func isNewer(
        _ candidate: RemoteCoordinatorChatReadPoint,
        than current: RemoteCoordinatorChatReadPoint?,
        in rows: [ToasttyTranscriptRow]
    ) -> Bool {
        isNewer(candidate, than: current) { index(of: $0, in: rows) }
    }

    /// The later of two read points, for a chat that has `rows`.
    public static func newer(
        _ first: RemoteCoordinatorChatReadPoint?,
        _ second: RemoteCoordinatorChatReadPoint?,
        in rows: [ToasttyTranscriptRow]
    ) -> RemoteCoordinatorChatReadPoint? {
        guard let first else { return second }
        guard let second else { return first }
        return isNewer(second, than: first, in: rows) ? second : first
    }
}
