import CoreState
import SwiftUI

enum SessionStatusIndicatorState: Equatable {
    case hidden
    case spinner
    case dot
}

/// Calm working indicator for child rows: a softly breathing dot instead of a
/// spinner, so an expanded orchestrator doesn't render a stack of spinners.
struct SessionChildActivityDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var size: CGFloat = 6
    // Staggering per row keeps a group of children from pulsing in lockstep.
    var phaseOffset: Double = 0

    var body: some View {
        Group {
            if reduceMotion {
                Circle()
                    .fill(ToastyTheme.sessionIndicatorSpinnerColor.opacity(0.75))
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { context in
                    Circle()
                        .fill(
                            ToastyTheme.sessionIndicatorSpinnerColor
                                .opacity(Self.pulseOpacity(at: context.date, phaseOffset: phaseOffset))
                        )
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    static func pulseOpacity(at date: Date, phaseOffset: Double = 0) -> Double {
        // 2s triangle-wave breathe between 0.35 and 0.95.
        let phase = (date.timeIntervalSinceReferenceDate + phaseOffset)
            .truncatingRemainder(dividingBy: 2) / 2
        return 0.35 + 0.6 * (1 - abs(2 * phase - 1))
    }

    static func phaseOffset(forStableID stableID: String) -> Double {
        // Deterministic per-row phase in [0, 2). djb2 keeps it stable across
        // launches, unlike seeded String.hashValue.
        var hash: UInt64 = 5381
        for scalar in stableID.unicodeScalars {
            hash = hash &* 33 &+ UInt64(scalar.value)
        }
        return Double(hash % 200) / 100
    }
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
