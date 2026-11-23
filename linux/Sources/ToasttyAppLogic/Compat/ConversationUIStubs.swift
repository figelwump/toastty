import Foundation
import RemoteProtocol

// The rules from Sources/ConversationUI that included App logic uses. That
// module mixes them with SwiftUI views (the transcript, the composer), which
// Linux does not build; `import ConversationUI` is dropped by the mirror
// (linux/shared-sources.json `importRewrites`). Each mirrors the macOS
// definition; keep them in step.

/// `CoordinatorChatReadPoint.isNewer(_:than:position:)` from
/// `Sources/ConversationUI/CoordinatorChatReadPoint.swift`, for
/// `CoordinatorChatReadThrough`.
enum CoordinatorChatReadPoint {
    static func isNewer(
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
}
