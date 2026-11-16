import ConversationUI
import Foundation
import RemoteProtocol

/// The coordinator chat's New line on the iPhone, from the read point that
/// the Mac keeps for its own chat and for this phone.
///
/// It follows the Mac chat's rules (`CoordinatorChatModel`):
/// - The line goes above the first coordinator message after the read
///   point, and Jump to latest counts the coordinator's messages below it
///   (`CoordinatorChatReadPoint`, which the Mac uses too).
/// - It is placed when the user comes to the chat: a new controller for
///   each visit, or the app back in the foreground. It stays where it is
///   while the user reads, and a send removes it.
/// - What arrives while the chat is on screen and the app is active is
///   read. This phone sends its reads to the Mac, which moves the read
///   point for both.
///
/// The phone reads only the newest page when the chat opens. When the read
/// point is older, the line goes above the oldest coordinator message
/// loaded, and moves up as older pages arrive, until the rows reach the
/// read point or `CoordinatorChatReadPoint.maximumOlderPages` pages came.
struct ToasttyCoordinatorChatReading: Equatable {
    /// What an update asks of the chat's owner.
    enum Step: Equatable {
        case none
        /// Read the page before the oldest row, to reach the read point.
        case loadOlder
    }

    /// A read of this phone to send to the Mac.
    struct Report: Equatable {
        var readPoint: RemoteCoordinatorChatReadPoint
        /// The row's event as the Mac named it, also a runtime event's,
        /// which the Mac finds in its current conversation.
        var eventID: String
    }

    /// The read point as the Mac last sent it.
    private(set) var macReadPoint: RemoteCoordinatorChatReadPoint?
    /// The newest row that this phone showed. It counts here until the
    /// Mac's read point reaches it.
    private(set) var phoneReadPoint: RemoteCoordinatorChatReadPoint?
    private var phoneReadEventID: String?
    /// The read last sent to the Mac.
    private var reported: RemoteCoordinatorChatReadPoint?
    /// The line on screen, or `nil`.
    private(set) var newMessages: ToasttyNewMessagesMarker?

    /// The next update places the line: the user came to the chat.
    private var arrives = true
    /// The read point when the user came. The line marks what is after it.
    private var arrival: RemoteCoordinatorChatReadPoint?
    /// Older pages are read so that the line goes where the user stopped.
    private var isPlacingLine = false
    /// The line marks the rows after this read point while the user stays.
    private var lineAfter: RemoteCoordinatorChatReadPoint?
    private var pagesRequested = 0
    /// The oldest row when the last page was asked for, and how often it
    /// was asked for: a request can be dropped, and asked again a few times.
    private var requestedBefore: ToasttyTranscriptRowID?
    private var requestsBeforeRow = 0
    static let maximumRequestsPerPage = 3

    /// The read point of this phone or the Mac, whichever is later.
    func readPoint(in rows: [ToasttyTranscriptRow]) -> RemoteCoordinatorChatReadPoint? {
        CoordinatorChatReadPoint.newer(macReadPoint, phoneReadPoint, in: rows)
    }

    mutating func consumeMacReadPoint(_ readPoint: RemoteCoordinatorChatReadPoint?) {
        macReadPoint = readPoint
    }

    /// The user came back to the chat: the app is in the foreground again.
    /// The line is placed again, and may read older pages again.
    mutating func userCameBack() {
        arrives = true
        pagesRequested = 0
        requestedBefore = nil
    }

    /// The rows changed, or whether the user reads. `isReading`: the chat
    /// is on screen, its rows are live, and the app is active.
    mutating func update(
        rows: [ToasttyTranscriptRow],
        hasOlder: Bool,
        isLoadingOlder: Bool,
        isReading: Bool
    ) -> Step {
        if arrives {
            arrives = false
            arrival = readPoint(in: rows)
            isPlacingLine = true
        }
        var step = Step.none
        if isPlacingLine {
            step = nextPage(rows: rows, hasOlder: hasOlder, isLoadingOlder: isLoadingOlder)
            lineAfter = CoordinatorChatReadPoint.marker(in: rows, after: arrival) == nil ? nil : arrival
        }
        newMessages = lineAfter.flatMap { CoordinatorChatReadPoint.marker(in: rows, after: $0) }
        if isReading {
            noteRead(through: rows)
        } else {
            // Not read: the line is placed again when the user reads.
            arrives = true
        }
        return step
    }

    /// The user sent a message: what is above the composer is read.
    mutating func userSent(rows: [ToasttyTranscriptRow]) {
        isPlacingLine = false
        lineAfter = nil
        newMessages = nil
        noteRead(through: rows)
    }

    /// The read to send to the Mac: this phone's newest read, when the
    /// Mac's read point is earlier and it was not sent yet.
    func report(in rows: [ToasttyTranscriptRow]) -> Report? {
        guard let phoneReadPoint, let phoneReadEventID, phoneReadPoint != reported,
              CoordinatorChatReadPoint.isNewer(phoneReadPoint, than: macReadPoint, in: rows) else { return nil }
        return Report(readPoint: phoneReadPoint, eventID: phoneReadEventID)
    }

    /// The Mac answered `report`: it moved its read point, or already had
    /// it, or cannot take it.
    mutating func didReport(_ report: Report) {
        reported = report.readPoint
    }

    private mutating func noteRead(through rows: [ToasttyTranscriptRow]) {
        guard let row = rows.last,
              let candidate = CoordinatorChatReadPoint.readPoint(through: rows),
              CoordinatorChatReadPoint.isNewer(candidate, than: readPoint(in: rows), in: rows) else { return }
        phoneReadPoint = candidate
        phoneReadEventID = row.eventID
    }

    /// Whether to ask for an older page now. Placing the line ends when
    /// the rows reach the read point, or the pages or requests run out.
    private mutating func nextPage(rows: [ToasttyTranscriptRow], hasOlder: Bool, isLoadingOlder: Bool) -> Step {
        guard let arrival, hasOlder, CoordinatorChatReadPoint.needsOlderRows(rows, toReach: arrival) else {
            isPlacingLine = false
            return .none
        }
        let oldest = rows.first?.id
        if oldest != requestedBefore {
            guard pagesRequested < CoordinatorChatReadPoint.maximumOlderPages else {
                isPlacingLine = false
                return .none
            }
            pagesRequested += 1
            requestedBefore = oldest
            requestsBeforeRow = 0
        }
        guard isLoadingOlder == false else { return .none }
        guard requestsBeforeRow < Self.maximumRequestsPerPage else {
            isPlacingLine = false
            return .none
        }
        requestsBeforeRow += 1
        return .loadOlder
    }
}
