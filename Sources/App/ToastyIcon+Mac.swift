import ConversationUI
import SwiftUI

extension ToastyIcon.Palette {
    /// The Mac's colors for Toasty: the sidebar's path text for the
    /// outline, the accent for the steam, and a session row's rail dots
    /// (`SessionRailStatusIcon`) for its status.
    static let mac = ToastyIcon.Palette(
        outline: ToastyTheme.sidebarSessionPathText,
        steam: ToastyTheme.accent,
        unreadDot: ToastyTheme.sessionReadyText,
        needsApprovalDot: ToastyTheme.sessionNeedsApprovalText,
        needsApprovalHalo: ToastyTheme.sidebarSessionRailApprovalHalo,
        errorDot: ToastyTheme.sessionErrorText
    )
}

extension ToastyIcon {
    /// Toasty in the Mac's colors, on the chrome's background unless the
    /// caller names another.
    init(
        style: Style = .outline,
        size: CGFloat = 14,
        status: Status = .none,
        badgeRingColor: Color = ToastyTheme.chromeBackground
    ) {
        self.init(style: style, size: size, status: status, palette: .mac, badgeRingColor: badgeRingColor)
    }
}
