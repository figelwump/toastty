import CoreState
import Foundation

/// How a terminal panel's shell is spawned.
public struct TerminalLaunchSpec: Equatable, Sendable {
    /// Extra environment for the shell (Toastty panel/socket/profile variables).
    public var environment: [String: String]
    /// Starting directory; `nil` lets Ghostty choose (home).
    public var workingDirectory: String?
    /// Typed into the shell once it starts (profile startup command or a
    /// restored agent resume command), newline-terminated.
    public var initialInput: String?
    /// Font size for the panel's window, in points.
    public var fontPoints: Double?

    public init(environment: [String: String] = [:], workingDirectory: String? = nil, initialInput: String? = nil, fontPoints: Double? = nil) {
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.initialInput = initialInput
        self.fontPoints = fontPoints
    }
}

/// Terminal facts reported by Ghostty, in the order the macOS
/// `GhosttyRuntimeAction` intents use.
public enum TerminalRuntimeEvent: Equatable, Sendable {
    case title(String)
    case workingDirectory(String)
    case bell
    case commandFinished(exitCode: Int?, durationNanoseconds: UInt64)
    case childExited(exitCode: Int, runtimeMilliseconds: UInt64)
    case programStatus(TerminalProgramStatusEvent)
    case desktopNotification(title: String, body: String)
}

/// Local keyboard input that reached a terminal (remote-send draft gate and
/// agent interrupt tracking on macOS: `TerminalLocalInputKind`).
public enum TerminalLocalInput: Equatable, Sendable {
    case key
    case paste
    case controlC
    case escape
}

/// What the Ghostty terminal host needs from the application layer.
///
/// `StandaloneTerminalRuntimeBridge` implements it over the GTK shell's
/// `LinuxStoreBinding` (reducer-only builds and tests). The app-logic build
/// implements it over `LinuxAppLogic` (`AppLogicTerminalRuntimeBridge`, compiled
/// with `TOASTTY_LINUX_APP_LOGIC`), which
/// owns launch environments, the automation socket, sessions and close rules.
@MainActor
public protocol TerminalRuntimeBridge: AnyObject {
    var state: AppState { get }

    @discardableResult
    func send(_ action: AppAction) -> Bool

    /// Environment, cwd, initial input and font for a new surface.
    func launchSpec(panelID: UUID, terminal: TerminalPanelState, windowID: UUID) -> TerminalLaunchSpec

    /// The panel's surface is live / gone.
    func surfaceDidAttach(_ surface: GhosttyTerminalSurface, panelID: UUID)
    func surfaceDidDetach(panelID: UUID)
    /// The shell process was spawned.
    func surfaceDidLaunch(panelID: UUID)

    func handle(_ event: TerminalRuntimeEvent, panelID: UUID)
    func noteLocalInput(_ input: TerminalLocalInput, panelID: UUID)

    /// Ghostty's configured `font-size` (Toastty's font steps start there).
    func setGhosttyConfiguredFontPoints(_ points: Double?)

    /// A link was opened in the terminal (Ghostty `open_url`, Ctrl+click).
    /// `alternate` is Shift held (macOS: alternate placement).
    func openLink(_ url: URL, panelID: UUID, alternate: Bool) -> Bool

    /// Closes a panel (after any confirmation the UI already asked for).
    func closePanel(panelID: UUID)
}

extension TerminalRuntimeBridge {
    func selection(containing panelID: UUID) -> (windowID: UUID, workspaceID: UUID)? {
        guard let selection = state.workspaceSelection(containingPanelID: panelID) else { return nil }
        return (selection.windowID, selection.workspaceID)
    }

    func terminalState(panelID: UUID) -> TerminalPanelState? {
        guard let selection = state.workspaceSelection(containingPanelID: panelID),
              let workspace = state.workspacesByID[selection.workspaceID],
              case .terminal(let terminal)? = workspace.panelState(for: panelID) else { return nil }
        return terminal
    }

    /// The panel is focused in the selected tab of its window's selected
    /// workspace.
    func isPanelFocused(_ panelID: UUID) -> Bool {
        guard let selection = state.workspaceSelection(containingPanelID: panelID),
              state.selectedWorkspaceID(in: selection.windowID) == selection.workspaceID,
              let tab = state.workspacesByID[selection.workspaceID]?.selectedTab else { return false }
        return tab.resolvedFocusedPanelID == panelID && tab.rightAuxPanel.focusedPanelID == nil
    }
}

// MARK: - Standalone (reducer-only) bridge

/// `TerminalRuntimeBridge` over `LinuxStoreBinding` alone: applies metadata
/// with reducer actions, builds the documented profile environment
/// (`TOASTTY_PANEL_ID`, `TOASTTY_TERMINAL_PROFILE_ID`, `TOASTTY_LAUNCH_REASON`)
/// and startup command, and marks bells / attention-worthy program status in
/// unfocused panels unread. No automation socket or managed agents.
@MainActor
public final class StandaloneTerminalRuntimeBridge: TerminalRuntimeBridge {
    public let store: any LinuxStoreBinding
    public var profileCatalog: () -> TerminalProfileCatalog
    /// Opens a URL outside Toastty (`gtk_show_uri`), injected by the host.
    public var openExternally: (URL) -> Bool = { _ in false }
    public private(set) var programStatusByPanelID: [UUID: TerminalProgramStatusRecords] = [:]
    public private(set) var lastCommandExitCodeByPanelID: [UUID: Int?] = [:]
    public private(set) var exitedPanelIDs: Set<UUID> = []
    private var launchedPanelIDs: Set<UUID> = []
    private let restoredPanelIDs: Set<UUID>

    public init(
        store: any LinuxStoreBinding,
        restoredPanelIDs: Set<UUID> = [],
        profileCatalog: @escaping () -> TerminalProfileCatalog = { TerminalProfileShortcuts.shared.catalog }
    ) {
        self.store = store
        self.restoredPanelIDs = restoredPanelIDs
        self.profileCatalog = profileCatalog
    }

    public var state: AppState { store.state }

    @discardableResult
    public func send(_ action: AppAction) -> Bool { store.send(action) }

    public func launchSpec(panelID: UUID, terminal: TerminalPanelState, windowID: UUID) -> TerminalLaunchSpec {
        var environment: [String: String] = [
            ToasttyLaunchContextEnvironment.panelIDKey: panelID.uuidString,
            ToasttyLaunchContextEnvironment.launchReasonKey: restoredPanelIDs.contains(panelID) && launchedPanelIDs.contains(panelID) == false
                ? "restore" : "create",
        ]
        var initialInput: String?
        if let binding = terminal.profileBinding {
            environment["TOASTTY_TERMINAL_PROFILE_ID"] = binding.profileID
            if let profile = profileCatalog().profile(id: binding.profileID) {
                let command = profile.startupCommand.trimmingCharacters(in: .newlines)
                if command.isEmpty == false { initialInput = command + "\n" }
            }
        }
        return TerminalLaunchSpec(
            environment: environment,
            workingDirectory: terminal.workingDirectorySeed,
            initialInput: initialInput,
            fontPoints: state.effectiveTerminalFontPoints(for: windowID)
        )
    }

    public func surfaceDidAttach(_ surface: GhosttyTerminalSurface, panelID: UUID) {}
    public func surfaceDidDetach(panelID: UUID) {
        programStatusByPanelID.removeValue(forKey: panelID)
        lastCommandExitCodeByPanelID.removeValue(forKey: panelID)
        exitedPanelIDs.remove(panelID)
    }
    public func surfaceDidLaunch(panelID: UUID) { launchedPanelIDs.insert(panelID) }

    public func handle(_ event: TerminalRuntimeEvent, panelID: UUID) {
        if GhosttyTerminalHost.debugActions {
            FileHandle.standardError.write(Data("toastty-linux: event \(event) panel=\(panelID) focused=\(isPanelFocused(panelID))\n".utf8))
        }
        switch event {
        case .title(let title):
            applyMetadata(panelID: panelID, title: title, cwd: nil)
        case .workingDirectory(let cwd):
            applyMetadata(panelID: panelID, title: nil, cwd: cwd)
        case .bell:
            markUnreadIfBackground(panelID)
        case .commandFinished(let exitCode, _):
            lastCommandExitCodeByPanelID[panelID] = exitCode
        case .childExited:
            exitedPanelIDs.insert(panelID)
        case .programStatus(let statusEvent):
            programStatusByPanelID[panelID, default: TerminalProgramStatusRecords()].apply(statusEvent)
            if case .report(let report) = statusEvent, [.done, .blocked, .error].contains(report.state) {
                markUnreadIfBackground(panelID)
            }
        case .desktopNotification:
            markUnreadIfBackground(panelID)
        }
    }

    public func noteLocalInput(_ input: TerminalLocalInput, panelID: UUID) {}

    public func setGhosttyConfiguredFontPoints(_ points: Double?) {
        store.send(.setConfiguredTerminalFont(points: points))
    }

    public func openLink(_ url: URL, panelID: UUID, alternate: Bool) -> Bool {
        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https", alternate == false,
           let workspaceID = selection(containing: panelID)?.workspaceID {
            let panel = WebPanelState(definition: .browser, initialURL: url.absoluteString)
            if store.send(.createWebPanel(workspaceID: workspaceID, panel: panel, placement: .rightPanel)) {
                store.send(.exitFocusedPanelMode(workspaceID: workspaceID))
                return true
            }
        }
        return openExternally(url)
    }

    public func closePanel(panelID: UUID) {
        store.send(.closePanel(panelID: panelID))
    }

    private func applyMetadata(panelID: UUID, title: String?, cwd: String?) {
        let title = title.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let cwd = cwd.flatMap(Self.normalizedCWD)
        guard title != nil || cwd != nil, let current = terminalState(panelID: panelID) else { return }
        guard (title != nil && title != current.title) || (cwd != nil && cwd != current.cwd) else { return }
        store.send(.updateTerminalPanelMetadata(panelID: panelID, title: title, cwd: cwd))
    }

    /// OSC 7 reports `file://host/path`; panel state keeps a plain path.
    static func normalizedCWD(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed), url.isFileURL {
            let path = url.path
            return path.isEmpty ? nil : path
        }
        return trimmed
    }

    private func markUnreadIfBackground(_ panelID: UUID) {
        guard isPanelFocused(panelID) == false, let workspaceID = selection(containing: panelID)?.workspaceID else { return }
        let changed = store.send(.recordDesktopNotification(workspaceID: workspaceID, panelID: panelID))
        if GhosttyTerminalHost.debugActions {
            FileHandle.standardError.write(Data("toastty-linux: unread \(panelID) changed=\(changed)\n".utf8))
        }
    }
}
