import CoreState
import Foundation
import RemoteProtocol

/// Cancels an observation when cancelled or released.
@MainActor
public final class LinuxAppLogicSubscription {
    private var cancellable: AnyCancellable?

    init(_ cancellable: AnyCancellable) {
        self.cancellable = cancellable
    }

    public func cancel() {
        cancellable?.cancel()
        cancellable = nil
    }
}

@MainActor
private final class LinuxStateObserver {
    let handler: @MainActor (AppState) -> Void
    var lastDelivered: AppState?

    init(handler: @escaping @MainActor (AppState) -> Void) {
        self.handler = handler
    }

    func deliver(_ state: AppState) {
        lastDelivered = state
        handler(state)
    }
}

// MARK: - State and actions

extension LinuxAppLogic {
    public var state: AppState { store.state }

    /// Dispatches through `AppStore.send`, which also drives persistence,
    /// terminal/web runtime synchronization, and automation bookkeeping.
    @discardableResult
    public func send(_ action: AppAction, source: String = "linux_ui") -> Bool {
        store.send(action, source: AppActionSource(source))
    }

    /// Emits the current state, then every new state, on the main thread.
    public var statePublisher: AnyPublisher<AppState, Never> {
        store.$state.eraseToAnyPublisher()
    }

    /// `handler` runs with the current state now and after every change,
    /// once the change has landed (reading `state` inside sees it). Actions
    /// notify synchronously from `send`; wholesale replacement (restore,
    /// automation fixtures) notifies on the next main-queue turn.
    public func observeState(_ handler: @escaping @MainActor (AppState) -> Void) -> LinuxAppLogicSubscription {
        let observer = LinuxStateObserver(handler: handler)
        observer.lastDelivered = store.state
        handler(store.state)
        let token = store.addActionAppliedObserver { [weak observer] _, _, next in
            observer?.deliver(next)
        }
        let replacement = store.$state.dropFirst().sink { [weak store, weak observer] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let store, let observer, store.state != observer.lastDelivered else { return }
                    observer.deliver(store.state)
                }
            }
        }
        return LinuxAppLogicSubscription(AnyCancellable { [weak store] in
            replacement.cancel()
            MainActor.assumeIsolated { store?.removeActionAppliedObserver(token) }
            _ = observer
        })
    }

    public func window(id: UUID) -> WindowState? { store.window(id: id) }

    /// The live terminal title (the latest OSC 0/2 title after macOS's
    /// coalescing and startup-command suppression), else the panel's title.
    /// Like macOS, live titles are display state and are not persisted.
    public func terminalDisplayTitle(panelID: UUID) -> String? {
        if let live = terminalRuntimeRegistry.terminalLiveTitleStore.title(for: panelID) {
            return live
        }
        guard let selection = store.state.workspaceSelection(containingPanelID: panelID),
              case .terminal(let terminal)? = store.state.workspacesByID[selection.workspaceID]?.panelState(for: panelID) else {
            return nil
        }
        return terminal.title
    }

    /// `state` with live terminal titles folded into each terminal panel's
    /// `title`, for UIs that render titles from state.
    public var displayState: AppState {
        var state = store.state
        let titles = terminalRuntimeRegistry.terminalLiveTitleStore
        for (workspaceID, workspace) in state.workspacesByID {
            var updatedWorkspace = workspace
            var changed = false
            for (tabID, tab) in workspace.tabsByID {
                var updatedTab = tab
                for (panelID, panel) in tab.panels {
                    guard case .terminal(var terminal) = panel,
                          let live = titles.title(for: panelID),
                          live != terminal.title else { continue }
                    terminal.title = live
                    updatedTab.panels[panelID] = .terminal(terminal)
                    changed = true
                }
                updatedWorkspace.tabsByID[tabID] = updatedTab
            }
            if changed {
                state.workspacesByID[workspaceID] = updatedWorkspace
            }
        }
        return state
    }

    /// Like `observeState`, delivering `displayState`, and also when only a
    /// live terminal title changed.
    public func observeDisplayState(_ handler: @escaping @MainActor (AppState) -> Void) -> LinuxAppLogicSubscription {
        let token = UUID()
        liveTitleObservers[token] = { [weak self] in
            guard let self else { return }
            handler(self.displayState)
        }
        let stateSubscription = observeState { [weak self] _ in
            guard let self else { return }
            handler(self.displayState)
        }
        return LinuxAppLogicSubscription(AnyCancellable { [weak self] in
            stateSubscription.cancel()
            MainActor.assumeIsolated { _ = self?.liveTitleObservers.removeValue(forKey: token) }
        })
    }

    /// Subscribes to a panel's live title once (called when a title arrives).
    func watchLiveTitle(panelID: UUID) {
        guard liveTitleSubscriptions[panelID] == nil else { return }
        let model = terminalRuntimeRegistry.terminalLiveTitleStore.model(for: panelID)
        liveTitleSubscriptions[panelID] = model.$title.dropFirst().sink { [weak self] _ in
            // @Published fires before the value lands; notify after.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for observer in Array(self.liveTitleObservers.values) { observer() }
                }
            }
        }
    }

    // Navigation history (Back/Forward).
    @discardableResult public func navigateBack() -> Bool { store.navigateBack() }
    @discardableResult public func navigateForward() -> Bool { store.navigateForward() }

    /// "Next unread / attention" (Cmd+Shift+A on macOS).
    @discardableResult
    public func focusNextUnreadOrActivePanel(windowID: UUID?) -> Bool {
        store.focusNextUnreadOrActivePanelFromCommand(
            preferredWindowID: windowID,
            sessionRuntimeStore: sessionRuntimeStore
        )
    }

    /// Closes the focused panel with the macOS confirmation rules (running
    /// process, unsaved document). Returns whether a panel closed.
    @discardableResult
    public func closeFocusedPanel(workspaceID: UUID? = nil) -> Bool {
        focusedPanelCommandController.closeFocusedPanel(
            in: workspaceID,
            confirmationPolicy: .interactive
        ) == .closed
    }

    @discardableResult
    public func closePanel(panelID: UUID) -> Bool {
        focusedPanelCommandController.closePanel(panelID: panelID, confirmationPolicy: .interactive) == .closed
    }

    /// "Watch running command" for the focused terminal.
    @discardableResult
    public func watchRunningCommand(windowID: UUID?) -> Bool {
        processWatchCommandController.watchFocusedProcess(preferredWindowID: windowID)
    }
}

// MARK: - Sessions (sidebar rows, later flags)

extension LinuxAppLogic {
    public func sessionStatuses(workspaceID: UUID) -> [WorkspaceSessionStatus] {
        sessionRuntimeStore.workspaceStatuses(for: workspaceID)
    }

    public func sessionStatus(panelID: UUID) -> WorkspaceSessionStatus? {
        sessionRuntimeStore.panelStatus(for: panelID)
    }

    public func isLaterFlagged(sessionID: String) -> Bool {
        sessionRuntimeStore.isLaterFlagged(sessionID: sessionID)
    }

    public func setLaterFlag(sessionID: String, isFlagged: Bool) {
        sessionRuntimeStore.setLaterFlag(sessionID: sessionID, isFlagged: isFlagged)
    }

    /// Fires (on the main thread, before the change lands, like
    /// `objectWillChange`) whenever session rows may change; re-read on the
    /// next main-loop turn.
    public var sessionsWillChangePublisher: AnyPublisher<Void, Never> {
        sessionRuntimeStore.objectWillChange.map { _ in () }.eraseToAnyPublisher()
    }

    /// `handler` runs after session state changed (coalesced per turn).
    public func observeSessions(_ handler: @escaping @MainActor () -> Void) -> LinuxAppLogicSubscription {
        LinuxAppLogicSubscription(sessionRuntimeStore.$sessionRegistry.sink { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { handler() } }
        })
    }
}

// MARK: - Agents

public struct LinuxAgentProfileSummary: Sendable, Equatable {
    public var profileID: String
    public var displayName: String
    public var agentKind: String
    public var isInstalled: Bool
}

extension LinuxAppLogic {
    public var agentProfiles: [LinuxAgentProfileSummary] {
        agentLaunchService.launchProfileSummaries().map {
            LinuxAgentProfileSummary(
                profileID: $0.profileID,
                displayName: $0.displayName,
                agentKind: $0.agent.rawValue,
                isInstalled: $0.isInstalled
            )
        }
    }

    /// Launches a managed agent in the focused terminal of `workspaceID`
    /// (or a new one, as macOS decides). Returns the session ID.
    public func launchAgent(profileID: String, workspaceID: UUID? = nil, panelID: UUID? = nil) throws -> String {
        try agentLaunchService.launch(profileID: profileID, workspaceID: workspaceID, panelID: panelID).sessionID
    }

    /// `~/.toastty/agents.toml` as parsed (profiles, shortcut keys, whether
    /// the header shows agent buttons).
    public var agentCatalog: AgentCatalog { agentCatalogStore.catalog }
    public var agentProfilesFilePath: String { agentCatalogStore.fileURL.path }

    /// `handler` runs after the agent catalog changes (reloads).
    public func observeAgentCatalog(_ handler: @escaping @MainActor () -> Void) -> LinuxAppLogicSubscription {
        LinuxAppLogicSubscription(agentCatalogStore.$catalog.dropFirst().sink { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { handler() } }
        })
    }

    /// Whether the header button / palette entry / shortcut for `profileID`
    /// can launch in `windowID`'s workspace (macOS `canLaunchAgent`).
    public func canLaunchAgent(profileID: String, windowID: UUID) -> Bool {
        agentLaunchService.canLaunchAgent(
            profileID: profileID,
            workspaceID: store.commandSelection(preferredWindowID: windowID)?.workspace.id
        )
    }

    /// The macOS UI launch path (`AgentLaunchUI`): Codex status-hook preflight,
    /// asynchronous launch, and an alert when it fails.
    @discardableResult
    public func launchAgentFromUI(profileID: String, windowID: UUID) -> Bool {
        AgentLaunchUI.launch(
            profileID: profileID,
            workspaceID: store.commandSelection(preferredWindowID: windowID)?.workspace.id,
            originWindowID: windowID,
            agentLaunchService: agentLaunchService
        )
    }
}

// MARK: - Terminal seam

extension LinuxAppLogic {
    /// What the frontend needs to spawn the shell for a terminal panel. Also
    /// creates the panel's runtime controller. `nil` if the panel is not a
    /// live terminal.
    public func terminalLaunchConfiguration(panelID: UUID) -> LinuxTerminalLaunchConfiguration? {
        guard let selection = store.state.workspaceSelection(containingPanelID: panelID),
              let workspace = store.state.workspacesByID[selection.workspaceID],
              case .terminal(let terminalState)? = workspace.panelState(for: panelID) else {
            return nil
        }
        _ = terminalRuntimeRegistry.controller(
            for: panelID,
            workspaceID: selection.workspaceID,
            windowID: selection.windowID
        )
        let launch = terminalRuntimeRegistry.surfaceLaunchConfiguration(for: panelID)
        // Bind the shell the frontend is about to spawn (process cwd fallback).
        pendingSurfaceChildSnapshots[panelID] = terminalMetadataService.snapshotChildPIDsForSurfaceCreation()
        let workingDirectory = launch.normalizedWorkingDirectoryOverride ?? terminalState.workingDirectorySeed
        return LinuxTerminalLaunchConfiguration(
            environment: launch.environmentVariables,
            workingDirectory: TerminalRuntimeRegistry.normalizedCWDValue(workingDirectory)
                .map { TerminalLaunchWorkingDirectory.existing($0) },
            initialInput: launch.normalizedInitialInput,
            fontSizePoints: store.state.effectiveTerminalFontPoints(for: selection.windowID)
        )
    }

    /// The frontend's widget for `panelID` is realized; terminal operations
    /// (send text, read text, search, focus, prompt state) now reach it.
    public func attachTerminalSurface(_ surface: any LinuxTerminalSurface, panelID: UUID) {
        guard let selection = store.state.workspaceSelection(containingPanelID: panelID) else { return }
        terminalRuntimeRegistry.controller(
            for: panelID,
            workspaceID: selection.workspaceID,
            windowID: selection.windowID
        ).attach(surface: surface)
    }

    public func detachTerminalSurface(panelID: UUID) {
        existingTerminalController(panelID: panelID)?.detachSurface()
    }

    /// The shell process started (after `terminalLaunchConfiguration`).
    /// Restored managed agents submit their resume command after this.
    public func terminalSurfaceDidLaunch(panelID: UUID) {
        if let previousChildren = pendingSurfaceChildSnapshots.removeValue(forKey: panelID),
           let selection = store.state.workspaceSelection(containingPanelID: panelID),
           case .terminal(let terminalState)? = store.state.workspacesByID[selection.workspaceID]?.panelState(for: panelID) {
            let hostState = TerminalPanelHostState(terminalState: terminalState)
            terminalMetadataService.registerChildPIDAfterSurfaceCreation(
                panelID: panelID,
                previousChildren: previousChildren,
                expectedWorkingDirectory: hostState.expectedProcessWorkingDirectory ?? hostState.workingDirectorySeed,
                isRestoredLaunch: hostState.expectedProcessWorkingDirectory == nil
                    && TerminalRuntimeRegistry.normalizedCWDValue(hostState.launchWorkingDirectory) != nil
            )
        }
        terminalRuntimeRegistry.markInitialSurfaceLaunchCompleted(for: panelID)
    }

    /// Keyboard or paste input reached the terminal (closes remote-send
    /// drafts, like macOS). `isPaste` distinguishes paste from key presses.
    public func terminalDidReceiveLocalInput(panelID: UUID, isPaste: Bool = false) {
        existingTerminalController(panelID: panelID)?.noteLocalInput(kind: isPaste ? .paste : .key)
    }

    /// Ctrl+C / Escape reached the terminal (agent interrupt tracking).
    public func terminalDidReceiveInterruptKey(panelID: UUID, isEscape: Bool) {
        existingTerminalController(panelID: panelID)?.noteLocalInterruptKey(kind: isEscape ? .escape : .controlC)
    }

    /// Title (OSC 0/2) and working directory (OSC 7) through the same
    /// normalization as macOS (`TerminalMetadataService`). Equivalent to
    /// `handleTerminalRuntimeEvent` with `.title` / `.workingDirectory`.
    public func reportTerminalMetadata(panelID: UUID, title: String?, workingDirectory: String?) {
        if let title {
            handleTerminalRuntimeEvent(panelID: panelID, event: .title(title))
        }
        if let workingDirectory {
            handleTerminalRuntimeEvent(panelID: panelID, event: .workingDirectory(workingDirectory))
        }
    }

    /// Routes a Ghostty runtime action for `panelID` the way macOS's
    /// `TerminalRuntimeRegistry.handleGhosttyRuntimeAction` does: title/cwd
    /// and command-finished through `TerminalMetadataService` (session
    /// lifecycle, pane journal), OSC 9/777 notifications through its
    /// desktop-notification path (unread marking, `SystemNotificationSender`,
    /// managed-session suppression), OSC 7501 program status/reset through
    /// `SessionRuntimeStore` (sidebar rows), child exit into close/prompt
    /// state. Returns whether the event was handled; `.bell` is not (macOS
    /// leaves the bell to Ghostty).
    @discardableResult
    public func handleTerminalRuntimeEvent(panelID: UUID, event: LinuxTerminalRuntimeEvent) -> Bool {
        let state = store.state
        guard let selection = state.workspaceSelection(containingPanelID: panelID) else { return false }
        let workspaceID = selection.workspaceID
        switch event {
        case .title(let title):
            watchLiveTitle(panelID: panelID)
            return terminalMetadataService.handleRuntimeMetadataAction(
                .setTerminalTitle(title), workspaceID: workspaceID, panelID: panelID, state: state
            )
        case .workingDirectory(let cwd):
            return terminalMetadataService.handleRuntimeMetadataAction(
                .setTerminalCWD(cwd), workspaceID: workspaceID, panelID: panelID, state: state
            )
        case .commandFinished(let exitCode, _):
            return terminalMetadataService.handleRuntimeMetadataAction(
                .commandFinished(exitCode: exitCode), workspaceID: workspaceID, panelID: panelID, state: state
            )
        case .childExited(let exitCode, _):
            existingTerminalController(panelID: panelID)?.markExited()
            ToasttyLog.debug(
                "Marked terminal panel as exited",
                category: .terminal,
                metadata: ["panel_id": panelID.uuidString, "exit_code": String(exitCode)]
            )
            return true
        case .programStatus(let statusEvent):
            sessionRuntimeStore.handleProgramStatusEvent(statusEvent, panelID: panelID)
            return true
        case .desktopNotification(let title, let body):
            return terminalMetadataService.handleDesktopNotification(
                title: title, body: body, workspaceID: workspaceID, panelID: panelID, state: state
            )
        case .bell:
            return false
        }
    }

    /// Cmd/Ctrl-click on a terminal link: local documents open in a Toastty
    /// panel, directories and local HTML per routing preferences, other URLs
    /// in the browser panel or the desktop handler (macOS
    /// `openCommandClickLink`). `alternate` flips the placement preference.
    @discardableResult
    public func openTerminalLink(panelID: UUID, url: URL, alternate: Bool) -> Bool {
        terminalRuntimeRegistry.openCommandClickLink(url, useAlternatePlacement: alternate, from: panelID)
    }

    /// Ghostty's configured `font-size` (the baseline Toastty's font steps
    /// start from). Call once Ghostty's config is loaded and after reloads.
    public func setGhosttyConfiguredFontPoints(_ points: Double?) {
        LinuxAppConfiguration.ghosttyConfiguredFontPoints = points
        let config = isAutomationMode ? ToasttyConfig() : ToasttyConfigStore.load()
        LinuxAppConfiguration.applyTerminalFontState(
            to: store,
            config: config,
            legacyTerminalFontSizePoints: nil,
            ghosttyConfiguredTerminalFontPoints: points
        )
    }

    private func existingTerminalController(panelID: UUID) -> TerminalSurfaceController? {
        guard let selection = store.state.workspaceSelection(containingPanelID: panelID) else { return nil }
        return terminalRuntimeRegistry.controller(
            for: panelID,
            workspaceID: selection.workspaceID,
            windowID: selection.windowID
        )
    }
}

/// Ghostty runtime actions the terminal frontend reports per panel.
public enum LinuxTerminalRuntimeEvent: Sendable, Equatable {
    case title(String)
    case workingDirectory(String)
    case bell
    case commandFinished(exitCode: Int?, durationNanoseconds: UInt64)
    case childExited(exitCode: Int, runtimeMilliseconds: UInt64)
    case programStatus(TerminalProgramStatusEvent)
    case desktopNotification(title: String, body: String)
}

// MARK: - Web panel seam

extension LinuxAppLogic {
    public func attachBrowserHost(_ host: any LinuxBrowserPanelHost, panelID: UUID) {
        webPanelRuntimeRegistry.browserRuntime(for: panelID).attach(host: host)
    }

    public func detachBrowserHost(panelID: UUID) {
        webPanelRuntimeRegistry.browserRuntime(for: panelID).detachHost()
    }

    /// Builds the frontend browser for a panel that has none (never shown),
    /// off screen, and attaches it, so `panel.browser.state` and
    /// `panel.browser.reload` load hidden panels in the background as on macOS.
    public func setBrowserHostMaterializer(_ materialize: (@MainActor (UUID) -> Void)?) {
        LinuxBrowserHostMaterializer.materialize = materialize
    }

    /// Main-frame navigation results (`panel.browser.state` `navigationState`
    /// and `navigationError`).
    public func browserNavigationDidChange(panelID: UUID, event: LinuxBrowserNavigationEvent) {
        webPanelRuntimeRegistry.browserRuntime(for: panelID).hostDidReport(event)
    }

    /// Browser callbacks: title/URL changed, user clicked into the page,
    /// a link wants a new panel/tab (returns whether Toastty routed it).
    public func browserDidUpdate(panelID: UUID, title: String?, url: String?) {
        webPanelRuntimeRegistry.browserRuntime(for: panelID).hostDidUpdateMetadata(title: title, url: url)
    }

    public func browserDidRequestFocus(panelID: UUID) {
        webPanelRuntimeRegistry.browserRuntime(for: panelID).hostDidRequestFocus()
    }

    public func browserRequestsSecondaryOpen(panelID: UUID, url: URL) -> Bool {
        // AppURLRouter hands file:// HTML and toastty:// pages to the
        // system opener (macOS NSWorkspace reopens them in a browser or in
        // Toastty itself). xdg-open has neither route, so on Linux they open
        // in a Toastty browser tab, as a terminal click on a local HTML file
        // does on macOS (TerminalCommandClickTarget.localBrowserFile).
        let scheme = url.scheme?.lowercased()
        if scheme == "toastty" || LocalBrowserFileLinkResolver.resolvedLocalBrowserFileURL(for: url) != nil {
            let windowID = store.state.workspaceSelection(containingPanelID: panelID)?.windowID
            if store.openURLInBrowser(
                preferredWindowID: windowID,
                url: url,
                placement: store.urlRoutingPreferences.resolvedBrowserPlacement(alternateOpen: false)
            ) {
                return true
            }
        }
        return webPanelRuntimeRegistry.browserRuntime(for: panelID).hostRequestsSecondaryOpen(url)
    }

    public func attachLocalDocumentHost(_ host: any LinuxLocalDocumentPanelHost, panelID: UUID) {
        webPanelRuntimeRegistry.localDocumentRuntime(for: panelID).attach(host: host)
    }

    public func detachLocalDocumentHost(panelID: UUID) {
        webPanelRuntimeRegistry.localDocumentRuntime(for: panelID).detachHost()
    }

    public func attachScratchpadHost(_ host: any LinuxScratchpadPanelHost, panelID: UUID) {
        webPanelRuntimeRegistry.scratchpadRuntime(for: panelID).attach(host: host)
    }

    public func detachScratchpadHost(panelID: UUID) {
        webPanelRuntimeRegistry.scratchpadRuntime(for: panelID).detachHost()
    }

    /// Scratchpad document HTML for a panel's document (the store is shared
    /// with the automation socket's `panel.scratchpad.*` commands).
    public func scratchpadDocumentContent(documentID: UUID) -> String? {
        try? webPanelRuntimeRegistry.scratchpadDocumentStore.load(documentID: documentID)?.content
    }
}

// MARK: - Remote Access

/// Remote Access state for the preferences page and pairing dialog.
public struct LinuxRemoteAccessStatus: Equatable, Sendable {
    public enum Indicator: Sendable, Equatable {
        case off
        case progress
        case ready
        case failure
    }

    public var isEnabled: Bool
    public var isReady: Bool
    public var indicator: Indicator
    public var title: String
    public var detail: String
    public var port: UInt16?
    public var tailnetOrigin: String
    public var connectedClientCount: Int
    public var devices: [RemoteDeviceRecord]
    /// Present while a pairing offer is open.
    public var pairingFallbackCode: String?
    public var pairingExpiresAt: Date?
    public var pairingError: String?
    public var canIssuePairingOffer: Bool
    /// Phone push notifications need a relay (TOASTTY_PUSH_RELAY_URL/ID/
    /// APNS_ENVIRONMENT on Linux); without one, phones only see live updates.
    public var isPushRelayConfigured: Bool
}

extension LinuxAppLogic {
    public var isRemoteAccessAvailable: Bool { remoteAccessService != nil }

    public var remoteAccessStatus: LinuxRemoteAccessStatus? {
        guard let service = remoteAccessService else { return nil }
        let presentation = RemoteAccessConnectionStatusPresentation.make(
            activationState: service.activationState,
            tailnetSetupState: service.tailnetSetupState,
            connectedNativeClientCount: service.connectedNativeClientCount,
            hasPairedNativeDevice: service.devices.contains { $0.authKind == .native && $0.isRevoked == false },
            hasUnrevokedDevice: service.devices.contains { $0.isRevoked == false },
            hasPendingPairing: service.currentPairingCode != nil || service.currentNativePairingOffer != nil,
            hasSavedOrigin: service.tailnetOrigin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        )
        let indicator: LinuxRemoteAccessStatus.Indicator = switch presentation.indicator {
        case .off: .off
        case .progress: .progress
        case .ready: .ready
        case .failure: .failure
        }
        return LinuxRemoteAccessStatus(
            isEnabled: service.isEnabled,
            isReady: service.isReady,
            indicator: indicator,
            title: presentation.title,
            detail: presentation.detail,
            port: service.listeningPort,
            tailnetOrigin: service.tailnetOrigin,
            connectedClientCount: service.connectedClientCount,
            devices: service.devices,
            pairingFallbackCode: service.currentNativePairingOffer?.fallbackCode,
            pairingExpiresAt: service.currentNativePairingOffer?.expiresAt,
            pairingError: service.nativePairingError,
            canIssuePairingOffer: service.canIssueNativePairingOffer,
            isPushRelayConfigured: LinuxAppConfiguration.pushConfiguration(environment: ProcessInfo.processInfo.environment) != nil
        )
    }

    /// Fires whenever any Remote Access state changes (main thread).
    public var remoteAccessWillChangePublisher: AnyPublisher<Void, Never>? {
        remoteAccessService?.objectWillChange.map { _ in () }.eraseToAnyPublisher()
    }

    /// The preferences switch: turning on also configures Tailscale Serve.
    public func setRemoteAccessEnabled(_ enabled: Bool) {
        remoteAccessService?.setEnabledFromSettings(enabled)
    }

    public func setRemoteAccessTailnetOrigin(_ origin: String) {
        remoteAccessService?.tailnetOrigin = origin
    }

    public func retryRemoteAccessTailnetSetup() {
        remoteAccessService?.setUpTailnetAccess()
    }

    /// Opens a native pairing offer. Read `remoteAccessPairingQRCodePNG`.
    public func issueRemoteAccessPairingOffer() {
        remoteAccessService?.issueNativePairingOffer()
    }

    public func cancelRemoteAccessPairingOffer() {
        remoteAccessService?.cancelNativePairingOffer()
    }

    /// The open offer's QR code as PNG (8 px per module, 4-module quiet zone).
    public var remoteAccessPairingQRCodePNG: Data? {
        remoteAccessService?.currentNativePairingQRCode?.pngData
    }

    public func revokeRemoteAccessDevice(_ deviceID: UUID) {
        remoteAccessService?.revokeDevice(deviceID)
    }

    public func revokeAllRemoteAccessDevices() {
        remoteAccessService?.revokeAllDevices()
    }
}

// MARK: - App commands

/// Result of `performAppCommand`.
public enum LinuxAppCommandOutcome: Equatable, Sendable {
    case handled
    /// Not an app-logic command (the UI handles it or reports it).
    case notHandled
    case failed(String)
}

extension LinuxAppLogic {
    /// The app-level commands from the Toastty command table that need
    /// app-logic services (macOS wires these in `ToasttyApp` /
    /// `CommandPaletteActionHandler`). IDs match `LinuxCommandTable`.
    public func performAppCommand(_ commandID: String, windowID: UUID?) -> LinuxAppCommandOutcome {
        switch commandID {
        case "app.reload-configuration":
            reloadConfiguration()
            return .handled
        case "navigation.back":
            return navigateBack() ? .handled : .failed("No earlier location")
        case "navigation.forward":
            return navigateForward() ? .handled : .failed("No later location")
        case "panel.focus-next-unread-or-active":
            _ = focusNextUnreadOrActivePanel(windowID: windowID)
            return .handled
        case "panel.process-watch.create":
            return watchRunningCommand(windowID: windowID) ? .handled : .failed("No running command to watch")
        case "scratchpad.create":
            guard let workspaceID = store.commandSelection(preferredWindowID: windowID)?.workspace.id else {
                return .failed("No workspace for a Scratchpad")
            }
            do {
                _ = try store.createBlankScratchpadPanel(
                    workspaceID: workspaceID,
                    documentStore: webPanelRuntimeRegistry.scratchpadDocumentStore
                )
                return .handled
            } catch {
                return .failed("Scratchpad creation failed: \(error.localizedDescription)")
            }
        case "scratchpad.show-current-session":
            return store.showScratchpadForCurrentSession(
                preferredWindowID: windowID,
                sessionRuntimeStore: sessionRuntimeStore,
                documentStore: webPanelRuntimeRegistry.scratchpadDocumentStore
            ) ? .handled : .failed("The focused session has no Scratchpad")
        case "app.config.manage":
            try? ToasttyConfigStore.ensureTemplateExists()
            return openConfigurationFile(ToasttyConfigStore.configFileURL(), format: .toml, windowID: windowID)
        case "terminal.profiles.manage":
            try? TerminalProfilesFile.ensureTemplateExists()
            return openConfigurationFile(TerminalProfilesFile.fileURL(), format: .toml, windowID: windowID)
        case "agent.profiles.manage":
            try? AgentProfilesFile.ensureTemplateExists()
            return openConfigurationFile(AgentProfilesFile.fileURL(), format: .toml, windowID: windowID)
        case "agent.status-hooks.setup":
            do {
                _ = try CodexStatusHookInstaller().install()
                return .handled
            } catch {
                return .failed("Unable to set up Codex status hooks: \(error.localizedDescription)")
            }
        case "diagnostics.snippet.copy":
            guard let skillPath = DiagnosticsSkillHandoffGenerator.bundledSkillPath(),
                  let cliPath = cliExecutablePath else {
                return .failed("The diagnostics skill or CLI is not installed")
            }
            let prompt = DiagnosticsSkillHandoffGenerator.prompt(skillPath: skillPath, cliPath: cliPath)
            return NSPasteboard.general.setString(prompt, forType: .string) ? .handled : .failed("Clipboard unavailable")
        default:
            return .notHandled
        }
    }

    /// Opens a Toastty configuration file in a local-document panel (macOS
    /// opens managed config files inside Toastty), else with the desktop.
    private func openConfigurationFile(_ url: URL, format: LocalDocumentFormat, windowID: UUID?) -> LinuxAppCommandOutcome {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let opened = store.createLocalDocumentPanelFromCommand(
            preferredWindowID: windowID,
            request: LocalDocumentPanelCreateRequest(
                filePath: path,
                placementOverride: store.localDocumentRoutingPreferences.openingPlacement.webPanelPlacement,
                formatOverride: format
            )
        )
        if opened { return .handled }
        return NSWorkspace.shared.open(url) ? .handled : .failed("Couldn't open \(path)")
    }
}
