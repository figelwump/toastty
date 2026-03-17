import AppKit
import CoreState
import SwiftUI

@MainActor
private enum ToasttyMenuActions {
    static func installShellIntegration() {
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
}

@MainActor
private final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    private let shouldConfirmQuit: Bool

    override init() {
        let processInfo = ProcessInfo.processInfo
        shouldConfirmQuit = !AutomationConfig.shouldBypassInteractiveConfirmation(
            arguments: processInfo.arguments,
            environment: processInfo.environment
        )
        super.init()
    }

    nonisolated func applicationDidBecomeActive(_ notification: Notification) {
        _ = notification
        #if TOASTTY_HAS_GHOSTTY_KIT
        Task { @MainActor in
            GhosttyRuntimeManager.shared.setAppFocus(true)
        }
        #endif
    }

    nonisolated func applicationDidResignActive(_ notification: Notification) {
        _ = notification
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
private final class MenuBridgeInstaller {
    private let closeWindowMenuBridge: CloseWindowMenuBridge
    private let helpMenuBridge: HelpMenuBridge
    private let hiddenSystemMenuItemsBridge: HiddenSystemMenuItemsBridge
    private var installationTask: Task<Void, Never>?

    init(
        closeWindowMenuBridge: CloseWindowMenuBridge,
        helpMenuBridge: HelpMenuBridge,
        hiddenSystemMenuItemsBridge: HiddenSystemMenuItemsBridge
    ) {
        self.closeWindowMenuBridge = closeWindowMenuBridge
        self.helpMenuBridge = helpMenuBridge
        self.hiddenSystemMenuItemsBridge = hiddenSystemMenuItemsBridge

        scheduleInstallations()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationLifecycleNotification(_:)),
            name: NSApplication.didFinishLaunchingNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationLifecycleNotification(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    deinit {
        installationTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func handleApplicationLifecycleNotification(_ notification: Notification) {
        _ = notification
        scheduleInstallations()
    }

    private func scheduleInstallations() {
        installationTask?.cancel()
        installationTask = Task { @MainActor [weak self] in
            for delay in [0, 100, 500, 1_000, 2_000] {
                if delay > 0 {
                    try? await Task.sleep(for: .milliseconds(delay))
                }
                guard Task.isCancelled == false else { return }
                self?.installIfPossible()
            }
        }
    }

    private func installIfPossible() {
        guard NSApplication.shared.mainMenu != nil else { return }
        closeWindowMenuBridge.installIfNeeded()
        helpMenuBridge.installIfNeeded()
        hiddenSystemMenuItemsBridge.installIfNeeded()
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
    private let terminalProfilesMenuController: TerminalProfilesMenuController
    private let menuBridgeInstaller: MenuBridgeInstaller
    private let focusedPanelCommandController: FocusedPanelCommandController
    private let focusTerminalShortcutInterceptor: FocusTerminalShortcutInterceptor

    init() {
        let processInfo = ProcessInfo.processInfo
        Self.ensureTerminalProfilesTemplateExists()
        Self.configureWindowPersistenceDefaults()
        let usesPersistentPreferences = AutomationConfig.parse(
            arguments: processInfo.arguments,
            environment: processInfo.environment
        ) == nil
        let terminalProfileStore = TerminalProfileStore()
        let initialToasttyConfig = usesPersistentPreferences ? ToasttyConfigStore.load() : ToasttyConfig()
        let initialToasttySettings = usesPersistentPreferences ? ToasttySettingsStore.load() : ToasttySettings()
        let initialDefaultTerminalProfileID = usesPersistentPreferences
            ? Self.resolvedDefaultTerminalProfileID(
                configuredDefaultTerminalProfileID: initialToasttyConfig.defaultTerminalProfileID,
                terminalProfileCatalog: terminalProfileStore.catalog,
                source: "startup"
            )
            : nil
        let bootstrap = AppBootstrap.make(
            processInfo: processInfo,
            defaultTerminalProfileID: initialDefaultTerminalProfileID
        )
        let persistTerminalFontPreference = bootstrap.automationConfig == nil
        let store = AppStore(
            state: bootstrap.state,
            persistTerminalFontPreference: persistTerminalFontPreference
        )
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
            Self.applyInitialToasttyConfigState(
                to: store,
                terminalProfileCatalog: terminalProfileStore.catalog,
                toasttyConfig: initialToasttyConfig,
                toasttySettings: initialToasttySettings
            )
            Self.ensureToasttyConfigTemplateExists()
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
        terminalProfilesMenuController = TerminalProfilesMenuController(
            store: store,
            installShellIntegrationAction: ToasttyMenuActions.installShellIntegration
        )
        menuBridgeInstaller = MenuBridgeInstaller(
            closeWindowMenuBridge: closeWindowMenuBridge,
            helpMenuBridge: helpMenuBridge,
            hiddenSystemMenuItemsBridge: hiddenSystemMenuItemsBridge
        )
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
        }
        // Let SwiftUI remove the native titlebar container so our custom
        // workspace chrome can occupy that space without AppKit overlaying it.
        .windowStyle(.hiddenTitleBar)
        .commands {
            ToasttyCommandMenus(
                store: store,
                terminalProfileStore: terminalProfileStore,
                focusedPanelCommandController: focusedPanelCommandController,
                terminalProfilesMenuController: terminalProfilesMenuController,
                supportsConfigurationReload: supportsConfigurationReload,
                reloadConfiguration: reloadConfiguration
            )
        }
    }

    private var supportsConfigurationReload: Bool {
        true
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

        let toasttyConfig = ToasttyConfigStore.load()
        let toasttySettings = ToasttySettingsStore.load()
        Self.applyConfiguredDefaultTerminalProfile(
            to: store,
            terminalProfileCatalog: terminalProfileStore.catalog,
            configuredDefaultTerminalProfileID: toasttyConfig.defaultTerminalProfileID,
            source: "reload"
        )

        #if TOASTTY_HAS_GHOSTTY_KIT
        let runtimeManager = GhosttyRuntimeManager.shared
        if runtimeManager.reloadConfiguration() {
            Self.applyToasttyTerminalFontState(
                to: store,
                toasttyConfig: toasttyConfig,
                toasttySettings: toasttySettings,
                ghosttyConfiguredTerminalFontPoints: runtimeManager.configuredTerminalFontPoints
            )
        } else {
            failureMessages.append("Failed to reload embedded Ghostty configuration.")
            Self.applyToasttyTerminalFontState(
                to: store,
                toasttyConfig: toasttyConfig,
                toasttySettings: toasttySettings,
                ghosttyConfiguredTerminalFontPoints: runtimeManager.configuredTerminalFontPoints
            )
        }
        #else
        Self.applyToasttyTerminalFontState(
            to: store,
            toasttyConfig: toasttyConfig,
            toasttySettings: toasttySettings,
            ghosttyConfiguredTerminalFontPoints: nil
        )
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
    private static func applyInitialToasttyConfigState(
        to store: AppStore,
        terminalProfileCatalog: TerminalProfileCatalog,
        toasttyConfig: ToasttyConfig,
        toasttySettings: ToasttySettings
    ) {
        applyConfiguredDefaultTerminalProfile(
            to: store,
            terminalProfileCatalog: terminalProfileCatalog,
            configuredDefaultTerminalProfileID: toasttyConfig.defaultTerminalProfileID,
            source: "startup"
        )

        #if TOASTTY_HAS_GHOSTTY_KIT
        let ghosttyConfiguredTerminalFontPoints = GhosttyRuntimeManager.shared.configuredTerminalFontPoints
        #else
        let ghosttyConfiguredTerminalFontPoints: Double? = nil
        #endif

        applyToasttyTerminalFontState(
            to: store,
            toasttyConfig: toasttyConfig,
            toasttySettings: toasttySettings,
            ghosttyConfiguredTerminalFontPoints: ghosttyConfiguredTerminalFontPoints
        )
    }

    private static func resolvedDefaultTerminalProfileID(
        configuredDefaultTerminalProfileID: String?,
        terminalProfileCatalog: TerminalProfileCatalog,
        source: String
    ) -> String? {
        guard let configuredDefaultTerminalProfileID = AppState.normalizedTerminalProfileID(
            configuredDefaultTerminalProfileID
        ) else {
            return nil
        }
        guard terminalProfileCatalog.profile(id: configuredDefaultTerminalProfileID) != nil else {
            ToasttyLog.warning(
                "Configured default terminal profile is unavailable; new terminals will remain unprofiled",
                category: .bootstrap,
                metadata: [
                    "profile_id": configuredDefaultTerminalProfileID,
                    "source": source,
                ]
            )
            return nil
        }
        return configuredDefaultTerminalProfileID
    }

    @MainActor
    private static func applyConfiguredDefaultTerminalProfile(
        to store: AppStore,
        terminalProfileCatalog: TerminalProfileCatalog,
        configuredDefaultTerminalProfileID: String?,
        source: String
    ) {
        let resolvedDefaultTerminalProfileID = resolvedDefaultTerminalProfileID(
            configuredDefaultTerminalProfileID: configuredDefaultTerminalProfileID,
            terminalProfileCatalog: terminalProfileCatalog,
            source: source
        )
        _ = store.send(.setDefaultTerminalProfile(profileID: resolvedDefaultTerminalProfileID))
    }

    @MainActor
    private static func applyToasttyTerminalFontState(
        to store: AppStore,
        toasttyConfig: ToasttyConfig,
        toasttySettings: ToasttySettings,
        ghosttyConfiguredTerminalFontPoints: Double?
    ) {
        let configuredBaseline = toasttyConfig.terminalFontSizePoints ?? ghosttyConfiguredTerminalFontPoints
        _ = store.send(.setConfiguredTerminalFont(points: configuredBaseline))

        if let persistedFontSizePoints = toasttySettings.terminalFontSizePoints {
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

    private static func ensureToasttyConfigTemplateExists() {
        do {
            try ToasttyConfigStore.ensureTemplateExists()
        } catch {
            ToasttyLog.warning(
                "Failed to ensure Toastty config template exists",
                category: .bootstrap,
                metadata: [
                    "path": ToasttyConfigStore.configFileURL().path,
                    "error": error.localizedDescription,
                ]
            )
        }
    }
}
