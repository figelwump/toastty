import ConversationUI
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
        ToasttyLayerAnimationView(shapes: [breathingDot], animates: reduceMotion == false)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// The opacity rises from 0.35 to 0.95 in one second and falls back in
    /// the next. With Reduce Motion it stays at 0.75.
    private var breathingDot: ToasttyLayerAnimationView.Shape {
        .init(
            path: CGPath(ellipseIn: CGRect(x: 0, y: 0, width: size, height: size), transform: nil),
            fillColor: ToastyTheme.sessionIndicatorSpinnerColor,
            restingOpacity: 0.75,
            animations: [
                .init(property: .opacity, values: [0.35, 0.95], duration: 1, autoreverses: true, delay: -phaseOffset),
            ]
        )
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
                ToasttyLayerAnimationView(shapes: [
                    .spinnerArc(size: size, lineWidth: lineWidth, color: ToastyTheme.sessionIndicatorSpinnerColor),
                ])
                .frame(width: size, height: size)
            case .dot:
                Circle()
                    .fill(ToastyTheme.badgeBlue)
                    .frame(width: size, height: size)
                    .shadow(color: ToastyTheme.badgeBlue.opacity(0.5), radius: 3, x: 0, y: 0)
            }
        }
        .accessibilityHidden(true)
    }
}
