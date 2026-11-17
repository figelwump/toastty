import Foundation

// Small pieces of excluded AppKit/SwiftUI view files that included logic
// references. Each mirrors the macOS definition's non-view part.

/// `BoundaryInteractionOverlay.swift`'s diagnostics switch (the hit-test
/// helpers are AppKit-only and unused on Linux).
enum CursorDiagnostics {
    static let environmentKey = "TOASTTY_BOUNDARY_CURSOR_DIAGNOSTICS"
    static let enabled: Bool = {
        switch ProcessInfo.processInfo.environment[environmentKey]?.lowercased() {
        case "1", "true", "yes", "on": true
        default: false
        }
    }()
}

/// `SessionActivityRail.swift` (a SwiftUI view file) defines this enum next
/// to its views; `PanelHeaderAppearance` needs only the enum.
enum SessionStatusIndicatorState: Equatable {
    case hidden
    case spinner
    case dot
}

/// The `Theme.swift` metrics that presentation logic reads (the rest of the
/// theme is SwiftUI colors; the GTK frontend has its own CSS).
enum ToastyTheme {
    static let titlebarHeight: CGFloat = 28
    static let sidebarTopPadding: CGFloat = titlebarHeight + 4
}

/// `DisplayShortcutConfig.swift` maps NSEvent key codes to shortcut numbers;
/// on Linux the GTK frontend owns key handling. App-control logic only reads
/// the shortcut counts.
enum DisplayShortcutConfig {
    static let maxWorkspaceShortcutCount = 9
    static let maxWorkspaceTabSelectionShortcutCount = 9
    static let maxPanelFocusShortcutCount = 10
}
