import AppKit
import CoreState
import SwiftUI

@MainActor
private enum ToasttyMenuActions {
    static func openTerminalProfilesConfiguration() {
        do {
            try TerminalProfilesFile.ensureTemplateExists()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Unable to Open Terminal Profiles"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let fileURL = TerminalProfilesFile.fileURL()
        guard NSWorkspace.shared.open(fileURL) else {
            let alert = NSAlert()
            alert.messageText = "Unable to Open Terminal Profiles"
            alert.informativeText = "Toastty couldn't open \(fileURL.path)."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
    }

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
func restoreHiddenToasttyWindows(
    windows: [NSWindow],
    store: AppStore,
    activateApp: () -> Void = {},
    makeKeyAndOrderFront: (NSWindow) -> Void = { $0.makeKeyAndOrderFront(nil) },
    orderFront: (NSWindow) -> Void = { $0.orderFront(nil) }
) -> Bool {
    let hiddenToasttyWindows = windows.filter { window in
        guard window.isVisible == false,
              window.isMiniaturized == false,
              let rawWindowID = window.identifier?.rawValue,
              let windowID = UUID(uuidString: rawWindowID) else {
            return false
        }
        return store.window(id: windowID) != nil
    }

    guard hiddenToasttyWindows.isEmpty == false else { return false }

    activateApp()
    for (index, window) in hiddenToasttyWindows.enumerated() {
        if index == 0 {
            makeKeyAndOrderFront(window)
        } else {
            orderFront(window)
        }
    }

    return true
}

@MainActor
private final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    private let shouldConfirmQuit: Bool
    private weak var store: AppStore?
    private var fileSplitMenuBridge: FileSplitMenuBridge?
    private var fileCloseMenuBridge: FileCloseMenuBridge?
    private var windowSplitMenuBridge: WindowSplitMenuBridge?
    private var helpMenuBridge: HelpMenuBridge?
    private var hiddenSystemMenuItemsBridge: HiddenSystemMenuItemsBridge?
    private var sparkleMenuBridge: SparkleMenuBridge?
    private var hasCompletedLaunch = false
    private var menuBridgeInstallationTask: Task<Void, Never>?
    let sparkleUpdaterBridge: SparkleUpdaterBridge

    override init() {
        let processInfo = ProcessInfo.processInfo
        let isInteractiveSession = Self.isInteractiveSession(processInfo)
        shouldConfirmQuit = isInteractiveSession
        sparkleUpdaterBridge = SparkleUpdaterBridge(startingUpdater: isInteractiveSession)
        super.init()
    }

    deinit {
        menuBridgeInstallationTask?.cancel()
    }

    static func isInteractiveSession(_ processInfo: ProcessInfo) -> Bool {
        !AutomationConfig.shouldBypassInteractiveConfirmation(
            arguments: processInfo.arguments,
            environment: processInfo.environment
        )
    }

    func configureStore(_ store: AppStore) {
        self.store = store
    }

    func configureMenuBridges(
        fileSplitMenuBridge: FileSplitMenuBridge,
        fileCloseMenuBridge: FileCloseMenuBridge,
        windowSplitMenuBridge: WindowSplitMenuBridge,
        helpMenuBridge: HelpMenuBridge,
        hiddenSystemMenuItemsBridge: HiddenSystemMenuItemsBridge
    ) {
        self.fileSplitMenuBridge = fileSplitMenuBridge
        self.fileCloseMenuBridge = fileCloseMenuBridge
        self.windowSplitMenuBridge = windowSplitMenuBridge
        self.helpMenuBridge = helpMenuBridge
        self.hiddenSystemMenuItemsBridge = hiddenSystemMenuItemsBridge
        hiddenSystemMenuItemsBridge.setOnOwnedMenuSectionRefreshRequested { [weak self] in
            self?.installOwnedMenuSections()
        }
        hiddenSystemMenuItemsBridge.setOnDynamicMenuBridgeRefreshRequested { [weak self] in
            self?.installDynamicMenuBridges()
        }

        if sparkleMenuBridge == nil {
            sparkleMenuBridge = SparkleMenuBridge(sparkleUpdaterBridge: sparkleUpdaterBridge)
        }

        guard hasCompletedLaunch else { return }
        scheduleMenuBridgeInstallations()
    }

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        Task { @MainActor [weak self] in
            self?.hasCompletedLaunch = true
            self?.scheduleMenuBridgeInstallations()
        }
    }

    nonisolated func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.hasCompletedLaunch = true
            self?.scheduleMenuBridgeInstallations()
        }
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

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        #if TOASTTY_HAS_GHOSTTY_KIT
        GhosttyClipboardBridge.releaseSelectionPasteboardIfNeeded()
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard flag == false else { return true }
        guard let store else { return true }

        // If Toastty has nothing ordered out to restore, let AppKit continue
        // with its default reopen handling (for example, miniaturized windows).
        _ = restoreHiddenToasttyWindows(
            windows: sender.windows,
            store: store,
            activateApp: {
                sender.activate(ignoringOtherApps: true)
            }
        )
        return true
    }

    private func installMenuBridges() {
        if let hiddenSystemMenuItemsBridge {
            hiddenSystemMenuItemsBridge.installIfNeeded()
        } else {
            installOwnedMenuSections()
            installDynamicMenuBridges()
        }
    }

    private func installOwnedMenuSections() {
        fileSplitMenuBridge?.installIfNeeded()
        fileCloseMenuBridge?.installIfNeeded()
        windowSplitMenuBridge?.installIfNeeded()
    }

    private func installDynamicMenuBridges() {
        helpMenuBridge?.installIfNeeded()
        sparkleMenuBridge?.installIfNeeded()
    }

    private func scheduleMenuBridgeInstallations() {
        menuBridgeInstallationTask?.cancel()
        installMenuBridges()

        menuBridgeInstallationTask = Task { @MainActor [weak self] in
            for delay in [100, 500, 1_000, 2_000] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard Task.isCancelled == false else { return }
                self?.installMenuBridges()
            }
        }
    }

    func sceneDidAppear() {
        // SwiftUI can materialize the live main menu after launch callbacks
        // have already fired, so scene appearance remains the reliable point
        // to refresh owned File/Window menu sections plus dynamic menu items.
        scheduleMenuBridgeInstallations()
    }
}

@MainActor
final class DisplayShortcutInterceptor {
    private weak var store: AppStore?
    private let focusedPanelCommandController: FocusedPanelCommandController
    nonisolated(unsafe) private var eventMonitor: Any?

    private enum ShortcutAction {
        case closePanel
        case switchWorkspace(Int)
        case focusPanel(Int)
    }

    init(store: AppStore, focusedPanelCommandController: FocusedPanelCommandController) {
        self.store = store
        self.focusedPanelCommandController = focusedPanelCommandController
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard let action = self.shortcutAction(for: event) else { return event }
            // Keep workspace switching in the local monitor so the embedded
            // terminal's key handling cannot swallow Option+digit before the
            // menu-based workspace switch path can run reliably.
            let didHandleShortcut = self.handle(action)
            // If no workspace or panel is mapped to this shortcut, keep default key behavior.
            return didHandleShortcut ? nil : event
        }
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    private func shortcutAction(for event: NSEvent) -> ShortcutAction? {
        if Self.isClosePanelShortcut(event),
           closePanelShortcutWindowID() != nil {
            return .closePanel
        }

        switch DisplayShortcutConfig.action(for: event) {
        case .workspaceSwitch(let shortcutNumber):
            return .switchWorkspace(shortcutNumber)
        case .panelFocus(let shortcutNumber):
            return .focusPanel(shortcutNumber)
        case nil:
            return nil
        }
    }

    private func handle(_ action: ShortcutAction) -> Bool {
        switch action {
        case .closePanel:
            closeFocusedPanel()
        case .switchWorkspace(let shortcutNumber):
            switchWorkspace(shortcutNumber: shortcutNumber)
        case .focusPanel(let shortcutNumber):
            focusTerminalPanel(shortcutNumber: shortcutNumber)
        }
    }

    static func isClosePanelShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "w" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command]
    }

    static func closePanelShortcutWindowID(keyWindow: NSWindow?, modalWindow: NSWindow?) -> UUID? {
        guard modalWindow == nil else { return nil }
        guard let keyWindow else { return nil }
        guard keyWindow.sheetParent == nil else { return nil }
        // Be conservative around active text input so Cmd+W stays with the
        // field editor or text control rather than being reclaimed by Toastty.
        if keyWindow.firstResponder is NSTextInputClient {
            return nil
        }
        guard let rawWindowID = keyWindow.identifier?.rawValue else { return nil }
        return UUID(uuidString: rawWindowID)
    }

    private func closePanelShortcutWindowID() -> UUID? {
        guard let store else { return nil }
        guard let windowID = Self.closePanelShortcutWindowID(
            keyWindow: NSApp.keyWindow,
            modalWindow: NSApp.modalWindow
        ) else {
            return nil
        }
        guard store.window(id: windowID) != nil else { return nil }
        return windowID
    }

    private func closeFocusedPanel() -> Bool {
        guard let store else { return false }
        guard let preferredWindowID = closePanelShortcutWindowID() else { return false }
        let preferredWorkspaceID = store.commandSelection(preferredWindowID: preferredWindowID)?.workspace.id
        guard focusedPanelCommandController.closeFocusedPanel(in: preferredWorkspaceID).consumesShortcut else {
            // Cmd+W is app-owned for normal workspace windows. If there is no
            // panel to close in that context, swallow the shortcut rather than
            // falling back to AppKit's native window-close path.
            return preferredWorkspaceID != nil
        }
        return true
    }

    private func switchWorkspace(shortcutNumber: Int) -> Bool {
        guard let store else { return false }
        guard shortcutNumber > 0, shortcutNumber <= DisplayShortcutConfig.maxWorkspaceShortcutCount else {
            return false
        }
        guard let window = store.selectedWindow else { return false }
        let index = shortcutNumber - 1
        guard window.workspaceIDs.indices.contains(index) else { return false }
        let workspaceID = window.workspaceIDs[index]
        guard store.state.workspacesByID[workspaceID] != nil else { return false }
        return store.send(.selectWorkspace(windowID: window.id, workspaceID: workspaceID))
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
    @StateObject private var agentCatalogStore: AgentCatalogStore
    @StateObject private var terminalProfileStore: TerminalProfileStore
    private let appWindowSceneCoordinator: AppWindowSceneCoordinator
    @StateObject private var terminalRuntimeRegistry: TerminalRuntimeRegistry
    @StateObject private var sessionRuntimeStore: SessionRuntimeStore
    private let automationLifecycle: AutomationLifecycle?
    private let automationSocketServer: AutomationSocketServer?
    private let automationStartupError: String?
    private let disableAnimations: Bool
    private let workspaceLayoutPersistenceCoordinator: WorkspaceLayoutPersistenceCoordinator?
    private let workspaceLayoutPersistenceObserverToken: UUID?
    private let appTerminationObserver: AppTerminationObserver?
    private let appResignActiveObserver: AppResignActiveObserver
    private let agentLaunchService: AgentLaunchService
    private let systemNotificationResponseCoordinator: SystemNotificationResponseCoordinator
    private let fileSplitMenuBridge: FileSplitMenuBridge
    private let fileCloseMenuBridge: FileCloseMenuBridge
    private let windowSplitMenuBridge: WindowSplitMenuBridge
    private let helpMenuBridge: HelpMenuBridge
    private let hiddenSystemMenuItemsBridge: HiddenSystemMenuItemsBridge
    private let terminalProfilesMenuController: TerminalProfilesMenuController
    private let focusedPanelCommandController: FocusedPanelCommandController
    private let displayShortcutInterceptor: DisplayShortcutInterceptor

    private var profileShortcutRegistry: ProfileShortcutRegistry {
        Self.makeProfileShortcutRegistry(
            terminalProfiles: terminalProfileStore.catalog,
            terminalProfilesFilePath: terminalProfileStore.fileURL.path,
            agentProfiles: agentCatalogStore.catalog,
            agentProfilesFilePath: agentCatalogStore.fileURL.path
        )
    }

    init() {
        let processInfo = ProcessInfo.processInfo
        Self.prepareRuntimeEnvironment(processInfo: processInfo)
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
        Self.recordRuntimeInstance(processInfo: processInfo, automationConfig: bootstrap.automationConfig)
        let persistUserSettings = bootstrap.automationConfig == nil
        let store = AppStore(
            state: bootstrap.state,
            persistTerminalFontPreference: persistUserSettings,
            initialHasEverLaunchedAgent: initialToasttySettings.hasEverLaunchedAgent
        )
        let agentCatalogStore = AgentCatalogStore()
        let initialProfileShortcutRegistry = Self.makeProfileShortcutRegistry(
            terminalProfiles: terminalProfileStore.catalog,
            terminalProfilesFilePath: terminalProfileStore.fileURL.path,
            agentProfiles: agentCatalogStore.catalog,
            agentProfilesFilePath: agentCatalogStore.fileURL.path
        )
        Self.logProfileShortcutWarnings(initialProfileShortcutRegistry.warningMessages)
        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        terminalRuntimeRegistry.bind(sessionLifecycleTracker: sessionRuntimeStore)
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
        if persistUserSettings {
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
        let splitLayoutCommandController = SplitLayoutCommandController(store: store)
        let closeWorkspaceCommandController = CloseWorkspaceCommandController(
            store: store,
            preferredWindowIDProvider: { currentToasttyKeyWindowID(in: store) }
        )
        fileSplitMenuBridge = FileSplitMenuBridge(
            splitLayoutCommandController: splitLayoutCommandController
        )
        fileCloseMenuBridge = FileCloseMenuBridge(
            windowCommandController: WindowCommandController(
                store: store,
                focusedPanelCommandController: focusedPanelCommandController,
                preferredWindowIDProvider: { currentToasttyKeyWindowID(in: store) }
            ),
            closeWorkspaceCommandController: closeWorkspaceCommandController
        )
        windowSplitMenuBridge = WindowSplitMenuBridge(
            splitLayoutCommandController: splitLayoutCommandController
        )
        helpMenuBridge = HelpMenuBridge()
        hiddenSystemMenuItemsBridge = HiddenSystemMenuItemsBridge()
        terminalProfilesMenuController = TerminalProfilesMenuController(
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            installShellIntegrationAction: ToasttyMenuActions.installShellIntegration,
            openProfilesConfigurationAction: ToasttyMenuActions.openTerminalProfilesConfiguration
        )
        displayShortcutInterceptor = DisplayShortcutInterceptor(
            store: store,
            focusedPanelCommandController: focusedPanelCommandController
        )
        _store = StateObject(wrappedValue: store)
        _agentCatalogStore = StateObject(wrappedValue: agentCatalogStore)
        _terminalProfileStore = StateObject(wrappedValue: terminalProfileStore)
        appWindowSceneCoordinator = AppWindowSceneCoordinator()
        _terminalRuntimeRegistry = StateObject(wrappedValue: terminalRuntimeRegistry)
        _sessionRuntimeStore = StateObject(wrappedValue: sessionRuntimeStore)
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

        let socketPath = bootstrap.automationConfig?.socketPath
            ?? AutomationConfig.resolveServerSocketPath(environment: ProcessInfo.processInfo.environment)
        agentLaunchService = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: agentCatalogStore,
            socketPathProvider: { socketPath }
        )
        do {
            automationSocketServer = try AutomationSocketServer(
                socketPath: socketPath,
                automationConfig: bootstrap.automationConfig,
                store: store,
                terminalRuntimeRegistry: terminalRuntimeRegistry,
                sessionRuntimeStore: sessionRuntimeStore,
                focusedPanelCommandController: focusedPanelCommandController,
                agentLaunchService: agentLaunchService
            )
            automationStartupError = nil
        } catch {
            automationSocketServer = nil
            automationStartupError = "Automation socket startup failed: \(error.localizedDescription)"
            if let messageData = ("toastty automation error: \(automationStartupError ?? "unknown")\n").data(using: .utf8) {
                FileHandle.standardError.write(messageData)
            }
        }

        appLifecycleDelegate.configureMenuBridges(
            fileSplitMenuBridge: fileSplitMenuBridge,
            fileCloseMenuBridge: fileCloseMenuBridge,
            windowSplitMenuBridge: windowSplitMenuBridge,
            helpMenuBridge: helpMenuBridge,
            hiddenSystemMenuItemsBridge: hiddenSystemMenuItemsBridge
        )
        appLifecycleDelegate.configureStore(store)
    }

    var body: some Scene {
        WindowGroup(id: AppWindowSceneID.value) {
            AppWindowSceneHostView(
                store: store,
                agentCatalogStore: agentCatalogStore,
                terminalProfileStore: terminalProfileStore,
                terminalRuntimeRegistry: terminalRuntimeRegistry,
                sessionRuntimeStore: sessionRuntimeStore,
                profileShortcutRegistry: profileShortcutRegistry,
                agentLaunchService: agentLaunchService,
                openAgentProfilesConfiguration: openAgentProfilesConfiguration,
                sceneCoordinator: appWindowSceneCoordinator,
                automationLifecycle: automationLifecycle,
                automationStartupError: automationStartupError,
                disableAnimations: disableAnimations
            )
            .frame(minWidth: 980, minHeight: 620)
            .onAppear {
                appLifecycleDelegate.sceneDidAppear()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            ToasttyCommandMenus(
                store: store,
                agentCatalogStore: agentCatalogStore,
                terminalProfileStore: terminalProfileStore,
                sessionRuntimeStore: sessionRuntimeStore,
                profileShortcutRegistry: profileShortcutRegistry,
                focusedPanelCommandController: focusedPanelCommandController,
                agentLaunchService: agentLaunchService,
                terminalProfilesMenuController: terminalProfilesMenuController,
                supportsConfigurationReload: supportsConfigurationReload,
                reloadConfiguration: reloadConfiguration,
                openAgentProfilesConfiguration: openAgentProfilesConfiguration
            )
        }
    }

    private var supportsConfigurationReload: Bool {
        true
    }

    @MainActor
    private func reloadConfiguration() {
        var failureMessages: [String] = []
        var warningMessages: [String] = []

        switch agentCatalogStore.reload() {
        case .success:
            break
        case .failure(let error):
            failureMessages.append(error.localizedDescription)
        }

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
            terminalRuntimeRegistry.applyGhosttyScrollbarPreferenceChange()
        } else {
            failureMessages.append("Failed to reload embedded Ghostty configuration.")
            Self.applyToasttyTerminalFontState(
                to: store,
                toasttyConfig: toasttyConfig,
                toasttySettings: toasttySettings,
                ghosttyConfiguredTerminalFontPoints: runtimeManager.configuredTerminalFontPoints
            )
            terminalRuntimeRegistry.applyGhosttyScrollbarPreferenceChange()
        }
        #else
        Self.applyToasttyTerminalFontState(
            to: store,
            toasttyConfig: toasttyConfig,
            toasttySettings: toasttySettings,
            ghosttyConfiguredTerminalFontPoints: nil
        )
        #endif

        let resolvedProfileShortcutRegistry = profileShortcutRegistry
        warningMessages.append(contentsOf: resolvedProfileShortcutRegistry.warningMessages)
        Self.logProfileShortcutWarnings(warningMessages)

        guard failureMessages.isEmpty == false || warningMessages.isEmpty == false else { return }

        let alert = NSAlert()
        alert.messageText = failureMessages.isEmpty
            ? "Configuration Reload Warnings"
            : "Unable to Reload Configuration"
        alert.informativeText = (failureMessages + warningMessages).joined(separator: "\n")
        alert.alertStyle = failureMessages.isEmpty ? .informational : .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @MainActor
    private func openAgentProfilesConfiguration() {
        do {
            try AgentProfilesFile.ensureTemplateExists()
            NSWorkspace.shared.open(AgentProfilesFile.fileURL())
        } catch {
            let alert = NSAlert()
            alert.messageText = "Unable to Open Agent Profiles"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
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

    private static func makeProfileShortcutRegistry(
        terminalProfiles: TerminalProfileCatalog,
        terminalProfilesFilePath: String,
        agentProfiles: AgentCatalog,
        agentProfilesFilePath: String
    ) -> ProfileShortcutRegistry {
        ProfileShortcutRegistry(
            terminalProfiles: terminalProfiles,
            terminalProfilesFilePath: terminalProfilesFilePath,
            agentProfiles: agentProfiles,
            agentProfilesFilePath: agentProfilesFilePath
        )
    }

    private static func logProfileShortcutWarnings(_ warnings: [String]) {
        for warning in warnings {
            ToasttyLog.warning(
                warning,
                category: .bootstrap
            )
        }
    }

    @MainActor
    private static func configureWindowPersistenceDefaults() {
        NSWindow.allowsAutomaticWindowTabbing = false

        // Toastty persists window/workspace state explicitly, so AppKit's
        // saved-state restoration only adds stale SwiftUI scene identifiers.
        let defaults = ToasttyAppDefaults.current
        defaults.set(true, forKey: "ApplePersistenceIgnoreState")
        defaults.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    private static func prepareRuntimeEnvironment(processInfo: ProcessInfo) {
        do {
            try ToasttyRuntimePaths.resolve(environment: processInfo.environment).prepare()
        } catch {
            if let errorData = "toastty runtime preparation failed: \(error.localizedDescription)\n".data(using: .utf8) {
                FileHandle.standardError.write(errorData)
            }
        }
    }

    private static func recordRuntimeInstance(processInfo: ProcessInfo, automationConfig: AutomationConfig?) {
        ToasttyRuntimeInstanceRecorder.recordLaunch(
            processInfo: processInfo,
            automationConfig: automationConfig
        )
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
