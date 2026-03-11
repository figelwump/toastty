import SwiftUI

/// Branded empty state shown when no workspace is selected.
/// Displays a Canvas-drawn toast character, headline, body copy, and recovery CTA.
struct EmptyStateView: View {
    let onCreateWorkspace: (() -> Void)?

    init(onCreateWorkspace: (() -> Void)? = nil) {
        self.onCreateWorkspace = onCreateWorkspace
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            toastCharacter
                .padding(.bottom, 28)
            headline
                .padding(.bottom, 10)
            bodyText
                .padding(.bottom, 32)
            createWorkspaceCTA
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ToastyTheme.surfaceBackground)
    }

    // MARK: - Toast Character

    private var toastCharacter: some View {
        Canvas { context, size in
            let cx = size.width / 2
            let cy = size.height / 2

            // Warm radial glow behind the toast
            let glowCenter = CGPoint(x: cx, y: cy + 4)
            let glowRadius: CGFloat = 56
            context.drawLayer { glow in
                let gradient = Gradient(colors: [
                    ToastyTheme.accent.opacity(0.12),
                    ToastyTheme.accent.opacity(0.04),
                    Color.clear,
                ])
                glow.fill(
                    Path(ellipseIn: CGRect(
                        x: glowCenter.x - glowRadius,
                        y: glowCenter.y - glowRadius,
                        width: glowRadius * 2,
                        height: glowRadius * 2
                    )),
                    with: .radialGradient(
                        gradient,
                        center: glowCenter,
                        startRadius: 0,
                        endRadius: glowRadius
                    )
                )
            }

            // Toast body — crust
            let crustRect = CGRect(x: cx - 28, y: cy - 22, width: 56, height: 48)
            let crustPath = RoundedRectangle(cornerRadius: 8)
                .path(in: crustRect)
            context.fill(crustPath, with: .color(ToastyTheme.emptyStateToastCrust))

            // Toast body — bread interior
            let breadRect = crustRect.insetBy(dx: 4, dy: 4)
            let breadPath = RoundedRectangle(cornerRadius: 5)
                .path(in: breadRect)
            context.fill(breadPath, with: .color(ToastyTheme.emptyStateToastBread))

            // Top highlight
            let highlightRect = CGRect(
                x: breadRect.minX + 3,
                y: breadRect.minY + 2,
                width: breadRect.width - 6,
                height: 6
            )
            let highlightPath = RoundedRectangle(cornerRadius: 3)
                .path(in: highlightRect)
            context.fill(highlightPath, with: .color(ToastyTheme.emptyStateToastHighlight))

            // Butter pat
            let butterRect = CGRect(x: cx - 8, y: cy - 10, width: 16, height: 10)
            let butterPath = RoundedRectangle(cornerRadius: 2)
                .path(in: butterRect)
            context.fill(butterPath, with: .color(ToastyTheme.accent))

            // Face — two dash eyes
            let eyeY = cy + 6
            let eyeWidth: CGFloat = 5
            var leftEye = Path()
            leftEye.move(to: CGPoint(x: cx - 10, y: eyeY))
            leftEye.addLine(to: CGPoint(x: cx - 10 + eyeWidth, y: eyeY))
            var rightEye = Path()
            rightEye.move(to: CGPoint(x: cx + 5, y: eyeY))
            rightEye.addLine(to: CGPoint(x: cx + 5 + eyeWidth, y: eyeY))
            let eyeStyle = StrokeStyle(lineWidth: 2, lineCap: .round)
            context.stroke(leftEye, with: .color(ToastyTheme.emptyStateToastFace), style: eyeStyle)
            context.stroke(rightEye, with: .color(ToastyTheme.emptyStateToastFace), style: eyeStyle)

            // Face — smile
            var smile = Path()
            smile.move(to: CGPoint(x: cx - 6, y: cy + 14))
            smile.addQuadCurve(
                to: CGPoint(x: cx + 6, y: cy + 14),
                control: CGPoint(x: cx, y: cy + 20)
            )
            context.stroke(
                smile,
                with: .color(ToastyTheme.emptyStateToastFace),
                style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
            )

            // Steam wisps
            drawSteamWisp(context: &context, x: cx - 12, baseY: cy - 26, height: 14, amplitude: 3)
            drawSteamWisp(context: &context, x: cx, baseY: cy - 30, height: 16, amplitude: 3.75)
            drawSteamWisp(context: &context, x: cx + 12, baseY: cy - 26, height: 14, amplitude: 4.5)
        }
        .frame(width: 120, height: 120)
    }

    private func drawSteamWisp(
        context: inout GraphicsContext,
        x: CGFloat,
        baseY: CGFloat,
        height: CGFloat,
        amplitude: CGFloat
    ) {
        var wisp = Path()
        wisp.move(to: CGPoint(x: x, y: baseY))
        wisp.addCurve(
            to: CGPoint(x: x + amplitude * 0.3, y: baseY - height),
            control1: CGPoint(x: x + amplitude, y: baseY - height * 0.33),
            control2: CGPoint(x: x - amplitude, y: baseY - height * 0.66)
        )
        context.stroke(
            wisp,
            with: .color(ToastyTheme.emptyStateMutedText.opacity(0.35)),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
        )
    }

    // MARK: - Text

    private var headline: some View {
        Text("Nothing's cooking yet")
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(ToastyTheme.primaryText)
    }

    private var bodyText: some View {
        VStack(spacing: 4) {
            Text("Open a terminal to get toasty.")
            Text("Your workspaces are waiting to warm up.")
        }
        .font(.system(size: 14))
        .foregroundStyle(ToastyTheme.emptyStateMutedText)
        .multilineTextAlignment(.center)
    }

    // MARK: - Primary Action

    // TODO: derive shortcut labels from actual keybinding configuration
    private var createWorkspaceCTA: some View {
        Button {
            onCreateWorkspace?()
        } label: {
            HStack(spacing: 12) {
                Text("New Workspace")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ToastyTheme.accentDark)

                Text("\u{2318}\u{21E7}N")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ToastyTheme.accentDark.opacity(0.72))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(ToastyTheme.accentDark.opacity(0.12))
                    )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                Capsule()
                    .fill(ToastyTheme.accent)
            )
            .overlay(
                Capsule()
                    .stroke(ToastyTheme.emptyStateToastHighlight.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: ToastyTheme.accent.opacity(0.18), radius: 14, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(onCreateWorkspace == nil)
        .opacity(onCreateWorkspace == nil ? 0.55 : 1)
        .accessibilityIdentifier("empty-state.new-workspace")
    }
}

#Preview {
    EmptyStateView(onCreateWorkspace: {})
}
