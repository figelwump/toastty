import AppKit
import CoreState
import SwiftUI

@MainActor
private final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    private let shouldConfirmQuit: Bool
    private var closeWindowMenuBridge: CloseWindowMenuBridge?
    private var helpMenuBridge: HelpMenuBridge?
    private var hiddenSystemMenuItemsBridge: HiddenSystemMenuItemsBridge?
    private var menuBridgeInstallationTask: Task<Void, Never>?

    override init() {
        let processInfo = ProcessInfo.processInfo
        shouldConfirmQuit = !AutomationConfig.shouldBypassInteractiveConfirmation(
            arguments: processInfo.arguments,
            environment: processInfo.environment
        )
        super.init()
    }

    func setCloseWindowMenuBridge(_ bridge: CloseWindowMenuBridge) {
        closeWindowMenuBridge = bridge
        scheduleMenuBridgeInstallations()
    }

    func setHelpMenuBridge(_ bridge: HelpMenuBridge) {
        helpMenuBridge = bridge
        scheduleMenuBridgeInstallations()
    }

    func setHiddenSystemMenuItemsBridge(_ bridge: HiddenSystemMenuItemsBridge) {
        hiddenSystemMenuItemsBridge = bridge
        scheduleMenuBridgeInstallations()
    }

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        Task { @MainActor [weak self] in
            self?.scheduleMenuBridgeInstallations()
        }
    }

    nonisolated func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.scheduleMenuBridgeInstallations()
        }
        #if TOASTTY_HAS_GHOSTTY_KIT
        Task { @MainActor in
            GhosttyRuntimeManager.shared.setAppFocus(true)
        }
        #endif
    }

    nonisolated func applicationDidResignActive(_ notification: Notification) {
        #if TOASTTY_HAS_GHOSTTY_KIT
        Task { @MainActor in
            GhosttyRuntimeManager.shared.setAppFocus(false)
        }
        #endif
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

    private func installMenuBridges() {
        closeWindowMenuBridge?.installIfNeeded()
        helpMenuBridge?.installIfNeeded()
        hiddenSystemMenuItemsBridge?.installIfNeeded()
    }

    private func scheduleMenuBridgeInstallations() {
        menuBridgeInstallationTask?.cancel()
        installMenuBridges()

        menuBridgeInstallationTask = Task { @MainActor [weak self] in
            for delay in [100, 500, 1_000] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard Task.isCancelled == false else { return }
                self?.installMenuBridges()
            }
        }
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

private final class AppResignActiveObserver: NSObject {
    private let onDidResignActive: () -> Void

    init(onDidResignActive: @escaping () -> Void) {
        self.onDidResignActive = onDidResignActive
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidResignActiveNotification),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func handleDidResignActiveNotification(_ notification: Notification) {
        _ = notification
        onDidResignActive()
    }
}

@MainActor
@main
struct ToasttyApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self)
    private var appLifecycleDelegate
    @StateObject private var store: AppStore
    @StateObject private var terminalProfileStore: TerminalProfileStore
    private let appWindowSceneCoordinator: AppWindowSceneCoordinator
    @StateObject private var terminalRuntimeRegistry: TerminalRuntimeRegistry
    private let automationLifecycle: AutomationLifecycle?
    private let automationSocketServer: AutomationSocketServer?
    private let automationStartupError: String?
    private let disableAnimations: Bool
    private let workspaceLayoutPersistenceCoordinator: WorkspaceLayoutPersistenceCoordinator?
    private let workspaceLayoutPersistenceObserverToken: UUID?
    private let appTerminationObserver: AppTerminationObserver?
    private let appResignActiveObserver: AppResignActiveObserver
    private let systemNotificationResponseCoordinator: SystemNotificationResponseCoordinator
    private let closeWindowMenuBridge: CloseWindowMenuBridge
    private let helpMenuBridge: HelpMenuBridge
    private let hiddenSystemMenuItemsBridge: HiddenSystemMenuItemsBridge
    private let focusedPanelCommandController: FocusedPanelCommandController
    private let focusTerminalShortcutInterceptor: FocusTerminalShortcutInterceptor

    init() {
        Self.ensureTerminalProfilesTemplateExists()
        Self.configureWindowPersistenceDefaults()
        let bootstrap = AppBootstrap.make()
        let persistTerminalFontPreference = bootstrap.automationConfig == nil
        let store = AppStore(
            state: bootstrap.state,
            persistTerminalFontPreference: persistTerminalFontPreference
        )
        let terminalProfileStore = TerminalProfileStore()
        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        terminalRuntimeRegistry.setTerminalProfileProvider(
            terminalProfileStore,
            restoredTerminalPanelIDs: bootstrap.restoredTerminalPanelIDs
        )
        terminalRuntimeRegistry.bind(store: store)
        let systemNotificationResponseCoordinator = SystemNotificationResponseCoordinator(
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry
        )
        systemNotificationResponseCoordinator.installDelegate()
        let slotFocusRestoreCoordinator = SlotFocusRestoreCoordinator()
        if persistTerminalFontPreference {
            Self.applyInitialTerminalFontState(to: store)
        }
        self.systemNotificationResponseCoordinator = systemNotificationResponseCoordinator
        let focusedPanelCommandController = FocusedPanelCommandController(
            store: store,
            runtimeRegistry: terminalRuntimeRegistry,
            slotFocusRestoreCoordinator: slotFocusRestoreCoordinator
        )
        self.focusedPanelCommandController = focusedPanelCommandController
        closeWindowMenuBridge = CloseWindowMenuBridge(
            windowCommandController: WindowCommandController(
                focusedPanelCommandController: focusedPanelCommandController
            )
        )
        helpMenuBridge = HelpMenuBridge()
        hiddenSystemMenuItemsBridge = HiddenSystemMenuItemsBridge()
        focusTerminalShortcutInterceptor = FocusTerminalShortcutInterceptor(store: store)
        _store = StateObject(wrappedValue: store)
        _terminalProfileStore = StateObject(wrappedValue: terminalProfileStore)
        appWindowSceneCoordinator = AppWindowSceneCoordinator()
        _terminalRuntimeRegistry = StateObject(wrappedValue: terminalRuntimeRegistry)
        automationLifecycle = bootstrap.automationLifecycle
        disableAnimations = bootstrap.disableAnimations
        appResignActiveObserver = AppResignActiveObserver { [weak terminalRuntimeRegistry] in
            terminalRuntimeRegistry?.synchronizeGhosttySurfaceFocusFromApplicationState()
        }

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
        WindowGroup(id: AppWindowSceneID.value) {
            AppWindowSceneHostView(
                store: store,
                terminalProfileStore: terminalProfileStore,
                terminalRuntimeRegistry: terminalRuntimeRegistry,
                sceneCoordinator: appWindowSceneCoordinator,
                automationLifecycle: automationLifecycle,
                automationStartupError: automationStartupError,
                disableAnimations: disableAnimations
            )
            .frame(minWidth: 980, minHeight: 620)
            .onAppear {
                appLifecycleDelegate.setCloseWindowMenuBridge(closeWindowMenuBridge)
                appLifecycleDelegate.setHelpMenuBridge(helpMenuBridge)
                appLifecycleDelegate.setHiddenSystemMenuItemsBridge(hiddenSystemMenuItemsBridge)
            }
        }
        // Let SwiftUI remove the native titlebar container so our custom
        // workspace chrome can occupy that space without AppKit overlaying it.
        .windowStyle(.hiddenTitleBar)
        .commands {
            ToasttyCommandMenus(
                store: store,
                terminalProfileStore: terminalProfileStore,
                focusedPanelCommandController: focusedPanelCommandController,
                supportsConfigurationReload: supportsConfigurationReload,
                reloadConfiguration: reloadConfiguration,
                installShellIntegration: installShellIntegration
            )
        }
    }

    private var supportsConfigurationReload: Bool {
        true
    }

    @MainActor
    private func installShellIntegration() {
        let installer = ProfileShellIntegrationInstaller()
        let status: ProfileShellIntegrationInstallStatus

        do {
            status = try installer.installationStatus()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Unable to Install Shell Integration"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        if status.isInstalled {
            let alert = NSAlert()
            alert.messageText = "Shell Integration Already Installed"
            alert.informativeText = """
            Toastty shell integration is already installed for \(status.plan.shell.displayName).

            Init file: \(status.plan.initFileURL.path)
            Managed snippet: \(status.plan.managedSnippetURL.path)
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let confirmationAlert = NSAlert()
        confirmationAlert.messageText = "Install Shell Integration?"
        let snippetAction = status.needsManagedSnippetWrite
            ? "write the managed snippet to \(status.plan.managedSnippetURL.path)"
            : "use the existing managed snippet at \(status.plan.managedSnippetURL.path)"
        let initFileAction: String
        if status.needsInitFileUpdate {
            initFileAction = status.createsInitFile
                ? "create \(status.plan.initFileURL.path) and add one source line to it"
                : "add one source line to \(status.plan.initFileURL.path)"
        } else {
            initFileAction = "\(status.plan.initFileURL.path) already references that snippet"
        }
        confirmationAlert.informativeText = """
        Toastty detected \(status.plan.shell.displayName). It will \(snippetAction).

        It will \(initFileAction).

        New profiled shells will pick it up automatically. Existing zmx or tmux sessions need to restart or re-source that init file before titles start updating.
        """
        confirmationAlert.alertStyle = .informational
        confirmationAlert.addButton(withTitle: "Install")
        confirmationAlert.addButton(withTitle: "Cancel")

        guard confirmationAlert.runModal() == .alertFirstButtonReturn else {
            return
        }

        do {
            let result = try installer.install(plan: status.plan)
            let alert = NSAlert()
            alert.messageText = "Shell Integration Installed"

            let snippetMessage = result.updatedManagedSnippet
                ? "Wrote \(result.plan.managedSnippetURL.path)."
                : "\(result.plan.managedSnippetURL.path) was already up to date."

            let initFileMessage: String
            if result.updatedInitFile {
                initFileMessage = result.createdInitFile
                    ? "Created \(result.plan.initFileURL.path)."
                    : "Updated \(result.plan.initFileURL.path)."
            } else {
                initFileMessage = "\(result.plan.initFileURL.path) already referenced the managed snippet."
            }

            alert.informativeText = """
            \(snippetMessage)
            \(initFileMessage)

            New shells will pick it up automatically. Existing profiled sessions need to restart or re-source that init file.
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Unable to Install Shell Integration"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @MainActor
    private func reloadConfiguration() {
        var failureMessages: [String] = []

        switch terminalProfileStore.reload() {
        case .success:
            break
        case .failure(let error):
            failureMessages.append(error.localizedDescription)
        }

        #if TOASTTY_HAS_GHOSTTY_KIT
        let runtimeManager = GhosttyRuntimeManager.shared
        if runtimeManager.reloadConfiguration() {
            let toasttyConfig = ToasttyConfigStore.load()
            _ = store.send(.setConfiguredTerminalFont(points: runtimeManager.configuredTerminalFontPoints))
            if toasttyConfig.terminalFontSizePoints == nil {
                _ = store.send(.resetGlobalTerminalFont)
            }
        } else {
            failureMessages.append("Failed to reload embedded Ghostty configuration.")
        }
        #endif

        guard failureMessages.isEmpty == false else { return }

        let alert = NSAlert()
        alert.messageText = "Unable to Reload Configuration"
        alert.informativeText = failureMessages.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
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

    @MainActor
    private static func configureWindowPersistenceDefaults() {
        NSWindow.allowsAutomaticWindowTabbing = false

        // Toastty persists window/workspace state explicitly, so AppKit's
        // saved-state restoration only adds stale SwiftUI scene identifiers.
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "ApplePersistenceIgnoreState")
        defaults.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    private static func ensureTerminalProfilesTemplateExists() {
        do {
            try TerminalProfilesFile.ensureTemplateExists()
        } catch {
            ToasttyLog.warning(
                "Failed to ensure terminal profiles template exists",
                category: .bootstrap,
                metadata: [
                    "path": TerminalProfilesFile.fileURL().path,
                    "error": error.localizedDescription,
                ]
            )
        }
    }
}
