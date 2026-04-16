import CoreState
import SwiftUI

struct MarkdownPanelView: View {
    let webState: WebPanelState
    @ObservedObject var runtime: MarkdownPanelRuntime
    let textScale: Double

    var body: some View {
        MarkdownPanelHostView(
            runtime: runtime,
            webState: webState,
            textScale: textScale
        )
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }
}
