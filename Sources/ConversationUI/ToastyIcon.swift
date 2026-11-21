import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Toasty, the empty-window toast, as a small glyph: the coordinator's icon
/// on the Mac and on the iPhone. It can carry the coordinator's status:
/// steam while the agent works, or a session row's status dot on its
/// top-right corner. Steam and dot draw outside the icon's frame, so leave
/// room above it and to its right.
///
/// Each app passes its own theme's colors in a `Palette`, so the Mac and the
/// iPhone draw the same Toasty in their own surroundings.
public struct ToastyIcon: View {
    public enum Style: Sendable {
        /// A gray outline, for places where color means status, such as
        /// the Mac's sidebar.
        case outline
        /// The golden toast with its butter.
        case golden
    }

    public enum Status: Equatable, Sendable {
        case none
        case working
        case unread
        case needsApproval
        case error
    }

    /// The colors Toasty draws with. The golden toast's own colors are the
    /// same everywhere; the outline, the steam and the status dots follow
    /// the app's theme.
    public struct Palette: Sendable {
        /// The outline style's line and face.
        public var outline: Color
        public var steam: Color
        public var unreadDot: Color
        public var needsApprovalDot: Color
        /// The faint ring around the approval dot.
        public var needsApprovalHalo: Color
        public var errorDot: Color
        public var goldenFill: Color
        public var goldenOutline: Color
        public var goldenFace: Color
        public var goldenButter: Color

        public init(
            outline: Color,
            steam: Color,
            unreadDot: Color,
            needsApprovalDot: Color,
            needsApprovalHalo: Color,
            errorDot: Color,
            goldenFill: Color = Color(.sRGB, red: 0xE2 / 255, green: 0xA5 / 255, blue: 0x5C / 255),
            goldenOutline: Color = Color(.sRGB, red: 0xA8 / 255, green: 0x66 / 255, blue: 0x2C / 255),
            goldenFace: Color = Color(.sRGB, red: 0x3A / 255, green: 0x22 / 255, blue: 0x0F / 255),
            goldenButter: Color = Color(.sRGB, red: 0xFF / 255, green: 0xE0 / 255, blue: 0x8A / 255)
        ) {
            self.outline = outline
            self.steam = steam
            self.unreadDot = unreadDot
            self.needsApprovalDot = needsApprovalDot
            self.needsApprovalHalo = needsApprovalHalo
            self.errorDot = errorDot
            self.goldenFill = goldenFill
            self.goldenOutline = goldenOutline
            self.goldenFace = goldenFace
            self.goldenButter = goldenButter
        }
    }

    var style: Style
    var size: CGFloat
    var status: Status
    var palette: Palette
    /// The color behind the icon. It rings the status dot, so the dot reads
    /// as a badge on Toasty.
    var badgeRingColor: Color

    public init(
        style: Style = .outline,
        size: CGFloat = 14,
        status: Status = .none,
        palette: Palette,
        badgeRingColor: Color
    ) {
        self.style = style
        self.size = size
        self.status = status
        self.palette = palette
        self.badgeRingColor = badgeRingColor
    }

    /// The drawing's coordinates are in a 16 x 16 box.
    static let unit: CGFloat = 16
    /// The status dot's diameter, as on a session row.
    public static let dotSize: CGFloat = 7
    private static let badgeRingWidth: CGFloat = 1.5
    /// The dot's center sits this far right of and above the icon's
    /// top-right corner.
    private static let badgeCenterOffset: CGFloat = 1.5

    public var body: some View {
        Canvas { context, canvasSize in
            context.scaleBy(x: canvasSize.width / Self.unit, y: canvasSize.height / Self.unit)
            drawToast(in: &context)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topLeading) {
            if status == .working {
                ToastySteam(scale: size / Self.unit, color: palette.steam)
            }
        }
        .overlay {
            if let dotColor {
                badge(dotColor)
            }
        }
        .accessibilityHidden(true)
    }

    private var dotColor: Color? {
        switch status {
        case .none, .working: nil
        case .unread: palette.unreadDot
        case .needsApproval: palette.needsApprovalDot
        case .error: palette.errorDot
        }
    }

    private func badge(_ color: Color) -> some View {
        ZStack {
            Circle()
                .fill(badgeRingColor)
                .frame(width: Self.dotSize + 2 * Self.badgeRingWidth, height: Self.dotSize + 2 * Self.badgeRingWidth)
            Circle()
                .fill(color)
                .frame(width: Self.dotSize, height: Self.dotSize)
                .overlay {
                    if status == .needsApproval {
                        Circle()
                            .stroke(palette.needsApprovalHalo, lineWidth: 3)
                    }
                }
        }
        .position(x: size + Self.badgeCenterOffset, y: -Self.badgeCenterOffset)
    }

    private func drawToast(in context: inout GraphicsContext) {
        let colors = Colors(style, palette: palette)
        let slice = Self.slicePath
        if let fill = colors.fill {
            context.fill(slice, with: .color(fill))
        }
        context.stroke(slice, with: .color(colors.outline), style: Self.sliceStroke)
        if let butter = colors.butter {
            context.fill(Self.butterPath, with: .color(butter))
        }
        for eye in Self.eyePaths {
            context.fill(eye, with: .color(colors.face))
        }
        context.stroke(Self.smilePath, with: .color(colors.face), style: Self.smileStroke)
    }

    private static let sliceStroke = StrokeStyle(lineWidth: 1.3, lineJoin: .round)
    private static let smileStroke = StrokeStyle(lineWidth: 1, lineCap: .round)

    /// The bread slice: a rounded crown over a body with rounded bottom
    /// corners.
    private static let slicePath: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 3.4, y: 7.4))
        path.addCurve(to: CGPoint(x: 1.7, y: 4.3), control1: CGPoint(x: 1.9, y: 6.9), control2: CGPoint(x: 1.3, y: 5.6))
        path.addCurve(to: CGPoint(x: 8, y: 1.3), control1: CGPoint(x: 2.3, y: 2.4), control2: CGPoint(x: 4.6, y: 1.3))
        path.addCurve(to: CGPoint(x: 14.3, y: 4.3), control1: CGPoint(x: 11.4, y: 1.3), control2: CGPoint(x: 13.7, y: 2.4))
        path.addCurve(to: CGPoint(x: 12.6, y: 7.4), control1: CGPoint(x: 14.7, y: 5.6), control2: CGPoint(x: 14.1, y: 6.9))
        path.addLine(to: CGPoint(x: 12.6, y: 13))
        path.addArc(tangent1End: CGPoint(x: 12.6, y: 14.8), tangent2End: CGPoint(x: 10.8, y: 14.8), radius: 1.8)
        path.addLine(to: CGPoint(x: 5.2, y: 14.8))
        path.addArc(tangent1End: CGPoint(x: 3.4, y: 14.8), tangent2End: CGPoint(x: 3.4, y: 13), radius: 1.8)
        path.closeSubpath()
        return path
    }()

    private static let butterPath = Path(roundedRect: CGRect(x: 6.3, y: 4.2, width: 3.4, height: 2.2), cornerRadius: 0.6)

    private static let eyePaths: [Path] = [6.3, 9.7].map { eyeX in
        Path(ellipseIn: CGRect(x: eyeX - 0.8, y: 9.3 - 0.8, width: 1.6, height: 1.6))
    }

    private static let smilePath: Path = {
        var smile = Path()
        smile.move(to: CGPoint(x: 6.5, y: 11.3))
        smile.addQuadCurve(to: CGPoint(x: 9.5, y: 11.3), control: CGPoint(x: 8, y: 12.5))
        return smile
    }()

    private struct Colors {
        let fill: Color?
        let outline: Color
        let face: Color
        let butter: Color?

        init(_ style: Style, palette: Palette) {
            switch style {
            case .outline:
                fill = nil
                outline = palette.outline
                face = palette.outline
                butter = nil
            case .golden:
                fill = palette.goldenFill
                outline = palette.goldenOutline
                face = palette.goldenFace
                butter = palette.goldenButter
            }
        }
    }
}

#if canImport(UIKit)
extension ToastyIcon {
    /// Toasty's outline as a template image, for a place that takes only a
    /// still image, such as a tab bar item. The system tints it. Drawn from
    /// the same paths as the view, so the two never drift apart.
    @MainActor
    public static func outlineTemplateImage(pointSize: CGFloat, lineWidthScale: CGFloat = 1) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: pointSize, height: pointSize))
        let image = renderer.image { rendererContext in
            let context = rendererContext.cgContext
            context.scaleBy(x: pointSize / unit, y: pointSize / unit)
            context.setStrokeColor(UIColor.black.cgColor)
            context.setFillColor(UIColor.black.cgColor)
            context.setLineJoin(.round)
            context.setLineWidth(sliceStroke.lineWidth * lineWidthScale)
            context.addPath(slicePath.cgPath)
            context.strokePath()
            for eye in eyePaths {
                context.addPath(eye.cgPath)
                context.fillPath()
            }
            context.setLineCap(.round)
            context.setLineWidth(smileStroke.lineWidth * lineWidthScale)
            context.addPath(smilePath.cgPath)
            context.strokePath()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }
}
#endif

/// Three wisps of steam that rise above Toasty and fade, one after another.
/// Core Animation moves them, so a working coordinator does not update the
/// window's views for each frame. With Reduce Motion they stand still.
private struct ToastySteam: View {
    /// Points per unit of Toasty's 16 x 16 box.
    let scale: CGFloat
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let wispXs: [CGFloat] = [5.2, 8, 10.8]
    /// The bottom of each wisp above the icon's top edge, at rest.
    private static let wispBaseYs: [CGFloat] = [-0.6, -1, -0.6]
    private static let wispHeight: CGFloat = 1.8
    private static let rise: CGFloat = 3.5
    private static let period: TimeInterval = 1.6
    private static let stagger: TimeInterval = 0.5
    /// The frame reaches this far above the icon's top edge and below it.
    private static let above: CGFloat = 7
    private static let below: CGFloat = 1.5
    /// A wisp that stands still has risen this far and shows this much.
    private static let stillLift: CGFloat = 1
    private static let fullOpacity: Double = 0.9

    var body: some View {
        ToasttyLayerAnimationView(shapes: Self.wispXs.indices.map(wisp), animates: reduceMotion == false)
            .frame(width: 16 * scale, height: (Self.above + Self.below) * scale)
            .offset(y: -Self.above * scale)
            .allowsHitTesting(false)
    }

    /// One wisp before it rises: a short curve whose bottom is one unit
    /// below its resting place. In each period it rises by `rise` and slows
    /// down, and its opacity grows in the first 40% and then fades.
    private func wisp(_ index: Int) -> ToasttyLayerAnimationView.Shape {
        let x = Self.wispXs[index] * scale
        let bottom = (Self.above + Self.wispBaseYs[index] + 1) * scale
        let height = Self.wispHeight * scale
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: bottom))
        path.addQuadCurve(
            to: CGPoint(x: x, y: bottom - height),
            control: CGPoint(x: x + 0.8 * scale, y: bottom - height / 2)
        )
        let delay = Double(index) * Self.stagger
        return .init(
            path: path,
            strokeColor: color,
            lineWidth: scale,
            roundLineCap: true,
            restingOpacity: Self.fullOpacity,
            restingOffsetY: -Self.stillLift * scale,
            animations: [
                .init(
                    property: .offsetY,
                    values: [0, -Self.rise * scale],
                    easing: .easeOutQuadratic,
                    duration: Self.period,
                    delay: delay
                ),
                .init(
                    property: .opacity,
                    values: [0, Self.fullOpacity, 0],
                    keyTimes: [0, 0.4, 1],
                    easing: .easeOutQuadratic,
                    duration: Self.period,
                    delay: delay
                ),
            ]
        )
    }
}
