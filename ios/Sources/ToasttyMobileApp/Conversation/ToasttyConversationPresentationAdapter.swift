import ConversationUI
import Foundation
import RemoteProtocol
import ToasttyMobileDomain

enum ToasttyConversationPresentationAdapter {
    /// `coordinatorMessages` is set for the coordinator's chat only: its
    /// digests, sender cards, quick entry messages and replies then show as
    /// the Mac's coordinator chat shows them.
    static func makeState(
        events: [CompatibleConversationEvent],
        projectionRunID: RemoteProjectionRunID?,
        projectionGeneration: UInt64?,
        phase: ToasttyConversationPresentationPhase,
        revision: ToasttyTranscriptRevision,
        historyTruncated: Bool,
        sendItems: [ToasttySendPresentationItem] = [],
        hasOlder: Bool = false,
        isLoadingOlder: Bool = false,
        prependAnchorID: ToasttyTranscriptRowID? = nil,
        coordinatorMessages: CoordinatorChatTranscript.Messages? = nil
    ) -> ToasttyConversationPresentationState {
        // An event this version does not know, and a status change, which
        // belongs in the header and the composer, are not rows.
        let known = events.compactMap { event -> ConversationEvent? in
            guard case .known(let value) = event else { return nil }
            return value
        }
        let rows = ToasttyTranscriptRows.rows(
            from: known,
            projectionRunID: projectionRunID?.rawValue
                ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            projectionGeneration: projectionGeneration ?? 0,
            interactions: .answerable,
            coordinatorMessages: coordinatorMessages
        )
        return ToasttyConversationPresentationState(
            rows: rows,
            sendItems: sendItems,
            phase: phase,
            revision: revision,
            historyTruncated: historyTruncated,
            hasOlder: hasOlder,
            isLoadingOlder: isLoadingOlder,
            prependAnchorID: prependAnchorID
        )
    }

    /// How the coordinator's chat on this phone shows the messages that
    /// Toastty typed: times as the phone writes them, the wake turns that
    /// the coordinator marked quiet folded under their digest's line, as on
    /// the Mac, and the attached files. `quietDigestKeys` is `nil` with a
    /// Mac that does not share them. With `showsAttachedImages`, for a Mac
    /// that serves the images, each file shows by itself, an image as a
    /// thumbnail that the phone fetches; without it, by name in the text.
    static func coordinatorMessages(
        quietDigestKeys: Set<String>? = nil,
        showsAttachedImages: Bool = false
    ) -> CoordinatorChatTranscript.Messages {
        CoordinatorChatTranscript.Messages(
            timeText: CoordinatorChatTranscript.timeText,
            attachedFiles: showsAttachedImages ? .apart : .byName,
            isQuietDigest: { ToasttyCoordinatorQuietDigests.isQuiet($0, keys: quietDigestKeys) }
        )
    }
}

extension ToasttyTranscriptSessionStatus {
    /// Every distinct host status gets its own epoch, so the transcript sees
    /// each status change.
    init(_ status: MobileSessionStatus) {
        let activity: Activity = switch status.bucket {
        case .ready: .ready
        case .working: .working
        case .error, .needsApproval, .idle: .other
        }
        switch status {
        case .known(let known):
            self.init(activity: activity, epoch: known.rawValue)
        case .unsupported(let rawValue):
            self.init(activity: activity, epoch: "unsupported:\(rawValue)")
        }
    }
}

extension ToasttyTranscriptWorkingIndicator.TurnElapsed {
    init(_ age: MobileActivityAge) {
        self.init(
            secondsAtReceipt: age.secondsAtReceipt,
            receivedAtMonotonicTime: age.receivedAtMonotonicTime
        )
    }
}
