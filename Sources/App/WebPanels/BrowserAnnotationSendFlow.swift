import AppKit
import CoreState
import Foundation

enum BrowserAnnotationSendAvailability: Equatable {
    case available
    case blocked(reason: String)

    var isAvailable: Bool {
        self == .available
    }

    var blockedReason: String? {
        switch self {
        case .available:
            return nil
        case .blocked(let reason):
            return reason
        }
    }
}

/// Maps a managed agent session's status to send availability. Terminal
/// prompt detection is useless here: agent TUIs never sit at a shell prompt,
/// so they would always read as busy. Working agents queue composer input
/// safely; approval prompts must not receive an auto-submitted Enter.
enum BrowserAnnotationSendGate {
    static func availability(for statusKind: SessionStatusKind?) -> BrowserAnnotationSendAvailability {
        switch statusKind {
        case .idle, .working, .ready:
            return .available
        case .needsApproval:
            return .blocked(reason: "awaiting approval")
        case .error:
            return .blocked(reason: "in an error state")
        case nil:
            return .blocked(reason: "unavailable")
        }
    }
}

enum BrowserAnnotationCopy {
    static func clearConfirmationTitle(draftCount: Int) -> String {
        draftCount == 1
            ? "Clear 1 annotation?"
            : "Clear \(draftCount) annotations?"
    }

    static func sentMessage(draftCount: Int, candidateLabel: String) -> String {
        draftCount == 1
            ? "Sent 1 annotation to \(candidateLabel)"
            : "Sent \(draftCount) annotations to \(candidateLabel)"
    }

    static func blockedMessage(candidateLabel: String, reason: String) -> String {
        "\(candidateLabel) is \(reason) — can't send right now"
    }

    static func sendFailedMessage(candidateLabel: String) -> String {
        "Couldn't send annotations to \(candidateLabel)"
    }
}

/// Renders, writes, and sends the current annotation drafts to one agent
/// candidate, publishing user-visible progress and outcome on the runtime.
/// Shared by the header accessory and the floating annotation toolbar.
@MainActor
enum BrowserAnnotationSendFlow {
    static func send(
        runtime: any WebPanelAnnotationRuntime,
        candidate: BrowserScreenshotSendCandidate,
        availability: (BrowserScreenshotSendCandidate) -> BrowserAnnotationSendAvailability,
        sendPayload: @escaping (String, BrowserScreenshotSendCandidate) -> Bool
    ) {
        guard runtime.isAnnotationSendInFlight == false,
              runtime.annotationState.hasDrafts else {
            return
        }
        if let blockedReason = availability(candidate).blockedReason {
            runtime.postAnnotationSendNotice(
                message: BrowserAnnotationCopy.blockedMessage(
                    candidateLabel: candidate.label,
                    reason: blockedReason
                ),
                isFailure: true
            )
            return
        }

        let sections = runtime.annotationState.sections
        let draftCount = runtime.annotationState.draftCount
        runtime.setAnnotationSendInFlight(true)

        Task { @MainActor in
            defer { runtime.setAnnotationSendInFlight(false) }

            await Task.yield()

            do {
                let renderedSections = try BrowserAnnotationScreenshotWriter.writeRenderedSections(
                    from: sections
                )
                let payload = BrowserAnnotationPayloadBuilder.payload(
                    renderedSections: renderedSections,
                    source: runtime.annotationSource
                )
                if sendPayload(payload, candidate) {
                    runtime.clearAnnotations(exitAnnotationMode: true)
                    runtime.postAnnotationSendNotice(
                        message: BrowserAnnotationCopy.sentMessage(
                            draftCount: draftCount,
                            candidateLabel: candidate.label
                        ),
                        isFailure: false
                    )
                } else {
                    for renderedSection in renderedSections {
                        try? FileManager.default.removeItem(at: renderedSection.fileURL)
                    }
                    runtime.postAnnotationSendNotice(
                        message: BrowserAnnotationCopy.sendFailedMessage(candidateLabel: candidate.label),
                        isFailure: true
                    )
                    NSLog(
                        "Browser annotation send failed: sessionID=%@ panelID=%@",
                        candidate.sessionID,
                        candidate.panelID.uuidString
                    )
                }
            } catch {
                runtime.postAnnotationSendNotice(
                    message: "Couldn't send annotations",
                    isFailure: true
                )
                NSLog("Browser annotation send failed: %@", error.localizedDescription)
            }
        }
    }
}
