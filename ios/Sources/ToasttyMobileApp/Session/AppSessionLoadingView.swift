import SwiftUI

enum AppSessionLoadingPhase: Equatable {
    case restoring
    case connecting(hostName: String)
}

/// The single loading screen shown from launch (or pairing completion) until
/// the first live snapshot mounts the home screen. Both phases share one
/// layout so the restore → connect handoff is invisible; only the caption
/// and the host line change.
struct AppSessionLoadingView: View {
    let phase: AppSessionLoadingPhase

    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @State private var cursorIsDimmed = false
    @State private var sweepIsAtTrailingEdge = false
    @State private var hostDotIsDimmed = false

    var body: some View {
        ZStack {
            ToasttyDesignTokens.background.ignoresSafeArea()
            VStack(spacing: 0) {
                brand
                progressTrack
                    .padding(.top, 30)
                caption
                    .padding(.top, 22)
            }
            .frame(maxWidth: 430)
            .padding(28)
        }
        .overlay(alignment: .bottom) {
            hostLine
        }
        .animation(.easeInOut(duration: 0.3), value: phase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(captionText)
        .accessibilityValue("In progress")
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var brand: some View {
        HStack(spacing: 5) {
            Text("TOASTTY")
                .font(.title3.monospaced())
                .fontWeight(.bold)
                .tracking(6)
            Rectangle()
                .fill(ToasttyDesignTokens.amber)
                .frame(width: 11, height: 20)
                .opacity(cursorIsDimmed ? 0 : 1)
                .onAppear {
                    guard !reducesMotion else { return }
                    withAnimation(
                        .easeInOut(duration: 0.55).repeatForever(autoreverses: true)
                    ) {
                        cursorIsDimmed = true
                    }
                }
        }
        .foregroundStyle(ToasttyDesignTokens.primaryText)
    }

    @ViewBuilder
    private var progressTrack: some View {
        if reducesMotion {
            ProgressView()
                .tint(ToasttyDesignTokens.amber)
        } else {
            GeometryReader { proxy in
                let segmentWidth = proxy.size.width * 0.44
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(ToasttyDesignTokens.border)
                    Capsule()
                        .fill(ToasttyDesignTokens.amber)
                        .frame(width: segmentWidth)
                        .offset(x: sweepIsAtTrailingEdge ? proxy.size.width : -segmentWidth)
                }
            }
            .frame(width: 148, height: 3)
            .clipShape(Capsule())
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 1.5).repeatForever(autoreverses: false)
                ) {
                    sweepIsAtTrailingEdge = true
                }
            }
        }
    }

    private var caption: some View {
        Text(captionText)
            .font(.footnote)
            .foregroundStyle(ToasttyDesignTokens.secondaryText)
            .contentTransition(.opacity)
    }

    @ViewBuilder
    private var hostLine: some View {
        if case .connecting(let hostName) = phase {
            HStack(spacing: 6) {
                Circle()
                    .fill(ToasttyDesignTokens.amber)
                    .frame(width: 6, height: 6)
                    .opacity(!reducesMotion && hostDotIsDimmed ? 0.35 : 1)
                    .onAppear {
                        guard !reducesMotion else { return }
                        withAnimation(
                            .easeInOut(duration: 0.75).repeatForever(autoreverses: true)
                        ) {
                            hostDotIsDimmed = true
                        }
                    }
                Text(hostName)
            }
            .font(.caption2.monospaced())
            .foregroundStyle(ToasttyDesignTokens.mutedText)
            .padding(.bottom, 30)
            .transition(.opacity)
        }
    }

    private var captionText: String {
        switch phase {
        case .restoring:
            "Restoring this device…"
        case .connecting(let hostName):
            "Connecting to \(hostName)…"
        }
    }

    private var accessibilityIdentifier: String {
        switch phase {
        case .restoring: "toastty-mobile-session-restoring"
        case .connecting: "toastty-mobile-session-connecting"
        }
    }
}

#Preview("Restoring") {
    AppSessionLoadingView(phase: .restoring)
}

#Preview("Connecting") {
    AppSessionLoadingView(phase: .connecting(hostName: "vishals-mac.tailnet.ts.net"))
}
