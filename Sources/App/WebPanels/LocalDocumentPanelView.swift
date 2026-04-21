import CoreState
import SwiftUI

struct LocalDocumentPanelView: View {
    let panelID: UUID
    let webState: WebPanelState
    @ObservedObject var runtime: LocalDocumentPanelRuntime
    let isEffectivelyVisible: Bool
    let isActivePanel: Bool
    let activatePanel: () -> Void
    let textScale: Double

    var body: some View {
        VStack(spacing: 0) {
            LocalDocumentPanelSearchBar(
                panelID: panelID,
                runtime: runtime,
                isActivePanel: isActivePanel,
                activatePanel: activatePanel
            )

            LocalDocumentPanelHostView(
                runtime: runtime,
                webState: webState,
                isEffectivelyVisible: isEffectivelyVisible,
                textScale: textScale
            )
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }
}
