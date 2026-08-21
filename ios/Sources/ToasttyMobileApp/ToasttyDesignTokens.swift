import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain

enum ToasttyDesignTokens {
    // Neutral surfaces lean warm so they harmonize with the cream text and
    // amber accent; luminance matches the previous cool-gray stack, keeping
    // every audited contrast ratio intact.
    static let background = Color(red: 19 / 255, green: 17 / 255, blue: 16 / 255)
    static let raisedSurface = Color(red: 28 / 255, green: 25 / 255, blue: 23 / 255)
    static let elevatedSurface = Color(red: 33 / 255, green: 29 / 255, blue: 26 / 255)
    static let border = Color(red: 44 / 255, green: 39 / 255, blue: 34 / 255)
    static let divider = Color(red: 38 / 255, green: 34 / 255, blue: 32 / 255)
    static let primaryText = Color(red: 232 / 255, green: 230 / 255, blue: 225 / 255)
    static let secondaryText = Color(red: 184 / 255, green: 180 / 255, blue: 172 / 255)
    // Muted text stays >= 4.5:1 against raisedSurface so caption-sized
    // metadata remains readable (WCAG AA).
    static let mutedText = Color(red: 146 / 255, green: 141 / 255, blue: 133 / 255)
    // Translucent white so the chip reads on both raised and status-tinted
    // card backgrounds.
    static let chipSurface = Color.white.opacity(0.055)
    static let chipBorder = Color.white.opacity(0.11)
    static let amber = Color(red: 232 / 255, green: 147 / 255, blue: 12 / 255)
    static let amberText = Color(red: 232 / 255, green: 180 / 255, blue: 106 / 255)
    /// Foreground for text and glyphs placed on the amber accent.
    static let inkOnAmber = Color(red: 22 / 255, green: 16 / 255, blue: 6 / 255)
    static let green = Color(red: 70 / 255, green: 165 / 255, blue: 126 / 255)
    static let red = Color(red: 224 / 255, green: 88 / 255, blue: 78 / 255)
    static let offline = Color(red: 107 / 255, green: 112 / 255, blue: 118 / 255)
    static let codex = Color(red: 45 / 255, green: 187 / 255, blue: 160 / 255)
    static let claude = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
    static let userBubbleSurface = Color(red: 64 / 255, green: 47 / 255, blue: 21 / 255)
    static let userBubbleBorder = Color(red: 90 / 255, green: 62 / 255, blue: 27 / 255)
    static let userBubbleText = Color(red: 240 / 255, green: 232 / 255, blue: 216 / 255)
    static let interactionSurface = Color(red: 24 / 255, green: 21 / 255, blue: 9 / 255)
    private static let sessionWorking = Color(red: 193 / 255, green: 138 / 255, blue: 74 / 255)
    private static let sessionNeedsApproval = Color(red: 232 / 255, green: 166 / 255, blue: 53 / 255)

    /// Corner scale: cards and bubbles, inset controls, and chips.
    static let cardCornerRadius: CGFloat = 14
    static let controlCornerRadius: CGFloat = 10
    static let chipCornerRadius: CGFloat = 6

    /// Trailing-edge speech shape for user-authored bubbles.
    static var userBubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: cardCornerRadius,
            bottomLeadingRadius: cardCornerRadius,
            bottomTrailingRadius: 5,
            topTrailingRadius: cardCornerRadius,
            style: .continuous
        )
    }

    static func color(for bucket: MobileSessionBucket) -> Color {
        switch bucket {
        case .ready: green
        case .working: sessionWorking
        case .needsApproval: sessionNeedsApproval
        case .error: red
        case .idle: offline
        }
    }

    static func color(for agent: AgentKind) -> Color {
        if agent == .claude { return claude }
        if agent == .codex { return codex }
        return secondaryText
    }
}

struct ToasttyPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(ToasttyDesignTokens.inkOnAmber)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(ToasttyDesignTokens.amber.opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(RoundedRectangle(
                cornerRadius: ToasttyDesignTokens.controlCornerRadius,
                style: .continuous
            ))
    }
}

extension View {
    func toasttyCard() -> some View {
        padding(14)
            .background(ToasttyDesignTokens.raisedSurface)
            .overlay {
                RoundedRectangle(
                    cornerRadius: ToasttyDesignTokens.cardCornerRadius,
                    style: .continuous
                )
                .stroke(ToasttyDesignTokens.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(
                cornerRadius: ToasttyDesignTokens.cardCornerRadius,
                style: .continuous
            ))
    }
}
