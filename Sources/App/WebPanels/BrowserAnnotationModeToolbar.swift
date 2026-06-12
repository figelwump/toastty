import AppKit
import SwiftUI

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

    static func busyMessage(candidateLabel: String) -> String {
        "\(candidateLabel) is busy — try again when it's idle"
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
        runtime: BrowserPanelRuntime,
        candidate: BrowserScreenshotSendCandidate,
        canSubmit: (BrowserScreenshotSendCandidate) -> Bool,
        sendPayload: (String, BrowserScreenshotSendCandidate) -> Bool
    ) {
        guard runtime.isAnnotationSendInFlight == false,
              runtime.annotationState.hasDrafts else {
            return
        }
        guard canSubmit(candidate) else {
            runtime.postAnnotationSendNotice(
                message: BrowserAnnotationCopy.busyMessage(candidateLabel: candidate.label),
                isFailure: true
            )
            return
        }

        runtime.setAnnotationSendInFlight(true)
        defer { runtime.setAnnotationSendInFlight(false) }

        let draftCount = runtime.annotationState.draftCount
        do {
            let renderedSections = try BrowserAnnotationScreenshotWriter.writeRenderedSections(
                from: runtime.annotationState.sections
            )
            let payload = BrowserAnnotationPayloadBuilder.payload(
                renderedSections: renderedSections
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

/// Candidate list shared by both send menus. Busy targets stay visible but
/// disabled so a send can't silently no-op after selection.
struct BrowserAnnotationSendMenuItems: View {
    let candidates: [BrowserScreenshotSendCandidate]
    let canSubmit: (BrowserScreenshotSendCandidate) -> Bool
    let send: (BrowserScreenshotSendCandidate) -> Void

    var body: some View {
        if candidates.isEmpty {
            Button("No active sessions in this tab") {}
                .disabled(true)
        } else {
            ForEach(candidates) { candidate in
                let isBusy = canSubmit(candidate) == false
                Button {
                    send(candidate)
                } label: {
                    Label(
                        isBusy ? "\(candidate.label) (busy)" : candidate.label,
                        systemImage: "paperplane"
                    )
                }
                .disabled(isBusy)
            }
        }
    }
}

struct BrowserAnnotationCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(min(count, 99))")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 3)
            .frame(minWidth: 12, minHeight: 12)
            .background(
                Capsule().fill(Color(nsColor: BrowserAnnotationMarkStyle.markColor))
            )
    }
}

/// Floating pill shown over the page while annotation mode is active. Puts
/// the draft count, send, clear, and exit controls at the point of use.
struct BrowserAnnotationModeToolbar: View {
    let panelID: UUID
    @ObservedObject var runtime: BrowserPanelRuntime
    let sendCandidates: [BrowserScreenshotSendCandidate]
    let canSubmitToAgent: (BrowserScreenshotSendCandidate) -> Bool
    let sendPayloadToAgent: (String, BrowserScreenshotSendCandidate) -> Bool

    @State private var isClearConfirmationPresented = false

    private var draftCount: Int {
        runtime.annotationState.draftCount
    }

    private var isSendDisabled: Bool {
        runtime.annotationState.hasDrafts == false
            || runtime.isAnnotationSendInFlight
            || runtime.isAnnotationEditorActive
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "pencil.and.outline")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ToastyTheme.accent)
                Text("Annotating")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ToastyTheme.primaryText)
                if draftCount > 0 {
                    BrowserAnnotationCountBadge(count: draftCount)
                }
            }
            .padding(.horizontal, 10)

            toolbarDivider

            Menu {
                BrowserAnnotationSendMenuItems(
                    candidates: sendCandidates,
                    canSubmit: canSubmitToAgent,
                    send: sendAnnotations(to:)
                )
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "paperplane")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Send to Agent")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(isSendDisabled ? ToastyTheme.mutedText : ToastyTheme.primaryText)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(isSendDisabled)
            .help("Send Browser Annotations to Agent")
            .accessibilityIdentifier("panel.annotationBar.send.\(panelID.uuidString)")

            if draftCount > 0 {
                toolbarDivider

                Button {
                    isClearConfirmationPresented = true
                } label: {
                    Text("Clear")
                        .font(.system(size: 11))
                        .foregroundStyle(ToastyTheme.inactiveText)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear Browser Annotations")
                .accessibilityIdentifier("panel.annotationBar.clear.\(panelID.uuidString)")
                .confirmationDialog(
                    BrowserAnnotationCopy.clearConfirmationTitle(draftCount: draftCount),
                    isPresented: $isClearConfirmationPresented,
                    titleVisibility: .visible
                ) {
                    Button("Clear All", role: .destructive) {
                        runtime.clearAnnotations(exitAnnotationMode: false)
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }

            toolbarDivider

            Button {
                runtime.setAnnotationModeEnabled(false)
            } label: {
                HStack(spacing: 5) {
                    Text("Done")
                        .font(.system(size: 11))
                        .foregroundStyle(ToastyTheme.inactiveText)
                    Text("esc")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ToastyTheme.mutedText)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(ToastyTheme.surfaceBackground)
                        )
                }
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Exit Annotation Mode")
            .accessibilityIdentifier("panel.annotationBar.done.\(panelID.uuidString)")
        }
        .padding(.vertical, 6)
        .background(
            Capsule().fill(ToastyTheme.elevatedBackground.opacity(0.96))
        )
        .overlay {
            Capsule().stroke(ToastyTheme.subtleBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 9, y: 3)
        .fixedSize()
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(ToastyTheme.slotDivider)
            .frame(width: 1, height: 14)
    }

    private func sendAnnotations(to candidate: BrowserScreenshotSendCandidate) {
        BrowserAnnotationSendFlow.send(
            runtime: runtime,
            candidate: candidate,
            canSubmit: canSubmitToAgent,
            sendPayload: sendPayloadToAgent
        )
    }
}

/// Transient send-outcome toast shown at the bottom of the browser body.
struct BrowserAnnotationNoticeToast: View {
    let notice: BrowserAnnotationSendNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: notice.isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(
                    notice.isFailure ? ToastyTheme.sessionErrorText : ToastyTheme.sessionReadyText
                )
            Text(notice.message)
                .font(.system(size: 11.5))
                .foregroundStyle(ToastyTheme.primaryText)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(ToastyTheme.elevatedBackground.opacity(0.97))
        )
        .overlay {
            Capsule().stroke(ToastyTheme.subtleBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 7, y: 2)
        .task(id: notice.id) {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            dismiss()
        }
    }
}
