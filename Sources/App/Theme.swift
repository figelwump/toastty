import SwiftUI

enum ToastyTheme {
    static let chromeBackground = Color(hex: 0x111111)
    static let surfaceBackground = Color(hex: 0x0D0D0D)
    static let elevatedBackground = Color(hex: 0x1A1A1A)
    static let hairline = Color(hex: 0x1F1F1F)

    static let primaryText = Color(hex: 0xE8E4DF)
    static let mutedText = Color(hex: 0x666666)
    static let mutedTextStrong = Color(hex: 0x555555)

    static let accent = Color(hex: 0xF5A623)
    static let badgeBlue = Color(hex: 0x3B82F6)

    static let sidebarWidth: CGFloat = 180
    static let topBarHeight: CGFloat = 36

    static let fontTitle = Font.system(size: 13, weight: .semibold, design: .rounded)
    static let fontBody = Font.system(size: 12, weight: .medium, design: .rounded)
    static let fontSubtext = Font.system(size: 10, weight: .medium, design: .rounded)
    static let fontMonoHeader = Font.system(size: 12, weight: .semibold, design: .monospaced)
}

private extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
