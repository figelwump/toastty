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
    @StateObject private var agentCatalogStore: AgentCatalogStore
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
    private let closeWindowMenuBridge: CloseWindowMenuBridge
    private let helpMenuBridge: HelpMenuBridge
    private let hiddenSystemMenuItemsBridge: HiddenSystemMenuItemsBridge
    private let focusedPanelCommandController: FocusedPanelCommandController
    private let focusTerminalShortcutInterceptor: FocusTerminalShortcutInterceptor

    init() {
        Self.configureWindowPersistenceDefaults()
        let bootstrap = AppBootstrap.make()
        let persistTerminalFontPreference = bootstrap.automationConfig == nil
        let store = AppStore(
            state: bootstrap.state,
            persistTerminalFontPreference: persistTerminalFontPreference
        )
        let agentCatalogStore = AgentCatalogStore()
        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        terminalRuntimeRegistry.bind(sessionLifecycleTracker: sessionRuntimeStore)
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
        _agentCatalogStore = StateObject(wrappedValue: agentCatalogStore)
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
    }

    var body: some Scene {
        WindowGroup(id: AppWindowSceneID.value) {
            AppWindowSceneHostView(
                store: store,
                terminalRuntimeRegistry: terminalRuntimeRegistry,
                sessionRuntimeStore: sessionRuntimeStore,
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
        .windowStyle(.hiddenTitleBar)
        .commands {
            ToasttyCommandMenus(
                store: store,
                agentCatalogStore: agentCatalogStore,
                focusedPanelCommandController: focusedPanelCommandController,
                agentLaunchService: agentLaunchService,
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

        switch agentCatalogStore.reload() {
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

        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "ApplePersistenceIgnoreState")
        defaults.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }
}
