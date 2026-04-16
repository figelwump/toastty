import CoreState
import SwiftUI

struct LocalDocumentPanelView: View {
    let webState: WebPanelState
    @ObservedObject var runtime: LocalDocumentPanelRuntime

    var body: some View {
        LocalDocumentPanelHostView(
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
