#if canImport(UIKit)
import QuartzCore
import SwiftUI
import UIKit

extension ToasttyLayerAnimationView {
    struct Layers: UIViewRepresentable {
        var shapes: [Shape]
        var animates: Bool

        func makeUIView(context _: Context) -> ToasttyLayerAnimationUIView {
            ToasttyLayerAnimationUIView()
        }

        func updateUIView(_ uiView: ToasttyLayerAnimationUIView, context: Context) {
            let resolved = shapes.map { shape in
                ToasttyLayerAnimationResolvedShape(
                    shape: shape,
                    strokeColor: shape.strokeColor?.resolve(in: context.environment).cgColor,
                    fillColor: shape.fillColor?.resolve(in: context.environment).cgColor
                )
            }
            uiView.show(resolved, animates: animates)
        }
    }
}

/// The iPhone's view behind `ToasttyLayerAnimationView`. Touches pass
/// through it. A layer in a `UIView` already has its origin at the top
/// left, so nothing flips.
final class ToasttyLayerAnimationUIView: UIView {
    private let layers = ToasttyLayerAnimationLayers(flipsGeometry: false)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        layer.addSublayer(layers.container)
        // The system can drop a layer's animations while the app is in the
        // background; they start again when it returns. The center removes
        // a selector observer when the view goes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    @objc private func applicationWillEnterForeground() {
        addMissingAnimations()
    }

    override func hitTest(_: CGPoint, with _: UIEvent?) -> UIView? {
        nil
    }

    func show(_ shapes: [ToasttyLayerAnimationResolvedShape], animates: Bool) {
        guard layers.show(shapes, animates: animates, bounds: bounds, contentsScale: displayScale) else { return }
        addMissingAnimations()
    }

    /// The animations that play now, for each shape. For tests.
    var playingAnimationKeys: [[String]] {
        layers.playingAnimationKeys
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layers.layout(bounds: bounds)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // SwiftUI can give the view its shapes before the view is in a
        // window, and a tab or a pushed screen takes it out of one. The
        // animations start when it joins one.
        layers.setContentsScale(displayScale)
        addMissingAnimations()
    }

    private var displayScale: CGFloat {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        return scale > 0 ? scale : 3
    }

    private func addMissingAnimations() {
        guard window != nil else { return }
        layers.addMissingAnimations()
    }
}
#endif
