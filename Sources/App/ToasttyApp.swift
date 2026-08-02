import AppKit
import CoreState
import SwiftUI

enum KeyboardShortcutsReferenceLocator {
    private static let fileName = "keyboard-shortcuts"
    private static let fileExtension = "md"

    static func bundledReferenceURL(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: fileName, withExtension: fileExtension)
    }

    static func referenceURL(
        worktreeRootURL: URL?,
        bundledReferenceURL: URL?,
        fileManager: FileManager = .default
    ) -> URL? {
        if let worktreeRootURL {
            let localReferenceURL = worktreeRootURL
                .appending(path: "docs", directoryHint: .isDirectory)
                .appending(path: "\(fileName).\(fileExtension)", directoryHint: .notDirectory)
            if fileManager.fileExists(atPath: localReferenceURL.path) {
                return localReferenceURL
            }
        }

        return bundledReferenceURL
    }

    static func openReferenceResult(
        runtimePaths: ToasttyRuntimePaths = .resolve(),
        fileManager: FileManager = .default,
        bundledReferenceURL: URL? = bundledReferenceURL(),
        openURL: (URL) -> Bool
    ) -> Result<Void, AgentGetStartedActionError> {
        guard let referenceURL = referenceURL(
            worktreeRootURL: runtimePaths.worktreeRootURL,
            bundledReferenceURL: bundledReferenceURL,
            fileManager: fileManager
        ) else {
            return .failure(
                AgentGetStartedActionError(
                    message: "Toastty couldn't find the keyboard shortcuts reference."
                )
            )
        }

        guard openURL(referenceURL) else {
            return .failure(
                AgentGetStartedActionError(
                    message: "Toastty couldn't open the keyboard shortcuts reference."
                )
            )
        }
        return .success(())
    }
}

typealias ManagedLocalDocumentOpener = @MainActor (URL, LocalDocumentFormat) -> Bool

enum AppKitDefaultPreferences {
    static let initialToolTipDelayKey = "NSInitialToolTipDelay"
    static let initialToolTipDelayMilliseconds = 250
    static let applePersistenceIgnoreStateKey = "ApplePersistenceIgnoreState"
    static let quitAlwaysKeepsWindowsKey = "NSQuitAlwaysKeepsWindows"

    static func apply(to defaults: UserDefaults, standardDefaults: UserDefaults = .standard) {
        registerToolTipTiming(in: defaults)
        if defaults !== standardDefaults {
            registerToolTipTiming(in: standardDefaults)
        }

        defaults.set(true, forKey: applePersistenceIgnoreStateKey)
        defaults.set(false, forKey: quitAlwaysKeepsWindowsKey)
    }

    static func registerToolTipTiming(in defaults: UserDefaults) {
        defaults.register(defaults: [
            initialToolTipDelayKey: initialToolTipDelayMilliseconds,
        ])
    }
}

@MainActor
private func openManagedLocalDocumentInToastty(
    store: AppStore,
    fileURL: URL,
    format: LocalDocumentFormat,
    preferredWindowID: UUID?
) -> Bool {
    let normalizedFilePath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
    guard normalizedFilePath.isEmpty == false else {
        return false
    }

    return store.createLocalDocumentPanelFromCommand(
        preferredWindowID: preferredWindowID,
        request: LocalDocumentPanelCreateRequest(
            filePath: normalizedFilePath,
            placementOverride: store.localDocumentRoutingPreferences.openingPlacement.webPanelPlacement,
            formatOverride: format
        )
    )
}

@MainActor
enum ToasttyMenuActions {
    static func openTerminalProfilesConfiguration(
        openManagedLocalDocument: ManagedLocalDocumentOpener = { _, _ in false },
        openExternally: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        switch openTerminalProfilesConfigurationResult(
            openManagedLocalDocument: openManagedLocalDocument,
            openExternally: openExternally
        ) {
        case .success:
            return
        case .failure(let error):
            presentWarningAlert(
                title: "Unable to Open Terminal Profiles",
                message: error.localizedDescription
            )
        }
    }

    static func openTerminalProfilesConfigurationResult(
        fileManager: FileManager = .default,
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        openManagedLocalDocument: ManagedLocalDocumentOpener = { _, _ in false },
        openExternally: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> Result<Void, AgentGetStartedActionError> {
        openConfigurationFile(
            prepareFile: {
                try TerminalProfilesFile.ensureTemplateExists(
                    fileManager: fileManager,
                    homeDirectoryPath: homeDirectoryPath,
                    environment: environment
                )
            },
            fileURL: TerminalProfilesFile.fileURL(
                homeDirectoryPath: homeDirectoryPath,
                environment: environment
            ),
            fileFormat: .toml,
            openManagedLocalDocument: openManagedLocalDocument,
            openExternally: openExternally
        )
    }

    static func openAgentProfilesConfigurationResult(
        fileManager: FileManager = .default,
        homeDirectoryPath: String = NSHomeDirectory(),
        openManagedLocalDocument: ManagedLocalDocumentOpener = { _, _ in false },
        openExternally: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> Result<Void, AgentGetStartedActionError> {
        openConfigurationFile(
            prepareFile: {
                try AgentProfilesFile.ensureTemplateExists(
                    fileManager: fileManager,
                    homeDirectoryPath: homeDirectoryPath
                )
            },
            fileURL: AgentProfilesFile.fileURL(homeDirectoryPath: homeDirectoryPath),
            fileFormat: .toml,
            openManagedLocalDocument: openManagedLocalDocument,
            openExternally: openExternally
        )
    }

    static func openToasttyConfigResult(
        fileManager: FileManager = .default,
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        openManagedLocalDocument: ManagedLocalDocumentOpener = { _, _ in false },
        openExternally: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> Result<Void, AgentGetStartedActionError> {
        openConfigurationFile(
            prepareFile: {
                try ToasttyConfigStore.ensureTemplateExists(
                    fileManager: fileManager,
                    homeDirectoryPath: homeDirectoryPath,
                    environment: environment
                )
            },
            fileURL: ToasttyConfigStore.configFileURL(
                homeDirectoryPath: homeDirectoryPath,
                environment: environment
            ),
            fileFormat: .toml,
            openManagedLocalDocument: openManagedLocalDocument,
            openExternally: openExternally
        )
    }

    static func openConfigReferenceResult(
        fileManager: FileManager = .default,
        homeDirectoryPath: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        openManagedLocalDocument: ManagedLocalDocumentOpener = { _, _ in false },
        openExternally: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> Result<Void, AgentGetStartedActionError> {
        openConfigurationFile(
            prepareFile: {
                try ToasttyConfigStore.writeConfigReference(
                    fileManager: fileManager,
                    homeDirectoryPath: homeDirectoryPath,
                    environment: environment
                )
            },
            fileURL: ToasttyConfigStore.configReferenceFileURL(
                homeDirectoryPath: homeDirectoryPath,
                environment: environment
            ),
            fileFormat: .toml,
            openManagedLocalDocument: openManagedLocalDocument,
            openExternally: openExternally
        )
    }

    static func openKeyboardShortcutsReferenceResult(
        runtimePaths: ToasttyRuntimePaths = .resolve(),
        fileManager: FileManager = .default,
        bundledReferenceURL: URL? = KeyboardShortcutsReferenceLocator.bundledReferenceURL(),
        openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> Result<Void, AgentGetStartedActionError> {
        KeyboardShortcutsReferenceLocator.openReferenceResult(
            runtimePaths: runtimePaths,
            fileManager: fileManager,
            bundledReferenceURL: bundledReferenceURL,
            openURL: openURL
        )
    }

    static func installShellIntegration() {
        installShellIntegration(preferredShellPath: nil)
    }

    static func installShellIntegration(
        preferredShellPath: String?,
        preferredShellSource: ProfileShellIntegrationResolvedShellSource = .liveTerminalShell
    ) {
        let installer = ProfileShellIntegrationInstaller(
            preferredShellPath: preferredShellPath,
            preferredShellSource: preferredShellSource
        )
        let status: ProfileShellIntegrationInstallStatus

        do {
            status = try installer.installationStatus()
        } catch {
            presentWarningAlert(
                title: "Unable to Install Shell Integration",
                message: error.localizedDescription
            )
            return
        }

        if status.isInstalled {
            let alert = NSAlert()
            alert.messageText = "Shell Integration Already Installed"
            alert.informativeText = ProfileShellIntegrationMessaging.alreadyInstalledSummary(for: status)
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let confirmationAlert = NSAlert()
        confirmationAlert.messageText = "Install Shell Integration?"
        confirmationAlert.informativeText = ProfileShellIntegrationMessaging.installationPlanSummary(for: status)
        confirmationAlert.alertStyle = .informational
        confirmationAlert.addConfiguredButton(withTitle: "Install", behavior: .defaultAction)
        confirmationAlert.addConfiguredButton(withTitle: "Cancel", behavior: .cancelAction)

        guard confirmationAlert.runModal() == .alertFirstButtonReturn else {
            return
        }

        do {
            let result = try installer.install(plan: status.plan)
            let alert = NSAlert()
            alert.messageText = "Shell Integration Installed"
            alert.informativeText = ProfileShellIntegrationMessaging.installationCompletionSummary(for: result)
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } catch {
            presentWarningAlert(
                title: "Unable to Install Shell Integration",
                message: error.localizedDescription
            )
        }
    }

    private static func openConfigurationFile(
        prepareFile: () throws -> Void,
        fileURL: URL,
        fileFormat: LocalDocumentFormat,
        openManagedLocalDocument: ManagedLocalDocumentOpener,
        openExternally: (URL) -> Bool
    ) -> Result<Void, AgentGetStartedActionError> {
        do {
            try prepareFile()
        } catch {
            return .failure(AgentGetStartedActionError(message: error.localizedDescription))
        }

        if openManagedLocalDocument(fileURL, fileFormat) {
            return .success(())
        }

        return openExistingFile(fileURL, openExternally: openExternally)
    }

    private static func openExistingFile(
        _ fileURL: URL,
        openExternally: (URL) -> Bool
    ) -> Result<Void, AgentGetStartedActionError> {
        guard openExternally(fileURL) else {
            return .failure(
                AgentGetStartedActionError(message: "Toastty couldn't open \(fileURL.path).")
            )
        }
        return .success(())
    }

    private static func presentWarningAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
    private weak var terminalRuntimeRegistry: TerminalRuntimeRegistry?
    private weak var webPanelRuntimeRegistry: WebPanelRuntimeRegistry?
    private var fileSplitMenuBridge: FileSplitMenuBridge?
    private var fileCloseMenuBridge: FileCloseMenuBridge?
    private var windowSplitMenuBridge: WindowSplitMenuBridge?
    private var workspaceMenuBridge: WorkspaceMenuBridge?
    private var helpMenuBridge: HelpMenuBridge?
    private var hiddenSystemMenuItemsBridge: HiddenSystemMenuItemsBridge?
    private var hasCompletedLaunch = false
    private var menuBridgeInstallationTask: Task<Void, Never>?

    override init() {
        let processInfo = ProcessInfo.processInfo
        let isInteractiveSession = Self.isInteractiveSession(processInfo)
        shouldConfirmQuit = isInteractiveSession
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

    func configureTerminalRuntimeRegistry(_ terminalRuntimeRegistry: TerminalRuntimeRegistry) {
        self.terminalRuntimeRegistry = terminalRuntimeRegistry
    }

    func configureWebPanelRuntimeRegistry(_ webPanelRuntimeRegistry: WebPanelRuntimeRegistry) {
        self.webPanelRuntimeRegistry = webPanelRuntimeRegistry
    }

    func configureMenuBridges(
        fileSplitMenuBridge: FileSplitMenuBridge,
        fileCloseMenuBridge: FileCloseMenuBridge,
        windowSplitMenuBridge: WindowSplitMenuBridge,
        workspaceMenuBridge: WorkspaceMenuBridge,
        helpMenuBridge: HelpMenuBridge,
        hiddenSystemMenuItemsBridge: HiddenSystemMenuItemsBridge
    ) {
        self.fileSplitMenuBridge = fileSplitMenuBridge
        self.fileCloseMenuBridge = fileCloseMenuBridge
        self.windowSplitMenuBridge = windowSplitMenuBridge
        self.workspaceMenuBridge = workspaceMenuBridge
        self.helpMenuBridge = helpMenuBridge
        self.hiddenSystemMenuItemsBridge = hiddenSystemMenuItemsBridge
        hiddenSystemMenuItemsBridge.setOnOwnedMenuSectionRefreshRequested { [weak self] in
            self?.installOwnedMenuSections()
        }
        hiddenSystemMenuItemsBridge.setOnDynamicMenuBridgeRefreshRequested { [weak self] in
            self?.installDynamicMenuBridges()
        }

        guard hasCompletedLaunch else { return }
        scheduleMenuBridgeInstallations()
    }

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        Task { @MainActor [weak self] in
            ToasttyApplicationIconPolicy.applyLegacySwitcherIconIfNeeded()
            self?.hasCompletedLaunch = true
            self?.scheduleMenuBridgeInstallations()
        }
    }

    nonisolated func applicationDidBecomeActive(_ notification: Notification) {
        _ = notification
        #if TOASTTY_HAS_GHOSTTY_KIT
        Task { @MainActor [weak self] in
            self?.hasCompletedLaunch = true
            self?.scheduleMenuBridgeInstallations()
            GhosttyRuntimeManager.shared.setAppFocus(true)
            self?.terminalRuntimeRegistry?.synchronizeGhosttySurfaceFocusFromApplicationState()
        }
        #else
        Task { @MainActor [weak self] in
            self?.hasCompletedLaunch = true
            self?.scheduleMenuBridgeInstallations()
        }
        #endif
    }

    nonisolated func applicationDidResignActive(_ notification: Notification) {
        _ = notification
        #if TOASTTY_HAS_GHOSTTY_KIT
        Task { @MainActor [weak self] in
            _ = self?.terminalRuntimeRegistry?.resetTrackedGhosttyModifiersForApplicationDeactivation()
            GhosttyRuntimeManager.shared.setAppFocus(false)
            self?.terminalRuntimeRegistry?.synchronizeGhosttySurfaceFocusFromApplicationState()
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
        _ = sender
        guard shouldConfirmQuit else { return .terminateNow }
        guard let store else {
            return presentQuitConfirmationAlert(assessment: nil, store: nil) ? .terminateNow : .terminateCancel
        }
        guard store.askBeforeQuitting else { return .terminateNow }

        let assessment = quitConfirmationAssessment(state: store.state)
        guard let assessment else {
            return presentQuitConfirmationAlert(assessment: nil, store: nil) ? .terminateNow : .terminateCancel
        }
        guard assessment.requiresConfirmation else { return .terminateNow }

        return presentQuitConfirmationAlert(assessment: assessment, store: store) ? .terminateNow : .terminateCancel
    }

    private func presentQuitConfirmationAlert(
        assessment: AppQuitConfirmationAssessment?,
        store: AppStore?
    ) -> Bool {
        let confirmationAlert = NSAlert()
        if assessment?.allowsDestructiveConfirmation == false {
            confirmationAlert.messageText = "Document save in progress"
        } else {
            confirmationAlert.messageText = "Quit Toastty?"
        }
        confirmationAlert.informativeText = assessment?.informativeText ?? "Are you sure you want to quit?"
        confirmationAlert.alertStyle = .warning
        if assessment != nil,
           assessment?.allowsDestructiveConfirmation != false {
            confirmationAlert.showsSuppressionButton = true
            confirmationAlert.suppressionButton?.title = "Always quit without asking"
        }
        if assessment?.allowsDestructiveConfirmation == false {
            confirmationAlert.addConfiguredButton(withTitle: "OK", behavior: .defaultAction)
        } else {
            confirmationAlert.addConfiguredButton(withTitle: "Cancel", behavior: .cancelAction)
            confirmationAlert.addConfiguredButton(
                withTitle: "Quit",
                behavior: .defaultAction
            )
        }

        let response = confirmationAlert.runModal()
        // Toastty keeps the visual button order as Cancel, then Quit, so the
        // confirmed quit response remains `.alertSecondButtonReturn`.
        let didConfirmQuit = assessment?.allowsDestructiveConfirmation == false ?
            false :
            response == .alertSecondButtonReturn
        if didConfirmQuit,
           assessment != nil,
           confirmationAlert.suppressionButton?.state == .on {
            store?.setAskBeforeQuitting(false)
            _ = ToasttyAppDefaults.current.synchronize()
        }
        return didConfirmQuit
    }

    private func quitConfirmationAssessment(state: AppState) -> AppQuitConfirmationAssessment? {
        guard let terminalRuntimeRegistry,
              let webPanelRuntimeRegistry else {
            return nil
        }
        return AppQuitConfirmation.assess(
            state: state,
            terminalAssessment: { panelID in
                terminalRuntimeRegistry.terminalCloseConfirmationAssessment(panelID: panelID)
            },
            localDocumentCloseConfirmationState: { panelID in
                webPanelRuntimeRegistry.localDocumentCloseConfirmationState(panelID: panelID)
            }
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard flag == false else { return true }
        guard let store else { return true }

        // If Toastty has no hidden windows to restore, let AppKit continue
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
        workspaceMenuBridge?.installIfNeeded()
        helpMenuBridge?.installIfNeeded()
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
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self)
    private var appLifecycleDelegate
    @StateObject private var store: AppStore
    @StateObject private var agentCatalogStore: AgentCatalogStore
    @StateObject private var terminalProfileStore: TerminalProfileStore
    @StateObject private var sparkleUpdaterBridge: SparkleUpdaterBridge
    private let appWindowSceneCoordinator: AppWindowSceneCoordinator
    @StateObject private var terminalRuntimeRegistry: TerminalRuntimeRegistry
    @StateObject private var webPanelRuntimeRegistry: WebPanelRuntimeRegistry
    @StateObject private var sessionRuntimeStore: SessionRuntimeStore
    private let automationLifecycle: AutomationLifecycle?
    private let automationSocketServer: AutomationSocketServer?
    private let automationStartupError: String?
    private let disableAnimations: Bool
    private let runtimePaths: ToasttyRuntimePaths
    private let agentLaunchSocketPath: String
    private let agentLaunchCLIExecutablePath: String?
    private let agentLaunchShimExecutablePath: String?
    private let workspaceLayoutPersistenceCoordinator: WorkspaceLayoutPersistenceCoordinator?
    private let workspaceLayoutPersistenceObserverToken: UUID?
    private let appTerminationObserver: AppTerminationObserver?
    private let scratchpadSessionLinkCleanupCoordinator: ScratchpadSessionLinkCleanupCoordinator
    private let agentLaunchService: AgentLaunchService
    private let systemNotificationResponseCoordinator: SystemNotificationResponseCoordinator
    private let fileSplitMenuBridge: FileSplitMenuBridge
    private let fileCloseMenuBridge: FileCloseMenuBridge
    private let windowSplitMenuBridge: WindowSplitMenuBridge
    private let workspaceMenuBridge: WorkspaceMenuBridge
    private let helpMenuBridge: HelpMenuBridge
    private let hiddenSystemMenuItemsBridge: HiddenSystemMenuItemsBridge
    private let terminalProfilesMenuController: TerminalProfilesMenuController
    private let focusedPanelCommandController: FocusedPanelCommandController
    private let processWatchCommandController: ProcessWatchCommandController
    private let commandPaletteController: CommandPaletteController
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
        let runtimePaths = ToasttyRuntimePaths.resolve(environment: processInfo.environment)
        let isInteractiveSession = AppLifecycleDelegate.isInteractiveSession(processInfo)
        Self.prepareRuntimeEnvironment(processInfo: processInfo)
        Self.ensureTerminalProfilesTemplateExists()
        Self.refreshManagedShellIntegrationSnippetIfInstalled(processInfo: processInfo)
        Self.configureWindowPersistenceDefaults()
        let usesPersistentPreferences = AutomationConfig.parse(
            arguments: processInfo.arguments,
            environment: processInfo.environment
        ) == nil
        let terminalProfileStore = TerminalProfileStore()
        let initialToasttyConfig = usesPersistentPreferences ? ToasttyConfigStore.load() : ToasttyConfig()
        let initialToasttySettings = usesPersistentPreferences ? ToasttySettingsStore.load() : ToasttySettings()
        let legacyTerminalFontSizePoints = usesPersistentPreferences
            ? ToasttySettingsStore.legacyTerminalFontSizePoints()
            : nil
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
        if usesPersistentPreferences {
            Self.prunePaneRestoreFiles(
                runtimePaths: runtimePaths,
                liveTerminalPanelIDs: bootstrap.state.allTerminalPanelIDs
            )
        }
        let preferredSocketPath = bootstrap.automationConfig?.socketPath
            ?? AutomationConfig.resolveServerSocketPath(environment: processInfo.environment)
        let socketPath = AutomationSocketServer.recommendedSocketPath(
            preferredSocketPath: preferredSocketPath,
            environment: processInfo.environment
        )
        bootstrap.automationLifecycle?.updateSocketPath(socketPath)
        Self.recordRuntimeInstance(
            processInfo: processInfo,
            automationConfig: bootstrap.automationConfig,
            socketPathOverride: socketPath
        )
        let persistUserSettings = bootstrap.automationConfig == nil
        let store = AppStore(
            state: bootstrap.state,
            persistTerminalFontPreference: persistUserSettings,
            initialHasEverLaunchedAgent: initialToasttySettings.hasEverLaunchedAgent,
            initialAskBeforeQuitting: initialToasttySettings.askBeforeQuitting,
            recentRightPanelItemsStore: RightPanelRecentItemsStore(runtimePaths: runtimePaths)
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
        let webPanelRuntimeRegistry = WebPanelRuntimeRegistry()
        let resolvedManagedHelperPaths: ManagedAgentHelperPaths
        do {
            resolvedManagedHelperPaths = try ManagedAgentHelperInstaller(
                runtimePaths: runtimePaths
            ).resolvePaths()
        } catch {
            resolvedManagedHelperPaths = ManagedAgentHelperPaths(
                cliExecutablePath: AgentLaunchService.defaultCLIExecutablePath(),
                agentShimExecutablePath: ToasttyBundledExecutableLocator.defaultAgentShimExecutablePath()
            )
            ToasttyLog.warning(
                "Failed to stage managed agent helpers",
                category: .bootstrap,
                metadata: [
                    "runtime_home": runtimePaths.runtimeHomeURL?.path ?? "none",
                    "runtime_home_enabled": runtimePaths.isRuntimeHomeEnabled ? "true" : "false",
                    "error": error.localizedDescription,
                ]
            )
        }
        let cliExecutablePath = resolvedManagedHelperPaths.cliExecutablePath
        let agentShimExecutablePath = resolvedManagedHelperPaths.agentShimExecutablePath
        let shimDirectoryPath: String?
        do {
            shimDirectoryPath = try Self.synchronizeManagedAgentCommandShims(
                enabled: initialToasttyConfig.enableAgentCommandShims,
                runtimePaths: runtimePaths,
                agentProfiles: agentCatalogStore.catalog,
                helperExecutablePath: agentShimExecutablePath
            )
        } catch {
            shimDirectoryPath = nil
            ToasttyLog.warning(
                "Failed to synchronize managed agent command shims",
                category: .bootstrap,
                metadata: [
                    "directory": runtimePaths.agentShimDirectoryURL.path,
                    "enabled": initialToasttyConfig.enableAgentCommandShims ? "true" : "false",
                    "helper_path": agentShimExecutablePath ?? "none",
                    "error": error.localizedDescription,
                ]
            )
        }
        Self.configureBaseLaunchEnvironmentProvider(
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            runtimePaths: runtimePaths,
            socketPath: socketPath,
            cliExecutablePath: cliExecutablePath,
            shimDirectoryPath: shimDirectoryPath,
            basePath: processInfo.environment["PATH"],
            agentBasePath: ManagedAgentBasePathResolver(
                environment: processInfo.environment,
                fallbackPath: nil
            ).resolve()
        )
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        terminalRuntimeRegistry.bind(sessionLifecycleTracker: sessionRuntimeStore)
        terminalRuntimeRegistry.setTerminalProfileProvider(
            terminalProfileStore,
            restoredTerminalPanelIDs: bootstrap.restoredTerminalPanelIDs
        )
        terminalRuntimeRegistry.setAgentCatalogProvider(agentCatalogStore)
        terminalRuntimeRegistry.bind(store: store)
        webPanelRuntimeRegistry.bind(store: store)
        terminalRuntimeRegistry.bind(webPanelRuntimeRegistry: webPanelRuntimeRegistry)
        let scratchpadSessionLinkCleanupCoordinator = ScratchpadSessionLinkCleanupCoordinator(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            documentStore: webPanelRuntimeRegistry.scratchpadDocumentStore
        )
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
                legacyTerminalFontSizePoints: legacyTerminalFontSizePoints
            )
            Self.ensureToasttyConfigTemplateExists()
        }
        Self.writeToasttyConfigReference()
        self.systemNotificationResponseCoordinator = systemNotificationResponseCoordinator
        self.scratchpadSessionLinkCleanupCoordinator = scratchpadSessionLinkCleanupCoordinator
        let focusedPanelCommandController = FocusedPanelCommandController(
            store: store,
            runtimeRegistry: terminalRuntimeRegistry,
            slotFocusRestoreCoordinator: slotFocusRestoreCoordinator,
            webPanelRuntimeRegistry: webPanelRuntimeRegistry
        )
        self.focusedPanelCommandController = focusedPanelCommandController
        let splitLayoutCommandController = SplitLayoutCommandController(store: store)
        terminalProfilesMenuController = TerminalProfilesMenuController(
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            terminalProfileProvider: terminalProfileStore,
            installShellIntegrationAction: { [store, terminalRuntimeRegistry] in
                ToasttyMenuActions.installShellIntegration(
                    preferredShellPath: terminalRuntimeRegistry.resolveShellIntegrationShellPath(
                        preferredWindowID: currentToasttyWorkspaceCommandWindowID(in: store)
                    )
                )
            },
            openProfilesConfigurationAction: { [store] in
                Self.openTerminalProfilesConfiguration(
                    store: store,
                    preferredWindowID: currentToasttyWorkspaceCommandWindowID(in: store)
                )
            }
        )
        agentLaunchService = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: agentCatalogStore,
            cliExecutablePathProvider: { cliExecutablePath },
            socketPathProvider: { socketPath }
        )
        terminalRuntimeRegistry.setRestoredManagedLaunchPlanner(agentLaunchService)
        let preferredWorkspaceCommandWindowID: () -> UUID? = {
            currentToasttyWorkspaceCommandWindowID(in: store)
        }
        let processWatchCommandController = ProcessWatchCommandController(
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            preferredWindowIDProvider: preferredWorkspaceCommandWindowID
        )
        let commandPaletteActionHandler = CommandPaletteActionHandler(
            store: store,
            splitLayoutCommandController: splitLayoutCommandController,
            focusedPanelCommandController: focusedPanelCommandController,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            agentLaunchService: agentLaunchService,
            terminalProfilesMenuController: terminalProfilesMenuController,
            supportsConfigurationReload: { true },
            reloadConfigurationAction: {
                Self.reloadConfiguration(
                    store: store,
                    agentCatalogStore: agentCatalogStore,
                    terminalProfileStore: terminalProfileStore,
                    runtimePaths: runtimePaths,
                    agentLaunchSocketPath: socketPath,
                    agentLaunchCLIExecutablePath: cliExecutablePath,
                    agentLaunchShimExecutablePath: agentShimExecutablePath,
                    terminalRuntimeRegistry: terminalRuntimeRegistry
                )
            },
            openLocalDocumentAction: { preferredWindowID, placement in
                Self.openLocalDocumentFile(
                    store: store,
                    preferredWindowID: preferredWindowID,
                    placement: placement
                )
            },
            createScratchpadAction: { preferredWindowID in
                Self.createBlankScratchpad(
                    store: store,
                    preferredWindowID: preferredWindowID,
                    documentStore: webPanelRuntimeRegistry.scratchpadDocumentStore
                )
            },
            showScratchpadForCurrentSessionAction: { preferredWindowID in
                store.showScratchpadForCurrentSession(
                    preferredWindowID: preferredWindowID,
                    sessionRuntimeStore: sessionRuntimeStore,
                    documentStore: webPanelRuntimeRegistry.scratchpadDocumentStore
                )
            },
            openManageConfigAction: { [store] originWindowID in
                Self.openManageConfig(store: store, preferredWindowID: originWindowID)
            },
            openTerminalProfilesConfigurationAction: { [store] originWindowID in
                Self.openTerminalProfilesConfiguration(store: store, preferredWindowID: originWindowID)
            },
            openAgentProfilesConfigurationAction: { [store] originWindowID in
                Self.openAgentProfilesConfiguration(store: store, preferredWindowID: originWindowID)
            },
            processWatchCommandController: processWatchCommandController
        )
        let commandPaletteUsageTracker = CommandPaletteUsageTracker(runtimePaths: runtimePaths)
        let commandPaletteController = CommandPaletteController(
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            actions: commandPaletteActionHandler,
            agentCatalogStore: agentCatalogStore,
            terminalProfileStore: terminalProfileStore,
            profileShortcutRegistryProvider: {
                Self.makeProfileShortcutRegistry(
                    terminalProfiles: terminalProfileStore.catalog,
                    terminalProfilesFilePath: terminalProfileStore.fileURL.path,
                    agentProfiles: agentCatalogStore.catalog,
                    agentProfilesFilePath: agentCatalogStore.fileURL.path
                )
            },
            usageTracker: commandPaletteUsageTracker
        )
        self.commandPaletteController = commandPaletteController
        let createWorkspaceCommandController = CreateWorkspaceCommandController(
            store: store,
            preferredWindowIDProvider: preferredWorkspaceCommandWindowID
        )
        let closeWorkspaceCommandController = CloseWorkspaceCommandController(
            store: store,
            preferredWindowIDProvider: { currentToasttyKeyWindowID(in: store) }
        )
        let renameWorkspaceCommandController = RenameWorkspaceCommandController(
            store: store,
            preferredWindowIDProvider: preferredWorkspaceCommandWindowID
        )
        let workspaceTabCommandController = WorkspaceTabCommandController(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            preferredWindowIDProvider: preferredWorkspaceCommandWindowID
        )
        self.processWatchCommandController = processWatchCommandController
        let workspaceClosePanelCommandController = WindowCommandController(
            store: store,
            focusedPanelCommandController: focusedPanelCommandController,
            preferredWindowIDProvider: preferredWorkspaceCommandWindowID
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
            splitLayoutCommandController: splitLayoutCommandController,
            preferredWindowIDProvider: { currentToasttyAppOwnedWindowID(in: store) }
        )
        workspaceMenuBridge = WorkspaceMenuBridge(
            windowCommandController: workspaceClosePanelCommandController,
            createWorkspaceCommandController: createWorkspaceCommandController,
            renameWorkspaceCommandController: renameWorkspaceCommandController,
            closeWorkspaceCommandController: closeWorkspaceCommandController,
            workspaceTabCommandController: workspaceTabCommandController,
            processWatchCommandController: processWatchCommandController
        )
        helpMenuBridge = HelpMenuBridge { [weak store] url in
            guard let store else { return }
            _ = AppURLRouter.open(
                url,
                preferredWindowID: currentToasttyWorkspaceCommandWindowID(in: store),
                appStore: store,
                requestLocalDocumentReveal: { [weak webPanelRuntimeRegistry] panelID, lineNumber in
                    webPanelRuntimeRegistry?.requestLocalDocumentReveal(panelID: panelID, lineNumber: lineNumber) ?? false
                }
            )
        }
        hiddenSystemMenuItemsBridge = HiddenSystemMenuItemsBridge()
        displayShortcutInterceptor = DisplayShortcutInterceptor(
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            webPanelRuntimeRegistry: webPanelRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            focusedPanelCommandController: focusedPanelCommandController,
            processWatchCommandController: processWatchCommandController,
            isCommandPalettePresented: { [weak commandPaletteController] in
                commandPaletteController?.isPresented ?? false
            },
            toggleCommandPalette: { [weak commandPaletteController] originWindowID in
                commandPaletteController?.toggle(originWindowID: originWindowID) ?? false
            }
        )
        _store = StateObject(wrappedValue: store)
        _agentCatalogStore = StateObject(wrappedValue: agentCatalogStore)
        _terminalProfileStore = StateObject(wrappedValue: terminalProfileStore)
        _sparkleUpdaterBridge = StateObject(
            wrappedValue: SparkleUpdaterBridge(startingUpdater: isInteractiveSession)
        )
        appWindowSceneCoordinator = AppWindowSceneCoordinator()
        _terminalRuntimeRegistry = StateObject(wrappedValue: terminalRuntimeRegistry)
        _webPanelRuntimeRegistry = StateObject(wrappedValue: webPanelRuntimeRegistry)
        _sessionRuntimeStore = StateObject(wrappedValue: sessionRuntimeStore)
        automationLifecycle = bootstrap.automationLifecycle
        disableAnimations = bootstrap.disableAnimations
        self.runtimePaths = runtimePaths
        agentLaunchSocketPath = socketPath
        agentLaunchCLIExecutablePath = cliExecutablePath
        agentLaunchShimExecutablePath = agentShimExecutablePath

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

        if socketPath != preferredSocketPath {
            ToasttyLog.warning(
                "Preferred automation socket path is already live; using a per-process fallback path",
                category: .automation,
                metadata: [
                    "preferred_socket_path": preferredSocketPath,
                    "socket_path": socketPath,
                    "pid": String(getpid()),
                ]
            )
        }
        do {
            automationSocketServer = try AutomationSocketServer(
                socketPath: socketPath,
                automationConfig: bootstrap.automationConfig,
                publishesDiscoveryRecord: true,
                store: store,
                terminalRuntimeRegistry: terminalRuntimeRegistry,
                webPanelRuntimeRegistry: webPanelRuntimeRegistry,
                sessionRuntimeStore: sessionRuntimeStore,
                focusedPanelCommandController: focusedPanelCommandController,
                agentLaunchService: agentLaunchService,
                reloadConfigurationAction: {
                    Self.reloadConfiguration(
                        store: store,
                        agentCatalogStore: agentCatalogStore,
                        terminalProfileStore: terminalProfileStore,
                        runtimePaths: runtimePaths,
                        agentLaunchSocketPath: socketPath,
                        agentLaunchCLIExecutablePath: cliExecutablePath,
                        agentLaunchShimExecutablePath: agentShimExecutablePath,
                        terminalRuntimeRegistry: terminalRuntimeRegistry
                    )
                }
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
            workspaceMenuBridge: workspaceMenuBridge,
            helpMenuBridge: helpMenuBridge,
            hiddenSystemMenuItemsBridge: hiddenSystemMenuItemsBridge
        )
        appLifecycleDelegate.configureStore(store)
        appLifecycleDelegate.configureTerminalRuntimeRegistry(terminalRuntimeRegistry)
        appLifecycleDelegate.configureWebPanelRuntimeRegistry(webPanelRuntimeRegistry)
        Self.scheduleCodexStatusHookMaintenanceIfNeeded(automationConfig: bootstrap.automationConfig)
    }

    private static func scheduleCodexStatusHookMaintenanceIfNeeded(
        automationConfig: AutomationConfig?
    ) {
        guard automationConfig == nil else { return }

        Task.detached(priority: .utility) {
            do {
                guard let result = try CodexStatusHookInstaller().performAutomaticMaintenanceIfNeeded() else {
                    return
                }
                ToasttyLog.info(
                    "Automatically maintained Codex status hooks",
                    category: .bootstrap,
                    metadata: [
                        "hooks_file": result.status.hooksFileURL.path,
                        "forwarder_script": result.status.forwarderScriptURL.path,
                        "hooks_file_changed": result.hooksFileChanged ? "true" : "false",
                        "forwarder_script_changed": result.forwarderScriptChanged ? "true" : "false",
                        "status": result.status.state.rawValue,
                    ]
                )
            } catch {
                ToasttyLog.warning(
                    "Failed automatic Codex status hook maintenance",
                    category: .bootstrap,
                    metadata: [
                        "error": error.localizedDescription,
                    ]
                )
            }
        }
    }

    private static func refreshManagedShellIntegrationSnippetIfInstalled(processInfo: ProcessInfo) {
        do {
            // Keep the managed snippet in sync for users who already opted into
            // shell integration, but do not touch login shell files here.
            _ = try ProfileShellIntegrationInstaller(
                environment: processInfo.environment
            ).refreshManagedSnippetIfInstalled()
        } catch {
            ToasttyLog.warning(
                "Failed to refresh managed shell integration snippet",
                category: .bootstrap,
                metadata: [
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    private static func synchronizeManagedAgentCommandShims(
        enabled: Bool,
        runtimePaths: ToasttyRuntimePaths,
        agentProfiles: AgentCatalog,
        helperExecutablePath: String?
    ) throws -> String? {
        try AgentCommandShimInstaller(
            runtimePaths: runtimePaths,
            managedCommandNames: ManagedAgentCommandResolver.shimCommandNames(for: agentProfiles),
            helperExecutablePathProvider: { helperExecutablePath }
        )
            .syncInstallation(enabled: enabled)?
            .directoryURL
            .path
    }

    private static func configureBaseLaunchEnvironmentProvider(
        terminalRuntimeRegistry: TerminalRuntimeRegistry,
        runtimePaths: ToasttyRuntimePaths,
        socketPath: String,
        cliExecutablePath: String?,
        shimDirectoryPath: String?,
        basePath: String?,
        agentBasePath: String?
    ) {
        let launchPath = shimDirectoryPath.map {
            AgentCommandShimInstaller.pathValue(prepending: $0, to: basePath)
        } ?? basePath
        ToasttyLog.info(
            "Configured terminal launch context environment",
            category: .bootstrap,
            metadata: [
                "socket_path": socketPath,
                "cli_path": cliExecutablePath ?? "none",
                "cli_path_present": cliExecutablePath == nil ? "false" : "true",
                "agent_shim_directory": shimDirectoryPath ?? "none",
                "agent_shim_directory_present": shimDirectoryPath == nil ? "false" : "true",
                "agent_base_path_present": agentBasePath == nil ? "false" : "true",
                "legacy_pane_history_directory": runtimePaths.paneHistoryDirectoryURL.path,
                "pane_journal_directory": runtimePaths.paneJournalDirectoryURL.path,
                "path_starts_with_shim_directory": pathStartsWithDirectory(
                    launchPath,
                    directoryPath: shimDirectoryPath
                ) ? "true" : "false",
                "path_contains_shim_directory": pathContainsDirectory(
                    launchPath,
                    directoryPath: shimDirectoryPath
                ) ? "true" : "false",
                "path_sample": pathEntriesSample(launchPath),
                "agent_base_path_sample": pathEntriesSample(agentBasePath),
            ]
        )
        terminalRuntimeRegistry.setBaseLaunchEnvironmentProvider { panelID in
            let paneJournalFilePath = runtimePaths.paneJournalFileURL(for: panelID).path
            var environment: [String: String] = [
                ToasttyLaunchContextEnvironment.panelIDKey: panelID.uuidString,
                ToasttyLaunchContextEnvironment.socketPathKey: socketPath,
                ToasttyLaunchContextEnvironment.paneJournalFileKey: paneJournalFilePath,
            ]
            if let cliExecutablePath {
                environment[ToasttyLaunchContextEnvironment.cliPathKey] = cliExecutablePath
            }
            if let agentBasePath {
                environment[ToasttyLaunchContextEnvironment.agentBasePathKey] = agentBasePath
            }
            if let shimDirectoryPath {
                environment[ToasttyLaunchContextEnvironment.agentShimDirectoryKey] = shimDirectoryPath
                environment["PATH"] = AgentCommandShimInstaller.pathValue(
                    prepending: shimDirectoryPath,
                    to: basePath
                )
            }
            return environment
        }
    }

    private static func pathEntriesSample(_ path: String?, limit: Int = 4) -> String {
        let entries = normalizedPathEntries(path)
        guard entries.isEmpty == false else {
            return "none"
        }
        return entries.prefix(limit).joined(separator: " | ")
    }

    private static func pathStartsWithDirectory(_ path: String?, directoryPath: String?) -> Bool {
        guard let directoryPath,
              let firstEntry = normalizedPathEntries(path).first else {
            return false
        }
        return firstEntry == directoryPath
    }

    private static func pathContainsDirectory(_ path: String?, directoryPath: String?) -> Bool {
        guard let directoryPath else {
            return false
        }
        return normalizedPathEntries(path).contains(directoryPath)
    }

    private static func normalizedPathEntries(_ path: String?) -> [String] {
        guard let path else {
            return []
        }
        return path
            .split(separator: ":")
            .map(String.init)
            .filter { $0.isEmpty == false }
    }

    var body: some Scene {
        WindowGroup(id: AppWindowSceneID.value) {
            AppWindowSceneHostView(
                store: store,
                agentCatalogStore: agentCatalogStore,
                terminalProfileStore: terminalProfileStore,
                terminalRuntimeRegistry: terminalRuntimeRegistry,
                webPanelRuntimeRegistry: webPanelRuntimeRegistry,
                sessionRuntimeStore: sessionRuntimeStore,
                profileShortcutRegistry: profileShortcutRegistry,
                focusedPanelCommandController: focusedPanelCommandController,
                agentLaunchService: agentLaunchService,
                openAgentProfilesConfigurationResult: openAgentProfilesConfigurationResult,
                openKeyboardShortcutsReferenceResult: openKeyboardShortcutsReferenceResult,
                toggleCommandPalette: { [weak commandPaletteController] originWindowID in
                    _ = commandPaletteController?.toggle(originWindowID: originWindowID)
                },
                presentCommandPalette: { [weak commandPaletteController] originWindowID, initialQuery in
                    _ = commandPaletteController?.present(originWindowID: originWindowID, initialQuery: initialQuery)
                },
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
                terminalRuntimeRegistry: terminalRuntimeRegistry,
                webPanelRuntimeRegistry: webPanelRuntimeRegistry,
                sessionRuntimeStore: sessionRuntimeStore,
                profileShortcutRegistry: profileShortcutRegistry,
                focusedPanelCommandController: focusedPanelCommandController,
                processWatchCommandController: processWatchCommandController,
                agentLaunchService: agentLaunchService,
                terminalProfilesMenuController: terminalProfilesMenuController,
                canCheckForUpdates: sparkleUpdaterBridge.canCheckForUpdates,
                checkForUpdates: sparkleUpdaterBridge.checkForUpdates,
                supportsConfigurationReload: supportsConfigurationReload,
                reloadConfiguration: reloadConfiguration,
                openManageConfig: openManageConfig,
                openConfigReference: openConfigReference,
                openAgentProfilesConfiguration: openAgentProfilesConfiguration,
                openLocalDocumentFile: { preferredWindowID in
                    self.openLocalDocumentFile(
                        preferredWindowID: preferredWindowID,
                        placement: store.localDocumentRoutingPreferences.openingPlacement.webPanelPlacement
                    )
                },
                openLocalDocumentFileInTab: { preferredWindowID in
                    self.openLocalDocumentFile(
                        preferredWindowID: preferredWindowID,
                        placement: WebPanelPlacement.newTab
                    )
                },
                openLocalDocumentFileInSplit: { preferredWindowID in
                    self.openLocalDocumentFile(
                        preferredWindowID: preferredWindowID,
                        placement: WebPanelPlacement.splitRight
                    )
                }
            )
        }
    }

    private var supportsConfigurationReload: Bool {
        true
    }

    @MainActor
    private func reloadConfiguration() {
        Self.reloadConfiguration(
            store: store,
            agentCatalogStore: agentCatalogStore,
            terminalProfileStore: terminalProfileStore,
            runtimePaths: runtimePaths,
            agentLaunchSocketPath: agentLaunchSocketPath,
            agentLaunchCLIExecutablePath: agentLaunchCLIExecutablePath,
            agentLaunchShimExecutablePath: agentLaunchShimExecutablePath,
            terminalRuntimeRegistry: terminalRuntimeRegistry
        )
    }

    @MainActor
    private static func reloadConfiguration(
        store: AppStore,
        agentCatalogStore: AgentCatalogStore,
        terminalProfileStore: TerminalProfileStore,
        runtimePaths: ToasttyRuntimePaths,
        agentLaunchSocketPath: String,
        agentLaunchCLIExecutablePath: String?,
        agentLaunchShimExecutablePath: String?,
        terminalRuntimeRegistry: TerminalRuntimeRegistry
    ) {
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
        store.setURLRoutingPreferences(toasttyConfig.urlRoutingPreferences)
        store.setLocalDocumentRoutingPreferences(toasttyConfig.localDocumentRoutingPreferences)
        do {
            let shimDirectoryPath = try Self.synchronizeManagedAgentCommandShims(
                enabled: toasttyConfig.enableAgentCommandShims,
                runtimePaths: runtimePaths,
                agentProfiles: agentCatalogStore.catalog,
                helperExecutablePath: agentLaunchShimExecutablePath
            )
            Self.configureBaseLaunchEnvironmentProvider(
                terminalRuntimeRegistry: terminalRuntimeRegistry,
                runtimePaths: runtimePaths,
                socketPath: agentLaunchSocketPath,
                cliExecutablePath: agentLaunchCLIExecutablePath,
                shimDirectoryPath: shimDirectoryPath,
                basePath: ProcessInfo.processInfo.environment["PATH"],
                agentBasePath: ManagedAgentBasePathResolver(
                    environment: ProcessInfo.processInfo.environment,
                    fallbackPath: nil
                ).resolve()
            )
        } catch {
            failureMessages.append("Failed to update managed agent command shims: \(error.localizedDescription)")
            Self.configureBaseLaunchEnvironmentProvider(
                terminalRuntimeRegistry: terminalRuntimeRegistry,
                runtimePaths: runtimePaths,
                socketPath: agentLaunchSocketPath,
                cliExecutablePath: agentLaunchCLIExecutablePath,
                shimDirectoryPath: nil,
                basePath: ProcessInfo.processInfo.environment["PATH"],
                agentBasePath: ManagedAgentBasePathResolver(
                    environment: ProcessInfo.processInfo.environment,
                    fallbackPath: nil
                ).resolve()
            )
        }
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
                legacyTerminalFontSizePoints: nil,
                ghosttyConfiguredTerminalFontPoints: runtimeManager.configuredTerminalFontPoints
            )
        } else {
            failureMessages.append("Failed to reload embedded Ghostty configuration.")
            Self.applyToasttyTerminalFontState(
                to: store,
                toasttyConfig: toasttyConfig,
                legacyTerminalFontSizePoints: nil,
                ghosttyConfiguredTerminalFontPoints: runtimeManager.configuredTerminalFontPoints
            )
        }
        #else
        Self.applyToasttyTerminalFontState(
            to: store,
            toasttyConfig: toasttyConfig,
            legacyTerminalFontSizePoints: nil,
            ghosttyConfiguredTerminalFontPoints: nil
        )
        #endif

        let resolvedProfileShortcutRegistry = Self.makeProfileShortcutRegistry(
            terminalProfiles: terminalProfileStore.catalog,
            terminalProfilesFilePath: terminalProfileStore.fileURL.path,
            agentProfiles: agentCatalogStore.catalog,
            agentProfilesFilePath: agentCatalogStore.fileURL.path
        )
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
        Self.openAgentProfilesConfiguration(
            store: store,
            preferredWindowID: currentToasttyWorkspaceCommandWindowID(in: store)
        )
    }

    @MainActor
    @discardableResult
    private static func openAgentProfilesConfiguration(
        store: AppStore,
        preferredWindowID: UUID?
    ) -> Bool {
        switch ToasttyMenuActions.openAgentProfilesConfigurationResult(
            openManagedLocalDocument: { fileURL, format in
                openManagedLocalDocumentInToastty(
                    store: store,
                    fileURL: fileURL,
                    format: format,
                    preferredWindowID: preferredWindowID
                )
            }
        ) {
        case .success:
            return true
        case .failure(let error):
            let alert = NSAlert()
            alert.messageText = "Unable to Open Agent Profiles"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
    }

    @MainActor
    private func openAgentProfilesConfigurationResult() -> Result<Void, AgentGetStartedActionError> {
        ToasttyMenuActions.openAgentProfilesConfigurationResult(
            openManagedLocalDocument: { [store] fileURL, format in
                openManagedLocalDocumentInToastty(
                    store: store,
                    fileURL: fileURL,
                    format: format,
                    preferredWindowID: currentToasttyWorkspaceCommandWindowID(in: store)
                )
            }
        )
    }

    @MainActor
    private func openKeyboardShortcutsReferenceResult() -> Result<Void, AgentGetStartedActionError> {
        ToasttyMenuActions.openKeyboardShortcutsReferenceResult(
            runtimePaths: runtimePaths,
            openURL: { [store] url in
                AppURLRouter.open(
                    url,
                    preferredWindowID: currentToasttyWorkspaceCommandWindowID(in: store),
                    appStore: store,
                    requestLocalDocumentReveal: { [weak webPanelRuntimeRegistry] panelID, lineNumber in
                        webPanelRuntimeRegistry?.requestLocalDocumentReveal(panelID: panelID, lineNumber: lineNumber) ?? false
                    }
                )
            }
        )
    }

    @MainActor
    private func openManageConfig() {
        Self.openManageConfig(
            store: store,
            preferredWindowID: currentToasttyWorkspaceCommandWindowID(in: store)
        )
    }

    @MainActor
    @discardableResult
    private static func openManageConfig(
        store: AppStore,
        preferredWindowID: UUID?
    ) -> Bool {
        switch ToasttyMenuActions.openToasttyConfigResult(
            openManagedLocalDocument: { fileURL, format in
                openManagedLocalDocumentInToastty(
                    store: store,
                    fileURL: fileURL,
                    format: format,
                    preferredWindowID: preferredWindowID
                )
            }
        ) {
        case .success:
            return true
        case .failure(let error):
            let alert = NSAlert()
            alert.messageText = "Unable to Open Config"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
    }

    @MainActor
    @discardableResult
    private static func openTerminalProfilesConfiguration(
        store: AppStore,
        preferredWindowID: UUID?
    ) -> Bool {
        switch ToasttyMenuActions.openTerminalProfilesConfigurationResult(
            openManagedLocalDocument: { fileURL, format in
                openManagedLocalDocumentInToastty(
                    store: store,
                    fileURL: fileURL,
                    format: format,
                    preferredWindowID: preferredWindowID
                )
            }
        ) {
        case .success:
            return true
        case .failure(let error):
            let alert = NSAlert()
            alert.messageText = "Unable to Open Terminal Profiles"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
    }

    @MainActor
    private func openConfigReference() {
        switch ToasttyMenuActions.openConfigReferenceResult(
            openManagedLocalDocument: { [store] fileURL, format in
                openManagedLocalDocumentInToastty(
                    store: store,
                    fileURL: fileURL,
                    format: format,
                    preferredWindowID: currentToasttyWorkspaceCommandWindowID(in: store)
                )
            }
        ) {
        case .success:
            return
        case .failure(let error):
            let alert = NSAlert()
            alert.messageText = "Unable to Open Config Reference"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @MainActor
    @discardableResult
    private func openLocalDocumentFile(preferredWindowID: UUID?, placement: WebPanelPlacement) -> Bool {
        Self.openLocalDocumentFile(
            store: store,
            preferredWindowID: preferredWindowID,
            placement: placement
        )
    }

    @MainActor
    @discardableResult
    private static func openLocalDocumentFile(
        store: AppStore,
        preferredWindowID: UUID?,
        placement: WebPanelPlacement
    ) -> Bool {
        let preferredDirectoryURL = store.preferredLocalDocumentOpenDirectoryURL(
            preferredWindowID: preferredWindowID
        )
        guard let fileURL = LocalDocumentOpenPanel.chooseFile(
            title: localDocumentOpenTitle(for: placement),
            directoryURL: preferredDirectoryURL
        ) else {
            return false
        }

        let normalizedFilePath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        let didOpen = store.createLocalDocumentPanelFromCommand(
            preferredWindowID: preferredWindowID,
            request: LocalDocumentPanelCreateRequest(
                filePath: normalizedFilePath,
                placementOverride: placement
            )
        )

        guard didOpen == false else { return true }

        let alert = NSAlert()
        alert.messageText = "Unable to Open Local File"
        alert.informativeText = "Toastty couldn't open \(normalizedFilePath) in the current workspace."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return false
    }

    @MainActor
    @discardableResult
    private static func createBlankScratchpad(
        store: AppStore,
        preferredWindowID: UUID?,
        documentStore: ScratchpadDocumentStore
    ) -> Bool {
        guard let workspaceID = store.commandSelection(preferredWindowID: preferredWindowID)?.workspace.id else {
            return false
        }

        do {
            _ = try store.createBlankScratchpadPanel(
                workspaceID: workspaceID,
                documentStore: documentStore
            )
            return true
        } catch {
            NSLog("Blank Scratchpad creation failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func localDocumentOpenTitle(for placement: WebPanelPlacement) -> String {
        switch placement {
        case .rightPanel:
            return "Open Local File"
        case .newTab:
            return "Open Local File in Tab"
        case .splitRight:
            return "Open Local File in Split"
        }
    }

    @MainActor
    private static func applyInitialToasttyConfigState(
        to store: AppStore,
        terminalProfileCatalog: TerminalProfileCatalog,
        toasttyConfig: ToasttyConfig,
        legacyTerminalFontSizePoints: Double?
    ) {
        store.setURLRoutingPreferences(toasttyConfig.urlRoutingPreferences)
        store.setLocalDocumentRoutingPreferences(toasttyConfig.localDocumentRoutingPreferences)
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
            legacyTerminalFontSizePoints: legacyTerminalFontSizePoints,
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
    static func applyToasttyTerminalFontState(
        to store: AppStore,
        toasttyConfig: ToasttyConfig,
        legacyTerminalFontSizePoints: Double?,
        ghosttyConfiguredTerminalFontPoints: Double?,
        clearLegacyTerminalFontSizePoints: @escaping () -> Void = {
            ToasttySettingsStore.clearLegacyTerminalFontSizePoints()
        }
    ) {
        let configuredBaseline = toasttyConfig.terminalFontSizePoints ?? ghosttyConfiguredTerminalFontPoints
        _ = store.send(.setConfiguredTerminalFont(points: configuredBaseline))

        guard let legacyTerminalFontSizePoints else { return }
        defer { clearLegacyTerminalFontSizePoints() }
        guard store.state.windows.allSatisfy({ $0.terminalFontSizePointsOverride == nil }) else {
            return
        }

        for windowID in store.state.windows.map(\.id) {
            _ = store.send(
                .setWindowTerminalFont(
                    windowID: windowID,
                    points: legacyTerminalFontSizePoints
                )
            )
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
        AppKitDefaultPreferences.apply(to: ToasttyAppDefaults.current)
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

    private static func recordRuntimeInstance(
        processInfo: ProcessInfo,
        automationConfig: AutomationConfig?,
        socketPathOverride: String? = nil
    ) {
        ToasttyRuntimeInstanceRecorder.recordLaunch(
            processInfo: processInfo,
            automationConfig: automationConfig,
            socketPathOverride: socketPathOverride
        )
    }

    private static func prunePaneRestoreFiles(
        runtimePaths: ToasttyRuntimePaths,
        liveTerminalPanelIDs: Set<UUID>
    ) {
        let result = PaneHistoryStore(runtimePaths: runtimePaths)
            .pruneUnreferencedHistoryFiles(keepingPanelIDs: liveTerminalPanelIDs)
        let journalResult = PaneCommandJournalStore(runtimePaths: runtimePaths)
            .pruneUnreferencedJournalFiles(keepingPanelIDs: liveTerminalPanelIDs)

        if result.removedFileCount > 0 {
            ToasttyLog.info(
                "Pruned stale legacy pane history files",
                category: .bootstrap,
                metadata: [
                    "directory": runtimePaths.paneHistoryDirectoryURL.path,
                    "removed_count": String(result.removedFileCount),
                    "live_panel_count": String(liveTerminalPanelIDs.count),
                ]
            )
        }

        if journalResult.removedFileCount > 0 {
            ToasttyLog.info(
                "Pruned stale pane journal files",
                category: .bootstrap,
                metadata: [
                    "directory": runtimePaths.paneJournalDirectoryURL.path,
                    "removed_count": String(journalResult.removedFileCount),
                    "live_panel_count": String(liveTerminalPanelIDs.count),
                ]
            )
        }

        if result.failedRemovalCount > 0 {
            ToasttyLog.warning(
                "Failed removing some stale legacy pane history files",
                category: .bootstrap,
                metadata: [
                    "directory": runtimePaths.paneHistoryDirectoryURL.path,
                    "failed_removal_count": String(result.failedRemovalCount),
                    "live_panel_count": String(liveTerminalPanelIDs.count),
                ]
            )
        }

        if journalResult.failedRemovalCount > 0 {
            ToasttyLog.warning(
                "Failed removing some stale pane journal files",
                category: .bootstrap,
                metadata: [
                    "directory": runtimePaths.paneJournalDirectoryURL.path,
                    "failed_removal_count": String(journalResult.failedRemovalCount),
                    "live_panel_count": String(liveTerminalPanelIDs.count),
                ]
            )
        }
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

    private static func writeToasttyConfigReference() {
        do {
            try ToasttyConfigStore.writeConfigReference()
        } catch {
            ToasttyLog.warning(
                "Failed to write Toastty config reference",
                category: .bootstrap,
                metadata: [
                    "path": ToasttyConfigStore.configReferenceFileURL().path,
                    "error": error.localizedDescription,
                ]
            )
        }
    }
}
