import SwiftUI

public enum ConversationTextStyle: Sendable {
    case body, headline, subheadline
}

public enum ConversationTextWeight: Sendable {
    case regular, medium, semibold, bold, heavy
}

public enum ConversationTextAlignment: Sendable {
    case natural, left, center, right
}

/// Selectable attributed text. Native text views own range selection; the host
/// conversation owns scrolling and handles application links through openURL.
public struct ConversationSelectableText: View {
    let text: AttributedString
    let textStyle: ConversationTextStyle
    let weight: ConversationTextWeight?
    let monospaced: Bool
    let textColor: Color
    let lineSpacing: CGFloat
    let alignment: ConversationTextAlignment
    let theme: ConversationTheme

    public init(_ text: AttributedString, textStyle: ConversationTextStyle = .body,
                weight: ConversationTextWeight? = nil, monospaced: Bool = false,
                textColor: Color? = nil, lineSpacing: CGFloat = 6,
                alignment: ConversationTextAlignment = .natural,
                theme: ConversationTheme = .toastty) {
        self.text = text
        self.textStyle = textStyle
        self.weight = weight
        self.monospaced = monospaced
        self.textColor = textColor ?? theme.primaryText
        self.lineSpacing = lineSpacing
        self.alignment = alignment
        self.theme = theme
    }

    public var body: some View {
        ConversationNativeSelectableText(
            text, textStyle: textStyle.native, weight: weight?.native,
            monospaced: monospaced, textColor: textColor, lineSpacing: lineSpacing,
            alignment: alignment.native, theme: theme
        )
    }
}
