import SwiftUI

@main
struct ToasttyApp: App {
    @StateObject private var store: AppStore
    @StateObject private var terminalRuntimeRegistry: TerminalRuntimeRegistry
    private let automationLifecycle: AutomationLifecycle?
    private let automationSocketServer: AutomationSocketServer?
    private let automationStartupError: String?
    private let disableAnimations: Bool

    init() {
        let bootstrap = AppBootstrap.make()
        let store = AppStore(state: bootstrap.state)
        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        terminalRuntimeRegistry.bind(store: store)
        _store = StateObject(wrappedValue: store)
        _terminalRuntimeRegistry = StateObject(wrappedValue: terminalRuntimeRegistry)
        automationLifecycle = bootstrap.automationLifecycle
        disableAnimations = bootstrap.disableAnimations

        if let automationConfig = bootstrap.automationConfig {
            do {
                automationSocketServer = try AutomationSocketServer(
                    config: automationConfig,
                    store: store,
                    terminalRuntimeRegistry: terminalRuntimeRegistry
                )
                automationStartupError = nil
            } catch {
                automationSocketServer = nil
                automationStartupError = "Automation socket startup failed: \(error.localizedDescription)"
                if let messageData = ("toastty automation error: \(automationStartupError ?? "unknown")\n").data(using: .utf8) {
                    FileHandle.standardError.write(messageData)
                }
            }
        } else {
            automationSocketServer = nil
            automationStartupError = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(
                store: store,
                terminalRuntimeRegistry: terminalRuntimeRegistry,
                automationLifecycle: automationLifecycle,
                automationStartupError: automationStartupError,
                disableAnimations: disableAnimations
            )
                .frame(minWidth: 980, minHeight: 620)
        }
        .commands {
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
                    createWorkspaceFromSelection()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                if let window = store.selectedWindow {
                    ForEach(Array(window.workspaceIDs.prefix(9).enumerated()), id: \.element) { index, workspaceID in
                        if let workspace = store.state.workspacesByID[workspaceID] {
                            Button(workspace.title) {
                                selectWorkspaceFromSelection(workspaceID: workspaceID)
                            }
                            .keyboardShortcut(
                                KeyEquivalent(Character(String(index + 1))),
                                modifiers: [.command]
                            )
                        }
                    }
                }
            }

            #if !TOASTTY_HAS_GHOSTTY_KIT
            CommandMenu("Pane") {
                Button("Split Right") {
                    guard let workspaceID = store.selectedWorkspace?.id else { return }
                    store.send(.splitFocusedPaneInDirection(workspaceID: workspaceID, direction: .right))
                }
                .keyboardShortcut("d", modifiers: [.command])

                Button("Split Down") {
                    guard let workspaceID = store.selectedWorkspace?.id else { return }
                    store.send(.splitFocusedPaneInDirection(workspaceID: workspaceID, direction: .down))
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button("Focus Previous Pane") {
                    guard let workspaceID = store.selectedWorkspace?.id else { return }
                    store.send(.focusPane(workspaceID: workspaceID, direction: .previous))
                }
                .keyboardShortcut("[", modifiers: [.command])

                Button("Focus Next Pane") {
                    guard let workspaceID = store.selectedWorkspace?.id else { return }
                    store.send(.focusPane(workspaceID: workspaceID, direction: .next))
                }
                .keyboardShortcut("]", modifiers: [.command])
            }
            #endif
        }
    }

    private func createWorkspaceFromSelection() {
        guard let windowID = store.selectedWindow?.id else { return }
        store.send(.createWorkspace(windowID: windowID, title: nil))
    }

    private func selectWorkspaceFromSelection(workspaceID: UUID) {
        guard let windowID = store.selectedWindow?.id else { return }
        store.send(.selectWorkspace(windowID: windowID, workspaceID: workspaceID))
    }
}
