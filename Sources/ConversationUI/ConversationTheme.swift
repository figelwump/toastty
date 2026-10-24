import SwiftUI

/// Colors and radii used by the shared conversation content. The defaults
/// preserve the iPhone appearance; a host can supply its own application theme.
public struct ConversationTheme: Equatable, Sendable {
    public var background: Color
    public var raisedSurface: Color
    public var border: Color
    public var primaryText: Color
    public var secondaryText: Color
    public var mutedText: Color
    public var chipSurface: Color
    public var codeHeaderSurface: Color
    public var amber: Color
    public var amberText: Color
    public var externalLink: Color
    public var inkOnAmber: Color
    public var green: Color
    public var red: Color
    public var interactionSurface: Color
    public var controlCornerRadius: CGFloat
    public var cardCornerRadius: CGFloat

    public static let toastty = ConversationTheme()

    public init(
        background: Color = Color(red: 19 / 255, green: 17 / 255, blue: 16 / 255),
        raisedSurface: Color = Color(red: 28 / 255, green: 25 / 255, blue: 23 / 255),
        border: Color = Color(red: 44 / 255, green: 39 / 255, blue: 34 / 255),
        primaryText: Color = Color(red: 232 / 255, green: 230 / 255, blue: 225 / 255),
        secondaryText: Color = Color(red: 184 / 255, green: 180 / 255, blue: 172 / 255),
        mutedText: Color = Color(red: 146 / 255, green: 141 / 255, blue: 133 / 255),
        chipSurface: Color = Color.white.opacity(0.055),
        codeHeaderSurface: Color = Color.white.opacity(0.025),
        amber: Color = Color(red: 232 / 255, green: 147 / 255, blue: 12 / 255),
        amberText: Color = Color(red: 232 / 255, green: 180 / 255, blue: 106 / 255),
        externalLink: Color = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255),
        inkOnAmber: Color = Color(red: 22 / 255, green: 16 / 255, blue: 6 / 255),
        green: Color = Color(red: 70 / 255, green: 165 / 255, blue: 126 / 255),
        red: Color = Color(red: 224 / 255, green: 88 / 255, blue: 78 / 255),
        interactionSurface: Color = Color(red: 24 / 255, green: 21 / 255, blue: 9 / 255),
        controlCornerRadius: CGFloat = 10,
        cardCornerRadius: CGFloat = 14
    ) {
        self.background = background
        self.raisedSurface = raisedSurface
        self.border = border
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.mutedText = mutedText
        self.chipSurface = chipSurface
        self.codeHeaderSurface = codeHeaderSurface
        self.amber = amber
        self.amberText = amberText
        self.externalLink = externalLink
        self.inkOnAmber = inkOnAmber
        self.green = green
        self.red = red
        self.interactionSurface = interactionSurface
        self.controlCornerRadius = controlCornerRadius
        self.cardCornerRadius = cardCornerRadius
    }
}
