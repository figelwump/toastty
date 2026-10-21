import AppKit
import CoreState
import SwiftUI

/// Candidate list shared by both send menus. Blocked targets stay visible but
/// disabled, with the reason in the label, so a send can't silently no-op
/// after selection.
struct BrowserAnnotationSendMenuItems: View {
    let candidates: [BrowserScreenshotSendCandidate]
    let availability: (BrowserScreenshotSendCandidate) -> BrowserAnnotationSendAvailability
    let send: (BrowserScreenshotSendCandidate) -> Void

    var body: some View {
        if candidates.isEmpty {
            Button("No active sessions in this tab") {}
                .disabled(true)
        } else {
            ForEach(candidates) { candidate in
                let blockedReason = availability(candidate).blockedReason
                Button {
                    send(candidate)
                } label: {
                    Label(
                        blockedReason.map { "\(candidate.label) (\($0))" } ?? candidate.label,
                        systemImage: "paperplane"
                    )
                }
                .disabled(blockedReason != nil)
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
struct BrowserAnnotationModeToolbar<Runtime: WebPanelAnnotationRuntime>: View {
    let panelID: UUID
    @ObservedObject var runtime: Runtime
    let sendCandidates: [BrowserScreenshotSendCandidate]
    let sendAvailability: (BrowserScreenshotSendCandidate) -> BrowserAnnotationSendAvailability
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
                Image(systemName: "pencil.tip.crop.circle")
                    .font(.system(size: 12, weight: .semibold))
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
                    availability: sendAvailability,
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
            .help("Send \(runtime.annotationSource.label) Annotations to Agent")
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
                .disabled(runtime.isAnnotationSendInFlight)
                .help("Clear \(runtime.annotationSource.label) Annotations")
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
            availability: sendAvailability,
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
