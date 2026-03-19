import CoreState
import Testing

struct ProfileShortcutRegistryTests {
    @Test
    func emptyRegistryHasNoBindingsOrConflicts() {
        let registry = ProfileShortcutRegistry(
            terminalProfiles: .empty,
            terminalProfilesFilePath: "/tmp/terminal-profiles.toml",
            agentProfiles: .empty,
            agentProfilesFilePath: "/tmp/agents.toml"
        )

        #expect(registry.chordByActionID.isEmpty)
        #expect(registry.conflicts.isEmpty)
    }

    @Test
    func terminalProfilesKeepBothSplitDirectionBindings() {
        let registry = ProfileShortcutRegistry(
            terminalProfiles: TerminalProfileCatalog(
                profiles: [
                    TerminalProfile(
                        id: "zmx",
                        displayName: "ZMX",
                        badgeLabel: "ZMX",
                        startupCommand: "zmx attach",
                        shortcutKey: "z"
                    ),
                ]
            ),
            terminalProfilesFilePath: "/tmp/terminal-profiles.toml",
            agentProfiles: .empty,
            agentProfilesFilePath: "/tmp/agents.toml"
        )

        #expect(
            registry.chord(
                for: .terminalProfileSplit(
                    profileID: "zmx",
                    direction: .right
                )
            ) == ShortcutChord(key: "z", modifiers: [.command, .control])
        )
        #expect(
            registry.chord(
                for: .terminalProfileSplit(
                    profileID: "zmx",
                    direction: .down
                )
            ) == ShortcutChord(key: "z", modifiers: [.command, .control, .shift])
        )
        #expect(registry.conflicts.isEmpty)
    }

    @Test
    func agentProfilesUseCommandControlShortcuts() {
        let registry = ProfileShortcutRegistry(
            terminalProfiles: .empty,
            terminalProfilesFilePath: "/tmp/terminal-profiles.toml",
            agentProfiles: AgentCatalog(
                profiles: [
                    AgentProfile(
                        id: "codex",
                        displayName: "Codex",
                        argv: ["codex"],
                        shortcutKey: "c"
                    ),
                ]
            ),
            agentProfilesFilePath: "/tmp/agents.toml"
        )

        #expect(
            registry.chord(for: .agentProfileLaunch(profileID: "codex")) ==
                ShortcutChord(key: "c", modifiers: [.command, .control])
        )
        #expect(registry.conflicts.isEmpty)
    }

    @Test
    func conflictingTerminalAndAgentShortcutDisablesConflictingChordOnly() {
        let registry = ProfileShortcutRegistry(
            terminalProfiles: TerminalProfileCatalog(
                profiles: [
                    TerminalProfile(
                        id: "zmx",
                        displayName: "ZMX",
                        badgeLabel: "ZMX",
                        startupCommand: "zmx attach",
                        shortcutKey: "z"
                    ),
                ]
            ),
            terminalProfilesFilePath: "/tmp/terminal-profiles.toml",
            agentProfiles: AgentCatalog(
                profiles: [
                    AgentProfile(
                        id: "codex",
                        displayName: "Codex",
                        argv: ["codex"],
                        shortcutKey: "z"
                    ),
                ]
            ),
            agentProfilesFilePath: "/tmp/agents.toml"
        )

        #expect(
            registry.chord(
                for: .terminalProfileSplit(
                    profileID: "zmx",
                    direction: .right
                )
            ) == nil
        )
        #expect(registry.chord(for: .agentProfileLaunch(profileID: "codex")) == nil)
        #expect(
            registry.chord(
                for: .terminalProfileSplit(
                    profileID: "zmx",
                    direction: .down
                )
            ) == ShortcutChord(key: "z", modifiers: [.command, .control, .shift])
        )
        #expect(registry.warningMessages.count == 1)
        #expect(registry.warningMessages[0].contains("agent profile [codex]"))
        #expect(registry.warningMessages[0].contains("terminal profile [zmx]"))
        #expect(registry.warningMessages[0].contains("⌃⌘Z"))
    }
}
