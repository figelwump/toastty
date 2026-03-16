import CoreState
import SwiftUI

@MainActor
struct ToasttyCommandMenus: Commands {
    private static let workspaceShortcutKeys: [KeyEquivalent] = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]

    @ObservedObject var store: AppStore
    let focusedPanelCommandController: FocusedPanelCommandController
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

            Button("Rename Workspace") {
                store.renameSelectedWorkspaceFromCommand(preferredWindowID: focusedWindowID)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(commandWorkspace == nil)

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
        store.send(.selectWorkspace(windowID: commandSelection.windowID, workspaceID: workspaceID))
    }

    private func toggleFocusedPanelFromCommandSelection() {
        guard let workspaceID = commandWorkspace?.id else { return }
        store.send(.toggleFocusedPanelMode(workspaceID: workspaceID))
    }

    private func closeFocusedPanelFromCommandSelection() {
        _ = focusedPanelCommandController.closeFocusedPanel(in: commandWorkspace?.id)
    }
}
