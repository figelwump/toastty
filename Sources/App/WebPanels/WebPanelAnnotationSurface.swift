import SwiftUI

struct WebPanelAnnotationSurface<Runtime: WebPanelAnnotationRuntime, Content: View>: View {
    let panelID: UUID
    @ObservedObject var runtime: Runtime
    let sendCandidates: [BrowserScreenshotSendCandidate]
    let activatePanel: () -> Void
    let sendAvailability: (BrowserScreenshotSendCandidate) -> BrowserAnnotationSendAvailability
    let sendPayloadToAgent: (String, BrowserScreenshotSendCandidate) -> Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            content()
            BrowserAnnotationOverlayView(runtime: runtime, activatePanel: activatePanel)

            if runtime.annotationState.isAnnotationModeEnabled {
                Rectangle()
                    .strokeBorder(ToastyTheme.accent.opacity(0.85), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if runtime.annotationState.isAnnotationModeEnabled {
                BrowserAnnotationModeToolbar(
                    panelID: panelID,
                    runtime: runtime,
                    sendCandidates: sendCandidates,
                    sendAvailability: sendAvailability,
                    sendPayloadToAgent: sendPayloadToAgent
                )
                .padding(.top, 10)
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = runtime.annotationSendNotice {
                BrowserAnnotationNoticeToast(notice: notice) {
                    runtime.clearAnnotationSendNotice(id: notice.id)
                }
                .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
