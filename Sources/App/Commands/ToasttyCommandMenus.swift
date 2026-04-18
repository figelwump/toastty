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
                        title: ToasttyBuiltInCommand.splitRight.title,
                        direction: .right,
                        shortcut: registry.chord(
                            for: .terminalProfileSplit(
                                profileID: profile.id,
                                direction: .right
                            )
                        )
                    ),
                    Section.Action(
                        title: ToasttyBuiltInCommand.splitDown.title,
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
    @ObservedObject var webPanelRuntimeRegistry: WebPanelRuntimeRegistry
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
    let openMarkdownFile: @MainActor (UUID?) -> Void
    let openMarkdownFileInTab: @MainActor (UUID?) -> Void
    let openMarkdownFileInSplit: @MainActor (UUID?) -> Void

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

    private var focusedMarkdownPanelSelection: FocusedMarkdownPanelCommandSelection? {
        store.focusedMarkdownPanelSelection(preferredWindowID: preferredCommandWindowID)
    }

    private var canSaveFocusedMarkdownPanel: Bool {
        guard let focusedMarkdownPanelSelection else {
            return false
        }
        return webPanelRuntimeRegistry.canSaveMarkdownPanel(panelID: focusedMarkdownPanelSelection.panelID)
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
            Button(ToasttyBuiltInCommand.newTab.title) {
                store.createWorkspaceTabFromCommand(preferredWindowID: preferredWindowID)
            }
            .keyboardShortcut(
                ToasttyBuiltInCommand.newTab.requiredShortcut.key,
                modifiers: ToasttyBuiltInCommand.newTab.requiredShortcut.modifiers
            )
            .disabled(commandWorkspace == nil)

            Button(ToasttyBuiltInCommand.newWindow.title) {
                store.createWindowFromCommand(preferredWindowID: preferredWindowID)
            }
            .keyboardShortcut(
                ToasttyBuiltInCommand.newWindow.requiredShortcut.key,
                modifiers: ToasttyBuiltInCommand.newWindow.requiredShortcut.modifiers
            )
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                guard let focusedMarkdownPanelSelection else { return }
                _ = webPanelRuntimeRegistry.saveMarkdownPanel(panelID: focusedMarkdownPanelSelection.panelID)
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(!canSaveFocusedMarkdownPanel)
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
                Label(ToasttyBuiltInCommand.reloadConfiguration.title, systemImage: "arrow.clockwise")
            }
            .disabled(!supportsConfigurationReload)

            Button("Install Shell Integration…") {
                terminalProfilesMenuController.installShellIntegration()
            }
            Divider()

            Button("Get Started with Toastty…") {
                showAgentGetStartedFlow()
            }
            .disabled(agentGetStartedTargetWindowID == nil)
        }

        CommandGroup(before: .appTermination) {
            Divider()

            Toggle(
                "Ask Before Quitting",
                isOn: Binding(
                    get: { store.askBeforeQuitting },
                    set: { store.setAskBeforeQuitting($0) }
                )
            )
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
            Button(ToasttyBuiltInCommand.toggleSidebarTitle(sidebarVisible: sidebarVisibleForCommand)) {
                toggleSidebarFromCommandSelection()
            }
            .keyboardShortcut(
                ToasttyBuiltInCommand.toggleSidebar.requiredShortcut.key,
                modifiers: ToasttyBuiltInCommand.toggleSidebar.requiredShortcut.modifiers
            )
            .disabled(commandSelection == nil)
        }

        CommandMenu("Workspace") {
            Button(ToasttyBuiltInCommand.newWorkspace.title) {
                store.createWorkspaceFromCommand(preferredWindowID: preferredWindowID)
            }
            .keyboardShortcut(
                ToasttyBuiltInCommand.newWorkspace.requiredShortcut.key,
                modifiers: ToasttyBuiltInCommand.newWorkspace.requiredShortcut.modifiers
            )
            .disabled(store.canCreateWorkspaceFromCommand(preferredWindowID: preferredWindowID) == false)

            Button(ToasttyBuiltInCommand.renameWorkspace.title) {
                store.renameSelectedWorkspaceFromCommand(preferredWindowID: preferredWindowID)
            }
            .keyboardShortcut(
                ToasttyBuiltInCommand.renameWorkspace.requiredShortcut.key,
                modifiers: ToasttyBuiltInCommand.renameWorkspace.requiredShortcut.modifiers
            )
            .disabled(commandWorkspace == nil)

            Button(ToasttyBuiltInCommand.closeWorkspace.title) {
                store.closeSelectedWorkspaceFromCommand(preferredWindowID: preferredWindowID)
            }
            .keyboardShortcut(
                ToasttyBuiltInCommand.closeWorkspace.requiredShortcut.key,
                modifiers: ToasttyBuiltInCommand.closeWorkspace.requiredShortcut.modifiers
            )
            .disabled(commandWorkspace == nil)

            Divider()

            Button("New Browser") {
                store.createBrowserPanelFromCommand(
                    preferredWindowID: preferredWindowID,
                    request: BrowserPanelCreateRequest(
                        placementOverride: .rootRight
                    )
                )
            }
            .keyboardShortcut(
                ToasttyKeyboardShortcuts.newBrowser.key,
                modifiers: ToasttyKeyboardShortcuts.newBrowser.modifiers
            )
            .disabled(commandWorkspace == nil)

            Button("New Browser Tab") {
                store.createBrowserPanelFromCommand(
                    preferredWindowID: preferredWindowID,
                    request: BrowserPanelCreateRequest(
                        placementOverride: .newTab
                    )
                )
            }
            .keyboardShortcut(
                ToasttyKeyboardShortcuts.newBrowserTab.key,
                modifiers: ToasttyKeyboardShortcuts.newBrowserTab.modifiers
            )
            .disabled(commandWorkspace == nil)

            Button("New Browser Split") {
                store.createBrowserPanelFromCommand(
                    preferredWindowID: preferredWindowID,
                    request: BrowserPanelCreateRequest(
                        placementOverride: .splitRight
                    )
                )
            }
            .disabled(commandWorkspace == nil)

            Divider()

            Button("Open Markdown File…") {
                openMarkdownFile(preferredWindowID)
            }
            .disabled(commandWorkspace == nil)

            Button("Open Markdown File in Tab…") {
                openMarkdownFileInTab(preferredWindowID)
            }
            .disabled(commandWorkspace == nil)

            Button("Open Markdown File in Split…") {
                openMarkdownFileInSplit(preferredWindowID)
            }
            .disabled(commandWorkspace == nil)

            Divider()

            Button(ToasttyBuiltInCommand.closePanel.title) {
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

            Button(ToasttyBuiltInCommand.newTab.title) {
                store.createWorkspaceTabFromCommand(preferredWindowID: preferredWindowID)
            }
            .disabled(commandWorkspace == nil)

            Button(ToasttyBuiltInCommand.renameTab.title) {
                store.renameSelectedWorkspaceTabFromCommand(preferredWindowID: preferredWindowID)
            }
            .keyboardShortcut(
                ToasttyBuiltInCommand.renameTab.requiredShortcut.key,
                modifiers: ToasttyBuiltInCommand.renameTab.requiredShortcut.modifiers
            )
            .disabled(store.canRenameSelectedWorkspaceTabFromCommand(preferredWindowID: preferredWindowID) == false)

            Button(ToasttyBuiltInCommand.selectPreviousTab.title) {
                store.selectAdjacentWorkspaceTab(
                    preferredWindowID: preferredWindowID,
                    direction: .previous
                )
            }
            .keyboardShortcut(
                ToasttyBuiltInCommand.selectPreviousTab.requiredShortcut.key,
                modifiers: ToasttyBuiltInCommand.selectPreviousTab.requiredShortcut.modifiers
            )
            .disabled(commandWorkspace.map { $0.orderedTabs.count > 1 } != true)

            Button(ToasttyBuiltInCommand.selectNextTab.title) {
                store.selectAdjacentWorkspaceTab(
                    preferredWindowID: preferredWindowID,
                    direction: .next
                )
            }
            .keyboardShortcut(
                ToasttyBuiltInCommand.selectNextTab.requiredShortcut.key,
                modifiers: ToasttyBuiltInCommand.selectNextTab.requiredShortcut.modifiers
            )
            .disabled(commandWorkspace.map { $0.orderedTabs.count > 1 } != true)

            Button(ToasttyBuiltInCommand.jumpToNextActive.title) {
                store.focusNextUnreadOrActivePanelFromCommand(
                    preferredWindowID: commandSelection?.windowID ?? preferredWindowID,
                    sessionRuntimeStore: sessionRuntimeStore
                )
            }
            .keyboardShortcut(
                ToasttyBuiltInCommand.jumpToNextActive.requiredShortcut.key,
                modifiers: ToasttyBuiltInCommand.jumpToNextActive.requiredShortcut.modifiers
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
        _ = terminalRuntimeRegistry.toggleFocusedPanelMode(workspaceID: workspaceID)
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
