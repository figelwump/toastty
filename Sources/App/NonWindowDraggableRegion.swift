import AppKit
import SwiftUI

// Hidden-titlebar windows let AppKit treat top chrome as draggable background.
// Wrap interactive SwiftUI content in this region when it must win pointer
// drags instead of moving the window. This also suppresses nested safe-area
// insets, so it should stay scoped to titlebar-aligned chrome content.
struct NonWindowDraggableRegion<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context _: Context) -> NonWindowDraggableContainerView {
        NonWindowDraggableContainerView(rootView: AnyView(content))
    }

    func updateNSView(_ nsView: NonWindowDraggableContainerView, context _: Context) {
        let previousFittingSize = nsView.fittingSize
        nsView.rootView = AnyView(content)
        if nsView.fittingSize != previousFittingSize {
            nsView.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NonWindowDraggableContainerView,
        context _: Context
    ) -> CGSize? {
        let fittingSize = nsView.fittingSize

        return CGSize(
            width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? fittingSize.width,
            height: proposal.height.flatMap { $0.isFinite ? max($0, fittingSize.height) : nil } ?? fittingSize.height
        )
    }
}

final class NonWindowDraggableContainerView: NSView {
    private let hostingView: NonWindowDraggableHostingView

    var rootView: AnyView {
        get { hostingView.rootView }
        set {
            hostingView.rootView = newValue
            hostingView.invalidateIntrinsicContentSize()
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    init(rootView: AnyView) {
        hostingView = NonWindowDraggableHostingView(rootView: rootView)
        super.init(frame: .zero)

        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsetsZero
    }

    override var intrinsicContentSize: NSSize {
        hostingView.intrinsicContentSize
    }

    override var fittingSize: NSSize {
        hostingView.fittingSize
    }

    override func layout() {
        super.layout()
        hostingView.frame = bounds
    }

    // Hidden-titlebar windows ask the hit-tested view whether a pointer drag
    // should move the window. Route ambiguous or SwiftUI-helper hits back to
    // the nested hosting view so AppKit consults a non-window-draggable view
    // while SwiftUI still receives the mouse sequence for gestures. Real
    // controls (NSButton, NSTextField, NSViewRepresentable wrappers) already
    // return `false` and keep receiving events directly.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isHidden == false, alphaValue > 0.01 else { return nil }
        guard let localPoint = hitTestPointInBounds(point) else { return nil }
        guard let hit = super.hitTest(localPoint) else { return hostingView }
        if hit !== self, hit.mouseDownCanMoveWindow == false {
            return hit
        }
        return hostingView
    }

    private func hitTestPointInBounds(_ point: NSPoint) -> NSPoint? {
        if bounds.contains(point) {
            return point
        }
        guard let superview else { return nil }

        let pointFromSuperview = convert(point, from: superview)
        return bounds.contains(pointFromSuperview) ? pointFromSuperview : nil
    }

    // Let a pointer drag that starts while the window is inactive reach the
    // SwiftUI gesture system on the first click. Without this, AppKit
    // sometimes treats the first mouse-down as an activation event and
    // forwards the rest of the drag to its titlebar-move recognizer.
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }
}

final class NonWindowDraggableHostingView: NSHostingView<AnyView> {
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsetsZero
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }
}
