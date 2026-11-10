import CoreState
import Foundation
import RemoteProtocol

/// The UI-free Toastty application on Linux: the same AppStore, automation
/// socket, managed agents, hooks, session runtime, persistence, and Remote
/// Access backend the macOS app builds in `ToasttyApp.init`, constructed in
/// the same order. The GTK frontend owns one instance for the process.
///
/// Everything in Sources/App is module-internal, so this class is the public
/// surface the frontend uses: state + actions, observation (callbacks or
/// OpenCombine publishers), the terminal and web-panel seams, and app-level
/// commands. Call from the main thread only.
@MainActor
public final class LinuxAppLogic {
    public struct Options {
        /// `toastty` and `toastty-agent-shim` binaries. Default: next to the
        /// running executable (`linux/.build/<config>/`), as on macOS.
        public var cliExecutablePath: String?
        public var agentShimExecutablePath: String?
        /// Sources/App/Resources (setup docs, web panels, workspace-pull-request.py).
        /// Default: $TOASTTY_APP_RESOURCES_PATH, <exe>/../share/toastty/Resources,
        /// <exe>/Resources, or the checkout's Sources/App/Resources.
        public var appResourcesPath: String?
        /// Desktop services (alerts, URLs, clipboard, notifications). Default:
        /// keep whatever `LinuxPlatform.services` holds (headless).
        public var platformServices: (any LinuxPlatformServices)?
        /// Start the automation socket (the CLI and agent hooks need it).
        public var startsAutomationSocket: Bool
        /// Allow Remote Access to start when it was left enabled.
        public var allowsRemoteAccess: Bool
        /// Run the startup-only skill-artifact sweep and Codex hook maintenance.
        public var runsBackgroundMaintenance: Bool
        /// Test seams: gateway port and the Tailscale Serve step.
        var remoteAccessPort: UInt16?
        var remoteAccessTailnetServeSetup: RemoteAccessService.TailnetServeSetup?

        public init(
            cliExecutablePath: String? = nil,
            agentShimExecutablePath: String? = nil,
            appResourcesPath: String? = nil,
            platformServices: (any LinuxPlatformServices)? = nil,
            startsAutomationSocket: Bool = true,
            allowsRemoteAccess: Bool = true,
            runsBackgroundMaintenance: Bool = true
        ) {
            self.cliExecutablePath = cliExecutablePath
            self.agentShimExecutablePath = agentShimExecutablePath
            self.appResourcesPath = appResourcesPath
            self.platformServices = platformServices
            self.startsAutomationSocket = startsAutomationSocket
            self.allowsRemoteAccess = allowsRemoteAccess
            self.runsBackgroundMaintenance = runsBackgroundMaintenance
        }

        /// Scripted UI runs: stand in for `tailscale serve` with a fixed
        /// origin (and optionally a gateway port), so the pairing UI can be
        /// exercised without touching the real tailnet.
        public mutating func simulateTailnet(origin: String, port: UInt16?) {
            remoteAccessTailnetServeSetup = { _, _, _ in origin }
            remoteAccessPort = port
        }
    }

    // MARK: Components (module-internal; tests and the Linux layer use them)

    let runtimePaths: ToasttyRuntimePaths
    let store: AppStore
    let agentCatalogStore: AgentCatalogStore
    let terminalProfileStore: TerminalProfileStore
    let terminalRuntimeRegistry: TerminalRuntimeRegistry
    let webPanelRuntimeRegistry: WebPanelRuntimeRegistry
    let sessionRuntimeStore: SessionRuntimeStore
    let annotationStyleStore: AnnotationStyleStore
    let agentHookDispatcher: AgentHookDispatcher
    let agentLaunchService: AgentLaunchService
    let focusedPanelCommandController: FocusedPanelCommandController
    let processWatchCommandController: ProcessWatchCommandController
    let remoteAccessService: RemoteAccessService?
    /// The Ghostty metadata path (title/cwd normalization, command-finished
    /// session lifecycle, terminal desktop notifications). On macOS the
    /// registry owns it behind TOASTTY_HAS_GHOSTTY_KIT; on Linux the facade
    /// does and feeds it from `handleTerminalRuntimeEvent`.
    let terminalMetadataService: TerminalMetadataService
    private var terminalMetadataSync: AnyCancellable?
    /// Unanswered Codex questions (see `LinuxAppLogic+CodexQuestions.swift`).
    var codexQuestionMonitor: CodexPendingQuestionMonitor?
    let codexQuestionChanges = PassthroughSubject<Void, Never>()
    var pendingSurfaceChildSnapshots: [UUID: Set<pid_t>] = [:]
    var liveTitleSubscriptions: [UUID: AnyCancellable] = [:]
    var liveTitleObservers: [UUID: @MainActor () -> Void] = [:]
    private(set) var automationSocketServer: AutomationSocketServer?
    let automationLifecycle: AutomationLifecycle?
    private let systemNotificationResponseCoordinator: SystemNotificationResponseCoordinator
    private let scratchpadSessionLinkCleanupCoordinator: ScratchpadSessionLinkCleanupCoordinator
    private let terminalReadActivityCleanupCoordinator: TerminalReadActivityCleanupCoordinator
    private let workspaceMergeCoordinator: WorkspaceMergeCoordinator
    private let persistenceCoordinator: WorkspaceLayoutPersistenceCoordinator?
    private let persistenceObserverToken: UUID?
    private let displayDiagnosticsObserver: WorkspaceLayoutDisplayDiagnosticsObserver?
    private let configuration: LinuxAppConfiguration

    // MARK: Public facts

    /// The automation socket this instance listens on (`TOASTTY_SOCKET_PATH`
    /// for terminals it launches).
    public let socketPath: String
    public let cliExecutablePath: String?
    public let agentShimExecutablePath: String?
    public let appResourcesPath: String?
    /// Set when the automation socket could not start.
    public private(set) var automationStartupError: String?
    /// `true` when launched with `--automation` / TOASTTY_AUTOMATION (smoke runs).
    public var isAutomationMode: Bool { automationLifecycle != nil }
    public var runtimeHomePath: String? { runtimePaths.runtimeHomeURL?.path }
    /// Desktop notifications this runtime delivered and has not withdrawn
    /// (the GTK frontend withdraws a crashed run's leftovers at startup).
    /// Per runtime home, so isolated runs never touch another run's list.
    public var desktopNotificationLedgerURL: URL {
        runtimePaths.configDirectoryURL.appendingPathComponent("linux-desktop-notifications.json")
    }

    private var isShutDown = false

    // MARK: Bootstrap

    /// Builds the app in macOS boot order (`ToasttyApp.init`):
    /// runtime environment → templates → config/settings → layout restore
    /// (`AppBootstrap.make`) → socket path + instance record → AppStore →
    /// catalogs → runtime registries → helper staging + agent command shims →
    /// launch environment → hook dispatcher → session runtime → merge,
    /// annotations, notifications → config state → agent launch service →
    /// Remote Access → layout persistence → automation socket → background
    /// maintenance.
    public init(options: Options = Options()) {
        if let services = options.platformServices {
            LinuxPlatform.install(services)
        }
        LinuxProcessSignals.ignoreSIGPIPE()

        // Like macOS, configuration comes from this process's arguments and
        // environment (automation mode, runtime isolation, socket overrides).
        let processInfo = ProcessInfo.processInfo
        let resolvedResourcesPath = options.appResourcesPath
            ?? Self.defaultAppResourcesPath(environment: processInfo.environment)
        if let resolvedResourcesPath,
           processInfo.environment[ToasttyLaunchContextEnvironment.appResourcesPathKey] == nil {
            // SetupResourceResolver and the CLI find setup docs through this.
            setenv(ToasttyLaunchContextEnvironment.appResourcesPathKey, resolvedResourcesPath, 0)
        }
        let environment = processInfo.environment
        let runtimePaths = ToasttyRuntimePaths.resolve(environment: environment)
        let automationConfig = AutomationConfig.parse(arguments: processInfo.arguments, environment: environment)
        let usesPersistentPreferences = automationConfig == nil

        let setupFootprint = usesPersistentPreferences
            ? GettingStartedEligibility.setupFootprint(
                runtimePaths: runtimePaths,
                userDefaults: ToasttyAppDefaults.current,
                homeDirectoryPath: NSHomeDirectory(),
                environment: environment
            )
            : GettingStartedSetupFootprint()
        let createsSetupTemplates = GettingStartedEligibility.shouldCreateStartupSetupTemplates(
            usesPersistentPreferences: usesPersistentPreferences,
            setupFootprint: setupFootprint
        )
        LinuxAppConfiguration.prepareRuntimeEnvironment(runtimePaths)
        if createsSetupTemplates {
            LinuxAppConfiguration.ensureTerminalProfilesTemplateExists()
        }
        LinuxAppConfiguration.refreshManagedShellIntegrationSnippetIfInstalled(environment: environment)

        let terminalProfileStore = TerminalProfileStore()
        let initialConfig = usesPersistentPreferences ? ToasttyConfigStore.load() : ToasttyConfig()
        let initialSettings = usesPersistentPreferences ? ToasttySettingsStore.load() : ToasttySettings()
        let legacyTerminalFontSizePoints = usesPersistentPreferences
            ? ToasttySettingsStore.legacyTerminalFontSizePoints()
            : nil
        let initialDefaultTerminalProfileID = usesPersistentPreferences
            ? LinuxAppConfiguration.resolvedDefaultTerminalProfileID(
                configuredDefaultTerminalProfileID: initialConfig.defaultTerminalProfileID,
                terminalProfileCatalog: terminalProfileStore.catalog,
                source: "startup"
            )
            : nil
        let bootstrap = AppBootstrap.make(
            processInfo: processInfo,
            defaultTerminalProfileID: initialDefaultTerminalProfileID,
            createAgentProfilesTemplate: createsSetupTemplates
        )
        if usesPersistentPreferences {
            LinuxAppConfiguration.prunePaneRestoreFiles(
                runtimePaths: runtimePaths,
                liveTerminalPanelIDs: bootstrap.state.allTerminalPanelIDs
            )
        }

        let preferredSocketPath = bootstrap.automationConfig?.socketPath
            ?? AutomationConfig.resolveServerSocketPath(environment: environment)
        let socketPath = AutomationSocketServer.recommendedSocketPath(
            preferredSocketPath: preferredSocketPath,
            environment: environment
        )
        bootstrap.automationLifecycle?.updateSocketPath(socketPath)
        ToasttyRuntimeInstanceRecorder.recordLaunch(
            processInfo: processInfo,
            automationConfig: bootstrap.automationConfig,
            socketPathOverride: socketPath
        )

        let store = AppStore(
            state: bootstrap.state,
            persistTerminalFontPreference: usesPersistentPreferences,
            initialHasEverLaunchedAgent: initialSettings.hasEverLaunchedAgent,
            initialAskBeforeQuitting: initialSettings.askBeforeQuitting,
            initialWorkspaceMergeMode: initialSettings.workspaceMergeMode,
            isWorkspaceMergeEnabled: initialSettings.isWorkspaceMergeEnabled,
            recentRightPanelItemsStore: RightPanelRecentItemsStore(runtimePaths: runtimePaths)
        )
        let agentCatalogStore = AgentCatalogStore()
        let shortcutWarnings = ProfileShortcutRegistry(
            terminalProfiles: terminalProfileStore.catalog,
            terminalProfilesFilePath: terminalProfileStore.fileURL.path,
            agentProfiles: agentCatalogStore.catalog,
            agentProfilesFilePath: agentCatalogStore.fileURL.path
        ).warningMessages
        for warning in shortcutWarnings {
            ToasttyLog.warning(warning, category: .bootstrap)
        }

        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        let webPanelRuntimeRegistry = WebPanelRuntimeRegistry()

        let explicitCLIPath = options.cliExecutablePath
        let explicitShimPath = options.agentShimExecutablePath
        let helperPaths: ManagedAgentHelperPaths
        do {
            helperPaths = try ManagedAgentHelperInstaller(
                runtimePaths: runtimePaths,
                cliExecutablePathProvider: {
                    explicitCLIPath ?? ToasttyBundledExecutableLocator.defaultCLIExecutablePath()
                },
                agentShimExecutablePathProvider: {
                    explicitShimPath ?? ToasttyBundledExecutableLocator.defaultAgentShimExecutablePath()
                }
            ).resolvePaths()
        } catch {
            helperPaths = ManagedAgentHelperPaths(
                cliExecutablePath: explicitCLIPath ?? AgentLaunchService.defaultCLIExecutablePath(),
                agentShimExecutablePath: explicitShimPath
                    ?? ToasttyBundledExecutableLocator.defaultAgentShimExecutablePath()
            )
            ToasttyLog.warning(
                "Failed to stage managed agent helpers",
                category: .bootstrap,
                metadata: [
                    "runtime_home": runtimePaths.runtimeHomeURL?.path ?? "none",
                    "error": error.localizedDescription,
                ]
            )
        }
        let cliExecutablePath = helperPaths.cliExecutablePath
        let agentShimExecutablePath = helperPaths.agentShimExecutablePath

        let configuration = LinuxAppConfiguration(
            runtimePaths: runtimePaths,
            environment: environment,
            socketPath: socketPath,
            cliExecutablePath: cliExecutablePath,
            agentShimExecutablePath: agentShimExecutablePath,
            appResourcesPath: resolvedResourcesPath
        )
        let shimDirectoryPath: String?
        do {
            shimDirectoryPath = try configuration.synchronizeManagedAgentCommandShims(
                enabled: initialConfig.enableAgentCommandShims,
                agentProfiles: agentCatalogStore.catalog
            )
        } catch {
            shimDirectoryPath = nil
            ToasttyLog.warning(
                "Failed to synchronize managed agent command shims",
                category: .bootstrap,
                metadata: [
                    "directory": runtimePaths.agentShimDirectoryURL.path,
                    "error": error.localizedDescription,
                ]
            )
        }
        let resolvedAgentBasePath = ManagedAgentBasePathResolver(environment: environment, fallbackPath: nil).resolve()
        let shimDirectoryForPathExclusion = runtimePaths.agentShimDirectoryURL.path
        let codexProcessPathStore = CodexProcessPathStore(
            path: ManagedAgentPathResolver.sanitizedMergedPath(
                preferredPath: resolvedAgentBasePath,
                fallbackPath: environment["PATH"],
                excludedDirectoryPaths: [shimDirectoryForPathExclusion]
            ),
            refreshPath: {
                let base = ManagedAgentBasePathResolver(environment: environment, fallbackPath: nil).resolve()
                return ManagedAgentPathResolver.sanitizedMergedPath(
                    preferredPath: base,
                    fallbackPath: environment["PATH"],
                    excludedDirectoryPaths: [shimDirectoryForPathExclusion]
                )
            }
        )
        let resolutionContextStore = ManagedAgentResolutionContextStore(
            context: configuration.managedAgentResolutionContext(
                agentBasePath: resolvedAgentBasePath,
                installedShimDirectoryPath: shimDirectoryPath
            )
        )
        configuration.configureBaseLaunchEnvironmentProvider(
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            shimDirectoryPath: shimDirectoryPath,
            agentBasePath: resolvedAgentBasePath
        )

        let agentHookDispatcher = AgentHookDispatcher(
            socketPath: socketPath,
            cliExecutablePath: cliExecutablePath,
            scriptPath: initialConfig.agentHookScriptPath
        )
        if let issue = AgentHookDispatcher.configuredScriptPathIssue(initialConfig.agentHookScriptPath) {
            ToasttyLog.warning(
                "Configured agent hook script is not currently usable",
                category: .automation,
                metadata: ["issue": issue]
            )
        }
        let sessionRuntimeStore = SessionRuntimeStore(agentHookDispatcher: agentHookDispatcher)
        sessionRuntimeStore.bind(store: store)
        let workspaceMergeCoordinator = WorkspaceMergeCoordinator(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            runner: WorkspaceMergeLiveCommandRunner(socketPath: socketPath, cliExecutablePath: cliExecutablePath),
            scriptPath: resolvedResourcesPath.map { "\($0)/workspace-pull-request.py" },
            userDefaults: usesPersistentPreferences ? ToasttyAppDefaults.current : nil
        )

        let inactiveAnnotationUsageCountsProvider: @MainActor () throws -> [String: Int]
        if let context = bootstrap.layoutPersistenceContext {
            let representedProfileIDs = bootstrap.layoutProfileIDsRepresentedByState
            inactiveAnnotationUsageCountsProvider = {
                try WorkspaceLayoutPersistenceStore(fileURL: context.fileURL)
                    .annotationUsageCounts(excludingProfileIDs: representedProfileIDs)
            }
        } else {
            inactiveAnnotationUsageCountsProvider = { [:] }
        }
        let annotationStyleStore = AnnotationStyleStore(runtimePaths: runtimePaths)
        var restoredAnnotationKeys = Set(store.state.workspacesByID.values.flatMap { $0.annotations.keys })
        do {
            restoredAnnotationKeys.formUnion(
                try inactiveAnnotationUsageCountsProvider().filter { $0.value > 0 }.map(\.key)
            )
            try annotationStyleStore.materializeMissingClaims(forKeys: restoredAnnotationKeys)
        } catch {
            ToasttyLog.warning(
                "Failed to materialize restored annotation color claims",
                category: .state,
                metadata: ["error": error.localizedDescription]
            )
        }

        terminalRuntimeRegistry.bind(sessionLifecycleTracker: sessionRuntimeStore)
        terminalRuntimeRegistry.setTerminalProfileProvider(
            terminalProfileStore,
            restoredTerminalPanelIDs: bootstrap.restoredTerminalPanelIDs
        )
        terminalRuntimeRegistry.setAgentCatalogProvider(agentCatalogStore)
        terminalRuntimeRegistry.bind(store: store)
        webPanelRuntimeRegistry.bind(store: store)
        terminalRuntimeRegistry.bind(webPanelRuntimeRegistry: webPanelRuntimeRegistry)
        let terminalMetadataService = TerminalMetadataService(
            store: store,
            registry: terminalRuntimeRegistry,
            sessionLifecycleTracker: sessionRuntimeStore
        )
        let scratchpadSessionLinkCleanupCoordinator = ScratchpadSessionLinkCleanupCoordinator(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            documentStore: webPanelRuntimeRegistry.scratchpadDocumentStore
        )
        let terminalReadActivityCleanupCoordinator = TerminalReadActivityCleanupCoordinator(
            sessionRuntimeStore: sessionRuntimeStore,
            readActivityStore: terminalRuntimeRegistry.terminalReadActivityStore
        )
        let systemNotificationResponseCoordinator = SystemNotificationResponseCoordinator(
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry
        )
        systemNotificationResponseCoordinator.installDelegate()
        if usesPersistentPreferences {
            LinuxAppConfiguration.applyInitialConfigState(
                to: store,
                terminalProfileCatalog: terminalProfileStore.catalog,
                config: initialConfig,
                legacyTerminalFontSizePoints: legacyTerminalFontSizePoints
            )
            LinuxAppConfiguration.ensureToasttyConfigTemplateExists()
            LinuxAppConfiguration.ensureAgentHookTemplateExists()
        }
        LinuxAppConfiguration.writeToasttyConfigReference()

        let focusedPanelCommandController = FocusedPanelCommandController(
            store: store,
            runtimeRegistry: terminalRuntimeRegistry,
            slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator(),
            webPanelRuntimeRegistry: webPanelRuntimeRegistry
        )

        let codexSkillsManager = CodexSkillsManager(runtimePaths: runtimePaths)
        let claudeSkillsBundleManager = ClaudeSkillsBundleManager(runtimePaths: runtimePaths)
        let userSkillCatalog = ToasttyUserSkillCatalog(runtimePaths: runtimePaths)
        let launchArtifactStore = ManagedAgentLaunchArtifactStore(runtimePaths: runtimePaths)
        if options.runsBackgroundMaintenance {
            let sweeper = ToasttySkillArtifactSweeper(
                runtimePaths: runtimePaths,
                userSkillCatalog: userSkillCatalog,
                claudeSkillsBundleManager: claudeSkillsBundleManager
            )
            DispatchQueue.global(qos: .utility).async { sweeper.sweep() }
        }
        let agentLaunchService = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: agentCatalogStore,
            codexSkillsManager: codexSkillsManager,
            claudeSkillsBundleManager: claudeSkillsBundleManager,
            userSkillCatalog: userSkillCatalog,
            cliExecutablePathProvider: { cliExecutablePath },
            socketPathProvider: { socketPath },
            codexProcessPathProvider: { codexProcessPathStore.currentPath() },
            codexProcessPathRefreshProvider: { codexProcessPathStore.refresh() },
            managedAgentResolutionContextProvider: { resolutionContextStore.current() },
            managedAgentLaunchArtifactStore: launchArtifactStore
        )
        terminalRuntimeRegistry.setRestoredManagedLaunchPlanner(agentLaunchService)
        let processWatchCommandController = ProcessWatchCommandController(
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            preferredWindowIDProvider: { [weak store] in store.flatMap(LinuxAppLogic.preferredCommandWindowID(in:)) }
        )

        let remoteAccessService: RemoteAccessService?
        if options.allowsRemoteAccess {
            remoteAccessService = RemoteAccessService(
                store: store,
                annotationStyleStore: annotationStyleStore,
                sessionRuntimeStore: sessionRuntimeStore,
                terminalRuntimeRegistry: terminalRuntimeRegistry,
                runtimePaths: runtimePaths,
                sessionLauncher: agentLaunchService,
                port: options.remoteAccessPort ?? RemoteAccessPreferences.loadPort(),
                pushConfiguration: LinuxAppConfiguration.pushConfiguration(environment: environment),
                tailnetServeSetup: options.remoteAccessTailnetServeSetup ?? { port, configuredOrigin, configureIfNeeded in
                    try await TailscaleServeSetup().run(
                        port: port,
                        configuredOrigin: configuredOrigin,
                        configureIfNeeded: configureIfNeeded
                    )
                }
            )
        } else {
            remoteAccessService = nil
        }

        if let context = bootstrap.layoutPersistenceContext {
            let coordinator = WorkspaceLayoutPersistenceCoordinator(context: context)
            persistenceObserverToken = store.addActionAppliedObserver { [weak coordinator] action, previous, next in
                coordinator?.handleAppliedAction(action, previousState: previous, nextState: next)
            }
            persistenceCoordinator = coordinator
            displayDiagnosticsObserver = WorkspaceLayoutDisplayDiagnosticsObserver(persistenceProfileID: context.profileID)
        } else {
            persistenceCoordinator = nil
            persistenceObserverToken = nil
            displayDiagnosticsObserver = nil
        }

        self.runtimePaths = runtimePaths
        self.store = store
        self.agentCatalogStore = agentCatalogStore
        self.terminalProfileStore = terminalProfileStore
        self.terminalRuntimeRegistry = terminalRuntimeRegistry
        self.webPanelRuntimeRegistry = webPanelRuntimeRegistry
        self.sessionRuntimeStore = sessionRuntimeStore
        self.annotationStyleStore = annotationStyleStore
        self.agentHookDispatcher = agentHookDispatcher
        self.agentLaunchService = agentLaunchService
        self.focusedPanelCommandController = focusedPanelCommandController
        self.processWatchCommandController = processWatchCommandController
        self.remoteAccessService = remoteAccessService
        self.terminalMetadataService = terminalMetadataService
        self.automationLifecycle = bootstrap.automationLifecycle
        self.systemNotificationResponseCoordinator = systemNotificationResponseCoordinator
        self.scratchpadSessionLinkCleanupCoordinator = scratchpadSessionLinkCleanupCoordinator
        self.terminalReadActivityCleanupCoordinator = terminalReadActivityCleanupCoordinator
        self.workspaceMergeCoordinator = workspaceMergeCoordinator
        self.configuration = configuration
        self.socketPath = socketPath
        self.cliExecutablePath = cliExecutablePath
        self.agentShimExecutablePath = agentShimExecutablePath
        self.appResourcesPath = resolvedResourcesPath

        if socketPath != preferredSocketPath {
            ToasttyLog.warning(
                "Preferred automation socket path is already live; using a per-process fallback path",
                category: .automation,
                metadata: ["preferred_socket_path": preferredSocketPath, "socket_path": socketPath]
            )
        }
        if options.startsAutomationSocket {
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
                    annotationStyleStore: annotationStyleStore,
                    inactiveAnnotationUsageCountsProvider: inactiveAnnotationUsageCountsProvider,
                    reloadConfigurationAction: { [weak self] in self?.reloadConfiguration() }
                )
                automationStartupError = nil
            } catch {
                automationSocketServer = nil
                automationStartupError = "Automation socket startup failed: \(error.localizedDescription)"
                FileHandle.standardError.write(Data("toastty automation error: \(automationStartupError ?? "unknown")\n".utf8))
            }
        }

        var previousTerminalPanelIDs = store.state.allTerminalPanelIDs
        terminalMetadataSync = store.$state.sink { [weak self, weak terminalMetadataService] state in
            MainActor.assumeIsolated {
                guard let terminalMetadataService else { return }
                let live = state.allTerminalPanelIDs
                for removed in previousTerminalPanelIDs.subtracting(live) {
                    terminalMetadataService.invalidate(panelID: removed)
                    self?.liveTitleSubscriptions.removeValue(forKey: removed)
                }
                previousTerminalPanelIDs = live
                terminalMetadataService.synchronizeLivePanels(live)
            }
        }

        // Stored here so reloadConfiguration can refresh these stores.
        codexProcessPathStoreForReload = codexProcessPathStore
        resolutionContextStoreForReload = resolutionContextStore

        if options.runsBackgroundMaintenance, bootstrap.automationConfig == nil {
            LinuxAppConfiguration.scheduleCodexIntegrationMaintenance()
        }
        startCodexQuestionMonitor()
        ToasttyLog.info(
            "Linux app logic bootstrapped",
            category: .bootstrap,
            metadata: [
                "socket_path": socketPath,
                "cli_path": cliExecutablePath ?? "none",
                "agent_shim_path": agentShimExecutablePath ?? "none",
                "app_resources_path": resolvedResourcesPath ?? "none",
                "remote_access": remoteAccessService == nil ? "disabled" : "available",
            ]
        )
    }

    private var codexProcessPathStoreForReload: CodexProcessPathStore?
    private var resolutionContextStoreForReload: ManagedAgentResolutionContextStore?

    // MARK: Lifecycle

    /// Call once the first window is on screen (macOS signals readiness from
    /// the first window scene). Writes the automation ready file in smoke runs.
    public func markAutomationReady() {
        automationLifecycle?.markReady(runtimeError: automationStartupError)
    }

    /// Flushes persisted layout and stops servers. Safe to call twice.
    public func shutdown(reason: String = "application_will_terminate") {
        guard isShutDown == false else { return }
        isShutDown = true
        persistenceCoordinator?.flushCurrentState(store.state, reason: reason)
        if let persistenceObserverToken {
            store.removeActionAppliedObserver(persistenceObserverToken)
        }
        codexQuestionMonitor?.stop()
        remoteAccessService?.setEnabled(false, persist: false)
        automationSocketServer = nil
        LinuxPlatform.postApplicationWillTerminate()
    }

    /// Writes the current layout now (e.g. before a risky operation).
    public func flushPersistedLayout(reason: String) {
        persistenceCoordinator?.flushCurrentState(store.state, reason: reason)
    }

    /// The `Reload Configuration` command: agents.toml, terminal profiles,
    /// config, hook script, command shims, launch environment.
    public func reloadConfiguration() {
        guard let codexProcessPathStoreForReload, let resolutionContextStoreForReload else { return }
        configuration.reload(
            store: store,
            agentCatalogStore: agentCatalogStore,
            terminalProfileStore: terminalProfileStore,
            codexProcessPathStore: codexProcessPathStoreForReload,
            resolutionContextStore: resolutionContextStoreForReload,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            agentHookDispatcher: agentHookDispatcher
        )
    }

    // MARK: Helpers

    static func preferredCommandWindowID(in store: AppStore) -> UUID? {
        if let key = NSApplication.shared.keyWindow?.windowID, store.window(id: key) != nil {
            return key
        }
        return store.state.selectedWindowID ?? store.state.windows.first?.id
    }

    static func defaultAppResourcesPath(environment: [String: String]) -> String? {
        let fileManager = FileManager.default
        func usable(_ path: String) -> String? {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        if let explicit = environment[ToasttyLaunchContextEnvironment.appResourcesPathKey], let path = usable(explicit) {
            return path
        }
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            for candidate in ["../share/toastty/Resources", "Resources"] {
                if let path = usable(executable.appendingPathComponent(candidate).path) {
                    return path
                }
            }
            // A checkout build: linux/.build/<triple>/<config>/ → Sources/App/Resources.
            var directory = executable
            for _ in 0..<6 {
                directory = directory.deletingLastPathComponent()
                if let path = usable(directory.appendingPathComponent("Sources/App/Resources").path),
                   fileManager.fileExists(atPath: directory.appendingPathComponent("linux/Package.swift").path) {
                    return path
                }
            }
        }
        if let root = environment["TOASTTY_DEV_WORKTREE_ROOT"],
           let path = usable("\(root)/Sources/App/Resources") {
            return path
        }
        return nil
    }
}
