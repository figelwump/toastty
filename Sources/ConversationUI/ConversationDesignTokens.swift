import SwiftUI

/// The colors and corner sizes the conversation views draw with. The iPhone
/// app's `ToasttyDesignTokens` reuses these values, so the conversation and
/// the screens around it keep one palette.
public enum ConversationDesignTokens {
    // Neutral surfaces lean warm so they harmonize with the cream text and
    // amber accent; luminance matches the previous cool-gray stack, keeping
    // every audited contrast ratio intact.
    public static let background = Color(red: 19 / 255, green: 17 / 255, blue: 16 / 255)
    public static let raisedSurface = Color(red: 28 / 255, green: 25 / 255, blue: 23 / 255)
    public static let border = Color(red: 44 / 255, green: 39 / 255, blue: 34 / 255)
    public static let primaryText = Color(red: 232 / 255, green: 230 / 255, blue: 225 / 255)
    public static let secondaryText = Color(red: 184 / 255, green: 180 / 255, blue: 172 / 255)
    // Muted text stays >= 4.5:1 against raisedSurface so caption-sized
    // metadata remains readable (WCAG AA).
    public static let mutedText = Color(red: 146 / 255, green: 141 / 255, blue: 133 / 255)
    // Translucent white so the chip reads on both raised and status-tinted
    // card backgrounds.
    public static let chipSurface = Color.white.opacity(0.055)
    public static let chipBorder = Color.white.opacity(0.11)
    /// Faint lift for the language header strip on transcript code blocks.
    public static let codeHeaderSurface = Color.white.opacity(0.025)
    public static let amber = Color(red: 232 / 255, green: 147 / 255, blue: 12 / 255)
    public static let amberText = Color(red: 232 / 255, green: 180 / 255, blue: 106 / 255)
    /// Dark-mode system blue for external web links in assistant Markdown.
    public static let externalLink = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)
    /// Foreground for text and glyphs placed on the amber accent.
    public static let inkOnAmber = Color(red: 22 / 255, green: 16 / 255, blue: 6 / 255)
    public static let green = Color(red: 70 / 255, green: 165 / 255, blue: 126 / 255)
    public static let red = Color(red: 224 / 255, green: 88 / 255, blue: 78 / 255)
    public static let userBubbleSurface = Color(red: 64 / 255, green: 47 / 255, blue: 21 / 255)
    public static let userBubbleBorder = Color(red: 90 / 255, green: 62 / 255, blue: 27 / 255)
    public static let userBubbleText = Color(red: 240 / 255, green: 232 / 255, blue: 216 / 255)
    public static let interactionSurface = Color(red: 24 / 255, green: 21 / 255, blue: 9 / 255)

    /// Corner scale: cards and bubbles, and inset controls.
    public static let cardCornerRadius: CGFloat = 14
    public static let controlCornerRadius: CGFloat = 10

    /// Trailing-edge speech shape for user-authored bubbles.
    public static var userBubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: cardCornerRadius,
            bottomLeadingRadius: cardCornerRadius,
            bottomTrailingRadius: 5,
            topTrailingRadius: cardCornerRadius,
            style: .continuous
        )
    }
}
