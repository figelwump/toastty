import CoreState
import SwiftUI

struct MarkdownPanelView: View {
    let webState: WebPanelState
    @ObservedObject var runtime: MarkdownPanelRuntime

    var body: some View {
        MarkdownPanelHostView(
            runtime: runtime,
            webState: webState
        )
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }
}
