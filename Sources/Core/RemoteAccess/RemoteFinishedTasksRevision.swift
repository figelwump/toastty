import CryptoKit
import Foundation
import RemoteProtocol

extension RemoteFinishedTasks {
    /// These tasks, with their revision.
    public init(tasks: [RemoteFinishedTask]) {
        self.init(revision: Self.revision(of: tasks), tasks: tasks)
    }

    /// The first 16 hex digits of the SHA-256 of the tasks as the wire
    /// encodes them. Any change that a device shows, such as a new title or
    /// a pull request that merged, gives a new revision; the same tasks give
    /// the same one, also after a relaunch.
    public static func revision(of tasks: [RemoteFinishedTask]) -> String {
        let data = (try? ConversationEventCoding.makeEncoder().encode(tasks)) ?? Data()
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
