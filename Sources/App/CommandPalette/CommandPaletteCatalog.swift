import CoreState
import Foundation

// Shared projection for the palette's command-mode slice. Keep this scoped to
// app-owned command surfaces rather than turning it into a general provider API.
@MainActor
enum CommandPaletteCatalog {
    static func commands(
        originWindowID: UUID,
        actions: CommandPaletteActionHandling,
        agentCatalog: AgentCatalog,
        terminalProfileCatalog: TerminalProfileCatalog,
        profileShortcutRegistry: ProfileShortcutRegistry
    ) -> [PaletteCommandDescriptor] {
        staticCommandDescriptors(originWindowID: originWindowID, actions: actions) +
            workspaceSwitchDescriptors(originWindowID: originWindowID, actions: actions) +
            terminalProfileDescriptors(
                originWindowID: originWindowID,
                actions: actions,
                catalog: terminalProfileCatalog,
                profileShortcutRegistry: profileShortcutRegistry
            ) +
            agentProfileDescriptors(
                originWindowID: originWindowID,
                actions: actions,
                catalog: agentCatalog,
                profileShortcutRegistry: profileShortcutRegistry
            )
    }

    private static func staticCommandDescriptors(
        originWindowID: UUID,
        actions: CommandPaletteActionHandling
    ) -> [PaletteCommandDescriptor] {
        let staticCommands: [(ToasttyBuiltInCommand, Bool)] = [
            (.splitRight, actions.canSplit(direction: .right, originWindowID: originWindowID)),
            (.splitLeft, actions.canSplit(direction: .left, originWindowID: originWindowID)),
            (.splitDown, actions.canSplit(direction: .down, originWindowID: originWindowID)),
            (.splitUp, actions.canSplit(direction: .up, originWindowID: originWindowID)),
            (.selectPreviousSplit, actions.canFocusSplit(originWindowID: originWindowID)),
            (.selectNextSplit, actions.canFocusSplit(originWindowID: originWindowID)),
            (.navigateSplitUp, actions.canFocusSplit(originWindowID: originWindowID)),
            (.navigateSplitDown, actions.canFocusSplit(originWindowID: originWindowID)),
            (.navigateSplitLeft, actions.canFocusSplit(originWindowID: originWindowID)),
            (.navigateSplitRight, actions.canFocusSplit(originWindowID: originWindowID)),
            (.equalizeSplits, actions.canEqualizeSplits(originWindowID: originWindowID)),
            (.resizeSplitLeft, actions.canResizeSplit(originWindowID: originWindowID)),
            (.resizeSplitRight, actions.canResizeSplit(originWindowID: originWindowID)),
            (.resizeSplitUp, actions.canResizeSplit(originWindowID: originWindowID)),
            (.resizeSplitDown, actions.canResizeSplit(originWindowID: originWindowID)),
            (.newWorkspace, actions.canCreateWorkspace(originWindowID: originWindowID)),
            (.newTab, actions.canCreateWorkspaceTab(originWindowID: originWindowID)),
            (.newWindow, actions.canCreateWindow(originWindowID: originWindowID)),
            (.newBrowser, actions.canCreateBrowser(originWindowID: originWindowID)),
            (.newBrowserTab, actions.canCreateBrowser(originWindowID: originWindowID)),
            (.newBrowserSplit, actions.canCreateBrowser(originWindowID: originWindowID)),
            (.openLocalFile, actions.canOpenLocalDocument(originWindowID: originWindowID)),
            (.openLocalFileInTab, actions.canOpenLocalDocument(originWindowID: originWindowID)),
            (.openLocalFileInSplit, actions.canOpenLocalDocument(originWindowID: originWindowID)),
            (.showScratchpadForCurrentSession, actions.canShowScratchpadForCurrentSession(originWindowID: originWindowID)),
            (.toggleSidebar, actions.canToggleSidebar(originWindowID: originWindowID)),
            (.toggleRightPanel, actions.canToggleRightPanel(originWindowID: originWindowID)),
            (.toggleFocusedPanelMode, actions.canToggleFocusedPanelMode(originWindowID: originWindowID)),
            (.watchRunningCommand, actions.canWatchRunningCommand(originWindowID: originWindowID)),
            (.closePanel, actions.canClosePanel(originWindowID: originWindowID)),
            (.renameWorkspace, actions.canRenameWorkspace(originWindowID: originWindowID)),
            (.closeWorkspace, actions.canCloseWorkspace(originWindowID: originWindowID)),
            (.renameTab, actions.canRenameTab(originWindowID: originWindowID)),
            (.selectPreviousTab, actions.canSelectAdjacentTab(direction: .previous, originWindowID: originWindowID)),
            (.selectNextTab, actions.canSelectAdjacentTab(direction: .next, originWindowID: originWindowID)),
            (
                .selectPreviousRightPanelTab,
                actions.canSelectAdjacentRightPanelTab(direction: .previous, originWindowID: originWindowID)
            ),
            (
                .selectNextRightPanelTab,
                actions.canSelectAdjacentRightPanelTab(direction: .next, originWindowID: originWindowID)
            ),
            (.jumpToNextActive, actions.canJumpToNextActive(originWindowID: originWindowID)),
            (.manageConfig, actions.canManageConfig(originWindowID: originWindowID)),
            (.manageTerminalProfiles, actions.canManageTerminalProfiles(originWindowID: originWindowID)),
            (.manageAgents, actions.canManageAgents(originWindowID: originWindowID)),
            (.reloadConfiguration, actions.canReloadConfiguration()),
        ]

        return staticCommands.compactMap { command, isAvailable in
            guard isAvailable else { return nil }
            return descriptor(
                for: command,
                title: title(for: command, originWindowID: originWindowID, actions: actions)
            )
        }
    }

    private static func workspaceSwitchDescriptors(
        originWindowID: UUID,
        actions: CommandPaletteActionHandling
    ) -> [PaletteCommandDescriptor] {
        actions.workspaceSwitchOptions(originWindowID: originWindowID).map { option in
            PaletteCommandDescriptor(
                id: "workspace.switch.\(option.workspaceID.uuidString)",
                usageKey: nil,
                title: "Switch to Workspace: \(option.title)",
                keywords: [
                    "workspace",
                    "switch",
                    option.title,
                ],
                shortcut: option.shortcut,
                invocation: .workspaceSwitch(workspaceID: option.workspaceID)
            )
        }
    }

    private static func terminalProfileDescriptors(
        originWindowID: UUID,
        actions: CommandPaletteActionHandling,
        catalog: TerminalProfileCatalog,
        profileShortcutRegistry: ProfileShortcutRegistry
    ) -> [PaletteCommandDescriptor] {
        guard actions.canSplitWithTerminalProfile(originWindowID: originWindowID) else {
            return []
        }

        return catalog.profiles.flatMap { profile in
            [
                dynamicDescriptor(
                    id: "terminal-profile.\(profile.id).split-right",
                    title: "Split Right With \(profile.displayName)",
                    keywords: ["split", "right", "terminal", "profile", profile.id, profile.displayName],
                    shortcut: profileShortcutRegistry.chord(
                        for: .terminalProfileSplit(profileID: profile.id, direction: .right)
                    ).map(PaletteShortcut.init),
                    invocation: .terminalProfileSplit(profileID: profile.id, direction: .right)
                ),
                dynamicDescriptor(
                    id: "terminal-profile.\(profile.id).split-down",
                    title: "Split Down With \(profile.displayName)",
                    keywords: ["split", "down", "terminal", "profile", profile.id, profile.displayName],
                    shortcut: profileShortcutRegistry.chord(
                        for: .terminalProfileSplit(profileID: profile.id, direction: .down)
                    ).map(PaletteShortcut.init),
                    invocation: .terminalProfileSplit(profileID: profile.id, direction: .down)
                ),
            ]
        }
    }

    private static func agentProfileDescriptors(
        originWindowID: UUID,
        actions: CommandPaletteActionHandling,
        catalog: AgentCatalog,
        profileShortcutRegistry: ProfileShortcutRegistry
    ) -> [PaletteCommandDescriptor] {
        catalog.profiles.compactMap { profile in
            guard actions.canLaunchAgent(profileID: profile.id, originWindowID: originWindowID) else {
                return nil
            }

            return dynamicDescriptor(
                id: "agent.run.\(profile.id)",
                title: "Run Agent: \(profile.displayName)",
                keywords: ["agent", "run", profile.id, profile.displayName],
                shortcut: profileShortcutRegistry.chord(
                    for: .agentProfileLaunch(profileID: profile.id)
                ).map(PaletteShortcut.init),
                invocation: .agentProfileLaunch(profileID: profile.id)
            )
        }
    }

    private static func descriptor(
        for command: ToasttyBuiltInCommand,
        title: String? = nil
    ) -> PaletteCommandDescriptor {
        PaletteCommandDescriptor(
            id: command.id,
            usageKey: command.id,
            title: title ?? command.title,
            keywords: command.keywords,
            shortcut: command.shortcut.map(PaletteShortcut.init),
            invocation: .builtIn(command)
        )
    }

    private static func dynamicDescriptor(
        id: String,
        title: String,
        keywords: [String],
        shortcut: PaletteShortcut?,
        invocation: PaletteCommandInvocation
    ) -> PaletteCommandDescriptor {
        PaletteCommandDescriptor(
            id: id,
            usageKey: id,
            title: title,
            keywords: keywords,
            shortcut: shortcut,
            invocation: invocation
        )
    }

    private static func title(
        for command: ToasttyBuiltInCommand,
        originWindowID: UUID,
        actions: CommandPaletteActionHandling
    ) -> String {
        switch command {
        case .toggleSidebar:
            return actions.sidebarTitle(originWindowID: originWindowID)
        case .toggleRightPanel:
            return actions.rightPanelTitle(originWindowID: originWindowID)
        case .toggleFocusedPanelMode:
            return actions.toggleFocusedPanelModeTitle(originWindowID: originWindowID)
        default:
            return command.title
        }
    }
}
