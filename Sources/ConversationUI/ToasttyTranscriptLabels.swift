import Foundation
import RemoteProtocol

/// The transcript's short labels, which the SwiftUI and GTK transcripts
/// both draw.
enum ToasttyTranscriptLabels {
    static func subagentPhase(_ phase: ConversationSubagentPhase) -> String {
        switch phase {
        case .started: "started"
        case .updated: "updated"
        case .finished: "finished"
        case .unknown: "activity"
        }
    }

    static func binding(_ reason: ConversationBindingChangeReason) -> String {
        switch reason {
        case .runtimeBound: "session connected"
        case .runtimeResumed: "session resumed"
        case .runtimeEnded: "session disconnected"
        case .projectionRebuilt: "transcript rebuilt"
        }
    }

    static func resolution(_ resolution: RemotePendingInteraction.State) -> String {
        "interaction \(resolution.rawValue)"
    }

    /// The caption over a message that waits in the queue.
    static func queuedCaption(_ queued: ToasttyQueuedSendPresentation) -> String {
        queued.isPaused
            ? "Paused · queued \(queued.position)"
            : queued.waitingCaption ?? "Queued \(queued.position) · sends after this turn"
    }
}
