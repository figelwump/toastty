import AppKit
import CoreState
import SwiftUI

@MainActor
final class TerminalProfilesMenuController {
    private let store: AppStore
    private let terminalRuntimeRegistry: TerminalRuntimeRegistry
    private let installShellIntegrationAction: @MainActor () -> Void
    private let openProfilesConfigurationAction: @MainActor () -> Void

    init(
        store: AppStore,
        terminalRuntimeRegistry: TerminalRuntimeRegistry,
        installShellIntegrationAction: @escaping @MainActor () -> Void,
        openProfilesConfigurationAction: @escaping @MainActor () -> Void
    ) {
        self.store = store
        self.terminalRuntimeRegistry = terminalRuntimeRegistry
        self.installShellIntegrationAction = installShellIntegrationAction
        self.openProfilesConfigurationAction = openProfilesConfigurationAction
    }

    func canSplitFocusedSlotWithTerminalProfile(preferredWindowID: UUID?) -> Bool {
        store.commandSelection(preferredWindowID: preferredWindowID) != nil
    }

    @discardableResult
    func splitFocusedSlot(
        profileID: String,
        direction: SlotSplitDirection,
        preferredWindowID: UUID?
    ) -> Bool {
        guard let workspaceID = store.commandSelection(preferredWindowID: preferredWindowID)?.workspace.id else {
            return false
        }

        return terminalRuntimeRegistry.splitFocusedSlotInDirectionWithTerminalProfile(
            workspaceID: workspaceID,
            direction: direction,
            profileBinding: TerminalProfileBinding(profileID: profileID)
        )
    }

    func installShellIntegration() {
        installShellIntegrationAction()
    }

    func openProfilesConfiguration() {
        openProfilesConfigurationAction()
    }
}

struct TerminalProfileMenuModel: Equatable {
    struct Section: Equatable, Identifiable {
        struct Action: Equatable, Identifiable {
            let title: String
            let direction: SlotSplitDirection
            let shortcut: ShortcutChord?

            var id: String { title }
        }

        let title: String
        let profileID: String
        let actions: [Action]

        var id: String { profileID }
    }

    let sections: [Section]

    init(catalog: TerminalProfileCatalog, registry: ProfileShortcutRegistry) {
        sections = catalog.profiles.map { profile in
            Section(
                title: profile.displayName,
                profileID: profile.id,
                actions: [
                    Section.Action(
                        title: "Split Right",
                        direction: .right,
                        shortcut: registry.chord(
                            for: .terminalProfileSplit(
                                profileID: profile.id,
                                direction: .right
                            )
                        )
                    ),
                    Section.Action(
                        title: "Split Down",
                        direction: .down,
                        shortcut: registry.chord(
                            for: .terminalProfileSplit(
                                profileID: profile.id,
                                direction: .down
                            )
                        )
                    ),
                ]
            )
        }
    }
}

@MainActor
struct ToasttyCommandMenus: Commands {
    @ObservedObject var store: AppStore
    @ObservedObject var agentCatalogStore: AgentCatalogStore
    @ObservedObject var terminalProfileStore: TerminalProfileStore
    @ObservedObject var terminalRuntimeRegistry: TerminalRuntimeRegistry
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore
    let profileShortcutRegistry: ProfileShortcutRegistry
    let focusedPanelCommandController: FocusedPanelCommandController
    let agentLaunchService: AgentLaunchService
    let terminalProfilesMenuController: TerminalProfilesMenuController
    let canCheckForUpdates: Bool
    let checkForUpdates: @MainActor () -> Void
    let supportsConfigurationReload: Bool
    let reloadConfiguration: () -> Void
    let openManageConfig: () -> Void
    let openConfigReference: () -> Void
    let openAgentProfilesConfiguration: () -> Void

    @FocusedValue(\.toasttyCommandWindowID) private var focusedWindowID

    private var preferredCommandWindowID: UUID? {
        // SwiftUI focused-scene propagation can lag briefly behind AppKit when a
        // new window becomes key, so prefer the live AppKit key window and only
        // fall back to the last focused-scene value when no Toastty key window
        // is currently available.
        Self.resolvedCommandWindowID(
            focusedWindowID: focusedWindowID,
            keyWindowID: currentToasttyKeyWindowID(in: store)
        )
    }

    private var agentGetStartedTargetWindowID: UUID? {
        Self.agentGetStartedTargetWindowID(
            store: store,
            preferredWindowID: preferredCommandWindowID
        )
    }

    private var commandSelection: WindowCommandSelection? {
        store.commandSelection(preferredWindowID: preferredCommandWindowID)
    }

    private var commandWindow: WindowState? {
        commandSelection?.window
    }

    private var commandWorkspace: WorkspaceState? {
        commandSelection?.workspace
    }

    private var canFocusNextUnreadOrActivePanel: Bool {
        Self.canFocusNextUnreadOrActivePanel(
            state: store.state,
            commandSelection: commandSelection,
            activePanelIDs: sessionRuntimeStore.activePanelIDs(
                matching: AppStore.nextUnreadOrActionRequiredFallbackStatusKinds
                    .union(AppStore.nextUnreadOrWorkingFallbackStatusKinds)
            )
        )
    }

    private var terminalProfileMenuModel: TerminalProfileMenuModel {
        TerminalProfileMenuModel(
            catalog: terminalProfileStore.catalog,
            registry: profileShortcutRegistry
        )
    }

    private var commandFocusedTerminalPanelID: UUID? {
        guard let workspace = commandWorkspace,
              let panelID = workspace.focusedPanelID,
              workspace.layoutTree.slotContaining(panelID: panelID) != nil,
              case .terminal = workspace.panels[panelID] else {
            return nil
        }
        return panelID
    }

    private var commandFocusedTerminalSearchState: TerminalSearchState? {
        guard let panelID = commandFocusedTerminalPanelID else {
            return nil
        }
        return terminalRuntimeRegistry.searchState(for: panelID)
    }

    private var commandFocusedTerminalSearchFieldFocused: Bool {
        guard let panelID = commandFocusedTerminalPanelID else {
            return false
        }
        return terminalRuntimeRegistry.isSearchFieldFocused(panelID: panelID)
    }

    private var textInputOwnsFindCommands: Bool {
        guard let keyWindow = NSApp.keyWindow else {
            return false
        }
        return Self.textInputOwnsFindCommands(
            modalWindowPresent: keyWindow.sheetParent != nil || NSApp.modalWindow != nil,
            firstResponderIsTextInput: toasttyResponderUsesReservedTextInput(keyWindow.firstResponder),
            terminalSearchFieldIsFocused: commandFocusedTerminalSearchFieldFocused
        )
    }

    private var canStartScrollbackSearch: Bool {
        guard commandFocusedTerminalPanelID != nil else {
            return false
        }
        return textInputOwnsFindCommands == false
    }

    private var canNavigateScrollbackSearch: Bool {
        commandFocusedTerminalPanelID != nil &&
        commandFocusedTerminalSearchState != nil &&
        textInputOwnsFindCommands == false
    }

    var body: some Commands {
        let preferredWindowID = preferredCommandWindowID
        let fontCommandWindowID = store.commandWindowID(preferredWindowID: preferredWindowID)

        CommandGroup(replacing: .newItem) {
            Button("New Tab") {
                store.createWorkspaceTabFromCommand(preferredWindowID: preferredWindowID)
            }
            .keyboardShortcut(
                ToasttyKeyboardShortcuts.newTab.key,
                modifiers: ToasttyKeyboardShortcuts.newTab.modifiers
            )
            .disabled(commandWorkspace == nil)

            Button("New Window") {
                store.createWindowFromCommand(preferredWindowID: preferredWindowID)
            }
            .keyboardShortcut(
                ToasttyKeyboardShortcuts.newWindow.key,
                modifiers: ToasttyKeyboardShortcuts.newWindow.modifiers
            )
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates...") {
                checkForUpdates()
            }
            .disabled(canCheckForUpdates == false)

            Divider()

            Button("Manage Config…", action: openManageConfig)

            Button("Open Config Reference…", action: openConfigReference)

            Divider()

            Button(action: reloadConfiguration) {
                Label("Reload Configuration", systemImage: "arrow.clockwise")
            }
            .disabled(!supportsConfigurationReload)

            Button("Install Shell Integration…") {
                terminalProfilesMenuController.installShellIntegration()
            }
            Divider()

            Button("Get Started with Agents…") {
                showAgentGetStartedFlow()
            }
            .disabled(agentGetStartedTargetWindowID == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Find…") {
                startScrollbackSearchFromCommandSelection()
            }
            .keyboardShortcut(
                ToasttyKeyboardShortcuts.find.key,
                modifiers: ToasttyKeyboardShortcuts.find.modifiers
            )
            .disabled(!canStartScrollbackSearch)

            Button("Find Next") {
                findNextFromCommandSelection()
            }
            .keyboardShortcut(
                ToasttyKeyboardShortcuts.findNext.key,
                modifiers: ToasttyKeyboardShortcuts.findNext.modifiers
            )
            .disabled(!canNavigateScrollbackSearch)

            Button("Find Previous") {
                findPreviousFromCommandSelection()
            }
            .keyboardShortcut(
                ToasttyKeyboardShortcuts.findPrevious.key,
                modifiers: ToasttyKeyboardShortcuts.findPrevious.modifiers
            )
            .disabled(!canNavigateScrollbackSearch)

            Button("Hide Find") {
                hideFindFromCommandSelection()
            }
            .disabled(!canNavigateScrollbackSearch)
        }

        CommandMenu("Terminal") {
            Button("Increase Terminal Font") {
                guard let fontCommandWindowID else { return }
                store.send(.increaseWindowTerminalFont(windowID: fontCommandWindowID))
            }
            .keyboardShortcut("+", modifiers: [.command])
            .disabled(fontCommandWindowID == nil)

            Button("Decrease Terminal Font") {
                guard let fontCommandWindowID else { return }
                store.send(.decreaseWindowTerminalFont(windowID: fontCommandWindowID))
            }
            .keyboardShortcut("-", modifiers: [.command])
            .disabled(fontCommandWindowID == nil)

            Button("Reset Terminal Font") {
                guard let fontCommandWindowID else { return }
                store.send(.resetWindowTerminalFont(windowID: fontCommandWindowID))
            }
            .keyboardShortcut("0", modifiers: [.command])
            .disabled(fontCommandWindowID == nil)

            Divider()

            terminalProfileMenuItems()

            Divider()

            Button("Manage Terminal Profiles…") {
                terminalProfilesMenuController.openProfilesConfiguration()
            }
        }

        CommandGroup(replacing: .sidebar) {
            Button(sidebarVisibleForCommand ? "Hide Sidebar" : "Show Sidebar") {
                toggleSidebarFromCommandSelection()
            }
            .keyboardShortcut(
                ToasttyKeyboardShortcuts.toggleSidebar.key,
                modifiers: ToasttyKeyboardShortcuts.toggleSidebar.modifiers
            )
            .disabled(commandSelection == nil)
        }

        CommandMenu("Workspace") {
            Button("New Workspace") {
                store.createWorkspaceFromCommand(preferredWindowID: preferredWindowID)
            }
            .keyboardShortcut(
                ToasttyKeyboardShortcuts.newWorkspace.key,
                modifiers: ToasttyKeyboardShortcuts.newWorkspace.modifiers
            )
            .disabled(store.canCreateWorkspaceFromCommand(preferredWindowID: preferredWindowID) == false)

            Button("Rename Workspace") {
                store.renameSelectedWorkspaceFromCommand(preferredWindowID: preferredWindowID)
            }
            .keyboardShortcut(
                ToasttyKeyboardShortcuts.renameWorkspace.key,
                modifiers: ToasttyKeyboardShortcuts.renameWorkspace.modifiers
            )
            .disabled(commandWorkspace == nil)

            Button("Close Workspace") {
                store.closeSelectedWorkspaceFromCommand(preferredWindowID: preferredWindowID)
            }
            .keyboardShortcut(
                ToasttyKeyboardShortcuts.closeWorkspace.key,
                modifiers: ToasttyKeyboardShortcuts.closeWorkspace.modifiers
            )
            .disabled(commandWorkspace == nil)

            Button("Close Panel") {
                closeFocusedPanelFromCommandSelection()
            }
            .disabled(commandWorkspace?.focusedPanelID == nil)

            Button(commandWorkspace?.focusedPanelModeActive == true ? "Restore Layout" : "Focus Panel") {
                toggleFocusedPanelFromCommandSelection()
            }
            .keyboardShortcut(
                ToasttyKeyboardShortcuts.toggleFocusedPanel.key,
                modifiers: ToasttyKeyboardShortcuts.toggleFocusedPanel.modifiers
            )
            .disabled(commandWorkspace == nil)

            if let window = commandWindow {
                ForEach(
                    Array(window.workspaceIDs.prefix(DisplayShortcutConfig.maxWorkspaceShortcutCount).enumerated()),
                    id: \.element
                ) { index, workspaceID in
                    let workspace = store.state.workspacesByID[workspaceID]
                    let title = workspace?.title ?? "Missing Workspace \(index + 1)"
                    workspaceSelectionMenuButton(
                        title: title,
                        workspaceID: workspaceID,
                        shortcutNumber: index + 1,
                        isDisabled: workspace == nil
                    )
                }
            }

            Divider()

            Button("New Tab") {
                store.createWorkspaceTabFromCommand(preferredWindowID: preferredWindowID)
            }
            .disabled(commandWorkspace == nil)

            Button("Rename Tab") {
                store.renameSelectedWorkspaceTabFromCommand(preferredWindowID: preferredWindowID)
            }
            .keyboardShortcut(
                ToasttyKeyboardShortcuts.renameTab.key,
                modifiers: ToasttyKeyboardShortcuts.renameTab.modifiers
            )
            .disabled(store.canRenameSelectedWorkspaceTabFromCommand(preferredWindowID: preferredWindowID) == false)

            Button("Select Previous Tab") {
                store.selectAdjacentWorkspaceTab(
                    preferredWindowID: preferredWindowID,
                    direction: .previous
                )
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(commandWorkspace.map { $0.orderedTabs.count > 1 } != true)

            Button("Select Next Tab") {
                store.selectAdjacentWorkspaceTab(
                    preferredWindowID: preferredWindowID,
                    direction: .next
                )
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(commandWorkspace.map { $0.orderedTabs.count > 1 } != true)

            Button("Jump to Next Active") {
                store.focusNextUnreadOrActivePanelFromCommand(
                    preferredWindowID: commandSelection?.windowID ?? preferredWindowID,
                    sessionRuntimeStore: sessionRuntimeStore
                )
            }
            .keyboardShortcut(
                ToasttyKeyboardShortcuts.focusNextUnreadOrActivePanel.key,
                modifiers: ToasttyKeyboardShortcuts.focusNextUnreadOrActivePanel.modifiers
            )
            .disabled(canFocusNextUnreadOrActivePanel == false)
        }
        CommandMenu("Agent") {
            if agentCatalogStore.catalog.profiles.isEmpty {
                Button("No Agents Configured") {}
                    .disabled(true)
            } else {
                ForEach(agentCatalogStore.catalog.profiles) { profile in
                    agentProfileMenuButton(profile)
                }
            }

            Divider()

            Button("Manage Agents…", action: openAgentProfilesConfiguration)
        }
    }

    private func selectWorkspaceFromCommandSelection(workspaceID: UUID) {
        guard let commandSelection else { return }
        guard commandSelection.window.workspaceIDs.contains(workspaceID) else { return }
        guard store.state.workspacesByID[workspaceID] != nil else { return }
        store.selectWorkspace(
            windowID: commandSelection.windowID,
            workspaceID: workspaceID,
            preferringUnreadSessionPanelIn: sessionRuntimeStore
        )
    }

    private func toggleFocusedPanelFromCommandSelection() {
        guard let workspaceID = commandWorkspace?.id else { return }
        store.send(.toggleFocusedPanelMode(workspaceID: workspaceID))
    }

    private func closeFocusedPanelFromCommandSelection() {
        _ = focusedPanelCommandController.closeFocusedPanel(in: commandWorkspace?.id)
    }

    private func startScrollbackSearchFromCommandSelection() {
        guard let panelID = commandFocusedTerminalPanelID else { return }
        _ = terminalRuntimeRegistry.startSearch(panelID: panelID)
    }

    private func findNextFromCommandSelection() {
        guard let panelID = commandFocusedTerminalPanelID else { return }
        _ = terminalRuntimeRegistry.findNext(panelID: panelID)
    }

    private func findPreviousFromCommandSelection() {
        guard let panelID = commandFocusedTerminalPanelID else { return }
        _ = terminalRuntimeRegistry.findPrevious(panelID: panelID)
    }

    private func hideFindFromCommandSelection() {
        guard let panelID = commandFocusedTerminalPanelID else { return }
        _ = terminalRuntimeRegistry.endSearch(panelID: panelID)
        terminalRuntimeRegistry.restoreTerminalFocusAfterSearch(panelID: panelID)
    }

    private func canLaunchAgent(profileID: String) -> Bool {
        agentLaunchService.canLaunchAgent(
            profileID: profileID,
            workspaceID: commandWorkspace?.id
        )
    }

    private func launchAgentFromCommandSelection(_ profileID: String) {
        AgentLaunchUI.launch(
            profileID: profileID,
            workspaceID: commandWorkspace?.id,
            agentLaunchService: agentLaunchService
        )
    }

    private func showAgentGetStartedFlow() {
        guard let windowID = agentGetStartedTargetWindowID else { return }
        NotificationCenter.default.post(name: .toasttyShowAgentGetStartedFlow, object: windowID)
    }

    @ViewBuilder
    private func workspaceSelectionMenuButton(
        title: String,
        workspaceID: UUID,
        shortcutNumber: Int,
        isDisabled: Bool
    ) -> some View {
        if let shortcutKey = workspaceShortcutKeyEquivalent(for: shortcutNumber) {
            Button(title) {
                selectWorkspaceFromCommandSelection(workspaceID: workspaceID)
            }
            .disabled(isDisabled)
            .keyboardShortcut(shortcutKey, modifiers: [.option])
        } else {
            Button(title) {
                selectWorkspaceFromCommandSelection(workspaceID: workspaceID)
            }
            .disabled(isDisabled)
        }
    }

    @ViewBuilder
    private func terminalProfileMenuItems() -> some View {
        if terminalProfileMenuModel.sections.isEmpty {
            Button("No Terminal Profiles Configured") {}
                .disabled(true)
        } else {
            ForEach(terminalProfileMenuModel.sections) { section in
                Menu(section.title) {
                    ForEach(section.actions) { action in
                        terminalProfileActionButton(section: section, action: action)
                    }
                }
            }
        }
    }


    @ViewBuilder
    private func terminalProfileActionButton(
        section: TerminalProfileMenuModel.Section,
        action: TerminalProfileMenuModel.Section.Action
    ) -> some View {
        let preferredWindowID = preferredCommandWindowID
        let button = Button(action.title) {
            _ = terminalProfilesMenuController.splitFocusedSlot(
                profileID: section.profileID,
                direction: action.direction,
                preferredWindowID: preferredWindowID
            )
        }
        .disabled(
            terminalProfilesMenuController.canSplitFocusedSlotWithTerminalProfile(
                preferredWindowID: preferredWindowID
            ) == false
        )

        if let shortcut = action.shortcut {
            button.keyboardShortcut(
                shortcut.keyEquivalent,
                modifiers: shortcut.eventModifiers
            )
        } else {
            button
        }
    }

    @ViewBuilder
    private func agentProfileMenuButton(_ profile: AgentProfile) -> some View {
        let button = Button(profile.displayName) {
            launchAgentFromCommandSelection(profile.id)
        }
        .disabled(canLaunchAgent(profileID: profile.id) == false)

        if let shortcut = profileShortcutRegistry.chord(
            for: .agentProfileLaunch(profileID: profile.id)
        ) {
            button.keyboardShortcut(
                shortcut.keyEquivalent,
                modifiers: shortcut.eventModifiers
            )
        } else {
            button
        }
    }

    private var sidebarVisibleForCommand: Bool {
        commandSelection?.window.sidebarVisible ?? true
    }

    private func toggleSidebarFromCommandSelection() {
        guard let windowID = commandSelection?.windowID else { return }
        store.send(.toggleSidebar(windowID: windowID))
    }

    private func workspaceShortcutKeyEquivalent(for number: Int) -> KeyEquivalent? {
        guard (1 ... DisplayShortcutConfig.maxWorkspaceShortcutCount).contains(number),
              let digit = Character(String(number)).unicodeScalars.first.map({ Character($0) }) else {
            return nil
        }
        return KeyEquivalent(digit)
    }

    static func canFocusNextUnreadOrActivePanel(
        state: AppState,
        commandSelection: WindowCommandSelection?,
        activePanelIDs: Set<UUID>
    ) -> Bool {
        guard let selection = commandSelection,
              let selectedTabID = selection.workspace.resolvedSelectedTabID else {
            return false
        }

        if state.nextUnreadPanel(
            fromWindowID: selection.windowID,
            workspaceID: selection.workspace.id,
            tabID: selectedTabID,
            focusedPanelID: selection.workspace.focusedPanelID
        ) != nil {
            return true
        }

        guard activePanelIDs.isEmpty == false else {
            return false
        }

        return state.nextMatchingPanel(
            fromWindowID: selection.windowID,
            workspaceID: selection.workspace.id,
            tabID: selectedTabID,
            focusedPanelID: selection.workspace.focusedPanelID
        ) { _, panelID in
            activePanelIDs.contains(panelID)
        } != nil
    }

    nonisolated static func textInputOwnsFindCommands(
        modalWindowPresent: Bool,
        firstResponderIsTextInput: Bool,
        terminalSearchFieldIsFocused: Bool
    ) -> Bool {
        if modalWindowPresent {
            return true
        }
        return firstResponderIsTextInput && terminalSearchFieldIsFocused == false
    }

    nonisolated static func resolvedCommandWindowID(focusedWindowID: UUID?, keyWindowID: UUID?) -> UUID? {
        keyWindowID ?? focusedWindowID
    }

    static func agentGetStartedTargetWindowID(store: AppStore, preferredWindowID: UUID?) -> UUID? {
        // Follow the same command-window resolution contract as other
        // window-targeted actions so stale focused-scene state disables the
        // command instead of rerouting it to another window.
        store.commandWindowID(preferredWindowID: preferredWindowID)
    }
}

private extension ShortcutChord {
    var keyEquivalent: KeyEquivalent {
        KeyEquivalent(key)
    }

    var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if self.modifiers.contains(.command) {
            modifiers.insert(.command)
        }
        if self.modifiers.contains(.control) {
            modifiers.insert(.control)
        }
        if self.modifiers.contains(.option) {
            modifiers.insert(.option)
        }
        if self.modifiers.contains(.shift) {
            modifiers.insert(.shift)
        }
        return modifiers
    }
}
