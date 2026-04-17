import CoreState
import SwiftUI

struct MarkdownPanelView: View {
    let webState: WebPanelState
    @ObservedObject var runtime: MarkdownPanelRuntime
    let isEffectivelyVisible: Bool

    var body: some View {
        MarkdownPanelHostView(
            runtime: runtime,
            webState: webState,
            isEffectivelyVisible: isEffectivelyVisible
        )
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }
}
