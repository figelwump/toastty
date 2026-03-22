import CoreState
import SwiftUI

@MainActor
final class TerminalProfilesMenuController {
    private let store: AppStore
    private let terminalRuntimeRegistry: TerminalRuntimeRegistry
    private let installShellIntegrationAction: @MainActor () -> Void

    init(
        store: AppStore,
        terminalRuntimeRegistry: TerminalRuntimeRegistry,
        installShellIntegrationAction: @escaping @MainActor () -> Void
    ) {
        self.store = store
        self.terminalRuntimeRegistry = terminalRuntimeRegistry
        self.installShellIntegrationAction = installShellIntegrationAction
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
}

struct TerminalProfileMenuModel: Equatable {
    struct Section: Equatable, Identifiable {
        struct Action: Equatable, Identifiable {
            let title: String
            let direction: SlotSplitDirection
            let shortcutKey: Character?

            var id: String { title }

            var shortcutModifiers: EventModifiers? {
                guard shortcutKey != nil else { return nil }
                return direction == .down
                    ? [.command, .control, .shift]
                    : [.command, .control]
            }
        }

        let title: String
        let profileID: String
        let actions: [Action]

        var id: String { profileID }
    }

    let sections: [Section]

    init(catalog: TerminalProfileCatalog) {
        sections = catalog.profiles.map { profile in
            Section(
                title: profile.displayName,
                profileID: profile.id,
                actions: [
                    Section.Action(
                        title: "Split Right",
                        direction: .right,
                        shortcutKey: profile.shortcutKey
                    ),
                    Section.Action(
                        title: "Split Down",
                        direction: .down,
                        shortcutKey: profile.shortcutKey
                    ),
                ]
            )
        }
    }
}

@MainActor
struct ToasttyCommandMenus: Commands {
    @ObservedObject var store: AppStore
    @ObservedObject var terminalProfileStore: TerminalProfileStore
    let focusedPanelCommandController: FocusedPanelCommandController
    let terminalProfilesMenuController: TerminalProfilesMenuController
    let supportsConfigurationReload: Bool
    let reloadConfiguration: () -> Void

    @FocusedValue(\.toasttyCommandWindowID) private var focusedWindowID

    private var commandSelection: WindowCommandSelection? {
        store.commandSelection(preferredWindowID: focusedWindowID)
    }

    private var commandWindow: WindowState? {
        commandSelection?.window
    }

    private var commandWorkspace: WorkspaceState? {
        commandSelection?.workspace
    }

    private var terminalProfileMenuModel: TerminalProfileMenuModel {
        TerminalProfileMenuModel(catalog: terminalProfileStore.catalog)
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(action: reloadConfiguration) {
                Label("Reload Configuration", systemImage: "arrow.clockwise")
            }
            .disabled(!supportsConfigurationReload)
        }

        CommandMenu("Terminal") {
            Button("Increase Terminal Font") {
                store.send(.increaseGlobalTerminalFont)
            }
            .keyboardShortcut("+", modifiers: [.command])

            Button("Decrease Terminal Font") {
                store.send(.decreaseGlobalTerminalFont)
            }
            .keyboardShortcut("-", modifiers: [.command])

            Button("Reset Terminal Font") {
                store.send(.resetGlobalTerminalFont)
            }
            .keyboardShortcut("0", modifiers: [.command])

            Divider()

            terminalProfileMenuItems()

            Divider()

            Button("Install Shell Integration…") {
                terminalProfilesMenuController.installShellIntegration()
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
                store.createWorkspaceFromCommand(preferredWindowID: focusedWindowID)
            }
            .keyboardShortcut(
                ToasttyKeyboardShortcuts.newWorkspace.key,
                modifiers: ToasttyKeyboardShortcuts.newWorkspace.modifiers
            )
            .disabled(store.canCreateWorkspaceFromCommand(preferredWindowID: focusedWindowID) == false)

            Button("Rename Workspace") {
                store.renameSelectedWorkspaceFromCommand(preferredWindowID: focusedWindowID)
            }
            .keyboardShortcut(
                ToasttyKeyboardShortcuts.renameWorkspace.key,
                modifiers: ToasttyKeyboardShortcuts.renameWorkspace.modifiers
            )
            .disabled(commandWorkspace == nil)

            Button("Close Workspace") {
                store.closeSelectedWorkspaceFromCommand(preferredWindowID: focusedWindowID)
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
        }
    }

    private func selectWorkspaceFromCommandSelection(workspaceID: UUID) {
        guard let commandSelection else { return }
        guard commandSelection.window.workspaceIDs.contains(workspaceID) else { return }
        guard store.state.workspacesByID[workspaceID] != nil else { return }
        store.send(.selectWorkspace(windowID: commandSelection.windowID, workspaceID: workspaceID))
    }

    private func toggleFocusedPanelFromCommandSelection() {
        guard let workspaceID = commandWorkspace?.id else { return }
        store.send(.toggleFocusedPanelMode(workspaceID: workspaceID))
    }

    private func closeFocusedPanelFromCommandSelection() {
        _ = focusedPanelCommandController.closeFocusedPanel(in: commandWorkspace?.id)
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
        let button = Button(action.title) {
            _ = terminalProfilesMenuController.splitFocusedSlot(
                profileID: section.profileID,
                direction: action.direction,
                preferredWindowID: focusedWindowID
            )
        }
        .disabled(
            terminalProfilesMenuController.canSplitFocusedSlotWithTerminalProfile(
                preferredWindowID: focusedWindowID
            ) == false
        )

        if let shortcutKey = action.shortcutKey {
            button.keyboardShortcut(
                KeyEquivalent(shortcutKey),
                modifiers: action.shortcutModifiers ?? []
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
}
