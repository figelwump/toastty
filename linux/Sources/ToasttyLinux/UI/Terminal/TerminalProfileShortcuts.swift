import CoreState
import Foundation

/// Terminal profiles (`~/.toastty/terminal-profiles.toml`, docs/terminal-profiles.md)
/// as Linux commands: "Split Right/Down with <profile>" in the palette and
/// `Ctrl+Alt+<key>` / `Ctrl+Alt+Shift+<key>` shortcuts (macOS Cmd+Opt[+Shift]).
/// Agent profiles (`~/.toastty/agents.toml`, supplied by the app-logic
/// frontend through `setAgentCatalog`) become "Run Agent: <profile>" commands
/// with `Ctrl+Alt+<key>` launches and the header's agent buttons.
/// Parsing and conflict detection are the shared Core code
/// (`TerminalProfilesFile`, `ProfileShortcutRegistry`).
@MainActor
public final class TerminalProfileShortcuts {
    public static let shared = TerminalProfileShortcuts()

    public static let splitRightPrefix = "terminal-profile.split-right."
    public static let splitDownPrefix = "terminal-profile.split-down."
    /// Same ids as the macOS palette (`agent.run.<profile>`).
    public static let agentRunPrefix = "agent.run."

    public struct Command: Equatable, Sendable {
        public let id: String
        public let title: String
        public let profileID: String
        public let direction: SlotSplitDirection
        public let accelerator: String?
    }

    /// Launches agents for the frontend that owns the agent catalog.
    @MainActor public protocol AgentLaunching: AnyObject {
        func canLaunchAgent(profileID: String, windowID: UUID) -> Bool
        @discardableResult func launchAgent(profileID: String, windowID: UUID) -> Bool
    }

    public struct AgentCommand: Equatable, Sendable {
        public let id: String
        public let profileID: String
        public let displayName: String
        public let accelerator: String?
    }

    public private(set) var catalog: TerminalProfileCatalog = .empty
    public private(set) var commands: [Command] = []
    public private(set) var agentCatalog: AgentCatalog = .empty
    public private(set) var agentCommands: [AgentCommand] = []
    public weak var agentLauncher: (any AgentLaunching)?
    /// Runs after terminal or agent commands change (windows rebuild their
    /// shortcut matchers and header buttons).
    public var onCommandsChanged: [@MainActor () -> Void] = []
    private var terminalProfilesFilePath = ""
    private var agentProfilesFilePath = ""
    public private(set) var warnings: [String] = []
    public private(set) var loadError: String?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        reload(environment: environment)
    }

    public func reload(environment: [String: String] = ProcessInfo.processInfo.environment) {
        do {
            catalog = try TerminalProfilesFile.load(environment: environment)
            loadError = nil
        } catch {
            catalog = .empty
            loadError = error.localizedDescription
            FileHandle.standardError.write(Data("toastty-linux: terminal profiles not loaded: \(error.localizedDescription)\n".utf8))
        }
        apply(catalog: catalog, filePath: TerminalProfilesFile.fileURL(environment: environment).path)
    }

    /// Rebuilds commands for `catalog` (tests and reloads).
    public func apply(catalog: TerminalProfileCatalog, filePath: String) {
        self.catalog = catalog
        terminalProfilesFilePath = filePath
        rebuild()
    }

    /// Agent profiles from the app-logic frontend (and after each reload).
    public func setAgentCatalog(_ catalog: AgentCatalog, filePath: String) {
        guard catalog != agentCatalog || filePath != agentProfilesFilePath else { return }
        agentCatalog = catalog
        agentProfilesFilePath = filePath
        rebuild()
    }

    private func rebuild() {
        let catalog = self.catalog
        // Same chord model as macOS with Ctrl+Alt in place of Cmd+Opt; the
        // registry drops agent/terminal chords that collide.
        let registry = ProfileShortcutRegistry(
            terminalProfiles: catalog,
            terminalProfilesFilePath: terminalProfilesFilePath,
            agentProfiles: agentCatalog,
            agentProfilesFilePath: agentProfilesFilePath,
            terminalSplitBaseModifiers: [.control, .option],
            agentShortcutModifiers: [.control, .option]
        )
        warnings = registry.warningMessages
        var commands: [Command] = []
        for profile in catalog.profiles {
            for direction in [SlotSplitDirection.right, .down] {
                var accelerator: String?
                if registry.chord(for: .terminalProfileSplit(profileID: profile.id, direction: direction)) != nil,
                   let key = profile.shortcutKey {
                    accelerator = LinuxCommandTable.profileAccelerator(shortcutKey: String(key), splitDown: direction == .down)
                    if accelerator == nil {
                        warnings.append("Terminal profile '\(profile.id)' shortcut key '\(key)' is reserved by Toastty on Linux (Ctrl+Alt+\(String(key).uppercased())).")
                    }
                }
                commands.append(Command(
                    id: (direction == .right ? Self.splitRightPrefix : Self.splitDownPrefix) + profile.id,
                    title: "Split \(direction == .right ? "Right" : "Down") with \(profile.displayName)",
                    profileID: profile.id,
                    direction: direction,
                    accelerator: accelerator
                ))
            }
        }
        self.commands = commands
        agentCommands = agentCatalog.profiles.map { profile in
            var accelerator: String?
            if registry.chord(for: .agentProfileLaunch(profileID: profile.id)) != nil, let key = profile.shortcutKey {
                accelerator = LinuxCommandTable.profileAccelerator(shortcutKey: String(key), splitDown: false)
                if accelerator == nil {
                    warnings.append("Agent profile '\(profile.id)' shortcut key '\(key)' is reserved by Toastty on Linux (Ctrl+Alt+\(String(key).uppercased())).")
                }
            }
            return AgentCommand(
                id: Self.agentRunPrefix + profile.id,
                profileID: profile.id,
                displayName: profile.displayName,
                accelerator: accelerator
            )
        }
        for warning in warnings {
            FileHandle.standardError.write(Data("toastty-linux: \(warning)\n".utf8))
        }
        for handler in onCommandsChanged { handler() }
    }

    public func agentCommand(id: String) -> AgentCommand? {
        agentCommands.first { $0.id == id }
    }

    public func command(id: String) -> Command? {
        commands.first { $0.id == id }
    }

    /// Reducer action for a profile split command in `windowID`.
    public static func action(for command: Command, windowID: UUID, state: AppState) -> AppAction? {
        guard let workspaceID = state.workspaceSelection(in: windowID)?.workspaceID else { return nil }
        return .splitFocusedSlotInDirectionWithTerminalProfile(
            workspaceID: workspaceID,
            direction: command.direction,
            profileBinding: TerminalProfileBinding(profileID: command.profileID)
        )
    }

    public var paletteItems: [PaletteItem] {
        commands.map {
            PaletteItem(
                id: $0.id,
                title: $0.title,
                subtitle: "Terminal profile",
                keywords: ["profile", "terminal", "split", $0.profileID],
                accelerator: $0.accelerator
            )
        }
    }

    /// "Run Agent: <profile>" items the window can launch now.
    public func agentPaletteItems(windowID: UUID) -> [PaletteItem] {
        guard let launcher = agentLauncher else { return [] }
        return agentCommands.compactMap { command in
            guard launcher.canLaunchAgent(profileID: command.profileID, windowID: windowID) else { return nil }
            return PaletteItem(
                id: command.id,
                title: "Run Agent: \(command.displayName)",
                subtitle: "Agent",
                keywords: ["agent", "run", command.profileID, command.displayName],
                accelerator: command.accelerator
            )
        }
    }
}
