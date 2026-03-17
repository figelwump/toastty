import AppKit
import CoreState
import SwiftUI

@MainActor
struct ToasttyCommandMenus: Commands {
    private static let workspaceShortcutKeys: [KeyEquivalent] = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]

    @ObservedObject var store: AppStore
    @ObservedObject var agentCatalogStore: AgentCatalogStore
    @ObservedObject var sessionRuntimeStore: SessionRuntimeStore
    let focusedPanelCommandController: FocusedPanelCommandController
    let agentLaunchService: AgentLaunchService
    let supportsConfigurationReload: Bool
    let reloadConfiguration: () -> Void
    let openAgentProfilesConfiguration: () -> Void

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
        }

        CommandMenu("Workspace") {
            Button("New Workspace") {
                store.createWorkspaceFromCommand(preferredWindowID: focusedWindowID)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(store.canCreateWorkspaceFromCommand(preferredWindowID: focusedWindowID) == false)

            Button("Close Panel") {
                closeFocusedPanelFromCommandSelection()
            }
            .disabled(commandWorkspace?.focusedPanelID == nil)

            Button(commandWorkspace?.focusedPanelModeActive == true ? "Restore Layout" : "Focus Panel") {
                toggleFocusedPanelFromCommandSelection()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(commandWorkspace == nil)

            if let window = commandWindow {
                ForEach(
                    Array(window.workspaceIDs.prefix(Self.workspaceShortcutKeys.count).enumerated()),
                    id: \.offset
                ) { index, workspaceID in
                    let workspace = store.state.workspacesByID[workspaceID]
                    let title = workspace?.title ?? "Missing Workspace \(index + 1)"
                    Button(title) {
                        selectWorkspaceFromShortcutIndex(index)
                    }
                    .keyboardShortcut(Self.workspaceShortcutKeys[index], modifiers: [.command])
                    .disabled(workspace == nil)
                }
            }
        }

        CommandMenu("Agent") {
            if agentCatalogStore.catalog.profiles.isEmpty {
                Button("No Agents Configured") {}
                    .disabled(true)
            } else {
                ForEach(agentCatalogStore.catalog.profiles) { profile in
                    Button(profile.displayName) {
                        launchAgentFromCommandSelection(profile.id)
                    }
                    .disabled(canLaunchAgent(profileID: profile.id) == false)
                }
            }

            Divider()

            Button("Manage Agents…", action: openAgentProfilesConfiguration)
        }

        #if !TOASTTY_HAS_GHOSTTY_KIT
        CommandMenu("Pane") {
            Button("Split Right") {
                guard let workspaceID = commandWorkspace?.id else { return }
                store.send(.splitFocusedSlotInDirection(workspaceID: workspaceID, direction: .right))
            }
            .keyboardShortcut("d", modifiers: [.command])

            Button("Split Down") {
                guard let workspaceID = commandWorkspace?.id else { return }
                store.send(.splitFocusedSlotInDirection(workspaceID: workspaceID, direction: .down))
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button("Focus Previous Pane") {
                guard let workspaceID = commandWorkspace?.id else { return }
                store.send(.focusSlot(workspaceID: workspaceID, direction: .previous))
            }
            .keyboardShortcut("[", modifiers: [.command])

            Button("Focus Next Pane") {
                guard let workspaceID = commandWorkspace?.id else { return }
                store.send(.focusSlot(workspaceID: workspaceID, direction: .next))
            }
            .keyboardShortcut("]", modifiers: [.command])
        }
        #endif
    }
    private func selectWorkspaceFromShortcutIndex(_ index: Int) {
        guard let commandSelection else { return }
        guard commandSelection.window.workspaceIDs.indices.contains(index) else { return }
        let workspaceID = commandSelection.window.workspaceIDs[index]
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

    private func canLaunchAgent(profileID: String) -> Bool {
        agentLaunchService.canLaunchAgent(
            profileID: profileID,
            workspaceID: commandWorkspace?.id
        )
    }

    private func launchAgentFromCommandSelection(_ profileID: String) {
        do {
            _ = try agentLaunchService.launch(
                profileID: profileID,
                workspaceID: commandWorkspace?.id
            )
        } catch {
            let alert = NSAlert()
            alert.messageText = "Unable to Run Agent"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
