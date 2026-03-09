import CoreState
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
    static let sidebarSessionAgentText = Color(hex: 0x7A7A7A)
    static let sidebarSessionDetailText = Color(hex: 0x555555)
    static let sidebarSessionPathText = Color(hex: 0x4E4E4E)
    static let shortcutBadgeText = Color(hex: 0xB8B8B8)
    static let sidebarSessionHoverBackground = Color(hex: 0x161616)
    static let sidebarSessionHoverBorder = Color(hex: 0x2F2F2F)

    static let accent = Color(hex: 0xF5A623)
    static let accentDark = Color(hex: 0x0D0D0D)
    static let badgeBlue = Color(hex: 0x3B82F6)
    static let sessionWorkingText = Color(hex: 0x8B5E34)
    static let sessionWorkingBackground = Color(hex: 0x8B5E34, alpha: 0.12)
    static let sessionNeedsApprovalText = Color(hex: 0xE8A849)
    static let sessionNeedsApprovalBackground = Color(hex: 0xE8A849, alpha: 0.12)
    static let sessionReadyText = Color(hex: 0xFDF8EC)
    static let sessionReadyBackground = Color(hex: 0xFDF8EC, alpha: 0.1)
    static let sessionErrorText = Color(hex: 0xD4553A)
    static let sessionErrorBackground = Color(hex: 0xD4553A, alpha: 0.12)

    // Empty state
    static let emptyStateToastCrust = Color(hex: 0x4A3425)
    static let emptyStateToastBread = Color(hex: 0x6B4E38)
    static let emptyStateToastHighlight = Color(hex: 0x7D5C42)
    static let emptyStateToastFace = Color(hex: 0x2A1A10)
    static let emptyStateMutedText = Color(hex: 0x6B5D52)
    static let emptyStateShortcutBg = Color(hex: 0x2A2420)
    static let emptyStateShortcutBorder = Color(hex: 0x3A3028)
    static let emptyStateShortcutText = Color(hex: 0x8A7B6E)

    static let sidebarWidth: CGFloat = 280
    static let topBarHeight: CGFloat = 36

    static let fontTitle = Font.system(size: 13, weight: .semibold, design: .rounded)
    static let fontBody = Font.system(size: 12, weight: .medium, design: .rounded)
    static let fontSubtext = Font.system(size: 11, weight: .medium)
    static let fontMonoHeader = Font.system(size: 12, weight: .semibold, design: .monospaced)
    static let fontMonoTerminalSlotTitle = Font.system(size: 12, weight: .regular, design: .monospaced)

    // Sidebar-specific fonts matching design spec
    static let fontLogoTitle = Font.system(size: 13, weight: .bold, design: .default)
    static let fontWorkspaceName = Font.system(size: 12, weight: .semibold, design: .default)
    static let fontWorkspaceNameInactive = Font.system(size: 12, weight: .medium, design: .default)
    static let fontWorkspaceSubtitle = Font.system(size: 10, weight: .regular, design: .monospaced)
    static let fontWorkspaceSessionAgent = Font.system(size: 10, weight: .medium, design: .monospaced)
    static let fontWorkspaceSessionChip = Font.system(size: 9, weight: .medium, design: .default)
    static let fontWorkspaceSessionDetail = Font.system(size: 10, weight: .regular, design: .default)
    static let fontWorkspaceSessionPath = Font.system(size: 10, weight: .regular, design: .monospaced)
    static let fontShortcutBadge = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let fontNewWorkspace = Font.system(size: 11, weight: .regular, design: .default)

    static func sessionStatusTextColor(for kind: SessionStatusKind) -> Color {
        switch kind {
        case .working:
            return sessionWorkingText
        case .needsApproval:
            return sessionNeedsApprovalText
        case .ready:
            return sessionReadyText
        case .error:
            return sessionErrorText
        }
    }

    static func sessionStatusBackgroundColor(for kind: SessionStatusKind) -> Color {
        switch kind {
        case .working:
            return sessionWorkingBackground
        case .needsApproval:
            return sessionNeedsApprovalBackground
        case .ready:
            return sessionReadyBackground
        case .error:
            return sessionErrorBackground
        }
    }

    static func sessionStatusIndicatorColor(for kind: SessionStatusKind) -> Color {
        sessionStatusTextColor(for: kind)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
