import CoreState
import SwiftUI

struct ScratchpadPanelView: View {
    let panelID: UUID
    let webState: WebPanelState
    @ObservedObject var runtime: ScratchpadPanelRuntime
    let isEffectivelyVisible: Bool
    let isActivePanel: Bool
    let activatePanel: () -> Void
    let annotationSendCandidates: [BrowserScreenshotSendCandidate]
    let annotationSendAvailability: (BrowserScreenshotSendCandidate) -> BrowserAnnotationSendAvailability
    let sendAnnotationPayloadToAgent: (String, BrowserScreenshotSendCandidate) -> Bool

    var body: some View {
        WebPanelAnnotationSurface(
            panelID: panelID,
            runtime: runtime,
            sendCandidates: annotationSendCandidates,
            activatePanel: activatePanel,
            sendAvailability: annotationSendAvailability,
            sendPayloadToAgent: sendAnnotationPayloadToAgent
        ) {
            ScratchpadPanelHostView(
                runtime: runtime,
                webState: webState,
                isEffectivelyVisible: isEffectivelyVisible,
                isActivePanel: isActivePanel && runtime.annotationState.isAnnotationModeEnabled == false
            )
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }
}
