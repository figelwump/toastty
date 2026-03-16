import CoreState
import SwiftUI

struct SessionActivityRail: View {
    let kind: SessionStatusKind
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat

    init(
        kind: SessionStatusKind,
        width: CGFloat = 4,
        height: CGFloat = 34,
        cornerRadius: CGFloat = 2
    ) {
        self.kind = kind
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
            let roundedShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

            roundedShape
                .fill(ToastyTheme.sessionActivityRailGradient(for: kind))
                .overlay {
                    if kind == .working {
                        shimmerOverlay(phaseDate: context.date)
                            .mask(roundedShape)
                    } else if kind == .needsApproval {
                        pulseOverlay(phaseDate: context.date)
                            .mask(roundedShape)
                    }
                }
                .overlay {
                    roundedShape
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                }
                .shadow(color: ToastyTheme.sessionActivityRailShadowColor(for: kind), radius: 4, x: 0, y: 0)
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }

    private func shimmerOverlay(phaseDate: Date) -> some View {
        let phase = phaseDate.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
        let travel = width * 3.4
        let offset = CGFloat(phase) * travel - travel / 2

        return Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        .clear,
                        ToastyTheme.sessionActivityRailHighlightColor(for: kind),
                        .clear,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: max(width * 2.4, 10), height: height * 1.25)
            .rotationEffect(.degrees(18))
            .offset(x: offset)
            .blur(radius: 1.2)
    }

    private func pulseOverlay(phaseDate: Date) -> some View {
        let phase = phaseDate.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
        let opacity = 0.28 + (sin(phase * .pi * 2) + 1) * 0.18

        return Rectangle()
            .fill(ToastyTheme.sessionActivityRailHighlightColor(for: kind))
            .opacity(opacity)
    }
}
