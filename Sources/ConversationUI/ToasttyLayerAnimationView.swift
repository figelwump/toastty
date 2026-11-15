import QuartzCore
import SwiftUI

/// Shapes that Core Animation animates without the app's main thread.
///
/// Use it for an indicator that moves for as long as it shows. A SwiftUI
/// animation without an end (`TimelineView(.animation)`, `repeatForever`)
/// updates the window's whole view graph for each frame. In a window with
/// many sessions one update takes several milliseconds, so a few working
/// indicators keep the main thread busy, and typing and transitions lag. Here
/// the app adds each animation once and the render server draws the frames.
///
/// Animations with the same cycle length follow one clock, so equal
/// indicators move in step wherever they are.
///
/// The view fills the space it is offered. Pointer events and touches pass
/// through the drawing to SwiftUI, which treats the whole frame as content,
/// so a button or a row that shows an indicator still gets a click or a tap
/// on it. The Mac hosts the layers in an `NSView`
/// (`ToasttyLayerAnimationView+macOS.swift`) and the iPhone in a `UIView`
/// (`ToasttyLayerAnimationView+iOS.swift`).
public struct ToasttyLayerAnimationView: View {
    public struct Shape: Equatable {
        /// In the view's coordinates: the origin is the top left corner and
        /// y grows downward, as in SwiftUI.
        public var path: CGPath
        public var strokeColor: Color?
        public var fillColor: Color?
        public var lineWidth: CGFloat
        public var roundLineCap: Bool
        /// The pose while nothing animates.
        public var restingOpacity: Double
        public var restingOffsetY: CGFloat
        public var animations: [Animation]

        public init(
            path: CGPath,
            strokeColor: Color? = nil,
            fillColor: Color? = nil,
            lineWidth: CGFloat = 1,
            roundLineCap: Bool = false,
            restingOpacity: Double = 1,
            restingOffsetY: CGFloat = 0,
            animations: [Animation]
        ) {
            self.path = path
            self.strokeColor = strokeColor
            self.fillColor = fillColor
            self.lineWidth = lineWidth
            self.roundLineCap = roundLineCap
            self.restingOpacity = restingOpacity
            self.restingOffsetY = restingOffsetY
            self.animations = animations
        }
    }

    public struct Animation: Equatable {
        public enum Property: String, Sendable {
            /// Radians, clockwise, around the view's center.
            case rotation = "transform.rotation.z"
            case opacity
            /// Points, downward.
            case offsetY = "transform.translation.y"
        }

        public enum Easing: Sendable {
            case linear
            /// `1 - (1 - t)^2`
            case easeOutQuadratic
        }

        public var property: Property
        /// The value at each of `keyTimes`.
        public var values: [CGFloat]
        /// Fractions of `duration`, from 0 to 1.
        public var keyTimes: [Double]
        /// How the value moves between two key times.
        public var easing: Easing
        public var duration: TimeInterval
        /// Plays backward after each forward pass. A cycle then takes twice
        /// `duration`.
        public var autoreverses: Bool
        /// Seconds by which this animation's cycle trails the shared clock.
        public var delay: TimeInterval

        public init(
            property: Property,
            values: [CGFloat],
            keyTimes: [Double] = [0, 1],
            easing: Easing = .linear,
            duration: TimeInterval,
            autoreverses: Bool = false,
            delay: TimeInterval = 0
        ) {
            self.property = property
            self.values = values
            self.keyTimes = keyTimes
            self.easing = easing
            self.duration = duration
            self.autoreverses = autoreverses
            self.delay = delay
        }
    }

    var shapes: [Shape]
    var animates: Bool

    /// - Parameter animates: `false` shows each shape in its resting pose.
    public init(shapes: [Shape], animates: Bool = true) {
        self.shapes = shapes
        self.animates = animates
    }

    public var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .overlay {
                Layers(shapes: shapes, animates: animates)
                    .allowsHitTesting(false)
            }
    }
}

extension ToasttyLayerAnimationView.Shape {
    /// The arc of the activity spinner: most of a circle, which turns once
    /// every 0.9 seconds.
    public static func spinnerArc(size: CGFloat, lineWidth: CGFloat, color: Color) -> Self {
        Self(
            path: Circle()
                .path(in: CGRect(x: 0, y: 0, width: size, height: size))
                .trimmedPath(from: 0.16, to: 0.9)
                .cgPath,
            strokeColor: color,
            lineWidth: lineWidth,
            roundLineCap: true,
            animations: [
                .init(property: .rotation, values: [0, 2 * .pi], duration: 0.9),
            ]
        )
    }
}

/// A shape with its colors resolved for the view's environment.
struct ToasttyLayerAnimationResolvedShape: Equatable {
    var shape: ToasttyLayerAnimationView.Shape
    var strokeColor: CGColor?
    var fillColor: CGColor?
}

/// The layers behind `ToasttyLayerAnimationView`, inside the platform view
/// that hosts them. The host calls `layout`, `setContentsScale` and
/// `addMissingAnimations` as its size, screen and window change.
@MainActor
final class ToasttyLayerAnimationLayers {
    /// Holds the shape layers. The Mac flips it, so that paths and offsets
    /// use SwiftUI's coordinates there too.
    let container = CALayer()
    private var shapeLayers: [CAShapeLayer] = []
    private var shapes: [ToasttyLayerAnimationResolvedShape] = []
    private var animates = true

    init(flipsGeometry: Bool) {
        container.isGeometryFlipped = flipsGeometry
    }

    /// The animations that play now, for each shape. For tests.
    var playingAnimationKeys: [[String]] {
        shapeLayers.map { ($0.animationKeys() ?? []).sorted() }
    }

    /// Returns whether anything changed, so the host knows to start the
    /// animations.
    func show(
        _ newShapes: [ToasttyLayerAnimationResolvedShape],
        animates newAnimates: Bool,
        bounds: CGRect,
        contentsScale: CGFloat
    ) -> Bool {
        guard newShapes != shapes || newAnimates != animates else { return false }
        shapes = newShapes
        animates = newAnimates
        withoutImplicitAnimation {
            shapeLayers.forEach { $0.removeFromSuperlayer() }
            shapeLayers = shapes.map { resolved in
                let layer = CAShapeLayer()
                layer.path = resolved.shape.path
                layer.strokeColor = resolved.strokeColor
                layer.fillColor = resolved.fillColor
                layer.lineWidth = resolved.shape.lineWidth
                layer.lineCap = resolved.shape.roundLineCap ? .round : .butt
                layer.opacity = Float(resolved.shape.restingOpacity)
                layer.setAffineTransform(CGAffineTransform(translationX: 0, y: resolved.shape.restingOffsetY))
                container.addSublayer(layer)
                return layer
            }
        }
        layout(bounds: bounds)
        setContentsScale(contentsScale)
        return true
    }

    func layout(bounds: CGRect) {
        withoutImplicitAnimation {
            container.frame = bounds
            for layer in shapeLayers {
                // `frame` depends on the transform; bounds and position do not.
                layer.bounds = container.bounds
                layer.position = CGPoint(x: container.bounds.midX, y: container.bounds.midY)
            }
        }
    }

    func setContentsScale(_ scale: CGFloat) {
        withoutImplicitAnimation {
            for layer in shapeLayers {
                layer.contentsScale = scale
            }
        }
    }

    /// Starts each animation that does not play. The host calls it when the
    /// view joins a window, because the system can drop a layer's
    /// animations while its view is out of one.
    func addMissingAnimations() {
        guard animates else { return }
        let now = CACurrentMediaTime()
        for (layer, resolved) in zip(shapeLayers, shapes) {
            for animation in resolved.shape.animations where layer.animation(forKey: animation.property.rawValue) == nil {
                layer.add(animation.coreAnimation(now: now, on: layer), forKey: animation.property.rawValue)
            }
        }
    }

    private func withoutImplicitAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

extension ToasttyLayerAnimationView.Animation {
    /// One pass forward, and one backward when the animation reverses.
    var cycleDuration: TimeInterval {
        autoreverses ? 2 * duration : duration
    }

    /// How far into its cycle the animation is at `now` on the shared clock.
    func cyclePosition(now: CFTimeInterval) -> TimeInterval {
        let position = (now - delay).truncatingRemainder(dividingBy: cycleDuration)
        return position < 0 ? position + cycleDuration : position
    }

    func coreAnimation(now: CFTimeInterval, on layer: CALayer) -> CAAnimation {
        let animation = CAKeyframeAnimation(keyPath: property.rawValue)
        animation.values = values.map { NSNumber(value: Double($0)) }
        animation.keyTimes = keyTimes.map { NSNumber(value: $0) }
        let timing: CAMediaTimingFunction = switch easing {
        case .linear: CAMediaTimingFunction(name: .linear)
        // The cubic Bézier that equals `1 - (1 - t)^2`.
        case .easeOutQuadratic: CAMediaTimingFunction(controlPoints: 1.0 / 3, 2.0 / 3, 2.0 / 3, 1)
        }
        animation.timingFunctions = Array(repeating: timing, count: max(values.count - 1, 1))
        animation.duration = duration
        animation.autoreverses = autoreverses
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        // The SwiftUI drawings updated 12 to 30 times per second. Ask for
        // the same, so a display with a higher refresh rate does not draw
        // these small shapes on every refresh.
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 12, maximum: 30, preferred: 24)
        // The cycle started in the past, on the shared clock's boundary.
        animation.beginTime = layer.convertTime(now - cyclePosition(now: now), from: nil)
        return animation
    }
}
