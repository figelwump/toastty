import CoreState
import Foundation
import RemoteProtocol

/// Linux ports of the configuration helpers that live as private statics on
/// the SwiftUI `ToasttyApp` (Sources/App/ToasttyApp.swift): launch
/// environment, agent command shims, configuration reload, templates.
/// Keep these in step with the macOS versions.
@MainActor
struct LinuxAppConfiguration {
    let runtimePaths: ToasttyRuntimePaths
    let environment: [String: String]
    let socketPath: String
    let cliExecutablePath: String?
    let agentShimExecutablePath: String?
    let appResourcesPath: String?

    // MARK: Launch environment (ToasttyApp.baseLaunchEnvironment)

    nonisolated static func baseLaunchEnvironment(
        panelID: UUID,
        runtimePaths: ToasttyRuntimePaths,
        socketPath: String,
        cliExecutablePath: String?,
        appResourcesPath: String?,
        shimDirectoryPath: String?,
        basePath: String?,
        agentBasePath: String?
    ) -> [String: String] {
        var environment: [String: String] = [
            ToasttyLaunchContextEnvironment.panelIDKey: panelID.uuidString,
            ToasttyLaunchContextEnvironment.socketPathKey: socketPath,
            ToasttyLaunchContextEnvironment.paneJournalFileKey: runtimePaths.paneJournalFileURL(for: panelID).path,
        ]
        if let cliExecutablePath {
            environment[ToasttyLaunchContextEnvironment.cliPathKey] = cliExecutablePath
        }
        if let appResourcesPath {
            environment[ToasttyLaunchContextEnvironment.appResourcesPathKey] = appResourcesPath
        }
        if let agentBasePath {
            environment[ToasttyLaunchContextEnvironment.agentBasePathKey] = agentBasePath
        }
        if let shimDirectoryPath {
            environment[ToasttyLaunchContextEnvironment.agentShimDirectoryKey] = shimDirectoryPath
            environment["PATH"] = AgentCommandShimInstaller.pathValue(prepending: shimDirectoryPath, to: basePath)
        }
        return environment
    }

    func configureBaseLaunchEnvironmentProvider(
        terminalRuntimeRegistry: TerminalRuntimeRegistry,
        shimDirectoryPath: String?,
        agentBasePath: String?
    ) {
        let runtimePaths = runtimePaths
        let socketPath = socketPath
        let cliExecutablePath = cliExecutablePath
        let appResourcesPath = appResourcesPath
        let basePath = environment["PATH"]
        ToasttyLog.info(
            "Configured terminal launch context environment",
            category: .bootstrap,
            metadata: [
                "socket_path": socketPath,
                "cli_path": cliExecutablePath ?? "none",
                "app_resources_path": appResourcesPath ?? "none",
                "agent_shim_directory": shimDirectoryPath ?? "none",
                "agent_base_path_present": agentBasePath == nil ? "false" : "true",
                "pane_journal_directory": runtimePaths.paneJournalDirectoryURL.path,
            ]
        )
        terminalRuntimeRegistry.setBaseLaunchEnvironmentProvider { panelID in
            Self.baseLaunchEnvironment(
                panelID: panelID,
                runtimePaths: runtimePaths,
                socketPath: socketPath,
                cliExecutablePath: cliExecutablePath,
                appResourcesPath: appResourcesPath,
                shimDirectoryPath: shimDirectoryPath,
                basePath: basePath,
                agentBasePath: agentBasePath
            )
        }
    }

    func managedAgentResolutionContext(
        agentBasePath: String?,
        installedShimDirectoryPath: String?
    ) -> ManagedAgentResolutionContext {
        var environment = environment
        if let agentBasePath {
            environment[ToasttyLaunchContextEnvironment.agentBasePathKey] = agentBasePath
        }
        return ManagedAgentResolutionContext(
            environment: environment,
            shimDirectoryPaths: [installedShimDirectoryPath, runtimePaths.agentShimDirectoryURL.path]
        )
    }

    // MARK: Agent command shims (ToasttyApp.synchronizeManagedAgentCommandShims)

    func synchronizeManagedAgentCommandShims(enabled: Bool, agentProfiles: AgentCatalog) throws -> String? {
        let managedDirectoryURL = Self.managedAgentCommandShimDirectoryURL(
            runtimePaths: runtimePaths,
            helperExecutablePath: agentShimExecutablePath
        )
        let helperExecutablePath = agentShimExecutablePath
        let installation = try AgentCommandShimInstaller(
            runtimePaths: runtimePaths,
            installationDirectoryURL: managedDirectoryURL,
            managedCommandNames: ManagedAgentCommandResolver.shimCommandNames(for: agentProfiles),
            helperExecutablePathProvider: { helperExecutablePath }
        ).syncInstallation(enabled: enabled)
        let compatibilityDirectoryURL = runtimePaths.agentShimDirectoryURL.standardizedFileURL
        if managedDirectoryURL.standardizedFileURL != compatibilityDirectoryURL {
            let compatibilityHelperPath = compatibilityDirectoryURL
                .appendingPathComponent("toastty-agent-shim", isDirectory: false)
                .path
            do {
                _ = try AgentCommandShimInstaller(
                    runtimePaths: runtimePaths,
                    installationDirectoryURL: compatibilityDirectoryURL,
                    managedCommandNames: ManagedAgentCommandResolver.shimCommandNames(for: agentProfiles),
                    helperExecutablePathProvider: { compatibilityHelperPath }
                ).syncInstallation(enabled: enabled)
            } catch {
                ToasttyLog.warning(
                    "Failed to refresh compatibility agent command shims",
                    category: .bootstrap,
                    metadata: [
                        "directory": compatibilityDirectoryURL.path,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }
        return installation?.directoryURL.path
    }

    nonisolated static func managedAgentCommandShimDirectoryURL(
        runtimePaths: ToasttyRuntimePaths,
        helperExecutablePath: String?
    ) -> URL {
        let fallbackURL = runtimePaths.agentShimDirectoryURL.standardizedFileURL
        let normalizedHelperPath = helperExecutablePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard runtimePaths.isRuntimeHomeEnabled,
              let normalizedHelperPath,
              normalizedHelperPath.isEmpty == false else {
            return fallbackURL
        }
        let directoryURL = URL(fileURLWithPath: normalizedHelperPath).standardizedFileURL.deletingLastPathComponent()
        let instancesRootURL = runtimePaths.managedAgentHelperInstancesDirectoryURL.standardizedFileURL
        let instanceName = directoryURL.lastPathComponent
        guard directoryURL.deletingLastPathComponent() == instancesRootURL,
              instanceName.hasPrefix("instance-"),
              UUID(uuidString: String(instanceName.dropFirst("instance-".count))) != nil else {
            return fallbackURL
        }
        return directoryURL
    }

    // MARK: Reload (ToasttyApp.reloadConfiguration)

    func reload(
        store: AppStore,
        agentCatalogStore: AgentCatalogStore,
        terminalProfileStore: TerminalProfileStore,
        codexProcessPathStore: CodexProcessPathStore,
        resolutionContextStore: ManagedAgentResolutionContextStore,
        terminalRuntimeRegistry: TerminalRuntimeRegistry,
        agentHookDispatcher: AgentHookDispatcher
    ) {
        var failureMessages: [String] = []
        var warningMessages: [String] = []

        if case .failure(let error) = agentCatalogStore.reload() {
            failureMessages.append(error.localizedDescription)
        }
        if case .failure(let error) = terminalProfileStore.reload() {
            failureMessages.append(error.localizedDescription)
        }

        let config = ToasttyConfigStore.load()
        store.setURLRoutingPreferences(config.urlRoutingPreferences)
        store.setLocalDocumentRoutingPreferences(config.localDocumentRoutingPreferences)
        agentHookDispatcher.updateScriptPath(config.agentHookScriptPath)
        if let issue = AgentHookDispatcher.configuredScriptPathIssue(config.agentHookScriptPath) {
            warningMessages.append(issue)
        }
        let processEnvironment = ProcessInfo.processInfo.environment
        let agentBasePath = ManagedAgentBasePathResolver(environment: processEnvironment, fallbackPath: nil).resolve()
        codexProcessPathStore.update(
            ManagedAgentPathResolver.sanitizedMergedPath(
                preferredPath: agentBasePath,
                fallbackPath: processEnvironment["PATH"],
                excludedDirectoryPaths: [runtimePaths.agentShimDirectoryURL.path]
            )
        )
        do {
            let shimDirectoryPath = try synchronizeManagedAgentCommandShims(
                enabled: config.enableAgentCommandShims,
                agentProfiles: agentCatalogStore.catalog
            )
            resolutionContextStore.update(
                managedAgentResolutionContext(agentBasePath: agentBasePath, installedShimDirectoryPath: shimDirectoryPath)
            )
            configureBaseLaunchEnvironmentProvider(
                terminalRuntimeRegistry: terminalRuntimeRegistry,
                shimDirectoryPath: shimDirectoryPath,
                agentBasePath: agentBasePath
            )
        } catch {
            failureMessages.append("Failed to update managed agent command shims: \(error.localizedDescription)")
            configureBaseLaunchEnvironmentProvider(
                terminalRuntimeRegistry: terminalRuntimeRegistry,
                shimDirectoryPath: nil,
                agentBasePath: agentBasePath
            )
        }
        Self.applyConfiguredDefaultTerminalProfile(
            to: store,
            terminalProfileCatalog: terminalProfileStore.catalog,
            configuredDefaultTerminalProfileID: config.defaultTerminalProfileID,
            source: "reload"
        )
        // Ghostty's configured font size is reported by the terminal frontend
        // through `LinuxAppLogic.setGhosttyConfiguredFontPoints`.
        Self.applyTerminalFontState(
            to: store,
            config: config,
            legacyTerminalFontSizePoints: nil,
            ghosttyConfiguredTerminalFontPoints: LinuxAppConfiguration.ghosttyConfiguredFontPoints
        )
        let shortcutWarnings = ProfileShortcutRegistry(
            terminalProfiles: terminalProfileStore.catalog,
            terminalProfilesFilePath: terminalProfileStore.fileURL.path,
            agentProfiles: agentCatalogStore.catalog,
            agentProfilesFilePath: agentCatalogStore.fileURL.path
        ).warningMessages
        warningMessages.append(contentsOf: shortcutWarnings)
        for warning in warningMessages {
            ToasttyLog.warning(warning, category: .bootstrap)
        }
        guard failureMessages.isEmpty == false || warningMessages.isEmpty == false else { return }

        let alert = NSAlert()
        alert.messageText = failureMessages.isEmpty ? "Configuration Reload Warnings" : "Unable to Reload Configuration"
        alert.informativeText = (failureMessages + warningMessages).joined(separator: "\n")
        alert.alertStyle = failureMessages.isEmpty ? .informational : .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Ghostty's own `font-size`, reported by the terminal frontend once its
    /// config loads (macOS reads `GhosttyRuntimeManager.configuredTerminalFontPoints`).
    static var ghosttyConfiguredFontPoints: Double?

    // MARK: Config state (ToasttyApp.applyInitialToasttyConfigState)

    static func applyInitialConfigState(
        to store: AppStore,
        terminalProfileCatalog: TerminalProfileCatalog,
        config: ToasttyConfig,
        legacyTerminalFontSizePoints: Double?
    ) {
        store.setURLRoutingPreferences(config.urlRoutingPreferences)
        store.setLocalDocumentRoutingPreferences(config.localDocumentRoutingPreferences)
        applyConfiguredDefaultTerminalProfile(
            to: store,
            terminalProfileCatalog: terminalProfileCatalog,
            configuredDefaultTerminalProfileID: config.defaultTerminalProfileID,
            source: "startup"
        )
        applyTerminalFontState(
            to: store,
            config: config,
            legacyTerminalFontSizePoints: legacyTerminalFontSizePoints,
            ghosttyConfiguredTerminalFontPoints: ghosttyConfiguredFontPoints
        )
    }

    static func applyTerminalFontState(
        to store: AppStore,
        config: ToasttyConfig,
        legacyTerminalFontSizePoints: Double?,
        ghosttyConfiguredTerminalFontPoints: Double?,
        clearLegacyTerminalFontSizePoints: @escaping () -> Void = {
            ToasttySettingsStore.clearLegacyTerminalFontSizePoints()
        }
    ) {
        let configuredBaseline = config.terminalFontSizePoints ?? ghosttyConfiguredTerminalFontPoints
        _ = store.send(.setConfiguredTerminalFont(points: configuredBaseline))
        guard let legacyTerminalFontSizePoints else { return }
        defer { clearLegacyTerminalFontSizePoints() }
        guard store.state.windows.allSatisfy({ $0.terminalFontSizePointsOverride == nil }) else { return }
        for windowID in store.state.windows.map(\.id) {
            _ = store.send(.setWindowTerminalFont(windowID: windowID, points: legacyTerminalFontSizePoints))
        }
    }

    nonisolated static func resolvedDefaultTerminalProfileID(
        configuredDefaultTerminalProfileID: String?,
        terminalProfileCatalog: TerminalProfileCatalog,
        source: String
    ) -> String? {
        guard let profileID = AppState.normalizedTerminalProfileID(configuredDefaultTerminalProfileID) else {
            return nil
        }
        guard terminalProfileCatalog.profile(id: profileID) != nil else {
            ToasttyLog.warning(
                "Configured default terminal profile is unavailable; new terminals will remain unprofiled",
                category: .bootstrap,
                metadata: ["profile_id": profileID, "source": source]
            )
            return nil
        }
        return profileID
    }

    static func applyConfiguredDefaultTerminalProfile(
        to store: AppStore,
        terminalProfileCatalog: TerminalProfileCatalog,
        configuredDefaultTerminalProfileID: String?,
        source: String
    ) {
        let profileID = resolvedDefaultTerminalProfileID(
            configuredDefaultTerminalProfileID: configuredDefaultTerminalProfileID,
            terminalProfileCatalog: terminalProfileCatalog,
            source: source
        )
        _ = store.send(.setDefaultTerminalProfile(profileID: profileID))
    }

    // MARK: Startup chores

    nonisolated static func prepareRuntimeEnvironment(_ runtimePaths: ToasttyRuntimePaths) {
        do {
            try runtimePaths.prepare()
        } catch {
            FileHandle.standardError.write(Data("toastty runtime preparation failed: \(error.localizedDescription)\n".utf8))
        }
    }

    nonisolated static func refreshManagedShellIntegrationSnippetIfInstalled(environment: [String: String]) {
        do {
            _ = try ProfileShellIntegrationInstaller(environment: environment).refreshManagedSnippetIfInstalled()
        } catch {
            ToasttyLog.warning(
                "Failed to refresh managed shell integration snippet",
                category: .bootstrap,
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    nonisolated static func prunePaneRestoreFiles(runtimePaths: ToasttyRuntimePaths, liveTerminalPanelIDs: Set<UUID>) {
        let history = PaneHistoryStore(runtimePaths: runtimePaths)
            .pruneUnreferencedHistoryFiles(keepingPanelIDs: liveTerminalPanelIDs)
        let journal = PaneCommandJournalStore(runtimePaths: runtimePaths)
            .pruneUnreferencedJournalFiles(keepingPanelIDs: liveTerminalPanelIDs)
        if history.removedFileCount > 0 || journal.removedFileCount > 0 {
            ToasttyLog.info(
                "Pruned stale pane restore files",
                category: .bootstrap,
                metadata: [
                    "history_removed_count": String(history.removedFileCount),
                    "journal_removed_count": String(journal.removedFileCount),
                    "live_panel_count": String(liveTerminalPanelIDs.count),
                ]
            )
        }
        if history.failedRemovalCount > 0 || journal.failedRemovalCount > 0 {
            ToasttyLog.warning(
                "Failed removing some stale pane restore files",
                category: .bootstrap,
                metadata: [
                    "history_failed_count": String(history.failedRemovalCount),
                    "journal_failed_count": String(journal.failedRemovalCount),
                ]
            )
        }
    }

    nonisolated static func ensureTerminalProfilesTemplateExists() {
        logFailure("Failed to ensure terminal profiles template exists", path: TerminalProfilesFile.fileURL().path) {
            try TerminalProfilesFile.ensureTemplateExists()
        }
    }

    nonisolated static func ensureToasttyConfigTemplateExists() {
        logFailure("Failed to ensure Toastty config template exists", path: ToasttyConfigStore.configFileURL().path) {
            try ToasttyConfigStore.ensureTemplateExists()
        }
    }

    nonisolated static func ensureAgentHookTemplateExists() {
        logFailure("Failed to ensure agent hook template exists", path: AgentHookTemplateFile.fileURL().path) {
            try AgentHookTemplateFile.ensureTemplateExists()
        }
    }

    nonisolated static func writeToasttyConfigReference() {
        logFailure("Failed to write Toastty config reference", path: ToasttyConfigStore.configReferenceFileURL().path) {
            try ToasttyConfigStore.writeConfigReference()
        }
    }

    nonisolated static func scheduleCodexIntegrationMaintenance() {
        Task.detached(priority: .utility) {
            do {
                guard let result = try CodexStatusHookInstaller().performAutomaticMaintenanceIfNeeded() else { return }
                ToasttyLog.info(
                    "Automatically maintained the Codex integration forwarder",
                    category: .bootstrap,
                    metadata: [
                        "hooks_file": result.status.hooksFileURL.path,
                        "status": result.status.state.rawValue,
                    ]
                )
            } catch {
                ToasttyLog.warning(
                    "Failed automatic Codex status hook maintenance",
                    category: .bootstrap,
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    /// Push relay settings come from the macOS Info.plist; on Linux from the
    /// environment (TOASTTY_PUSH_RELAY_URL, TOASTTY_PUSH_RELAY_ID,
    /// TOASTTY_PUSH_APNS_ENVIRONMENT). Unset means push is off.
    nonisolated static func pushConfiguration(environment: [String: String]) -> RemotePushConfiguration? {
        guard let rawURL = environment["TOASTTY_PUSH_RELAY_URL"], let url = URL(string: rawURL),
              let relayID = environment["TOASTTY_PUSH_RELAY_ID"], relayID.isEmpty == false,
              let rawEnvironment = environment["TOASTTY_PUSH_APNS_ENVIRONMENT"],
              let apnsEnvironment = RemotePushAPNsEnvironment(rawValue: rawEnvironment) else {
            return nil
        }
        return RemotePushConfiguration(relayURL: url, relayID: relayID, apnsEnvironment: apnsEnvironment)
    }

    private nonisolated static func logFailure(_ message: String, path: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            ToasttyLog.warning(
                message,
                category: .bootstrap,
                metadata: ["path": path, "error": error.localizedDescription]
            )
        }
    }
}
