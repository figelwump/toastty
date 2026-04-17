import CoreState
import SwiftUI

struct MarkdownPanelView: View {
    let webState: WebPanelState
    @ObservedObject var runtime: MarkdownPanelRuntime
    let isEffectivelyVisible: Bool
    let textScale: Double

    var body: some View {
        MarkdownPanelHostView(
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
