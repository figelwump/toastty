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
    static let mutedText = Color(red: 119 / 255, green: 114 / 255, blue: 106 / 255)
    static let amber = Color(red: 232 / 255, green: 147 / 255, blue: 12 / 255)
    static let amberText = Color(red: 232 / 255, green: 180 / 255, blue: 106 / 255)
    static let green = Color(red: 31 / 255, green: 169 / 255, blue: 113 / 255)
    static let blue = Color(red: 66 / 255, green: 133 / 255, blue: 244 / 255)
    static let red = Color(red: 224 / 255, green: 90 / 255, blue: 73 / 255)
    static let offline = Color(red: 107 / 255, green: 112 / 255, blue: 118 / 255)
    static let codex = Color(red: 45 / 255, green: 187 / 255, blue: 160 / 255)
    static let claude = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)

    static func color(for bucket: MobileSessionBucket) -> Color {
        switch bucket {
        case .needsYou: amber
        case .working: green
        case .ready: blue
        case .attention: red
        case .offline: offline
        }
    }

    static func color(for agent: AgentKind) -> Color {
        if agent == .claude { return claude }
        if agent == .codex { return codex }
        return secondaryText
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
