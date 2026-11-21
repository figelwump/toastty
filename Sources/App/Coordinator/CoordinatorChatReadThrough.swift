import Combine
import ConversationUI
import Foundation
import RemoteProtocol

/// The coordinator chat's read point: the newest row that the user read,
/// in the Mac's chat or on a paired device. It lives with the coordinator,
/// so the chat and Remote Access read and move the same one, and it only
/// moves forward.
///
/// It is saved in user defaults, so that it survives a relaunch, in two
/// values:
/// - `timeDefaultsKey`: the read row's time, as Toastty saved it before it
///   named rows by identity. An older Toastty reads and writes only this.
/// - `eventDefaultsKey`: the read row's transcript event, with the time it
///   belongs to. It counts only while that time is the saved time, so a
///   read point that an older Toastty moved since is read by its time.
@MainActor
final class CoordinatorChatReadThrough {
    static let timeDefaultsKey = "toastty.coordinator.chatReadThrough"
    static let eventDefaultsKey = "toastty.coordinator.chatReadThroughEvent"

    /// `nil` before the user read the chat.
    private(set) var point: RemoteCoordinatorChatReadPoint?
    /// Each move, after it is saved.
    let moves = PassthroughSubject<RemoteCoordinatorChatReadPoint, Never>()
    /// `nil` for a run that saves no preferences, such as an automation run.
    private let defaults: UserDefaults?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        point = Self.load(from: defaults)
    }

    /// Moves the read point to `candidate` when it is a later read.
    /// `position` gives a read point's place in the caller's rows or
    /// events, when the caller has its row.
    @discardableResult
    func advance(
        to candidate: RemoteCoordinatorChatReadPoint,
        position: (RemoteCoordinatorChatReadPoint) -> Int?
    ) -> Bool {
        guard CoordinatorChatReadPoint.isNewer(candidate, than: point, position: position) else { return false }
        point = candidate
        save(candidate)
        moves.send(candidate)
        return true
    }

    private static func load(from defaults: UserDefaults?) -> RemoteCoordinatorChatReadPoint? {
        guard let time = defaults?.object(forKey: timeDefaultsKey) as? Double else { return nil }
        let saved = defaults?.dictionary(forKey: eventDefaultsKey)
        let eventID = (saved?["time"] as? Double) == time ? saved?["eventID"] as? String : nil
        return RemoteCoordinatorChatReadPoint(eventID: eventID, timestamp: Date(timeIntervalSinceReferenceDate: time))
    }

    private func save(_ point: RemoteCoordinatorChatReadPoint) {
        guard let defaults else { return }
        let time = point.timestamp.timeIntervalSinceReferenceDate
        defaults.set(time, forKey: Self.timeDefaultsKey)
        if let eventID = point.eventID {
            defaults.set(["eventID": eventID, "time": time], forKey: Self.eventDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.eventDefaultsKey)
        }
    }
}
