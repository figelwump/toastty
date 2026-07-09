import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
struct AgentLaunchServiceTests {
    @Test
    func defaultCLIExecutablePathPrefersBundledHelperCLIOverOtherFallbacks() throws {
        let fixture = try makeCLIResolutionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        try makeExecutableFile(at: fixture.bundledHelperCLIURL)
        try makeExecutableFile(at: fixture.legacyBundledCLIURL)
        try makeExecutableFile(at: fixture.siblingCLIURL)

        let resolvedPath = AgentLaunchService.resolvedDefaultCLIExecutablePath(
            fileManager: .default,
            bundleURL: fixture.bundleURL,
            executableURL: fixture.executableURL
        )

        #expect(resolvedPath == fixture.bundledHelperCLIURL.path)
    }

    @Test
    func defaultCLIExecutablePathFallsBackToLegacyBundledCLIWhenHelperCopyIsMissing() throws {
        let fixture = try makeCLIResolutionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        try makeExecutableFile(at: fixture.legacyBundledCLIURL)
        try makeExecutableFile(at: fixture.siblingCLIURL)

        let resolvedPath = AgentLaunchService.resolvedDefaultCLIExecutablePath(
            fileManager: .default,
            bundleURL: fixture.bundleURL,
            executableURL: fixture.executableURL
        )

        #expect(resolvedPath == fixture.legacyBundledCLIURL.path)
    }

    @Test
    func defaultCLIExecutablePathFallsBackToSiblingCLIWhenBundleCopyIsMissing() throws {
        let fixture = try makeCLIResolutionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        try makeExecutableFile(at: fixture.siblingCLIURL)

        let resolvedPath = AgentLaunchService.resolvedDefaultCLIExecutablePath(
            fileManager: .default,
            bundleURL: fixture.bundleURL,
            executableURL: fixture.executableURL
        )

        #expect(resolvedPath == fixture.siblingCLIURL.path)
    }

    @Test
    func defaultCLIExecutablePathDoesNotMistakeAppExecutableForLegacyCLI() throws {
        let fixture = try makeCLIResolutionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        try makeExecutableFile(at: fixture.executableURL)
        try makeExecutableFile(at: fixture.siblingCLIURL)

        let resolvedPath = AgentLaunchService.resolvedDefaultCLIExecutablePath(
            fileManager: .default,
            bundleURL: fixture.bundleURL,
            executableURL: fixture.executableURL
        )

        #expect(resolvedPath == fixture.siblingCLIURL.path)
    }

    @Test
    func defaultCLIExecutablePathSkipsNonExecutableBundledHelper() throws {
        let fixture = try makeCLIResolutionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        try makeFile(at: fixture.bundledHelperCLIURL, executable: false)
        try makeExecutableFile(at: fixture.siblingCLIURL)

        let resolvedPath = AgentLaunchService.resolvedDefaultCLIExecutablePath(
            fileManager: .default,
            bundleURL: fixture.bundleURL,
            executableURL: fixture.executableURL
        )

        #expect(resolvedPath == fixture.siblingCLIURL.path)
    }

    @Test
    func defaultAgentShimExecutablePathPrefersBundledHelperCopy() throws {
        let fixture = try makeCLIResolutionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        try makeExecutableFile(at: fixture.bundledHelperAgentShimURL)
        try makeExecutableFile(at: fixture.siblingAgentShimURL)

        let resolvedPath = ToasttyBundledExecutableLocator.resolvedAgentShimExecutablePath(
            fileManager: .default,
            bundleURL: fixture.bundleURL,
            executableURL: fixture.executableURL
        )

        #expect(resolvedPath == fixture.bundledHelperAgentShimURL.path)
    }

    @Test
    func defaultAgentShimExecutablePathFallsBackToUnderscoredSiblingBuildProduct() throws {
        let fixture = try makeCLIResolutionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        try makeExecutableFile(at: fixture.siblingAgentShimURL)

        let resolvedPath = ToasttyBundledExecutableLocator.resolvedAgentShimExecutablePath(
            fileManager: .default,
            bundleURL: fixture.bundleURL,
            executableURL: fixture.executableURL
        )

        #expect(resolvedPath == fixture.siblingAgentShimURL.path)
    }

    @Test
    func codexStatusHookPreflightRequiresSetupForMissingOrStaleCodexHooks() {
        let missingStatus = codexHookInstallStatus(state: .notInstalled)
        let staleStatus = codexHookInstallStatus(state: .needsUpdate)

        #expect(
            CodexStatusHookLaunchPreflightResolver.state(
                profileID: "codex",
                installationStatus: missingStatus
            ) == .needsSetup(missingStatus)
        )
        #expect(
            CodexStatusHookLaunchPreflightResolver.state(
                profileID: "codex",
                installationStatus: staleStatus
            ) == .needsSetup(staleStatus)
        )
    }

    @Test
    func codexStatusHookPreflightAllowsInstalledCodexHooksAndNonCodexLaunches() {
        let installedStatus = codexHookInstallStatus(state: .installed)
        let missingStatus = codexHookInstallStatus(state: .notInstalled)

        #expect(
            CodexStatusHookLaunchPreflightResolver.state(
                profileID: "codex",
                installationStatus: installedStatus
            ) == .ready
        )
        #expect(
            CodexStatusHookLaunchPreflightResolver.state(
                profileID: "claude",
                installationStatus: missingStatus
            ) == .ready
        )
    }

    @Test
    func codexStatusHookPreflightAllowsAutomaticallyMaintainableCodexHooks() {
        let maintenanceStatus = codexHookInstallStatus(
            state: .needsUpdate,
            setupRequirement: .automaticMaintenance
        )

        #expect(
            CodexStatusHookLaunchPreflightResolver.state(
                profileID: "codex",
                installationStatus: maintenanceStatus
            ) == .ready
        )
    }

    @Test
    func codexStatusHookPreflightAllowsRestoredCodexLaunches() {
        let missingStatus = codexHookInstallStatus(state: .notInstalled)

        #expect(
            CodexStatusHookLaunchPreflightResolver.state(
                profileID: "codex",
                launchReason: .restore,
                installationStatus: missingStatus
            ) == .ready
        )
    }

    @Test
    func agentLaunchUICancelCodexHooksWarningDoesNotLaunch() throws {
        let fixture = try makeLaunchUITestFixture()
        let missingStatus = codexHookInstallStatus(state: .notInstalled)
        var observedWarningState: CodexStatusHookLaunchPreflightState?
        var observedCanOpenSetup: Bool?
        var setupWindowID: UUID?

        let launched = AgentLaunchUI.launch(
            profileID: "codex",
            workspaceID: fixture.workspaceID,
            originWindowID: fixture.windowID,
            agentLaunchService: fixture.service,
            codexStatusHooksPreflightProvider: { profileID in
                #expect(profileID == "codex")
                return .needsSetup(missingStatus)
            },
            codexStatusHooksWarningPresenter: { state, canOpenSetup in
                observedWarningState = state
                observedCanOpenSetup = canOpenSetup
                return .cancel
            },
            agentStatusHooksSetupPresenter: { windowID in
                setupWindowID = windowID
            }
        )

        #expect(launched == false)
        #expect(observedWarningState == .needsSetup(missingStatus))
        #expect(observedCanOpenSetup == true)
        #expect(setupWindowID == nil)
        #expect(fixture.terminalRouter.sentTextByPanelID.isEmpty)
        #expect(fixture.sessionRuntimeStore.sessionRegistry.sessionsByID.isEmpty)
    }

    @Test
    func agentLaunchUISetUpHooksOpensSetupWithoutLaunching() throws {
        let fixture = try makeLaunchUITestFixture()
        let missingStatus = codexHookInstallStatus(state: .notInstalled)
        var setupWindowID: UUID?

        let launched = AgentLaunchUI.launch(
            profileID: "codex",
            workspaceID: fixture.workspaceID,
            originWindowID: fixture.windowID,
            agentLaunchService: fixture.service,
            codexStatusHooksPreflightProvider: { _ in .needsSetup(missingStatus) },
            codexStatusHooksWarningPresenter: { _, _ in .setUpHooks },
            agentStatusHooksSetupPresenter: { windowID in
                setupWindowID = windowID
            }
        )

        #expect(launched == false)
        #expect(setupWindowID == fixture.windowID)
        #expect(fixture.terminalRouter.sentTextByPanelID.isEmpty)
        #expect(fixture.sessionRuntimeStore.sessionRegistry.sessionsByID.isEmpty)
    }

    @Test
    func agentLaunchUIRunAnywayBypassesCodexHooksWarningAndLaunches() throws {
        let fixture = try makeLaunchUITestFixture()
        let missingStatus = codexHookInstallStatus(state: .notInstalled)

        let launched = AgentLaunchUI.launch(
            profileID: "codex",
            workspaceID: fixture.workspaceID,
            originWindowID: fixture.windowID,
            agentLaunchService: fixture.service,
            codexStatusHooksPreflightProvider: { _ in .needsSetup(missingStatus) },
            codexStatusHooksWarningPresenter: { _, _ in .runAnyway },
            agentStatusHooksSetupPresenter: { _ in
                Issue.record("Run Anyway should not open setup")
            }
        )

        #expect(launched)
        #expect(fixture.terminalRouter.sentTextByPanelID[fixture.panelID] != nil)
        #expect(fixture.sessionRuntimeStore.sessionRegistry.sessionsByID.count == 1)
    }

    @Test
    func launchInjectsToasttyContextAndStartsSession() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .idleAtPrompt
        let agentCatalogProvider = TestAgentCatalogProvider()

        let workspace = try #require(store.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelID)
        let projectRoot = try makeProjectRoot()
        let cwd = projectRoot.appendingPathComponent("Packages/toastty", isDirectory: true).path
        _ = store.send(.updateTerminalPanelMetadata(panelID: panelID, title: nil, cwd: cwd))

        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: agentCatalogProvider,
            nowProvider: { Date(timeIntervalSince1970: 1_700_000_000) },
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-tests.sock" },
            codexStatusTrackingSourceProvider: { .sessionLogFallback(reason: "test") }
        )

        let result = try service.launch(profileID: "codex")
        let activeSession = try #require(sessionRuntimeStore.sessionRegistry.activeSession(sessionID: result.sessionID))

        #expect(result.agent == .codex)
        #expect(result.displayName == "Codex")
        #expect(result.panelID == panelID)
        #expect(result.cwd == cwd)
        #expect(result.repoRoot == projectRoot.path)
        #expect(activeSession.panelID == panelID)
        #expect(activeSession.cwd == cwd)
        #expect(activeSession.repoRoot == projectRoot.path)
        #expect(activeSession.usesSessionStatusNotifications)
        #expect(activeSession.status == SessionStatus(kind: .idle, summary: "Waiting", detail: "Ready for prompt"))
        #expect(store.hasEverLaunchedAgent)

        let injectedCommand = try #require(terminalRouter.sentTextByPanelID[panelID])
        #expect(terminalRouter.focusPolicyByPanelID[panelID] == .focusTarget)
        #expect(injectedCommand.contains("TOASTTY_SESSION_ID=\(result.sessionID)"))
        #expect(injectedCommand.contains("TOASTTY_PANEL_ID=\(panelID.uuidString)"))
        #expect(injectedCommand.contains("TOASTTY_SOCKET_PATH=/tmp/toastty-tests.sock"))
        #expect(injectedCommand.contains("TOASTTY_CLI_PATH=/bin/sh"))
        #expect(injectedCommand.contains("TOASTTY_CWD=\(cwd)"))
        #expect(injectedCommand.contains("TOASTTY_REPO_ROOT=\(projectRoot.path)"))
        #expect(injectedCommand.contains("TOASTTY_MANAGED_AGENT_SHIM_BYPASS=1"))
        #expect(injectedCommand.contains("CODEX_TUI_RECORD_SESSION=1"))
        #expect(injectedCommand.contains("CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT=1"))
        #expect(injectedCommand.contains("CODEX_TUI_SESSION_LOG_PATH="))
        #expect(injectedCommand.contains("codex -c "))
        #expect(injectedCommand.contains("notify=[\"/bin/sh\",\""))
        #expect(injectedCommand.contains("codex-notify.sh"))
        #expect(injectedCommand.contains("\\/") == false)
        #expect(injectedCommand.contains(" agent run ") == false)
        #expect(injectedCommand.hasPrefix("exec ") == false)
        #expect(injectedCommand.hasSuffix("\n"))
    }

    @Test
    func launchUsesRestoredLaunchWorkingDirectoryWhenLiveCWDIsEmpty() throws {
        let restoredCWD = try makeProjectRoot().path
        let restoredState = try makeStateWithFocusedTerminal(
            TerminalPanelState(
                title: "Terminal 1",
                shell: "zsh",
                cwd: "",
                launchWorkingDirectory: restoredCWD
            )
        )
        let store = AppStore(state: restoredState.state, persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .idleAtPrompt
        let observerRegistry = SpyNativeSessionObserverRegistry()
        let agentCatalogProvider = TestAgentCatalogProvider()

        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: agentCatalogProvider,
            nowProvider: { Date(timeIntervalSince1970: 1_700_000_000) },
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-tests.sock" },
            codexStatusTrackingSourceProvider: { .sessionLogFallback(reason: "test") },
            nativeSessionObserverRegistry: observerRegistry
        )

        let result = try service.launch(profileID: "codex")
        let activeSession = try #require(sessionRuntimeStore.sessionRegistry.activeSession(sessionID: result.sessionID))
        let observation = try #require(observerRegistry.startedObservations.first)
        let injectedCommand = try #require(terminalRouter.sentTextByPanelID[restoredState.panelID])

        #expect(result.panelID == restoredState.panelID)
        #expect(result.cwd == restoredCWD)
        #expect(result.repoRoot == restoredCWD)
        #expect(activeSession.cwd == restoredCWD)
        #expect(activeSession.repoRoot == restoredCWD)
        #expect(observation.cwd == restoredCWD)
        #expect(observation.panelID == restoredState.panelID)
        #expect(injectedCommand.contains("TOASTTY_CWD=\(restoredCWD)"))
        #expect(injectedCommand.contains("TOASTTY_REPO_ROOT=\(restoredCWD)"))
    }

    @Test
    func launchRejectsBusyPanels() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .busy
        let agentCatalogProvider = TestAgentCatalogProvider()

        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: agentCatalogProvider,
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-tests.sock" },
            codexStatusTrackingSourceProvider: { .sessionLogFallback(reason: "test") }
        )

        #expect(throws: AgentLaunchError.panelBusy(runningCommand: nil)) {
            try service.launch(profileID: "claude")
        }
        #expect(store.hasEverLaunchedAgent == false)
    }

    @Test
    func profileNotFoundErrorListsAvailableProfiles() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .idleAtPrompt
        let agentCatalogProvider = TestAgentCatalogProvider(
            profiles: [
                AgentProfile(id: "codex", displayName: "Codex", argv: ["codex"]),
                AgentProfile(id: "claude", displayName: "Claude Code", argv: ["claude"]),
                AgentProfile(id: "pi", displayName: "Pi", argv: ["pi"]),
            ]
        )
        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: agentCatalogProvider,
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-tests.sock" },
            codexStatusTrackingSourceProvider: { .sessionLogFallback(reason: "test") }
        )

        do {
            _ = try service.launch(profileID: "missing")
            Issue.record("Expected profileNotFound")
        } catch let error as AgentLaunchError {
            #expect(
                error.errorDescription ==
                    "Toastty could not find an agent profile named 'missing' in ~/.toastty/agents.toml. Available profiles: codex, claude, pi."
            )
        } catch {
            Issue.record("Expected AgentLaunchError, got \(error)")
        }
    }

    @Test
    func launchCancelsNativeSessionObservationWhenSendTextFails() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .idleAtPrompt
        terminalRouter.sendSucceeds = false
        let observerRegistry = SpyNativeSessionObserverRegistry()
        let agentCatalogProvider = TestAgentCatalogProvider()

        let workspace = try #require(store.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelID)
        _ = store.send(.updateTerminalPanelMetadata(panelID: panelID, title: nil, cwd: "/tmp/repo"))

        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: agentCatalogProvider,
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-tests.sock" },
            codexStatusTrackingSourceProvider: { .sessionLogFallback(reason: "test") },
            nativeSessionObserverRegistry: observerRegistry
        )

        #expect(throws: AgentLaunchError.terminalUnavailable(panelID: panelID)) {
            try service.launch(profileID: "codex")
        }

        let startedSessionID = try #require(observerRegistry.startedObservations.first?.managedSessionID)
        #expect(observerRegistry.cancelledSessionIDs == [startedSessionID])
        #expect(sessionRuntimeStore.sessionRegistry.activeSession(sessionID: startedSessionID) == nil)
    }

    @Test
    func prepareManagedLaunchSkipsBusyPanelValidationForTypedLaunches() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .busy
        let agentCatalogProvider = TestAgentCatalogProvider()

        let workspace = try #require(store.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelID)
        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: agentCatalogProvider,
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-tests.sock" },
            codexStatusTrackingSourceProvider: { .sessionLogFallback(reason: "test") }
        )

        let plan = try service.prepareManagedLaunch(
            ManagedAgentLaunchRequest(
                agent: .codex,
                panelID: panelID,
                argv: ["codex"],
                cwd: "/tmp/repo"
            )
        )

        #expect(plan.agent == .codex)
        #expect(plan.panelID == panelID)
        #expect(plan.environment["TOASTTY_SESSION_ID"] == plan.sessionID)
        #expect(plan.environment["TOASTTY_PANEL_ID"] == panelID.uuidString)
        #expect(plan.environment["CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT"] == "1")
    }

    @Test
    func launchQuotesDirectLaunchEnvironmentAndArgv() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .idleAtPrompt
        let agentCatalogProvider = TestAgentCatalogProvider(
            profiles: [
                AgentProfile(
                    id: "claude",
                    displayName: "Claude Code",
                    argv: [
                        "/Applications/Claude Code.app/Contents/MacOS/cc",
                        "--append-system-prompt=review only"
                    ]
                )
            ]
        )
        let workspace = try #require(store.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelID)
        _ = store.send(
            .updateTerminalPanelMetadata(
                panelID: panelID,
                title: nil,
                cwd: "/tmp/toastty project/src"
            )
        )

        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: agentCatalogProvider,
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty sockets/test.sock" }
        )

        _ = try service.launch(profileID: "claude")

        let injectedCommand = try #require(terminalRouter.sentTextByPanelID[panelID])
        #expect(injectedCommand.contains("TOASTTY_SOCKET_PATH='/tmp/toastty sockets/test.sock'"))
        #expect(injectedCommand.contains("TOASTTY_CWD='/tmp/toastty project/src'"))
        #expect(injectedCommand.contains("TOASTTY_REPO_ROOT=") == false)
        #expect(injectedCommand.contains("'/Applications/Claude Code.app/Contents/MacOS/cc' --settings "))
        #expect(injectedCommand.contains("'--append-system-prompt=review only'"))
    }

    @Test
    func launchThreadsParentSessionIDIntoStartedSession() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .idleAtPrompt
        let workspace = try #require(store.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelID)
        let windowID = try #require(store.state.windows.first?.id)
        let parentSessionID = "parent-live"
        sessionRuntimeStore.startSession(
            sessionID: parentSessionID,
            agent: .claude,
            panelID: panelID,
            windowID: windowID,
            workspaceID: workspace.id,
            cwd: "/tmp/repo",
            repoRoot: "/tmp/repo",
            at: Date(timeIntervalSince1970: 1_000)
        )
        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: TestAgentCatalogProvider(),
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-tests.sock" }
        )

        let result = try service.launch(
            profileID: "codex",
            parentSessionID: parentSessionID
        )

        #expect(sessionRuntimeStore.sessionRegistry.sessionsByID[result.sessionID]?.parentSessionID == parentSessionID)
    }

    @Test
    func launchUsesImplicitBuiltInProfileWhenCatalogIsEmpty() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .idleAtPrompt
        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: TestAgentCatalogProvider(profiles: []),
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-tests.sock" },
            codexStatusTrackingSourceProvider: { .hooks }
        )

        let result = try service.launch(profileID: "codex", initialPrompt: "/work-on POP-1234")
        let command = try #require(terminalRouter.sentTextByPanelID[result.panelID])

        #expect(result.agent == .codex)
        #expect(result.displayName == "Codex")
        #expect(command.contains("codex '/work-on POP-1234'"))
    }

    @Test
    func launchWithExplicitCWDAndEnvironmentRendersStructuredShellPrefix() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .idleAtPrompt
        let projectRoot = try makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let cwd = projectRoot.appendingPathComponent("Packages/toastty", isDirectory: true).path
        let workspace = try #require(store.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelID)
        _ = store.send(.updateTerminalPanelMetadata(panelID: panelID, title: nil, cwd: "/tmp/other"))
        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: TestAgentCatalogProvider(),
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-tests.sock" },
            codexStatusTrackingSourceProvider: { .hooks }
        )

        let result = try service.launch(
            profileID: "codex",
            cwd: cwd,
            environment: [
                "TOASTTY_DEV_WORKTREE_ROOT": projectRoot.path,
                "TOASTTY_DERIVED_PATH": projectRoot.appendingPathComponent("artifacts/Derived").path,
            ],
            initialPrompt: "Read WORKTREE_HANDOFF.md"
        )
        let command = try #require(terminalRouter.sentTextByPanelID[result.panelID])
        let activeSession = try #require(sessionRuntimeStore.sessionRegistry.activeSession(sessionID: result.sessionID))

        #expect(command.hasPrefix("cd \(cwd) && "))
        #expect(command.contains("TOASTTY_DEV_WORKTREE_ROOT=\(projectRoot.path)"))
        #expect(command.contains("TOASTTY_DERIVED_PATH=\(projectRoot.path)/artifacts/Derived"))
        #expect(command.contains("TOASTTY_CWD=\(cwd)"))
        #expect(command.contains("codex 'Read WORKTREE_HANDOFF.md'"))
        #expect(result.cwd == cwd)
        #expect(activeSession.cwd == cwd)
    }

    @Test
    func launchRendersInitialCommandsBetweenCWDAndAgentCommand() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .idleAtPrompt
        let projectRoot = try makeProjectRoot()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let cwd = projectRoot.appendingPathComponent("Packages/toastty", isDirectory: true).path
        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: TestAgentCatalogProvider(),
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-tests.sock" },
            codexStatusTrackingSourceProvider: { .hooks }
        )

        let result = try service.launch(
            profileID: "codex",
            cwd: cwd,
            environment: ["EXTRA_FLAG": "alpha beta"],
            initialPrompt: "/work-on POP-1234",
            initialCommands: ["direnv allow", "export FEATURE_FLAG=1"]
        )
        let command = try #require(terminalRouter.sentTextByPanelID[result.panelID])

        #expect(command.hasPrefix("cd \(cwd) && direnv allow && export FEATURE_FLAG=1 && "))
        #expect(command.contains("EXTRA_FLAG='alpha beta'"))
        #expect(command.contains("codex '/work-on POP-1234'"))
    }

    @Test
    func launchRejectsRelativeExplicitCWD() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .idleAtPrompt
        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: TestAgentCatalogProvider(),
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-tests.sock" }
        )

        #expect(throws: AgentLaunchError.invalidWorkingDirectory(path: "Sources")) {
            _ = try service.launch(profileID: "codex", cwd: "Sources")
        }
    }

    @Test
    func launchQuotesStructuredCWDEnvironmentAndInitialPromptMetacharacters() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .idleAtPrompt
        let cwdURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty agent 'quote' \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwdURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwdURL) }
        let envValue = "alpha beta; $(echo nope) 'tail'"
        let prompt = "review 'quoted'; $(echo nope)"
        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: TestAgentCatalogProvider(),
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-tests.sock" },
            codexStatusTrackingSourceProvider: { .hooks }
        )

        let result = try service.launch(
            profileID: "codex",
            cwd: cwdURL.path,
            environment: ["CUSTOM_VALUE": envValue],
            initialPrompt: prompt
        )
        let command = try #require(terminalRouter.sentTextByPanelID[result.panelID])

        #expect(command.hasPrefix("cd \(shellQuoteForTest(cwdURL.path)) && "))
        #expect(command.contains("CUSTOM_VALUE=\(shellQuoteForTest(envValue))"))
        #expect(command.contains("codex \(shellQuoteForTest(prompt))"))
    }

    @Test
    func launchPreservesInitialCommandShellSyntaxWhileQuotingStructuredValues() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .idleAtPrompt
        let cwdURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty agent command quoting \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwdURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwdURL) }
        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: TestAgentCatalogProvider(),
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-tests.sock" },
            codexStatusTrackingSourceProvider: { .hooks }
        )

        let result = try service.launch(
            profileID: "codex",
            cwd: cwdURL.path,
            initialPrompt: "review 'quoted'; $(echo prompt)",
            initialCommands: ["direnv allow && printf '%s\\n' ready"]
        )
        let command = try #require(terminalRouter.sentTextByPanelID[result.panelID])

        #expect(command.contains(" && direnv allow && printf '%s\\n' ready && "))
        #expect(command.contains("codex \(shellQuoteForTest("review 'quoted'; $(echo prompt)"))"))
    }

    @Test
    func launchRejectsInvalidInitialCommands() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .idleAtPrompt
        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: TestAgentCatalogProvider(),
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-tests.sock" }
        )

        #expect(throws: AgentLaunchError.invalidInitialCommands(message: "command 1 must not be blank")) {
            _ = try service.launch(profileID: "codex", initialCommands: ["  \n"])
        }
        #expect(throws: AgentLaunchError.invalidInitialCommands(message: "command 1 contains a NUL byte")) {
            _ = try service.launch(profileID: "codex", initialCommands: ["printf 'ok'\u{0}"])
        }
        #expect(throws: AgentLaunchError.invalidInitialCommands(message: "command 1 must be a single line")) {
            _ = try service.launch(profileID: "codex", initialCommands: ["direnv allow\nprintf ready"])
        }
        #expect(throws: AgentLaunchError.invalidInitialCommands(message: "at most 16 commands are supported")) {
            _ = try service.launch(profileID: "codex", initialCommands: Array(repeating: "true", count: 17))
        }
        #expect(terminalRouter.sentTextByPanelID.isEmpty)
    }

    @Test
    func launchRejectsReservedEnvironmentVariables() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .idleAtPrompt
        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: TestAgentCatalogProvider(),
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-tests.sock" }
        )

        #expect(throws: AgentLaunchError.invalidLaunchEnvironment(message: "'TOASTTY_SESSION_ID' is managed by Toastty")) {
            _ = try service.launch(
                profileID: "codex",
                environment: ["TOASTTY_SESSION_ID": "user-value"]
            )
        }
    }

    @Test
    func launchRejectsInitialPromptForCustomProfileWithoutDeclaredPlacement() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .idleAtPrompt
        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: TestAgentCatalogProvider(
                profiles: [AgentProfile(id: "gemini", displayName: "Gemini", argv: ["gemini"])]
            ),
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-tests.sock" }
        )

        #expect(throws: AgentLaunchError.initialPromptUnsupported(profileID: "gemini")) {
            _ = try service.launch(profileID: "gemini", initialPrompt: "start")
        }
    }

    @Test
    func launchRejectsInitialPromptForShellHelperWithoutDeclaredPlacement() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .idleAtPrompt
        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: TestAgentCatalogProvider(
                profiles: [AgentProfile(id: "codex", displayName: "Codex", argv: ["scodex"])]
            ),
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-tests.sock" }
        )

        #expect(throws: AgentLaunchError.initialPromptUnsupported(profileID: "codex")) {
            _ = try service.launch(profileID: "codex", initialPrompt: "start")
        }
    }

    @Test
    func launchRejectsInitialPromptForFirstPartyProfileWithExtraArgumentsWithoutDeclaredPlacement() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .idleAtPrompt
        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: TestAgentCatalogProvider(
                profiles: [AgentProfile(id: "codex", displayName: "Codex", argv: ["codex", "resume"])]
            ),
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-tests.sock" }
        )

        #expect(throws: AgentLaunchError.initialPromptUnsupported(profileID: "codex")) {
            _ = try service.launch(profileID: "codex", initialPrompt: "start")
        }
    }

    @Test
    func launchUsesDeclaredTrailingInitialPromptPlacementForCustomProfile() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .idleAtPrompt
        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: TestAgentCatalogProvider(
                profiles: [
                    AgentProfile(
                        id: "gemini",
                        displayName: "Gemini",
                        argv: ["gemini", "--prompt"],
                        initialPromptPlacement: .trailing
                    ),
                ]
            ),
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-tests.sock" }
        )

        let result = try service.launch(profileID: "gemini", initialPrompt: "hello world")
        let command = try #require(terminalRouter.sentTextByPanelID[result.panelID])

        #expect(command.contains("gemini --prompt 'hello world'"))
    }

    @Test
    func launchInjectsCodexOverridesAfterWrappedCodexCommand() throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .idleAtPrompt
        let agentCatalogProvider = TestAgentCatalogProvider(
            profiles: [
                AgentProfile(
                    id: "codex",
                    displayName: "Codex",
                    argv: [
                        "/Users/vishal/.config/sandbox-exec/run-sandboxed.sh",
                        "--workdir=/tmp/toastty project",
                        "codex",
                        "--dangerously-bypass-approvals-and-sandbox",
                    ]
                )
            ]
        )

        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: agentCatalogProvider,
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-tests.sock" },
            codexStatusTrackingSourceProvider: { .sessionLogFallback(reason: "test") }
        )

        _ = try service.launch(profileID: "codex")

        let workspace = try #require(store.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelID)
        let injectedCommand = try #require(terminalRouter.sentTextByPanelID[panelID])
        #expect(
            injectedCommand.contains(
                "/Users/vishal/.config/sandbox-exec/run-sandboxed.sh '--workdir=/tmp/toastty project' codex -c "
            )
        )
        #expect(injectedCommand.contains("--dangerously-bypass-approvals-and-sandbox"))
    }

    @Test
    func codexHistoryInsertRefreshesWorkingDetailImmediately() async throws {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .idleAtPrompt
        let agentCatalogProvider = TestAgentCatalogProvider()

        let workspace = try #require(store.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelID)
        terminalRouter.visibleTextByPanelID[panelID] = """
        vishal@toastty ~/repo %
        """
        terminalRouter.promptStateByPanelID[panelID] = .idleAtPrompt

        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: agentCatalogProvider,
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-tests.sock" },
            codexStatusTrackingSourceProvider: { .sessionLogFallback(reason: "test") }
        )

        let result = try service.launch(profileID: "codex")
        let injectedCommand = try #require(terminalRouter.sentTextByPanelID[result.panelID])
        terminalRouter.promptStateByPanelID[result.panelID] = .busy
        terminalRouter.visibleTextByPanelID[result.panelID] = """
        OpenAI Codex (v0.117.0)
        • Running pwd and git status --short now, then I'll return just the count.
        """
        let logURL = URL(fileURLWithPath: try #require(extractEnvironmentValue(
            key: "CODEX_TUI_SESSION_LOG_PATH",
            from: injectedCommand
        )))

        try append(
            """
            {"ts":"2026-03-27T18:46:23.170Z","dir":"from_tui","kind":"op","payload":{"type":"user_turn","items":[{"type":"text","text":"Run repo checks"}]}}
            {"ts":"2026-03-27T18:46:24.000Z","dir":"to_tui","kind":"insert_history_cell","lines":1}
            """,
            to: logURL
        )

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if sessionRuntimeStore.sessionRegistry.activeSession(sessionID: result.sessionID)?.status ==
                SessionStatus(
                    kind: .working,
                    summary: "Working",
                    detail: "Running pwd and git status --short now, then I'll return just the count."
                ) {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        Issue.record("expected insert_history_cell watcher event to refresh working detail immediately")
    }

    private func makeProjectRoot() throws -> URL {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-agent-tests-\(UUID().uuidString)", isDirectory: true)
        let nestedDirectory = projectRoot.appendingPathComponent("Packages/toastty", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: projectRoot.appendingPathComponent(".git", isDirectory: false).path,
            contents: Data("gitdir: /tmp/fake-worktree".utf8)
        )
        return projectRoot
    }

    private func makeStateWithFocusedTerminal(
        _ terminalState: TerminalPanelState
    ) throws -> (state: AppState, panelID: UUID) {
        var state = AppState.bootstrap()
        let window = try #require(state.windows.first)
        let workspaceID = try #require(window.selectedWorkspaceID ?? window.workspaceIDs.first)
        var workspace = try #require(state.workspacesByID[workspaceID])
        let panelID = try #require(workspace.focusedPanelID)
        _ = workspace.updateSelectedTab { tab in
            tab.panels[panelID] = .terminal(terminalState)
        }
        state.workspacesByID[workspaceID] = workspace
        return (state, panelID)
    }

    private func makeCLIResolutionFixture() throws -> (
        rootURL: URL,
        bundleURL: URL,
        executableURL: URL,
        bundledHelperCLIURL: URL,
        legacyBundledCLIURL: URL,
        siblingCLIURL: URL,
        bundledHelperAgentShimURL: URL,
        siblingAgentShimURL: URL
    ) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastty-cli-resolution-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = rootURL.appendingPathComponent("Toastty.app", isDirectory: true)
        let executableURL = bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent("Toastty", isDirectory: false)
        let bundledHelperCLIURL = bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("toastty", isDirectory: false)
        let legacyBundledCLIURL = executableURL
            .deletingLastPathComponent()
            .appendingPathComponent("toastty", isDirectory: false)
        let siblingCLIURL = rootURL.appendingPathComponent("toastty", isDirectory: false)
        let bundledHelperAgentShimURL = bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("toastty-agent-shim", isDirectory: false)
        let siblingAgentShimURL = rootURL.appendingPathComponent("toastty_agent_shim", isDirectory: false)

        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: bundledHelperCLIURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        return (
            rootURL,
            bundleURL,
            executableURL,
            bundledHelperCLIURL,
            legacyBundledCLIURL,
            siblingCLIURL,
            bundledHelperAgentShimURL,
            siblingAgentShimURL
        )
    }

    private func codexHookInstallStatus(
        state: CodexStatusHookInstallState,
        setupRequirement: CodexStatusHookSetupRequirement? = nil
    ) -> CodexStatusHookInstallStatus {
        let rootURL = URL(fileURLWithPath: "/tmp/toastty-codex-hooks-\(state.rawValue)", isDirectory: true)
        return CodexStatusHookInstallStatus(
            hooksFileURL: rootURL.appendingPathComponent("hooks.json", isDirectory: false),
            forwarderScriptURL: rootURL.appendingPathComponent("forwarder.sh", isDirectory: false),
            state: state,
            setupRequirement: setupRequirement
        )
    }

    private func makeLaunchUITestFixture() throws -> (
        store: AppStore,
        sessionRuntimeStore: SessionRuntimeStore,
        terminalRouter: TestTerminalCommandRouter,
        service: AgentLaunchService,
        windowID: UUID,
        workspaceID: UUID,
        panelID: UUID
    ) {
        let store = AppStore(persistTerminalFontPreference: false)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let terminalRouter = TestTerminalCommandRouter()
        terminalRouter.defaultPromptState = .idleAtPrompt
        let agentCatalogProvider = TestAgentCatalogProvider()
        let windowID = try #require(store.state.windows.first?.id)
        let workspace = try #require(store.selectedWorkspace)
        let workspaceID = workspace.id
        let panelID = try #require(workspace.focusedPanelID)
        let service = AgentLaunchService(
            store: store,
            terminalCommandRouter: terminalRouter,
            sessionRuntimeStore: sessionRuntimeStore,
            agentCatalogProvider: agentCatalogProvider,
            cliExecutablePathProvider: { "/bin/sh" },
            socketPathProvider: { "/tmp/toastty-tests.sock" },
            codexStatusTrackingSourceProvider: { .sessionLogFallback(reason: "test") }
        )

        return (store, sessionRuntimeStore, terminalRouter, service, windowID, workspaceID, panelID)
    }

    private func makeExecutableFile(at url: URL) throws {
        try makeFile(at: url, executable: true)
}

@MainActor
private final class SpyNativeSessionObserverRegistry: ManagedAgentNativeSessionObserving {
    private(set) var startedObservations: [ManagedAgentNativeSessionObservationContext] = []
    private(set) var cancelledSessionIDs: [String] = []

    func startObservation(_ observation: ManagedAgentNativeSessionObservationContext) {
        startedObservations.append(observation)
    }

    func cancelObservation(sessionID: String) {
        cancelledSessionIDs.append(sessionID)
    }
}

private func makeFile(at url: URL, executable: Bool) throws {
        let contents = Data("#!/bin/sh\nexit 0\n".utf8)
        FileManager.default.createFile(atPath: url.path, contents: contents)
        let permissions: NSNumber = executable ? 0o755 : 0o644
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private func extractEnvironmentValue(key: String, from command: String) -> String? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: key))=([^\\s]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        guard let match = regex.firstMatch(in: command, range: range),
              match.numberOfRanges == 2,
              let valueRange = Range(match.range(at: 1), in: command) else {
            return nil
        }
        return String(command[valueRange]).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }

    private func append(_ string: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path) == false {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let terminatedString = string.hasSuffix("\n") ? string : string + "\n"
        try handle.write(contentsOf: Data(terminatedString.utf8))
    }

    private func shellQuoteForTest(_ value: String) -> String {
        guard value.isEmpty == false else { return "''" }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789%+,-./:=@_")
        if value.unicodeScalars.allSatisfy(allowed.contains) {
            return value
        }
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }
}
