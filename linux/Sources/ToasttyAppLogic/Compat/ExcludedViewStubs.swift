import Foundation
import CoreState
import RemoteProtocol
import ToasttyAppKitShim

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

/// `TerminalHostView.swift`'s record of one key press. The GTK terminal
/// does not report key presses to the registry yet, so nothing makes one.
struct TerminalKeyPress {
    let keyCode: UInt16
    let modifierFlags: NSEvent.ModifierFlags
    let isRepeat: Bool
    let localInputKind: TerminalLocalInputKind
    let hadComposedText: Bool
    var composing = false
    var ghosttyModifiers: UInt32?
    var sentText = false
    var ghosttyHandled: Bool?
}

/// `Coordinator/CoordinatorTerminalKeyLog.swift` logs the key presses
/// after Show Terminal from an AppKit event monitor. Linux has no such
/// monitor; the record stays empty.
@MainActor
final class CoordinatorTerminalKeyLog {
    var isCoordinatorTerminal: (NSResponder) -> Bool = { _ in false }
    var terminalWindow: () -> NSWindow? = { nil }
    var context: () -> [String: String] = { [:] }

    func start() {}
    func stop() {}
    func record(_ press: TerminalKeyPress) {}
    func keyboardOwner() -> String { "unknown" }
}
