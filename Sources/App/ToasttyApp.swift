import AppKit
import CoreState
import SwiftUI

@MainActor
private final class ReloadConfigurationMenuIconInstaller: NSObject, NSApplicationDelegate {
    private static let menuItemTitle = "Reload Configuration"
    private static let symbolName = "arrow.clockwise"
    private var iconWasApplied = false
    private let shouldConfirmQuit: Bool

    override init() {
        let processInfo = ProcessInfo.processInfo
        shouldConfirmQuit = !AutomationConfig.shouldBypassQuitConfirmation(
            arguments: processInfo.arguments,
            environment: processInfo.environment
        )
        super.init()
    }

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.applyReloadIconIfPresent()
        }
        DispatchQueue.main.async { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyReloadIconIfPresent()
            }
        }
    }

    nonisolated func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard !self.iconWasApplied else { return }
            self.applyReloadIconIfPresent()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard shouldConfirmQuit else { return .terminateNow }

        let confirmationAlert = NSAlert()
        confirmationAlert.messageText = "Quit Toastty?"
        confirmationAlert.informativeText = "Are you sure you want to quit?"
        confirmationAlert.alertStyle = .informational
        confirmationAlert.addButton(withTitle: "Cancel")
        confirmationAlert.addButton(withTitle: "Quit")

        let response = confirmationAlert.runModal()
        return response == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    private func applyReloadIconIfPresent() {
        guard !iconWasApplied else { return }
        guard let mainMenu = NSApp.mainMenu else { return }
        guard let menuItem = findMenuItem(in: mainMenu.items) else { return }
        guard menuItem.image == nil else { return }
        menuItem.image = NSImage(
            systemSymbolName: Self.symbolName,
            accessibilityDescription: Self.menuItemTitle
        )
        menuItem.image?.isTemplate = true
        iconWasApplied = true
    }

    private func findMenuItem(in items: [NSMenuItem]) -> NSMenuItem? {
        for item in items {
            if item.title == Self.menuItemTitle {
                return item
            }
            if let submenu = item.submenu,
               let nestedItem = findMenuItem(in: submenu.items) {
                return nestedItem
            }
        }
        return nil
    }
}

@MainActor
private final class ClosePanelShortcutInterceptor {
    private let commandController: FocusedPanelCommandController
    nonisolated(unsafe) private var eventMonitor: Any?

    init(commandController: FocusedPanelCommandController) {
        self.commandController = commandController
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard Self.isClosePanelShortcut(event) else { return event }
            let didClosePanel = self.commandController.closeFocusedPanel()
            // If we didn't close a panel, fall back to default key handling.
            return didClosePanel ? nil : event
        }
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    private static func isClosePanelShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.command] else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == "w"
    }
}

@MainActor
private final class FocusTerminalShortcutInterceptor {
    private weak var store: AppStore?
    nonisolated(unsafe) private var eventMonitor: Any?

    init(store: AppStore) {
        self.store = store
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard let shortcutNumber = Self.shortcutNumber(for: event) else { return event }
            let didFocusPanel = self.focusTerminalPanel(shortcutNumber: shortcutNumber)
            // If no panel is mapped to this shortcut, keep default key behavior.
            return didFocusPanel ? nil : event
        }
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    private static func shortcutNumber(for event: NSEvent) -> Int? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.option] else { return nil }
        return TerminalShortcutConfig.shortcutNumber(from: event.charactersIgnoringModifiers)
    }

    private func focusTerminalPanel(shortcutNumber: Int) -> Bool {
        guard let store else { return false }
        guard let workspace = store.selectedWorkspace else { return false }
        guard let panelID = workspace.terminalPanelID(forDisplayShortcutNumber: shortcutNumber) else {
            return false
        }
        return store.send(.focusPanel(workspaceID: workspace.id, panelID: panelID))
    }
}

private final class AppTerminationObserver: NSObject {
    private let onWillTerminate: () -> Void

    init(onWillTerminate: @escaping () -> Void) {
        self.onWillTerminate = onWillTerminate
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillTerminateNotification),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func handleWillTerminateNotification(_ notification: Notification) {
        _ = notification
        onWillTerminate()
    }
}

@MainActor
@main
struct ToasttyApp: App {
    private static let workspaceShortcutKeys: [KeyEquivalent] = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]

    @NSApplicationDelegateAdaptor(ReloadConfigurationMenuIconInstaller.self)
    private var reloadConfigurationMenuIconInstaller
    @StateObject private var store: AppStore
    @StateObject private var terminalRuntimeRegistry: TerminalRuntimeRegistry
    private let automationLifecycle: AutomationLifecycle?
    private let automationSocketServer: AutomationSocketServer?
    private let automationStartupError: String?
    private let disableAnimations: Bool
    private let workspaceLayoutPersistenceCoordinator: WorkspaceLayoutPersistenceCoordinator?
    private let workspaceLayoutPersistenceObserverToken: UUID?
    private let appTerminationObserver: AppTerminationObserver?
    private let systemNotificationResponseCoordinator: SystemNotificationResponseCoordinator
    private let focusedPanelCommandController: FocusedPanelCommandController
    private let closePanelShortcutInterceptor: ClosePanelShortcutInterceptor
    private let focusTerminalShortcutInterceptor: FocusTerminalShortcutInterceptor

    init() {
        let bootstrap = AppBootstrap.make()
        let persistTerminalFontPreference = bootstrap.automationConfig == nil
        let store = AppStore(
            state: bootstrap.state,
            persistTerminalFontPreference: persistTerminalFontPreference
        )
        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        terminalRuntimeRegistry.bind(store: store)
        let systemNotificationResponseCoordinator = SystemNotificationResponseCoordinator(
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry
        )
        systemNotificationResponseCoordinator.installDelegate()
        let paneFocusRestoreCoordinator = PaneFocusRestoreCoordinator()
        if persistTerminalFontPreference {
            Self.applyInitialTerminalFontState(to: store)
        }
        self.systemNotificationResponseCoordinator = systemNotificationResponseCoordinator
        let focusedPanelCommandController = FocusedPanelCommandController(
            store: store,
            runtimeRegistry: terminalRuntimeRegistry,
            paneFocusRestoreCoordinator: paneFocusRestoreCoordinator
        )
        self.focusedPanelCommandController = focusedPanelCommandController
        closePanelShortcutInterceptor = ClosePanelShortcutInterceptor(
            commandController: focusedPanelCommandController
        )
        focusTerminalShortcutInterceptor = FocusTerminalShortcutInterceptor(store: store)
        _store = StateObject(wrappedValue: store)
        _terminalRuntimeRegistry = StateObject(wrappedValue: terminalRuntimeRegistry)
        automationLifecycle = bootstrap.automationLifecycle
        disableAnimations = bootstrap.disableAnimations

        if let layoutPersistenceContext = bootstrap.layoutPersistenceContext {
            let coordinator = WorkspaceLayoutPersistenceCoordinator(context: layoutPersistenceContext)
            workspaceLayoutPersistenceObserverToken = store.addActionAppliedObserver { [weak coordinator] action, previousState, nextState in
                coordinator?.handleAppliedAction(
                    action,
                    previousState: previousState,
                    nextState: nextState
                )
            }
            workspaceLayoutPersistenceCoordinator = coordinator
            appTerminationObserver = AppTerminationObserver { [weak store, weak coordinator] in
                guard let store, let coordinator else { return }
                coordinator.flushCurrentState(store.state, reason: "application_will_terminate")
            }
        } else {
            workspaceLayoutPersistenceCoordinator = nil
            workspaceLayoutPersistenceObserverToken = nil
            appTerminationObserver = nil
        }

        if let automationConfig = bootstrap.automationConfig {
            do {
                automationSocketServer = try AutomationSocketServer(
                    config: automationConfig,
                    store: store,
                    terminalRuntimeRegistry: terminalRuntimeRegistry,
                    focusedPanelCommandController: focusedPanelCommandController
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
            CommandGroup(after: .appInfo) {
                Button("Reload Configuration") {
                    reloadConfiguration()
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
                    createWorkspaceFromSelection()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(store.selectedWindow == nil)

                Button("Close Panel") {
                    closeFocusedPanelFromSelection()
                }
                .disabled(store.selectedWorkspace?.focusedPanelID == nil)

                Button(store.selectedWorkspace?.focusedPanelModeActive == true ? "Restore Layout" : "Focus Panel") {
                    toggleFocusedPanelFromSelection()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(store.selectedWorkspace == nil)

                if let window = store.selectedWindow {
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

    private func selectWorkspaceFromShortcutIndex(_ index: Int) {
        guard let window = store.selectedWindow else { return }
        guard window.workspaceIDs.indices.contains(index) else { return }
        let workspaceID = window.workspaceIDs[index]
        guard store.state.workspacesByID[workspaceID] != nil else { return }
        let windowID = window.id
        store.send(.selectWorkspace(windowID: windowID, workspaceID: workspaceID))
    }

    private func toggleFocusedPanelFromSelection() {
        guard let workspaceID = store.selectedWorkspace?.id else { return }
        store.send(.toggleFocusedPanelMode(workspaceID: workspaceID))
    }

    private func closeFocusedPanelFromSelection() {
        _ = focusedPanelCommandController.closeFocusedPanel()
    }

    private var supportsConfigurationReload: Bool {
        #if TOASTTY_HAS_GHOSTTY_KIT
        true
        #else
        false
        #endif
    }

    @MainActor
    private func reloadConfiguration() {
        #if TOASTTY_HAS_GHOSTTY_KIT
        let runtimeManager = GhosttyRuntimeManager.shared
        guard runtimeManager.reloadConfiguration() else { return }
        let toasttyConfig = ToasttyConfigStore.load()
        _ = store.send(.setConfiguredTerminalFont(points: runtimeManager.configuredTerminalFontPoints))
        if toasttyConfig.terminalFontSizePoints == nil {
            _ = store.send(.resetGlobalTerminalFont)
        }
        #endif
    }

    @MainActor
    private static func applyInitialTerminalFontState(to store: AppStore) {
        #if TOASTTY_HAS_GHOSTTY_KIT
        _ = store.send(.setConfiguredTerminalFont(points: GhosttyRuntimeManager.shared.configuredTerminalFontPoints))
        #endif

        let toasttyConfig = ToasttyConfigStore.load()
        if let persistedFontSizePoints = toasttyConfig.terminalFontSizePoints {
            _ = store.send(.setGlobalTerminalFont(points: persistedFontSizePoints))
        } else {
            _ = store.send(.resetGlobalTerminalFont)
        }
    }
}
