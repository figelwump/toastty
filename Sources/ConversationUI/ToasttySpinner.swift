import SwiftUI

/// The activity spinner of the conversation and the iPhone app. It matches the
/// desktop app's `SessionStatusIndicator`: a trimmed arc that rotates once
/// every 0.9 seconds. Core Animation turns it, on the Mac and on the iPhone,
/// so it costs the main thread nothing while it turns; see
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
        ToasttyLayerAnimationView(
            shapes: [.spinnerArc(size: size, lineWidth: lineWidth, color: color)],
            animates: reduceMotion == false
        )
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
