import CoreState
import SwiftUI

enum SessionStatusIndicatorState: Equatable {
    case hidden
    case spinner
    case dot
}

struct SessionStatusIndicator: View {
    let state: SessionStatusIndicatorState
    var size: CGFloat
    var lineWidth: CGFloat

    init(
        state: SessionStatusIndicatorState,
        size: CGFloat = 8,
        lineWidth: CGFloat = 1.5
    ) {
        self.state = state
        self.size = size
        self.lineWidth = lineWidth
    }

    var body: some View {
        Group {
            switch state {
            case .hidden:
                EmptyView()
            case .spinner:
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
                    spinner(angle: spinnerAngle(at: context.date))
                }
            case .dot:
                Circle()
                    .fill(ToastyTheme.badgeBlue)
                    .frame(width: size, height: size)
                    .shadow(color: ToastyTheme.badgeBlue.opacity(0.5), radius: 3, x: 0, y: 0)
            }
        }
        .accessibilityHidden(true)
    }

    private func spinner(angle: Angle) -> some View {
        Circle()
            .trim(from: 0.16, to: 0.9)
            .stroke(
                ToastyTheme.sessionIndicatorSpinnerColor,
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .rotationEffect(angle)
            .frame(width: size, height: size)
    }

    private func spinnerAngle(at date: Date) -> Angle {
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: 0.9) / 0.9
        return .degrees(phase * 360)
    }
}
