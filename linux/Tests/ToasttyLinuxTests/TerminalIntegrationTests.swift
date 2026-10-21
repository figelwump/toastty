import CoreState
import Foundation
import Testing
@testable import ToasttyLinuxUI

/// Display-free tests for the Ghostty terminal integration's pure parts
/// (the closed-loop GUI test is `TerminalBroadwayTests`).
@MainActor
@Suite("Terminal integration")
struct TerminalIntegrationTests {
    @Test func searchMatchLabelMatchesMacOS() {
        var model = TerminalSearchModel(isPresented: true, needle: "x")
        #expect(model.matchLabel == nil)
        model.total = 0
        #expect(model.matchLabel == "0 results")
        model.total = 12
        #expect(model.matchLabel == "12 results")
        model.selected = 2
        #expect(model.matchLabel == "3 of 12")
    }

    @Test func profileCommandsUseCtrlAltAndSkipReservedKeys() {
        let shortcuts = TerminalProfileShortcuts(environment: ["TOASTTY_TERMINAL_PROFILES_PATH": "/nonexistent/profiles.toml"])
        shortcuts.apply(catalog: TerminalProfileCatalog(profiles: [
            TerminalProfile(id: "logs", displayName: "Logs", badgeLabel: "LOG", startupCommand: "tail -f x", shortcutKey: "l"),
            TerminalProfile(id: "news", displayName: "News", badgeLabel: "N", startupCommand: "true", shortcutKey: "n"),
            TerminalProfile(id: "plain", displayName: "Plain", badgeLabel: "P", startupCommand: "true"),
        ]), filePath: "/tmp/terminal-profiles.toml")

        #expect(shortcuts.commands.count == 6)
        let right = shortcuts.command(id: "terminal-profile.split-right.logs")
        #expect(right?.accelerator == "<Control><Alt>l")
        #expect(right?.title == "Split Right with Logs")
        #expect(shortcuts.command(id: "terminal-profile.split-down.logs")?.accelerator == "<Control><Alt><Shift>l")
        // Ctrl+Alt+N is New Workspace on Linux: no accelerator, a warning instead.
        #expect(shortcuts.command(id: "terminal-profile.split-right.news")?.accelerator == nil)
        #expect(shortcuts.warnings.contains { $0.contains("news") })
        #expect(shortcuts.command(id: "terminal-profile.split-right.plain")?.accelerator == nil)
        #expect(shortcuts.paletteItems.map(\.id).contains("terminal-profile.split-down.plain"))
    }

    @Test func agentProfilesBecomeRunCommandsAndYieldCollidingKeysToTheRegistry() {
        let shortcuts = TerminalProfileShortcuts(environment: ["TOASTTY_TERMINAL_PROFILES_PATH": "/nonexistent/profiles.toml"])
        shortcuts.apply(catalog: TerminalProfileCatalog(profiles: [
            TerminalProfile(id: "logs", displayName: "Logs", badgeLabel: "LOG", startupCommand: "tail -f x", shortcutKey: "l"),
        ]), filePath: "/tmp/terminal-profiles.toml")
        var notified = 0
        shortcuts.onCommandsChanged.append { notified += 1 }
        shortcuts.setAgentCatalog(AgentCatalog(profiles: [
            AgentProfile(id: "claude", displayName: "Claude Code", argv: ["claude"], shortcutKey: "c"),
            AgentProfile(id: "clash", displayName: "Clash", argv: ["clash"], shortcutKey: "l"),
            AgentProfile(id: "workspace", displayName: "Reserved", argv: ["x"], shortcutKey: "n"),
        ]), filePath: "/tmp/agents.toml")

        #expect(notified == 1)
        #expect(shortcuts.agentCommand(id: "agent.run.claude")?.accelerator == "<Control><Alt>c")
        // Ctrl+Alt+L is both an agent launch and a terminal split: the shared
        // registry binds neither, as on macOS.
        #expect(shortcuts.agentCommand(id: "agent.run.clash")?.accelerator == nil)
        #expect(shortcuts.command(id: "terminal-profile.split-right.logs")?.accelerator == nil)
        // Ctrl+Alt+N is New Workspace on Linux.
        #expect(shortcuts.agentCommand(id: "agent.run.workspace")?.accelerator == nil)
        #expect(shortcuts.warnings.contains { $0.contains("workspace") })
        // No launcher (frontend without app-logic): no palette entries.
        #expect(shortcuts.agentPaletteItems(windowID: UUID()).isEmpty)
        // An unchanged catalog does not rebuild.
        shortcuts.setAgentCatalog(shortcuts.agentCatalog, filePath: "/tmp/agents.toml")
        #expect(notified == 1)
    }

    @Test func profileCommandAcceleratorsDoNotCollideWithTheCommandTable() {
        let shortcuts = TerminalProfileShortcuts(environment: ["TOASTTY_TERMINAL_PROFILES_PATH": "/nonexistent/profiles.toml"])
        let keys = "abcdefghijklmnopqrstuvwxyz0123456789".map { String($0) }
        shortcuts.apply(catalog: TerminalProfileCatalog(profiles: keys.map {
            TerminalProfile(id: "p\($0)", displayName: $0, badgeLabel: $0, startupCommand: "true", shortcutKey: Character($0))
        }), filePath: "/tmp/terminal-profiles.toml")
        var matcher = ShortcutMatcher(bindings: LinuxCommandTable.globalBindings)
        for command in shortcuts.commands {
            if let accelerator = command.accelerator { matcher.add(accelerator: accelerator, commandID: command.id) }
        }
        #expect(matcher.duplicateAccelerators().isEmpty, "\(matcher.duplicateAccelerators())")
    }

    @Test func profileSplitActionTargetsSelectedWorkspace() throws {
        let state = AppState.bootstrap()
        let windowID = try #require(state.windows.first?.id)
        let command = TerminalProfileShortcuts.Command(
            id: "terminal-profile.split-down.demo", title: "", profileID: "demo", direction: .down, accelerator: nil
        )
        let action = TerminalProfileShortcuts.action(for: command, windowID: windowID, state: state)
        guard case .splitFocusedSlotInDirectionWithTerminalProfile(let workspaceID, let direction, let binding)? = action else {
            Issue.record("unexpected action \(String(describing: action))")
            return
        }
        #expect(workspaceID == state.workspaceSelection(in: windowID)?.workspaceID)
        #expect(direction == .down)
        #expect(binding.profileID == "demo")
    }

    @Test func standaloneLaunchSpecCarriesProfileEnvironmentAndStartupCommand() throws {
        let store = ReducerStoreBinding(state: .bootstrap())
        let catalog = TerminalProfileCatalog(profiles: [
            TerminalProfile(id: "demo", displayName: "Demo", badgeLabel: "D", startupCommand: "echo hi"),
        ])
        let bridge = StandaloneTerminalRuntimeBridge(store: store, profileCatalog: { catalog })
        let windowID = try #require(store.state.windows.first?.id)
        let panelID = UUID()
        var terminal = TerminalPanelState(title: "Terminal", shell: "", cwd: "/usr")
        terminal.profileBinding = TerminalProfileBinding(profileID: "demo")
        let spec = bridge.launchSpec(panelID: panelID, terminal: terminal, windowID: windowID)
        #expect(spec.environment["TOASTTY_PANEL_ID"] == panelID.uuidString)
        #expect(spec.environment["TOASTTY_TERMINAL_PROFILE_ID"] == "demo")
        #expect(spec.environment["TOASTTY_LAUNCH_REASON"] == "create")
        #expect(spec.initialInput == "echo hi\n")
        #expect(spec.workingDirectory == "/usr")
        #expect(spec.fontPoints == store.state.effectiveTerminalFontPoints(for: windowID))
    }

    @Test func standaloneMetadataUpdatesPanelState() throws {
        let store = ReducerStoreBinding(state: .bootstrap())
        let bridge = StandaloneTerminalRuntimeBridge(store: store, profileCatalog: { .empty })
        let panelID = try #require(store.state.workspacesByID.values.first?.focusedPanelID)
        bridge.handle(.title("vim notes.md"), panelID: panelID)
        bridge.handle(.workingDirectory("file://localhost/usr/share"), panelID: panelID)
        let terminal = try #require(bridge.terminalState(panelID: panelID))
        #expect(terminal.title == "vim notes.md")
        #expect(terminal.cwd == "/usr/share")
    }

    @Test func bellMarksOnlyBackgroundPanelsUnread() throws {
        let store = ReducerStoreBinding(state: .bootstrap())
        let bridge = StandaloneTerminalRuntimeBridge(store: store, profileCatalog: { .empty })
        let workspaceID = try #require(store.state.workspacesByID.keys.first)
        let first = try #require(store.state.workspacesByID[workspaceID]?.focusedPanelID)
        bridge.handle(.bell, panelID: first)
        #expect(store.state.workspacesByID[workspaceID]?.selectedTab?.unreadPanelIDs.isEmpty == true)

        store.send(.splitFocusedSlotInDirection(workspaceID: workspaceID, direction: .right))
        #expect(store.state.workspacesByID[workspaceID]?.focusedPanelID != first)
        bridge.handle(.bell, panelID: first)
        #expect(store.state.workspacesByID[workspaceID]?.selectedTab?.unreadPanelIDs == [first])
    }

    @Test func standaloneOpensWebLinksInTheRightPanel() throws {
        let store = ReducerStoreBinding(state: .bootstrap())
        let bridge = StandaloneTerminalRuntimeBridge(store: store, profileCatalog: { .empty })
        var external: [URL] = []
        bridge.openExternally = { external.append($0); return true }
        let workspaceID = try #require(store.state.workspacesByID.keys.first)
        let panelID = try #require(store.state.workspacesByID[workspaceID]?.focusedPanelID)

        #expect(bridge.openLink(URL(string: "https://example.com/a")!, panelID: panelID, alternate: false))
        #expect(store.state.workspacesByID[workspaceID]?.rightAuxPanel.isVisible == true)
        #expect(external.isEmpty)
        // Shift (alternate) and non-web links go to the desktop handler.
        #expect(bridge.openLink(URL(string: "https://example.com/b")!, panelID: panelID, alternate: true))
        #expect(bridge.openLink(URL(fileURLWithPath: "/etc/hosts"), panelID: panelID, alternate: false))
        #expect(external.map(\.absoluteString) == ["https://example.com/b", "file:///etc/hosts"])
    }

    @Test func linkURLsAndWorkingDirectories() {
        #expect(GhosttyTerminalHost.linkURL("https://x.dev/p?q=1")?.absoluteString == "https://x.dev/p?q=1")
        #expect(GhosttyTerminalHost.linkURL("/etc/hosts")?.isFileURL == true)
        #expect(GhosttyTerminalHost.linkURL("not a url") == nil)
        #expect(GhosttyTerminalHost.existingDirectory("/usr/share") == "/usr/share")
        #expect(GhosttyTerminalHost.existingDirectory("/usr/share/definitely-missing/deeper") == "/usr/share")
        #expect(StandaloneTerminalRuntimeBridge.normalizedCWD("file:///tmp") == "/tmp")
        #expect(StandaloneTerminalRuntimeBridge.normalizedCWD("  ") == nil)
    }

    @Test func automationUnescape() {
        #expect(TerminalAutomation.unescape(#"a\nb\tc\\d\e"#) == "a\nb\tc\\d\u{1B}")
    }
}
