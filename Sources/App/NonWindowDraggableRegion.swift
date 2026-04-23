import AppKit
import SwiftUI

// Hidden-titlebar windows let AppKit treat top chrome as draggable background.
// Wrap interactive SwiftUI content in this host when it must win pointer drags
// instead of moving the window. This host also suppresses nested safe-area
// insets, so it should stay scoped to titlebar-aligned chrome content.
struct NonWindowDraggableRegion<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context _: Context) -> NonWindowDraggableHostingView {
        NonWindowDraggableHostingView(rootView: AnyView(content))
    }

    func updateNSView(_ nsView: NonWindowDraggableHostingView, context _: Context) {
        let previousFittingSize = nsView.fittingSize
        nsView.rootView = AnyView(content)
        if nsView.fittingSize != previousFittingSize {
            nsView.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NonWindowDraggableHostingView,
        context _: Context
    ) -> CGSize? {
        let fittingSize = nsView.fittingSize

        return CGSize(
            width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? fittingSize.width,
            height: proposal.height.flatMap { $0.isFinite ? max($0, fittingSize.height) : nil } ?? fittingSize.height
        )
    }
}

final class NonWindowDraggableHostingView: NSHostingView<AnyView> {
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsetsZero
    }
}
