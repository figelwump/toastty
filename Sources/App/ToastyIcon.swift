import SwiftUI

/// Toasty, the empty-window toast, as a small glyph: the coordinator's icon.
/// It can carry the coordinator's status: steam while the agent works, or a
/// session row's rail dot on its top-right corner. Steam and dot draw
/// outside the icon's frame, so leave room above it and to its right.
struct ToastyIcon: View {
    enum Style {
        /// A gray outline, for places where color means status, such as
        /// the sidebar.
        case outline
        /// The golden toast with its butter.
        case golden
    }

    enum Status: Equatable {
        case none
        case working
        case unread
        case needsApproval
        case error
    }

    var style: Style = .outline
    var size: CGFloat = 14
    var status: Status = .none
    /// The color behind the icon. It rings the status dot, so the dot reads
    /// as a badge on Toasty.
    var badgeRingColor: Color = ToastyTheme.chromeBackground

    /// The drawing's coordinates are in a 16 x 16 box.
    private static let unit: CGFloat = 16
    private static let badgeRingWidth: CGFloat = 1.5
    /// The dot's center sits this far right of and above the icon's
    /// top-right corner.
    private static let badgeCenterOffset: CGFloat = 1.5

    var body: some View {
        Canvas { context, canvasSize in
            context.scaleBy(x: canvasSize.width / Self.unit, y: canvasSize.height / Self.unit)
            drawToast(in: &context)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topLeading) {
            if status == .working {
                ToastySteam(scale: size / Self.unit)
            }
        }
        .overlay {
            if let railState {
                badge(railState)
            }
        }
        .accessibilityHidden(true)
    }

    private var railState: SidebarSessionPresentation.SessionRailState? {
        switch status {
        case .none, .working: nil
        case .unread: .unreadDot
        case .needsApproval: .approvalDot
        case .error: .errorDot
        }
    }

    private func badge(_ state: SidebarSessionPresentation.SessionRailState) -> some View {
        let dotSize = SessionRailStatusIcon.dotSize
        return ZStack {
            Circle()
                .fill(badgeRingColor)
                .frame(width: dotSize + 2 * Self.badgeRingWidth, height: dotSize + 2 * Self.badgeRingWidth)
            SessionRailStatusIcon(state: state)
        }
        .position(x: size + Self.badgeCenterOffset, y: -Self.badgeCenterOffset)
    }

    private func drawToast(in context: inout GraphicsContext) {
        let colors = Colors(style)
        let slice = Self.slicePath
        if let fill = colors.fill {
            context.fill(slice, with: .color(fill))
        }
        context.stroke(slice, with: .color(colors.outline), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
        if let butter = colors.butter {
            context.fill(
                Path(roundedRect: CGRect(x: 6.3, y: 4.2, width: 3.4, height: 2.2), cornerRadius: 0.6),
                with: .color(butter)
            )
        }
        for eyeX in [6.3, 9.7] {
            context.fill(Path(ellipseIn: CGRect(x: eyeX - 0.8, y: 9.3 - 0.8, width: 1.6, height: 1.6)), with: .color(colors.face))
        }
        var smile = Path()
        smile.move(to: CGPoint(x: 6.5, y: 11.3))
        smile.addQuadCurve(to: CGPoint(x: 9.5, y: 11.3), control: CGPoint(x: 8, y: 12.5))
        context.stroke(smile, with: .color(colors.face), style: StrokeStyle(lineWidth: 1, lineCap: .round))
    }

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

    private struct Colors {
        let fill: Color?
        let outline: Color
        let face: Color
        let butter: Color?

        init(_ style: Style) {
            switch style {
            case .outline:
                fill = nil
                outline = ToastyTheme.sidebarSessionPathText
                face = ToastyTheme.sidebarSessionPathText
                butter = nil
            case .golden:
                fill = ToastyTheme.toastyIconGoldenFill
                outline = ToastyTheme.toastyIconGoldenOutline
                face = ToastyTheme.toastyIconGoldenFace
                butter = ToastyTheme.toastyIconGoldenButter
            }
        }
    }
}

/// Three wisps of steam that rise above Toasty and fade, one after another.
/// With Reduce Motion they stand still.
private struct ToastySteam: View {
    /// Points per unit of Toasty's 16 x 16 box.
    let scale: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let wispXs: [CGFloat] = [5.2, 8, 10.8]
    /// The bottom of each wisp above the icon's top edge, at rest.
    private static let wispBaseYs: [CGFloat] = [-0.6, -1, -0.6]
    private static let wispHeight: CGFloat = 1.8
    private static let rise: CGFloat = 3.5
    private static let period: TimeInterval = 1.6
    private static let stagger: TimeInterval = 0.5
    /// The canvas reaches this far above the icon's top edge and below it.
    private static let above: CGFloat = 7
    private static let below: CGFloat = 1.5

    var body: some View {
        Group {
            if reduceMotion {
                canvas(at: nil)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    canvas(at: context.date)
                }
            }
        }
        .frame(width: 16 * scale, height: (Self.above + Self.below) * scale)
        .offset(y: -Self.above * scale)
        .allowsHitTesting(false)
    }

    private func canvas(at date: Date?) -> some View {
        Canvas { context, _ in
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: 0, y: Self.above)
            for index in Self.wispXs.indices {
                let (lift, opacity) = Self.motion(index: index, date: date)
                guard opacity > 0 else { continue }
                let x = Self.wispXs[index]
                let bottom = Self.wispBaseYs[index] + 1 - lift
                var wisp = Path()
                wisp.move(to: CGPoint(x: x, y: bottom))
                wisp.addQuadCurve(
                    to: CGPoint(x: x, y: bottom - Self.wispHeight),
                    control: CGPoint(x: x + 0.8, y: bottom - Self.wispHeight / 2)
                )
                context.stroke(
                    wisp,
                    with: .color(ToastyTheme.accent.opacity(opacity)),
                    style: StrokeStyle(lineWidth: 1, lineCap: .round)
                )
            }
        }
    }

    /// How far a wisp has risen from its start, and its opacity. Without a
    /// date, the still pose of Reduce Motion.
    private static func motion(index: Int, date: Date?) -> (lift: CGFloat, opacity: Double) {
        guard let date else { return (1, 0.9) }
        let time = date.timeIntervalSinceReferenceDate - Double(index) * stagger
        let phase = time.truncatingRemainder(dividingBy: period) / period
        let progress = phase < 0 ? phase + 1 : phase
        let lift = rise * CGFloat(easeOut(progress))
        let opacity = progress < 0.4
            ? 0.9 * easeOut(progress / 0.4)
            : 0.9 * (1 - easeOut((progress - 0.4) / 0.6))
        return (lift, opacity)
    }

    private static func easeOut(_ value: Double) -> Double {
        1 - (1 - value) * (1 - value)
    }
}
