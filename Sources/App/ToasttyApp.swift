import AppKit
import Carbon.HIToolbox
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
            placementOverride: .newTab,
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

@MainActor
final class DisplayShortcutInterceptor {
    private weak var store: AppStore?
    private let terminalRuntimeRegistry: TerminalRuntimeRegistry
    private let webPanelRuntimeRegistry: WebPanelRuntimeRegistry
    private let sessionRuntimeStore: SessionRuntimeStore
    private let focusedPanelCommandController: FocusedPanelCommandController
    private let isCommandPalettePresented: @MainActor () -> Bool
    private let toggleCommandPalette: @MainActor (UUID?) -> Bool
    nonisolated(unsafe) private var eventMonitor: Any?

    enum ShortcutAction: Equatable {
        case commandPalette
        case closePanel
        case createBrowser
        case createBrowserTab
        case createWorkspaceTab
        case increaseTextSize
        case decreaseTextSize
        case resetTextSize
        case split(SlotSplitDirection)
        case enterLocalDocumentEdit
        case cancelLocalDocumentEdit
        case saveLocalDocument
        case focusNextUnreadOrActivePanel
        case toggleLaterFlag
        case toggleFocusedPanelMode
        case renameSelectedTab
        case selectWorkspaceTab(Int)
        case selectAdjacentTab(TabNavigationDirection)
        case switchWorkspace(Int)
        case focusPanel(Int)
        case focusSplit(SlotFocusDirection)
        case resizeSplit(SplitResizeDirection)
        case equalizeSplits
        case browserOpenLocation
        case browserReload
        case cycleWorkspaceNext
        case cycleWorkspacePrevious
    }

    init(
        store: AppStore,
        terminalRuntimeRegistry: TerminalRuntimeRegistry,
        webPanelRuntimeRegistry: WebPanelRuntimeRegistry,
        sessionRuntimeStore: SessionRuntimeStore,
        focusedPanelCommandController: FocusedPanelCommandController,
        isCommandPalettePresented: @escaping @MainActor () -> Bool = { false },
        toggleCommandPalette: @escaping @MainActor (UUID?) -> Bool = { _ in false },
        installEventMonitor: Bool = true
    ) {
        self.store = store
        self.terminalRuntimeRegistry = terminalRuntimeRegistry
        self.webPanelRuntimeRegistry = webPanelRuntimeRegistry
        self.sessionRuntimeStore = sessionRuntimeStore
        self.focusedPanelCommandController = focusedPanelCommandController
        self.isCommandPalettePresented = isCommandPalettePresented
        self.toggleCommandPalette = toggleCommandPalette
        if installEventMonitor {
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
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    private func shortcutAction(for event: NSEvent) -> ShortcutAction? {
        shortcutAction(for: event, appOwnedWindowID: appOwnedShortcutWindowID())
    }

    func shortcutAction(for event: NSEvent, appOwnedWindowID: UUID?) -> ShortcutAction? {
        if Self.isCommandPaletteShortcut(event),
           isCommandPalettePresented() {
            return .commandPalette
        }

        if Self.isCommandPaletteShortcut(event),
           appOwnedWindowID != nil {
            return .commandPalette
        }
        if let shortcutNumber = Self.tabSelectionShortcutNumber(for: event),
           appOwnedWindowID != nil {
            return .selectWorkspaceTab(shortcutNumber)
        }

        if let direction = Self.tabNavigationDirection(for: event),
           appOwnedWindowID != nil {
            return .selectAdjacentTab(direction)
        }

        if Self.isNewTabShortcut(event),
           appOwnedWindowID != nil {
            return .createWorkspaceTab
        }

        if Self.isNewBrowserShortcut(event),
           appOwnedWindowID != nil {
            return .createBrowser
        }

        if Self.isNewBrowserTabShortcut(event),
           appOwnedWindowID != nil {
            return .createBrowserTab
        }

        if let textSizeShortcutAction = textSizeShortcutAction(
            for: event,
            appOwnedWindowID: appOwnedWindowID
        ) {
            return textSizeShortcutAction
        }

        if let direction = Self.splitDirection(for: event),
           appOwnedWindowID != nil {
            return .split(direction)
        }

        if Self.isClosePanelShortcut(event),
           appOwnedWindowID != nil {
            return .closePanel
        }

        if Self.isEnterEditShortcut(event),
           canEnterFocusedLocalDocumentEdit(preferredWindowID: appOwnedWindowID) {
            return .enterLocalDocumentEdit
        }

        if Self.isCancelEditShortcut(event),
           canCancelFocusedLocalDocumentEdit(preferredWindowID: appOwnedWindowID) {
            return .cancelLocalDocumentEdit
        }

        if Self.isSaveShortcut(event),
           appOwnedFocusedLocalDocumentSelection(preferredWindowID: appOwnedWindowID) != nil {
            return .saveLocalDocument
        }

        if Self.isFocusNextUnreadOrActiveShortcut(event),
           appOwnedWindowID != nil {
            return .focusNextUnreadOrActivePanel
        }

        if Self.isToggleLaterFlagShortcut(event),
           appOwnedWindowID != nil {
            return .toggleLaterFlag
        }

        if Self.isToggleFocusedPanelShortcut(event),
           appOwnedWindowID != nil {
            return .toggleFocusedPanelMode
        }

        if Self.isRenameTabShortcut(event),
           appOwnedWindowID != nil {
            return .renameSelectedTab
        }

        if let direction = Self.focusSplitDirection(for: event),
           appOwnedWindowID != nil {
            return .focusSplit(direction)
        }

        if let direction = Self.directionalFocusSplitDirection(for: event),
           appOwnedWindowID != nil {
            return .focusSplit(direction)
        }

        if let direction = Self.resizeSplitDirection(for: event),
           appOwnedWindowID != nil {
            return .resizeSplit(direction)
        }

        if Self.isEqualizeSplitsShortcut(event),
           appOwnedWindowID != nil {
            return .equalizeSplits
        }

        if Self.isBrowserOpenLocationShortcut(event),
           appOwnedFocusedBrowserSelection(preferredWindowID: appOwnedWindowID) != nil {
            return .browserOpenLocation
        }

        if Self.isBrowserReloadShortcut(event),
           appOwnedFocusedBrowserSelection(preferredWindowID: appOwnedWindowID) != nil {
            return .browserReload
        }

        switch DisplayShortcutConfig.action(for: event) {
        case .workspaceSwitch(let shortcutNumber):
            return .switchWorkspace(shortcutNumber)
        case .panelFocus(let shortcutNumber):
            return .focusPanel(shortcutNumber)
        case .cycleWorkspaceNext:
            return .cycleWorkspaceNext
        case .cycleWorkspacePrevious:
            return .cycleWorkspacePrevious
        case nil:
            return nil
        }
    }

    private func handle(_ action: ShortcutAction) -> Bool {
        handle(action, appOwnedWindowID: appOwnedShortcutWindowID())
    }

    func handle(_ action: ShortcutAction, appOwnedWindowID: UUID?) -> Bool {
        switch action {
        case .commandPalette:
            toggleCommandPalette(appOwnedWindowID)
        case .closePanel:
            closeFocusedPanel()
        case .createBrowser:
            createBrowser(preferredWindowID: appOwnedWindowID, placement: .rootRight)
        case .createBrowserTab:
            createBrowser(preferredWindowID: appOwnedWindowID, placement: .newTab)
        case .createWorkspaceTab:
            createWorkspaceTab()
        case .increaseTextSize:
            adjustTextSize(direction: .increase, preferredWindowID: appOwnedWindowID)
        case .decreaseTextSize:
            adjustTextSize(direction: .decrease, preferredWindowID: appOwnedWindowID)
        case .resetTextSize:
            adjustTextSize(direction: .reset, preferredWindowID: appOwnedWindowID)
        case .split(let direction):
            split(direction: direction, preferredWindowID: appOwnedWindowID)
        case .enterLocalDocumentEdit:
            handleEnterLocalDocumentEditShortcut(preferredWindowID: appOwnedWindowID)
        case .cancelLocalDocumentEdit:
            handleCancelLocalDocumentEditShortcut(preferredWindowID: appOwnedWindowID)
        case .saveLocalDocument:
            handleSaveLocalDocumentShortcut(preferredWindowID: appOwnedWindowID)
        case .focusNextUnreadOrActivePanel:
            focusNextUnreadOrActivePanel(preferredWindowID: appOwnedWindowID)
        case .toggleLaterFlag:
            toggleLaterFlag(preferredWindowID: appOwnedWindowID)
        case .toggleFocusedPanelMode:
            toggleFocusedPanelMode()
        case .renameSelectedTab:
            renameSelectedTab()
        case .selectWorkspaceTab(let shortcutNumber):
            selectWorkspaceTab(shortcutNumber: shortcutNumber)
        case .selectAdjacentTab(let direction):
            selectAdjacentTab(direction: direction)
        case .switchWorkspace(let shortcutNumber):
            switchWorkspace(shortcutNumber: shortcutNumber)
        case .focusPanel(let shortcutNumber):
            focusTerminalPanel(shortcutNumber: shortcutNumber)
        case .focusSplit(let direction):
            focusSplit(direction: direction, preferredWindowID: appOwnedWindowID)
        case .resizeSplit(let direction):
            resizeSplit(direction: direction, preferredWindowID: appOwnedWindowID)
        case .equalizeSplits:
            equalizeSplits(preferredWindowID: appOwnedWindowID)
        case .browserOpenLocation:
            openFocusedBrowserLocation(preferredWindowID: appOwnedWindowID)
        case .browserReload:
            reloadFocusedBrowser(preferredWindowID: appOwnedWindowID)
        case .cycleWorkspaceNext:
            cycleWorkspace(direction: 1)
        case .cycleWorkspacePrevious:
            cycleWorkspace(direction: -1)
        }
    }

    static func isCommandPaletteShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "p" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command, .shift]
    }

    static func isNewTabShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "t" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command]
    }

    static func isNewBrowserShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "b" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command, .control]
    }

    static func isNewBrowserTabShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "b" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command, .control, .shift]
    }

    static func isSaveShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "s" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command]
    }

    static func isCancelEditShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              Int(event.keyCode) == Int(kVK_Escape) else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers.isEmpty
    }

    enum TextSizeShortcutDirection: Equatable {
        case increase
        case decrease
        case reset
    }

    static func textSizeShortcutDirection(for event: NSEvent) -> TextSizeShortcutDirection? {
        guard event.type == .keyDown,
              event.isARepeat == false else {
            return nil
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case Int(kVK_ANSI_Equal), Int(kVK_ANSI_KeypadPlus):
            guard modifiers == [.command] || modifiers == [.command, .shift] else {
                return nil
            }
            return .increase
        case Int(kVK_ANSI_Minus), Int(kVK_ANSI_KeypadMinus):
            guard modifiers == [.command] else {
                return nil
            }
            return .decrease
        case Int(kVK_ANSI_0), Int(kVK_ANSI_Keypad0):
            guard modifiers == [.command] else {
                return nil
            }
            return .reset
        default:
            return nil
        }
    }

    static func splitDirection(for event: NSEvent) -> SlotSplitDirection? {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "d" else {
            return nil
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch modifiers {
        case [.command]:
            return .right
        case [.command, .shift]:
            return .down
        default:
            return nil
        }
    }

    static func tabSelectionShortcutNumber(for event: NSEvent) -> Int? {
        guard event.type == .keyDown, event.isARepeat == false else { return nil }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == [.command] else { return nil }

        let shortcutNumber: Int?
        switch Int(event.keyCode) {
        case Int(kVK_ANSI_1), Int(kVK_ANSI_Keypad1):
            shortcutNumber = 1
        case Int(kVK_ANSI_2), Int(kVK_ANSI_Keypad2):
            shortcutNumber = 2
        case Int(kVK_ANSI_3), Int(kVK_ANSI_Keypad3):
            shortcutNumber = 3
        case Int(kVK_ANSI_4), Int(kVK_ANSI_Keypad4):
            shortcutNumber = 4
        case Int(kVK_ANSI_5), Int(kVK_ANSI_Keypad5):
            shortcutNumber = 5
        case Int(kVK_ANSI_6), Int(kVK_ANSI_Keypad6):
            shortcutNumber = 6
        case Int(kVK_ANSI_7), Int(kVK_ANSI_Keypad7):
            shortcutNumber = 7
        case Int(kVK_ANSI_8), Int(kVK_ANSI_Keypad8):
            shortcutNumber = 8
        case Int(kVK_ANSI_9), Int(kVK_ANSI_Keypad9):
            shortcutNumber = 9
        default:
            shortcutNumber = nil
        }

        guard let shortcutNumber,
              shortcutNumber <= DisplayShortcutConfig.maxWorkspaceTabSelectionShortcutCount else {
            return nil
        }
        return shortcutNumber
    }

    /// Detects Cmd+Shift+[ (previous tab) and Cmd+Shift+] (next tab).
    static func tabNavigationDirection(for event: NSEvent) -> TabNavigationDirection? {
        guard event.type == .keyDown, event.isARepeat == false else { return nil }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == [.command, .shift] else { return nil }

        switch Int(event.keyCode) {
        case Int(kVK_ANSI_LeftBracket):
            return .previous
        case Int(kVK_ANSI_RightBracket):
            return .next
        default:
            return nil
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

    static func isEnterEditShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              Int(event.keyCode) == Int(kVK_ANSI_E) else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command]
    }

    static func isFocusNextUnreadOrActiveShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "a" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command, .shift]
    }

    static func isToggleLaterFlagShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "l" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command, .shift]
    }

    static func isToggleFocusedPanelShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "f" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command, .shift]
    }

    static func isRenameTabShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.isARepeat == false else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == [.option, .shift] else { return false }
        return Int(event.keyCode) == Int(kVK_ANSI_E)
    }

    static func focusSplitDirection(for event: NSEvent) -> SlotFocusDirection? {
        guard event.type == .keyDown, event.isARepeat == false else { return nil }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == [.command] else { return nil }

        switch Int(event.keyCode) {
        case Int(kVK_ANSI_LeftBracket):
            return .previous
        case Int(kVK_ANSI_RightBracket):
            return .next
        default:
            return nil
        }
    }

    static func directionalFocusSplitDirection(for event: NSEvent) -> SlotFocusDirection? {
        guard event.type == .keyDown, event.isARepeat == false else { return nil }
        // AppKit marks arrow-key events with .numericPad even on the main
        // keyboard, so strip that flag before matching the app-owned chord.
        let modifiers = event
            .modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.numericPad)
        guard modifiers == [.command, .option] else { return nil }

        switch Int(event.keyCode) {
        case Int(kVK_LeftArrow):
            return .left
        case Int(kVK_RightArrow):
            return .right
        case Int(kVK_UpArrow):
            return .up
        case Int(kVK_DownArrow):
            return .down
        default:
            return nil
        }
    }

    static func resizeSplitDirection(for event: NSEvent) -> SplitResizeDirection? {
        guard event.type == .keyDown, event.isARepeat == false else { return nil }
        // AppKit marks arrow-key events with .numericPad even on the main
        // keyboard, so strip that flag before matching the app-owned chord.
        let modifiers = event
            .modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.numericPad)
        guard modifiers == [.command, .control] else { return nil }

        switch Int(event.keyCode) {
        case Int(kVK_LeftArrow):
            return .left
        case Int(kVK_RightArrow):
            return .right
        case Int(kVK_UpArrow):
            return .up
        case Int(kVK_DownArrow):
            return .down
        default:
            return nil
        }
    }

    static func isEqualizeSplitsShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.isARepeat == false else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == [.command, .control] else {
            return false
        }
        return Int(event.keyCode) == Int(kVK_ANSI_Equal)
    }

    static func isBrowserOpenLocationShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "l" else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == [.command]
    }

    static func isBrowserReloadShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.isARepeat == false,
              event.charactersIgnoringModifiers?.lowercased() == "r" else {
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
        if toasttyResponderUsesReservedClosePanelShortcut(keyWindow.firstResponder) {
            return nil
        }
        guard let rawWindowID = keyWindow.identifier?.rawValue else { return nil }
        return UUID(uuidString: rawWindowID)
    }

    private func appOwnedShortcutWindowID() -> UUID? {
        guard let store else { return nil }
        return currentToasttyAppOwnedWindowID(in: store)
    }

    private func closeFocusedPanel() -> Bool {
        guard let store else { return false }
        guard let preferredWindowID = appOwnedShortcutWindowID() else { return false }
        let preferredWorkspaceID = store.commandSelection(preferredWindowID: preferredWindowID)?.workspace.id
        guard focusedPanelCommandController.closeFocusedPanel(in: preferredWorkspaceID).consumesShortcut else {
            // Cmd+W is app-owned for normal workspace windows. If there is no
            // panel to close in that context, swallow the shortcut rather than
            // falling back to AppKit's native window-close path.
            return preferredWorkspaceID != nil
        }
        return true
    }

    private func createWorkspaceTab() -> Bool {
        guard let store else { return false }
        guard let preferredWindowID = appOwnedShortcutWindowID() else { return false }
        return store.createWorkspaceTabFromCommand(preferredWindowID: preferredWindowID)
    }

    private func textSizeShortcutAction(
        for event: NSEvent,
        appOwnedWindowID: UUID?
    ) -> ShortcutAction? {
        guard appOwnedFocusedScaleTarget(preferredWindowID: appOwnedWindowID) != nil else {
            return nil
        }

        switch Self.textSizeShortcutDirection(for: event) {
        case .increase:
            return .increaseTextSize
        case .decrease:
            return .decreaseTextSize
        case .reset:
            return .resetTextSize
        case nil:
            return nil
        }
    }

    private func split(direction: SlotSplitDirection, preferredWindowID: UUID?) -> Bool {
        guard let store else { return false }
        guard let preferredWindowID else { return false }
        guard let workspaceID = store.commandSelection(preferredWindowID: preferredWindowID)?.workspace.id else {
            return false
        }

        _ = terminalRuntimeRegistry.splitFocusedSlotInDirection(
            workspaceID: workspaceID,
            direction: direction
        )
        // Cmd+D / Cmd+Shift+D should remain app-owned for resolved Toastty
        // workspace windows so embedded web views cannot reject the shortcut.
        return true
    }

    private func createBrowser(preferredWindowID: UUID?, placement: WebPanelPlacement) -> Bool {
        guard let store else { return false }
        guard let preferredWindowID else { return false }
        return store.createBrowserPanelFromCommand(
            preferredWindowID: preferredWindowID,
            request: BrowserPanelCreateRequest(
                placementOverride: placement
            )
        )
    }

    private func adjustTextSize(
        direction: TextSizeShortcutDirection,
        preferredWindowID: UUID?
    ) -> Bool {
        guard let store else { return false }
        guard let target = appOwnedFocusedScaleTarget(preferredWindowID: preferredWindowID) else {
            return false
        }

        switch (target, direction) {
        case (.terminal(let windowID), .increase):
            _ = store.send(.increaseWindowTerminalFont(windowID: windowID))
        case (.terminal(let windowID), .decrease):
            _ = store.send(.decreaseWindowTerminalFont(windowID: windowID))
        case (.terminal(let windowID), .reset):
            _ = store.send(.resetWindowTerminalFont(windowID: windowID))
        case (.markdown(let windowID), .increase):
            _ = store.send(.increaseWindowMarkdownTextScale(windowID: windowID))
        case (.markdown(let windowID), .decrease):
            _ = store.send(.decreaseWindowMarkdownTextScale(windowID: windowID))
        case (.markdown(let windowID), .reset):
            _ = store.send(.resetWindowMarkdownTextScale(windowID: windowID))
        case (.browser(_, let panelID), .increase):
            _ = store.send(.increaseBrowserPanelPageZoom(panelID: panelID))
        case (.browser(_, let panelID), .decrease):
            _ = store.send(.decreaseBrowserPanelPageZoom(panelID: panelID))
        case (.browser(_, let panelID), .reset):
            _ = store.send(.resetBrowserPanelPageZoom(panelID: panelID))
        }
        return true
    }

    private func focusNextUnreadOrActivePanel(preferredWindowID: UUID? = nil) -> Bool {
        guard let store else { return false }
        guard let preferredWindowID = preferredWindowID ?? appOwnedShortcutWindowID() else { return false }
        guard store.commandSelection(preferredWindowID: preferredWindowID) != nil else {
            return false
        }

        _ = store.focusNextUnreadOrActivePanelFromCommand(
            preferredWindowID: preferredWindowID,
            sessionRuntimeStore: sessionRuntimeStore
        )
        // Cmd+Shift+A is app-owned for normal workspace windows. If there is no
        // next unread or active target, swallow the shortcut rather than
        // passing it to the embedded terminal or default responder.
        return true
    }

    private func toggleLaterFlag(preferredWindowID: UUID? = nil) -> Bool {
        guard let store else { return false }
        guard let preferredWindowID = preferredWindowID ?? appOwnedShortcutWindowID() else { return false }
        guard let focusedPanelID = store.commandSelection(preferredWindowID: preferredWindowID)?.workspace.focusedPanelID else {
            return false
        }

        _ = sessionRuntimeStore.toggleLaterFlagForPanel(panelID: focusedPanelID)
        // Cmd+Shift+L is app-owned for normal workspace windows. If the
        // focused panel does not currently host a managed session, keep the
        // shortcut as a no-op rather than forwarding raw input.
        return true
    }

    private func toggleFocusedPanelMode() -> Bool {
        guard let store else { return false }
        guard let preferredWindowID = appOwnedShortcutWindowID() else { return false }
        guard let workspaceID = store.commandSelection(preferredWindowID: preferredWindowID)?.workspace.id else {
            return false
        }

        _ = terminalRuntimeRegistry.toggleFocusedPanelMode(workspaceID: workspaceID)
        // Cmd+Shift+F is app-owned for normal workspace windows. If the
        // selection does not produce a valid focus root, still swallow the
        // shortcut so the terminal does not interpret it as raw input.
        return true
    }

    private func renameSelectedTab() -> Bool {
        guard let store else { return false }
        guard let preferredWindowID = appOwnedShortcutWindowID() else { return false }
        return store.renameSelectedWorkspaceTabFromCommand(preferredWindowID: preferredWindowID)
    }

    private func switchWorkspace(shortcutNumber: Int) -> Bool {
        guard let store else { return false }
        guard shortcutNumber > 0, shortcutNumber <= DisplayShortcutConfig.maxWorkspaceShortcutCount else {
            return false
        }
        let preferredWindowID = currentToasttyKeyWindowID(in: store)
        guard let window = store.commandSelection(preferredWindowID: preferredWindowID)?.window else {
            return false
        }
        let index = shortcutNumber - 1
        guard window.workspaceIDs.indices.contains(index) else { return false }
        let workspaceID = window.workspaceIDs[index]
        guard store.state.workspacesByID[workspaceID] != nil else { return false }
        return store.send(.selectWorkspace(windowID: window.id, workspaceID: workspaceID))
    }

    private func selectWorkspaceTab(shortcutNumber: Int) -> Bool {
        guard let store else { return false }
        guard let preferredWindowID = appOwnedShortcutWindowID() else { return false }
        return store.selectWorkspaceTabFromCommand(
            preferredWindowID: preferredWindowID,
            shortcutNumber: shortcutNumber
        )
    }

    private func selectAdjacentTab(direction: TabNavigationDirection) -> Bool {
        guard let store else { return false }
        guard let preferredWindowID = appOwnedShortcutWindowID() else { return false }
        return store.selectAdjacentWorkspaceTab(
            preferredWindowID: preferredWindowID,
            direction: direction
        )
    }

    private func cycleWorkspace(direction: Int) -> Bool {
        guard let store else { return false }
        guard let window = store.selectedWindow else { return false }
        let workspaceIDs = window.workspaceIDs
        guard workspaceIDs.count > 1 else { return false }
        guard let currentID = store.selectedWorkspaceID(in: window.id),
              let currentIndex = workspaceIDs.firstIndex(of: currentID) else {
            return false
        }
        let nextIndex = (currentIndex + direction + workspaceIDs.count) % workspaceIDs.count
        return store.send(.selectWorkspace(windowID: window.id, workspaceID: workspaceIDs[nextIndex]))
    }

    private func focusTerminalPanel(shortcutNumber: Int) -> Bool {
        guard let store else { return false }
        let preferredWindowID = currentToasttyKeyWindowID(in: store)
        guard let workspace = store.commandSelection(preferredWindowID: preferredWindowID)?.workspace else {
            return false
        }
        guard let panelID = workspace.terminalPanelID(forDisplayShortcutNumber: shortcutNumber) else {
            return false
        }
        return store.send(.focusPanel(workspaceID: workspace.id, panelID: panelID))
    }

    private func focusSplit(direction: SlotFocusDirection, preferredWindowID: UUID?) -> Bool {
        guard let store else { return false }
        guard let preferredWindowID else { return false }
        guard let workspaceID = store.commandSelection(preferredWindowID: preferredWindowID)?.workspace.id else {
            return false
        }
        _ = store.send(.focusSlot(workspaceID: workspaceID, direction: direction))
        // Toastty-owned pane-focus shortcuts should not fall through to
        // embedded views once the current workspace window resolves, even if
        // there is no adjacent split target in that direction.
        return true
    }

    private func resizeSplit(direction: SplitResizeDirection, preferredWindowID: UUID?) -> Bool {
        guard let store else { return false }
        guard let preferredWindowID else { return false }
        guard let workspaceID = store.commandSelection(preferredWindowID: preferredWindowID)?.workspace.id else {
            return false
        }

        _ = store.send(
            .resizeFocusedSlotSplit(
                workspaceID: workspaceID,
                direction: direction,
                amount: SplitLayoutCommandController.appOwnedResizeAmount
            )
        )
        // Cmd+Ctrl+Arrow is a Toastty-owned layout shortcut. Once the current
        // workspace window resolves, keep it out of Ghostty even if the
        // focused slot cannot resize further in that direction.
        return true
    }

    private func equalizeSplits(preferredWindowID: UUID?) -> Bool {
        guard let store else { return false }
        guard let preferredWindowID else { return false }
        guard let workspaceID = store.commandSelection(preferredWindowID: preferredWindowID)?.workspace.id else {
            return false
        }

        _ = store.send(.equalizeLayoutSplits(workspaceID: workspaceID))
        // Cmd+Ctrl+= is likewise app-owned once a Toastty workspace window is
        // resolved so embedded terminals never reinterpret it as raw input.
        return true
    }

    private func openFocusedBrowserLocation(preferredWindowID: UUID?) -> Bool {
        guard let runtime = focusedBrowserRuntime(preferredWindowID: preferredWindowID) else { return false }
        runtime.requestLocationFieldFocus()
        return true
    }

    private func reloadFocusedBrowser(preferredWindowID: UUID?) -> Bool {
        guard let runtime = focusedBrowserRuntime(preferredWindowID: preferredWindowID) else { return false }
        _ = runtime.reloadOrStop()
        return true
    }

    private func saveFocusedLocalDocument(preferredWindowID: UUID?) -> Bool {
        guard let selection = focusedLocalDocumentSelection(preferredWindowID: preferredWindowID) else {
            return false
        }
        return webPanelRuntimeRegistry.saveLocalDocumentPanel(panelID: selection.panelID)
    }

    private func canEnterFocusedLocalDocumentEdit(preferredWindowID: UUID?) -> Bool {
        guard let selection = focusedLocalDocumentSelection(preferredWindowID: preferredWindowID) else {
            return false
        }
        return webPanelRuntimeRegistry.canEnterEditingLocalDocumentPanel(panelID: selection.panelID)
    }

    private func enterFocusedLocalDocumentEdit(preferredWindowID: UUID?) -> Bool {
        guard let selection = focusedLocalDocumentSelection(preferredWindowID: preferredWindowID) else {
            return false
        }
        return webPanelRuntimeRegistry.enterEditingLocalDocumentPanel(panelID: selection.panelID)
    }

    private func canCancelFocusedLocalDocumentEdit(preferredWindowID: UUID?) -> Bool {
        guard let selection = focusedLocalDocumentSelection(preferredWindowID: preferredWindowID) else {
            return false
        }
        return webPanelRuntimeRegistry.canCancelEditingLocalDocumentPanel(panelID: selection.panelID)
    }

    private func cancelFocusedLocalDocumentEdit(preferredWindowID: UUID?) -> Bool {
        guard let selection = focusedLocalDocumentSelection(preferredWindowID: preferredWindowID) else {
            return false
        }
        return webPanelRuntimeRegistry.cancelEditingLocalDocumentPanel(panelID: selection.panelID)
    }

    private func handleCancelLocalDocumentEditShortcut(preferredWindowID: UUID?) -> Bool {
        guard canCancelFocusedLocalDocumentEdit(preferredWindowID: preferredWindowID) else {
            return false
        }
        // Keep bare Escape with the active local-document editor only while it
        // has a cancelable edit session; otherwise let the embedded view or the
        // default responder handle Escape normally.
        _ = cancelFocusedLocalDocumentEdit(preferredWindowID: preferredWindowID)
        return true
    }

    private func handleEnterLocalDocumentEditShortcut(preferredWindowID: UUID?) -> Bool {
        enterFocusedLocalDocumentEdit(preferredWindowID: preferredWindowID)
    }

    private func handleSaveLocalDocumentShortcut(preferredWindowID: UUID?) -> Bool {
        guard focusedLocalDocumentSelection(preferredWindowID: preferredWindowID) != nil else {
            return false
        }
        _ = saveFocusedLocalDocument(preferredWindowID: preferredWindowID)
        // Cmd+S is app-owned for focused local-document panels, even when save is
        // currently disabled in preview mode or conflict state.
        return true
    }

    private func focusedBrowserRuntime(preferredWindowID: UUID?) -> BrowserPanelRuntime? {
        guard let selection = appOwnedFocusedBrowserSelection(preferredWindowID: preferredWindowID) else {
            return nil
        }
        return webPanelRuntimeRegistry.browserRuntime(for: selection.panelID)
    }

    private func appOwnedFocusedBrowserSelection(
        preferredWindowID: UUID?
    ) -> FocusedBrowserPanelCommandSelection? {
        guard let preferredWindowID else { return nil }
        return focusedBrowserSelection(preferredWindowID: preferredWindowID)
    }

    private func appOwnedFocusedLocalDocumentSelection(
        preferredWindowID: UUID?
    ) -> FocusedLocalDocumentPanelCommandSelection? {
        guard let preferredWindowID else { return nil }
        return focusedLocalDocumentSelection(preferredWindowID: preferredWindowID)
    }

    private func appOwnedFocusedScaleTarget(
        preferredWindowID: UUID?
    ) -> FocusedScaleCommandTarget? {
        guard let preferredWindowID,
              let store else {
            return nil
        }
        return store.focusedScaleCommandTarget(preferredWindowID: preferredWindowID)
    }

    private func focusedBrowserSelection(preferredWindowID: UUID?) -> FocusedBrowserPanelCommandSelection? {
        guard let store else { return nil }
        return store.focusedBrowserPanelSelection(preferredWindowID: preferredWindowID)
    }

    private func focusedLocalDocumentSelection(preferredWindowID: UUID?) -> FocusedLocalDocumentPanelCommandSelection? {
        guard let store else { return nil }
        return store.focusedLocalDocumentPanelSelection(preferredWindowID: preferredWindowID)
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
            initialAskBeforeQuitting: initialToasttySettings.askBeforeQuitting
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
        terminalRuntimeRegistry.bind(store: store)
        webPanelRuntimeRegistry.bind(store: store)
        terminalRuntimeRegistry.bind(webPanelRuntimeRegistry: webPanelRuntimeRegistry)
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
                ToasttyMenuActions.openTerminalProfilesConfiguration(
                    openManagedLocalDocument: { fileURL, format in
                        openManagedLocalDocumentInToastty(
                            store: store,
                            fileURL: fileURL,
                            format: format,
                            preferredWindowID: currentToasttyWorkspaceCommandWindowID(in: store)
                        )
                    }
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
            }
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
        let preferredWorkspaceCommandWindowID: () -> UUID? = {
            currentToasttyWorkspaceCommandWindowID(in: store)
        }
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
            workspaceTabCommandController: workspaceTabCommandController
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
        let paneHistoryDebugDirectoryPath = resolvedPaneHistoryDebugDirectoryPath(
            runtimePaths: runtimePaths
        )
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
                "pane_history_debug_enabled": paneHistoryDebugDirectoryPath == nil ? "false" : "true",
                "pane_history_debug_directory": paneHistoryDebugDirectoryPath ?? "none",
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
            if let paneHistoryDebugDirectoryPath {
                environment[ToasttyLaunchContextEnvironment.paneHistoryDebugLogFileKey] = URL(
                    fileURLWithPath: paneHistoryDebugDirectoryPath,
                    isDirectory: true
                )
                .appendingPathComponent("\(panelID.uuidString).log", isDirectory: false)
                .path
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

    private static func resolvedPaneHistoryDebugDirectoryPath(
        runtimePaths: ToasttyRuntimePaths
    ) -> String? {
        #if DEBUG
        return runtimePaths.defaultLogFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("pane-history-debug", isDirectory: true)
            .path
        #else
        return nil
        #endif
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
                        placement: WebPanelPlacement.rootRight
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
        switch openAgentProfilesConfigurationResult() {
        case .success:
            return
        case .failure(let error):
            let alert = NSAlert()
            alert.messageText = "Unable to Open Agent Profiles"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
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
        switch ToasttyMenuActions.openToasttyConfigResult(
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
            alert.messageText = "Unable to Open Config"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
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

    private static func localDocumentOpenTitle(for placement: WebPanelPlacement) -> String {
        switch placement {
        case .rootRight:
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
