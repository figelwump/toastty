import CoreState
import SwiftUI

struct ScratchpadPanelView: View {
    let webState: WebPanelState
    @ObservedObject var runtime: ScratchpadPanelRuntime
    let isEffectivelyVisible: Bool
    let isActivePanel: Bool

    var body: some View {
        ScratchpadPanelHostView(
            runtime: runtime,
            webState: webState,
            isEffectivelyVisible: isEffectivelyVisible,
            isActivePanel: isActivePanel
        )
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }
}
