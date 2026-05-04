import CoreState
import SwiftUI

struct LocalDocumentPanelView: View {
    let webState: WebPanelState
    @ObservedObject var runtime: LocalDocumentPanelRuntime
    let isEffectivelyVisible: Bool
    let isActivePanel: Bool
    let textScale: Double

    var body: some View {
        LocalDocumentPanelHostView(
            runtime: runtime,
            webState: webState,
            isEffectivelyVisible: isEffectivelyVisible,
            isActivePanel: isActivePanel,
            textScale: textScale
        )
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }
}
