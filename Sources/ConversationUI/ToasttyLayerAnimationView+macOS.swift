#if os(macOS)
import AppKit
import QuartzCore
import SwiftUI

extension ToasttyLayerAnimationView {
    struct Layers: NSViewRepresentable {
        var shapes: [Shape]
        var animates: Bool

        func makeNSView(context _: Context) -> ToasttyLayerAnimationNSView {
            ToasttyLayerAnimationNSView()
        }

        func updateNSView(_ nsView: ToasttyLayerAnimationNSView, context: Context) {
            let resolved = shapes.map { shape in
                ToasttyLayerAnimationResolvedShape(
                    shape: shape,
                    strokeColor: shape.strokeColor?.resolve(in: context.environment).cgColor,
                    fillColor: shape.fillColor?.resolve(in: context.environment).cgColor
                )
            }
            nsView.show(resolved, animates: animates)
        }
    }
}

/// The Mac's view behind `ToasttyLayerAnimationView`. Pointer events pass
/// through it.
final class ToasttyLayerAnimationNSView: NSView {
    private let layers = ToasttyLayerAnimationLayers(flipsGeometry: true)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The view hosts its own layer, so AppKit never replaces it.
        let root = CALayer()
        layer = root
        wantsLayer = true
        root.addSublayer(layers.container)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    func show(_ shapes: [ToasttyLayerAnimationResolvedShape], animates: Bool) {
        guard layers.show(shapes, animates: animates, bounds: bounds, contentsScale: backingScale) else { return }
        addMissingAnimations()
    }

    /// The animations that play now, for each shape. For tests.
    var playingAnimationKeys: [[String]] {
        layers.playingAnimationKeys
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layers.layout(bounds: bounds)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // SwiftUI can give the view its shapes before the view is in a
        // window. The animations start when it joins one.
        layers.setContentsScale(backingScale)
        addMissingAnimations()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layers.setContentsScale(backingScale)
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func addMissingAnimations() {
        guard window != nil else { return }
        layers.addMissingAnimations()
    }
}
#endif
