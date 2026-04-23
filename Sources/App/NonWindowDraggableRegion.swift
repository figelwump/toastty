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

    // Hidden-titlebar windows ask the hit-tested view whether a pointer drag
    // should move the window. `NSHostingView`'s default hit-test can return
    // an internal SwiftUI helper view whose `mouseDownCanMoveWindow` is
    // `true`, which lets the titlebar drag engine win over in-strip
    // `DragGesture`s and manifests as intermittent "clicks drag the window
    // instead of the tab" behavior. Intercept only that case: if the hit
    // view would allow window dragging, claim the hit ourselves so AppKit
    // consults our `false` override. Real controls (NSButton, NSTextField,
    // NSViewRepresentable wrappers) already return `false` here and keep
    // receiving events directly.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit !== self, hit.mouseDownCanMoveWindow == false {
            return hit
        }
        return self
    }

    // Let a pointer drag that starts while the window is inactive reach the
    // SwiftUI gesture system on the first click. Without this, AppKit
    // sometimes treats the first mouse-down as an activation event and
    // forwards the rest of the drag to its titlebar-move recognizer.
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }
}
