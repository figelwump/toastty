import RemoteProtocol
import SwiftUI
import ToasttyMobileDomain

enum ToasttyDesignTokens {
    static let background = Color(red: 16 / 255, green: 18 / 255, blue: 20 / 255)
    static let raisedSurface = Color(red: 24 / 255, green: 27 / 255, blue: 30 / 255)
    static let elevatedSurface = Color(red: 27 / 255, green: 31 / 255, blue: 34 / 255)
    static let border = Color(red: 35 / 255, green: 39 / 255, blue: 43 / 255)
    static let divider = Color(red: 31 / 255, green: 35 / 255, blue: 39 / 255)
    static let primaryText = Color(red: 232 / 255, green: 230 / 255, blue: 225 / 255)
    static let secondaryText = Color(red: 184 / 255, green: 180 / 255, blue: 172 / 255)
    // Muted text stays >= 4.5:1 against raisedSurface so caption-sized
    // metadata remains readable (WCAG AA).
    static let mutedText = Color(red: 146 / 255, green: 141 / 255, blue: 133 / 255)
    static let amber = Color(red: 232 / 255, green: 147 / 255, blue: 12 / 255)
    static let amberText = Color(red: 232 / 255, green: 180 / 255, blue: 106 / 255)
    /// Foreground for text and glyphs placed on the amber accent.
    static let inkOnAmber = Color(red: 22 / 255, green: 16 / 255, blue: 6 / 255)
    static let green = Color(red: 31 / 255, green: 169 / 255, blue: 113 / 255)
    static let blue = Color(red: 66 / 255, green: 133 / 255, blue: 244 / 255)
    static let red = Color(red: 224 / 255, green: 90 / 255, blue: 73 / 255)
    static let offline = Color(red: 107 / 255, green: 112 / 255, blue: 118 / 255)
    static let codex = Color(red: 45 / 255, green: 187 / 255, blue: 160 / 255)
    static let claude = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
    static let userBubbleSurface = Color(red: 58 / 255, green: 46 / 255, blue: 20 / 255)
    static let userBubbleBorder = Color(red: 85 / 255, green: 67 / 255, blue: 29 / 255)
    static let userBubbleText = Color(red: 240 / 255, green: 232 / 255, blue: 216 / 255)
    static let interactionSurface = Color(red: 24 / 255, green: 21 / 255, blue: 9 / 255)
    private static let sessionWorking = Color(red: 180 / 255, green: 130 / 255, blue: 75 / 255)
    private static let sessionNeedsApproval = Color(red: 232 / 255, green: 166 / 255, blue: 53 / 255)
    private static let sessionReady = Color(red: 91 / 255, green: 160 / 255, blue: 138 / 255)
    private static let sessionError = Color(red: 229 / 255, green: 92 / 255, blue: 92 / 255)

    static func color(for bucket: MobileSessionBucket) -> Color {
        switch bucket {
        case .ready: sessionReady
        case .working: sessionWorking
        case .needsApproval: sessionNeedsApproval
        case .error: sessionError
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
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

extension View {
    func toasttyCard() -> some View {
        padding(14)
            .background(ToasttyDesignTokens.raisedSurface)
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(ToasttyDesignTokens.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
