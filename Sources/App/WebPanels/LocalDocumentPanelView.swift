import CoreState
import SwiftUI

struct LocalDocumentPanelView: View {
    let webState: WebPanelState
    @ObservedObject var runtime: LocalDocumentPanelRuntime
    let isEffectivelyVisible: Bool
    let textScale: Double

    var body: some View {
        LocalDocumentPanelHostView(
            runtime: runtime,
            webState: webState,
            isEffectivelyVisible: isEffectivelyVisible,
            textScale: textScale
        )
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }
}
