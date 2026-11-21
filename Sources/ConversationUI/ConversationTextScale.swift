import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public extension EnvironmentValues {
    /// Multiplies the size of all text in the transcript. The Mac sets it
    /// for Command-plus and Command-minus, because macOS has no Dynamic
    /// Type. The iPhone leaves it at 1 and follows Dynamic Type.
    @Entry var conversationTextScale: CGFloat = 1
}

/// A transcript font: a text style, multiplied by `conversationTextScale`.
/// At a scale of 1 it is the text style's own font, so Dynamic Type still
/// applies.
struct ConversationFontModifier: ViewModifier {
    @Environment(\.conversationTextScale) private var scale

    let style: Font.TextStyle
    var weight: Font.Weight?
    var monospaced = false

    func body(content: Content) -> some View {
        content.font(Self.font(style, weight: weight, monospaced: monospaced, scale: scale))
    }

    static func font(_ style: Font.TextStyle, weight: Font.Weight?, monospaced: Bool, scale: CGFloat) -> Font {
        var font: Font
        if scale == 1 {
            font = Font.system(style)
        } else {
            font = Font.system(size: pointSize(of: style) * scale)
            // `.headline` is bold. A sized system font is not.
            if weight == nil, style == .headline { font = font.weight(.bold) }
        }
        if let weight { font = font.weight(weight) }
        if monospaced { font = font.monospaced() }
        return font
    }

    /// The size of the text style on this platform, before any scale.
    static func pointSize(of style: Font.TextStyle) -> CGFloat {
        #if canImport(UIKit)
        UIFont.preferredFont(forTextStyle: platformStyle(style)).pointSize
        #else
        NSFont.preferredFont(forTextStyle: platformStyle(style)).pointSize
        #endif
    }

    #if canImport(UIKit)
    private static func platformStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
    #else
    private static func platformStyle(_ style: Font.TextStyle) -> NSFont.TextStyle {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
    #endif
}

/// A fixed-size transcript font, such as a small icon's, multiplied by
/// `conversationTextScale`.
struct ConversationFixedFontModifier: ViewModifier {
    @Environment(\.conversationTextScale) private var scale

    let size: CGFloat
    let weight: Font.Weight

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight))
    }
}

extension View {
    /// Sets a transcript font that follows `conversationTextScale`.
    func conversationFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, monospaced: Bool = false) -> some View {
        modifier(ConversationFontModifier(style: style, weight: weight, monospaced: monospaced))
    }

    /// Sets a fixed-size transcript font that follows `conversationTextScale`.
    func conversationFont(size: CGFloat, weight: Font.Weight) -> some View {
        modifier(ConversationFixedFontModifier(size: size, weight: weight))
    }
}
