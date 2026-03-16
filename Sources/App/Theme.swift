import SwiftUI

enum ToastyTheme {
    static let chromeBackground = Color(hex: 0x111111)
    static let surfaceBackground = Color(hex: 0x0D0D0D)
    static let elevatedBackground = Color(hex: 0x1A1A1A)
    static let hairline = Color(hex: 0x1F1F1F)
    static let subtleBorder = Color(hex: 0x2A2A2A)
    static let slotDivider = Color(hex: 0x333333)

    static let primaryText = Color(hex: 0xE8E4DF)
    static let mutedText = Color(hex: 0x666666)
    static let inactiveText = Color(hex: 0xB8B8B8)
    static let inactiveWorkspaceSubtitleText = Color(hex: 0xB0B0B0)
    static let subtleText = Color(hex: 0x5A5A5A)
    static let shortcutBadgeText = Color(hex: 0xB8B8B8)

    static let accent = Color(hex: 0xF5A623)
    static let accentDark = Color(hex: 0x0D0D0D)
    static let badgeBlue = Color(hex: 0x3B82F6)
    static let terminalProfileBadgeText = Color(hex: 0xF5D6A0)
    static let terminalProfileBadgeBackground = Color(hex: 0x5A3B14, alpha: 0.65)
    static let terminalProfileBadgeMissingText = Color(hex: 0xF4B183)
    static let terminalProfileBadgeMissingBackground = Color(hex: 0x5A2414, alpha: 0.65)

    // Empty state
    static let emptyStateToastCrust = Color(hex: 0x4A3425)
    static let emptyStateToastBread = Color(hex: 0x6B4E38)
    static let emptyStateToastHighlight = Color(hex: 0x7D5C42)
    static let emptyStateToastFace = Color(hex: 0x2A1A10)
    static let emptyStateMutedText = Color(hex: 0x6B5D52)
    static let emptyStateShortcutBg = Color(hex: 0x2A2420)
    static let emptyStateShortcutBorder = Color(hex: 0x3A3028)
    static let emptyStateShortcutText = Color(hex: 0x8A7B6E)

    static let sidebarWidth: CGFloat = 180
    // Slightly taller than the native compact titlebar so the custom
    // title/buttons don't sit flush against the window edge.
    static let topBarHeight: CGFloat = 32
    static let topBarContentTopPadding: CGFloat = 2
    static let fontHUDTopPadding: CGFloat = topBarHeight + 12
    /// Standard macOS compact titlebar height on current supported macOS releases.
    /// Used only to keep sidebar content clear of the traffic lights.
    static let titlebarHeight: CGFloat = 28
    static let sidebarTopPadding: CGFloat = titlebarHeight + 4

    static let fontTitle = Font.system(size: 13, weight: .semibold, design: .rounded)
    static let fontBody = Font.system(size: 12, weight: .medium, design: .rounded)
    static let fontSubtext = Font.system(size: 11, weight: .medium)
    static let fontMonoHeader = Font.system(size: 12, weight: .semibold, design: .monospaced)
    static let fontMonoTerminalSlotTitle = Font.system(size: 12, weight: .regular, design: .monospaced)

    // Sidebar-specific fonts matching design spec
    static let fontWorkspaceName = Font.system(size: 12, weight: .semibold, design: .default)
    static let fontWorkspaceNameInactive = Font.system(size: 12, weight: .medium, design: .default)
    static let fontWorkspaceSubtitle = Font.system(size: 10, weight: .regular, design: .monospaced)
    static let fontShortcutBadge = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let fontTerminalProfileBadge = Font.system(size: 10, weight: .semibold, design: .monospaced)
    static let fontNewWorkspace = Font.system(size: 11, weight: .regular, design: .default)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
