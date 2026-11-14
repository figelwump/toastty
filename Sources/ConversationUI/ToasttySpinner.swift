import SwiftUI

/// The activity spinner of the conversation and the iPhone app. It matches the
/// desktop app's `SessionStatusIndicator`: a trimmed arc that rotates once
/// every 0.9 seconds. On the Mac, Core Animation turns it; see
/// `ToasttyLayerAnimationView`.
public struct ToasttySpinner: View {
    var size: CGFloat
    var lineWidth: CGFloat
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(size: CGFloat = 8, lineWidth: CGFloat = 1.5, color: Color = ConversationDesignTokens.amber) {
        self.size = size
        self.lineWidth = lineWidth
        self.color = color
    }

    public var body: some View {
        spinner
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    #if os(macOS)
    private var spinner: some View {
        ToasttyLayerAnimationView(
            shapes: [.spinnerArc(size: size, lineWidth: lineWidth, color: color)],
            animates: reduceMotion == false
        )
    }
    #else
    private var spinner: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { context in
            Circle()
                .trim(from: 0.16, to: 0.9)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(reduceMotion ? .zero : angle(at: context.date))
        }
    }

    private func angle(at date: Date) -> Angle {
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: 0.9) / 0.9
        return .degrees(phase * 360)
    }
    #endif
}
