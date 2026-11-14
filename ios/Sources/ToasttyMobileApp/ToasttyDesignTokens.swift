import ConversationUI
import SwiftUI
import ToasttyMobileDomain

/// The app palette. The conversation colors come from `ConversationUI`, which
/// draws the transcript, so the two cannot differ.
enum ToasttyDesignTokens {
    // Neutral surfaces lean warm so they harmonize with the cream text and
    // amber accent; luminance matches the previous cool-gray stack, keeping
    // every audited contrast ratio intact.
    static let background = ConversationDesignTokens.background
    static let raisedSurface = ConversationDesignTokens.raisedSurface
    static let elevatedSurface = Color(red: 33 / 255, green: 29 / 255, blue: 26 / 255)
    static let border = ConversationDesignTokens.border
    static let divider = Color(red: 38 / 255, green: 34 / 255, blue: 32 / 255)
    static let primaryText = ConversationDesignTokens.primaryText
    static let secondaryText = ConversationDesignTokens.secondaryText
    // Muted text stays >= 4.5:1 against raisedSurface so caption-sized
    // metadata remains readable (WCAG AA).
    static let mutedText = ConversationDesignTokens.mutedText
    // Translucent white so the chip reads on both raised and status-tinted
    // card backgrounds.
    static let chipSurface = ConversationDesignTokens.chipSurface
    static let chipBorder = ConversationDesignTokens.chipBorder
    /// Faint lift for the language header strip on transcript code blocks.
    static let codeHeaderSurface = ConversationDesignTokens.codeHeaderSurface
    static let amber = ConversationDesignTokens.amber
    static let amberText = ConversationDesignTokens.amberText
    /// Dark-mode system blue for external web links in assistant Markdown.
    static let externalLink = ConversationDesignTokens.externalLink
    /// Foreground for text and glyphs placed on the amber accent.
    static let inkOnAmber = ConversationDesignTokens.inkOnAmber
    static let green = ConversationDesignTokens.green
    static let red = ConversationDesignTokens.red
    static let offline = Color(red: 107 / 255, green: 112 / 255, blue: 118 / 255)
    static let userBubbleSurface = ConversationDesignTokens.userBubbleSurface
    static let userBubbleBorder = ConversationDesignTokens.userBubbleBorder
    static let userBubbleText = ConversationDesignTokens.userBubbleText
    static let interactionSurface = ConversationDesignTokens.interactionSurface
    /// The desktop's waiting colors, for a session whose own turn has ended
    /// while work it started is still running.
    static let waitingText = Color(red: 230 / 255, green: 207 / 255, blue: 169 / 255)
    static let waitingSurface = Color(red: 193 / 255, green: 170 / 255, blue: 138 / 255).opacity(0.14)
    static let waitingBorder = Color(red: 193 / 255, green: 170 / 255, blue: 138 / 255).opacity(0.42)
    private static let sessionWorking = Color(red: 193 / 255, green: 138 / 255, blue: 74 / 255)
    private static let sessionNeedsApproval = Color(red: 232 / 255, green: 166 / 255, blue: 53 / 255)
    /// Task marks, as the Mac sidebar draws them: a question waits for the
    /// user's reply, a review for their look, and a merged task for a release.
    static let taskQuestion = Color(red: 232 / 255, green: 166 / 255, blue: 53 / 255)
    static let taskReview = Color(red: 110 / 255, green: 159 / 255, blue: 230 / 255)
    static let taskToShip = Color(red: 185 / 255, green: 140 / 255, blue: 224 / 255)
    /// The Mac sidebar's Needs you yellow, for bucket titles and counts.
    static let needsYou = Color(red: 242 / 255, green: 196 / 255, blue: 107 / 255)

    /// Corner scale: cards and bubbles, inset controls, and chips.
    static let cardCornerRadius = ConversationDesignTokens.cardCornerRadius
    static let controlCornerRadius = ConversationDesignTokens.controlCornerRadius
    static let chipCornerRadius: CGFloat = 6

    /// Trailing-edge speech shape for user-authored bubbles.
    static var userBubbleShape: UnevenRoundedRectangle { ConversationDesignTokens.userBubbleShape }

    static func color(for bucket: MobileSessionBucket) -> Color {
        switch bucket {
        case .ready: green
        case .working: sessionWorking
        case .needsApproval: sessionNeedsApproval
        case .error: red
        case .idle: offline
        }
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
