import Foundation
import RemoteProtocol

/// Which of the coordinator's wake turns are quiet, as the Mac shares them:
/// the keys of the digests whose turn the coordinator marked quiet. The
/// coordinator's chat folds such a turn under its digest's line, as the
/// Mac's chat does.
///
/// The session snapshot names only the revision of the Mac's set. The keys
/// are read when the snapshot names a revision that this phone does not
/// have, one read at a time. A read that fails is tried again with the next
/// snapshot.
struct ToasttyCoordinatorQuietDigests: Equatable {
    /// The keys from the Mac's last answer. `nil` with a Mac that does not
    /// share them, or before its first answer: then no turn folds.
    private(set) var keys: Set<String>?
    /// The revision of `keys`.
    private var revision: String?
    /// The revision that the newest snapshot names.
    private var announced: String?
    /// The announced revision when the read that runs now started. `nil`
    /// while no read runs.
    private var reading: String?
    /// The announced revision that the last answer was for. A late answer
    /// can be newer than the snapshot that asked for it; the snapshot with
    /// that newer revision follows.
    private var answeredFor: String?

    /// The newest snapshot names `revision` on the coordinator's workspace,
    /// or `nil`: a Mac that does not share the quiet turns, or no
    /// coordinator. Returns whether to read the keys now; then call
    /// `willRead()` and, with the answer, `didRead(_:)`.
    mutating func consume(revision: String?) -> Bool {
        announced = revision
        guard revision != nil else {
            // Turns fold only with a Mac that shares the marks.
            keys = nil
            self.revision = nil
            answeredFor = nil
            return false
        }
        return needsRead
    }

    mutating func willRead() {
        reading = announced ?? ""
    }

    /// The Mac's answer, or `nil` when the read failed or was not sent.
    /// Returns whether to read again: the snapshot named a newer revision
    /// while the read ran.
    mutating func didRead(_ answer: RemoteCoordinatorQuietDigests?) -> Bool {
        let askedFor = reading
        reading = nil
        guard let answer else {
            // The next snapshot tries again.
            answeredFor = nil
            return false
        }
        // A snapshot that no longer names a revision ended the sharing.
        guard announced != nil else { return false }
        keys = Set(answer.keys)
        revision = answer.revision
        answeredFor = askedFor
        return needsRead
    }

    private var needsRead: Bool {
        guard reading == nil, let announced else { return false }
        return announced != revision && announced != answeredFor
    }

    /// Whether the digest with this text started a quiet turn.
    static func isQuiet(_ text: String, keys: Set<String>?) -> Bool {
        guard let keys, keys.isEmpty == false else { return false }
        return keys.contains(CoordinatorMessageHeader.digestKey(text))
    }
}
