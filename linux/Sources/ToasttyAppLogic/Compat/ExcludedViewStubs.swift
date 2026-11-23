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

/// `Tasks/QuickEntry/QuickEntryController.swift` owns the macOS quick entry
/// panel (an AppKit window with SwiftUI content). Linux has no quick entry
/// panel yet, so nothing creates one; included logic only names the type
/// (`TaskBoardStore.showShortcut(of:)`, Remote Access task creation).
@MainActor
final class QuickEntryController: ObservableObject {
    @Published private(set) var shortcut: QuickEntryShortcut?
    @Published private(set) var isShortcutGlobal = false

    private init() {}

    func currentChoices(
        includeProfile: (AgentLaunchProfileSummary) -> Bool = { _ in true }
    ) -> QuickEntryChoices {
        QuickEntryChoices(workspaces: [], profiles: [], frequentPresets: [])
    }

    func recordCreatedTask(preset: QuickEntryPreset?, workspaceID: UUID?) {}

    /// The top-level workspaces a task can go to, in window order. As the
    /// macOS definition.
    static func taskWorkspaces(in state: AppState) -> [QuickEntryChoices.Workspace] {
        var seen: Set<UUID> = []
        var workspaces: [QuickEntryChoices.Workspace] = []
        for window in state.windows {
            for workspaceID in state.topLevelWorkspaceIDs(in: window.id) where seen.insert(workspaceID).inserted {
                guard let workspace = state.workspacesByID[workspaceID] else { continue }
                workspaces.append(QuickEntryChoices.Workspace(id: workspaceID, title: workspace.title))
            }
        }
        return workspaces
    }
}

/// `QuickEntryController.swift`'s choices, as the macOS definition.
struct QuickEntryChoices: Equatable {
    struct Workspace: Equatable {
        var id: UUID
        var title: String
    }

    var workspaces: [Workspace]
    var initialWorkspaceID: UUID?
    var profiles: [QuickEntryAgentProfile]
    var frequentPresets: [QuickEntryPreset]
    var initialPreset: QuickEntryPreset?
}

/// `Coordinator/CoordinatorChatModel.swift` drives the macOS coordinator
/// chat (the ConversationUI transcript and an AppKit composer). Linux has no
/// coordinator chat yet, so `CoordinatorController.chat` stays nil and the
/// coordinator works through its terminal.
@MainActor
final class CoordinatorChatModel {
    enum Host: Hashable {
        case panel
        case dock
    }

    private init() {}

    func composerHasKeyboard(host: Host) -> Bool { false }
    func requestComposerFocus() {}
    func requestComposerFocus(host: Host) {}
    func focusComposer() -> Bool { false }

    static func attachmentCount(of text: String) -> Int {
        CoordinatorMessageHeader.attachedFiles(in: text)?.paths.count ?? 0
    }
}

/// `Tasks/QuickEntry/QuickEntryModel.swift` is the quick entry panel's view
/// model (draft attachments, pasteboard drops). The included quick entry
/// logic (the picker, workspace folders) only needs its `Option`.
@MainActor
enum QuickEntryModel {
    struct Option: Identifiable, Equatable {
        let id: String
        let title: String
        var folder: String? = nil
        var isInGitRepository: Bool? = nil
    }
}
