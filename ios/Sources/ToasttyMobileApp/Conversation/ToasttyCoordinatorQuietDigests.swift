import ConversationUI
import Foundation
import RemoteProtocol

/// Something the Mac shares by revision: the session snapshot names only
/// the revision, and a device reads the value when a snapshot names a
/// revision that it does not have, one read at a time. An answer belongs to
/// the snapshot that asked for it, not to a revision: the value can change
/// and change back while a read runs, so a later snapshot always counts. A
/// read that fails is tried again when a snapshot came while it ran, and
/// otherwise with the next snapshot.
protocol ToasttyMacRevisioned: Equatable {
    var revision: String { get }
}

extension RemoteCoordinatorQuietDigests: ToasttyMacRevisioned {}
extension RemoteCoordinatorQueue: ToasttyMacRevisioned {}

struct ToasttyMacRevisionedRead<Answer: ToasttyMacRevisioned>: Equatable {
    /// The Mac's last answer. `nil` with a Mac that does not share it, or
    /// before its first answer.
    private(set) var answer: Answer?
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

    /// The newest snapshot names `revision`, or `nil`: a Mac that does not
    /// share the value, or no coordinator. Returns whether to read now;
    /// then call `willRead()` and, with the answer, `didRead(_:)`.
    mutating func consume(revision: String?) -> Bool {
        announcements += 1
        announced = revision
        guard revision != nil else {
            answer = nil
            return false
        }
        return needsRead
    }

    mutating func willRead() {
        reading = announcements
    }

    /// The Mac's answer, or `nil` when the read failed or was not sent.
    /// Returns whether to read again.
    mutating func didRead(_ answer: Answer?) -> Bool {
        let askedAt = reading
        reading = nil
        // A snapshot that no longer names a revision ended the sharing.
        guard announced != nil else { return false }
        if let answer {
            self.answer = answer
            answered = askedAt
        } else if askedAt == announcements {
            // No snapshot came while it ran: the next one tries again.
            return false
        }
        return needsRead
    }

    private var needsRead: Bool {
        guard reading == nil, let announced else { return false }
        return announced != answer?.revision && answered != announcements
    }
}

/// Which of the coordinator's wake turns are quiet, as the Mac shares them:
/// the keys of the digests whose turn the coordinator marked quiet. The
/// coordinator's chat folds such a turn under its digest's line, as the
/// Mac's chat does. The keys are read by revision
/// (`ToasttyMacRevisionedRead`).
struct ToasttyCoordinatorQuietDigests: Equatable {
    private var reads = ToasttyMacRevisionedRead<RemoteCoordinatorQuietDigests>()

    /// The keys from the Mac's last answer. `nil` with a Mac that does not
    /// share them, or before its first answer: then no turn folds.
    var keys: Set<String>? { reads.answer.map { Set($0.keys) } }

    /// The newest snapshot names `revision` on the coordinator's workspace,
    /// or `nil`: a Mac that does not share the quiet turns, or no
    /// coordinator. Returns whether to read the keys now; then call
    /// `willRead()` and, with the answer, `didRead(_:)`.
    mutating func consume(revision: String?) -> Bool {
        reads.consume(revision: revision)
    }

    mutating func willRead() {
        reads.willRead()
    }

    /// The Mac's answer, or `nil` when the read failed or was not sent.
    /// Returns whether to read again.
    mutating func didRead(_ answer: RemoteCoordinatorQuietDigests?) -> Bool {
        reads.didRead(answer)
    }

    /// Whether the digest with this text started a quiet turn.
    static func isQuiet(_ text: String, keys: Set<String>?) -> Bool {
        guard let keys, keys.isEmpty == false else { return false }
        return keys.contains(CoordinatorChatTranscript.digestKey(text))
    }
}
