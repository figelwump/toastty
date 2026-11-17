import Foundation
import RemoteProtocol

/// Which of the coordinator's wake turns are quiet, as the Mac shares them:
/// the keys of the digests whose turn the coordinator marked quiet. The
/// coordinator's chat folds such a turn under its digest's line, as the
/// Mac's chat does.
///
/// The session snapshot names only the revision of the Mac's set. The keys
/// are read when a snapshot names a revision that this phone does not
/// have, one read at a time. An answer belongs to the snapshot that asked
/// for it, not to a revision: the marks can change and change back while a
/// read runs, so a later snapshot always counts. A read that fails is tried
/// again when a snapshot came while it ran, and otherwise with the next
/// snapshot.
struct ToasttyCoordinatorQuietDigests: Equatable {
    /// The keys from the Mac's last answer. `nil` with a Mac that does not
    /// share them, or before its first answer: then no turn folds.
    private(set) var keys: Set<String>?
    /// The revision of `keys`.
    private var revision: String?
    /// The revision that the newest snapshot names.
    private var announced: String?
    /// Counts the snapshots, so that an answer is tied to the one that
    /// asked for it.
    private var announcements = 0
    /// `announcements` when the read that runs now started. `nil` while no
    /// read runs.
    private var reading: Int?
    /// `announcements` when the read that answered last started. Its answer
    /// can be newer than that snapshot, when the Mac changed in between:
    /// that snapshot asks for nothing more, and a later one does.
    private var answered: Int?

    /// The newest snapshot names `revision` on the coordinator's workspace,
    /// or `nil`: a Mac that does not share the quiet turns, or no
    /// coordinator. Returns whether to read the keys now; then call
    /// `willRead()` and, with the answer, `didRead(_:)`.
    mutating func consume(revision: String?) -> Bool {
        announcements += 1
        announced = revision
        guard revision != nil else {
            // Turns fold only with a Mac that shares the marks.
            keys = nil
            self.revision = nil
            return false
        }
        return needsRead
    }

    mutating func willRead() {
        reading = announcements
    }

    /// The Mac's answer, or `nil` when the read failed or was not sent.
    /// Returns whether to read again.
    mutating func didRead(_ answer: RemoteCoordinatorQuietDigests?) -> Bool {
        let askedAt = reading
        reading = nil
        // A snapshot that no longer names a revision ended the sharing.
        guard announced != nil else { return false }
        if let answer {
            keys = Set(answer.keys)
            revision = answer.revision
            answered = askedAt
        } else if askedAt == announcements {
            // No snapshot came while it ran: the next one tries again.
            return false
        }
        return needsRead
    }

    private var needsRead: Bool {
        guard reading == nil, let announced else { return false }
        return announced != revision && answered != announcements
    }

    /// Whether the digest with this text started a quiet turn.
    static func isQuiet(_ text: String, keys: Set<String>?) -> Bool {
        guard let keys, keys.isEmpty == false else { return false }
        return keys.contains(CoordinatorMessageHeader.digestKey(text))
    }
}
