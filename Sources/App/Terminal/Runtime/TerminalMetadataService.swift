#if TOASTTY_HAS_GHOSTTY_KIT
import AppKit
import CoreState
import Foundation

@MainActor
final class TerminalMetadataService {
    private struct DesktopNotificationRoute {
        let workspaceID: UUID?
        let panelID: UUID?
        let source: String
    }

    private static let nativeCWDProcessFallbackPollInterval: TimeInterval = 30
    static let immediateProcessRefreshAttemptCount = immediateProcessRefreshRetryDelaysNanoseconds.count + 1
    // Retry quickly on startup so restored pane labels stop showing stale cwd
    // while the login -> shell child process is still materializing.
    private static let immediateProcessRefreshRetryDelaysNanoseconds: [UInt64] = [
        75_000_000,
        150_000_000,
        250_000_000,
        500_000_000,
    ]

    private unowned let store: AppStore
    private unowned let registry: TerminalRuntimeRegistry
    // Once a panel proves native Ghostty cwd support, keep process-based cwd
    // fallback disabled for that panel's lifetime to avoid misbinding drift.
    private var panelsWithConfirmedNativeCWDSupport: Set<UUID> = []
    private var nativeCWDLastProcessFallbackPollAtByPanelID: [UUID: Date] = [:]
    private let processWorkingDirectoryResolver = TerminalProcessWorkingDirectoryResolver()
    private let resolveWorkingDirectoryFromProcessOverride: ((UUID) -> String?)?
    private let processRefreshRetryDelay: @Sendable (UInt64) async -> Void
    private var immediateProcessRefreshTaskByPanelID: [UUID: Task<Void, Never>] = [:]
    private var immediateProcessRefreshTokenByPanelID: [UUID: UUID] = [:]

    deinit {
        for task in immediateProcessRefreshTaskByPanelID.values {
            task.cancel()
        }
    }

    convenience init(store: AppStore, registry: TerminalRuntimeRegistry) {
        self.init(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: nil,
            processRefreshRetryDelay: Self.defaultProcessRefreshRetryDelay
        )
    }

    init(
        store: AppStore,
        registry: TerminalRuntimeRegistry,
        resolveWorkingDirectoryFromProcessOverride: ((UUID) -> String?)?,
        processRefreshRetryDelay: @escaping @Sendable (UInt64) async -> Void
    ) {
        self.store = store
        self.registry = registry
        self.resolveWorkingDirectoryFromProcessOverride = resolveWorkingDirectoryFromProcessOverride
        self.processRefreshRetryDelay = processRefreshRetryDelay
    }

    func synchronizeLivePanels(_ livePanelIDs: Set<UUID>) {
        processWorkingDirectoryResolver.prune(panelIDs: livePanelIDs)
        for (panelID, task) in immediateProcessRefreshTaskByPanelID where !livePanelIDs.contains(panelID) {
            task.cancel()
        }
        immediateProcessRefreshTaskByPanelID = immediateProcessRefreshTaskByPanelID.filter { panelID, _ in
            livePanelIDs.contains(panelID)
        }
        immediateProcessRefreshTokenByPanelID = immediateProcessRefreshTokenByPanelID.filter { panelID, _ in
            livePanelIDs.contains(panelID)
        }
        panelsWithConfirmedNativeCWDSupport = panelsWithConfirmedNativeCWDSupport.filter { livePanelIDs.contains($0) }
        nativeCWDLastProcessFallbackPollAtByPanelID = nativeCWDLastProcessFallbackPollAtByPanelID.filter { panelID, _ in
            livePanelIDs.contains(panelID)
        }
    }

    func invalidate(panelID: UUID) {
        processWorkingDirectoryResolver.invalidate(panelID: panelID)
        immediateProcessRefreshTaskByPanelID.removeValue(forKey: panelID)?.cancel()
        immediateProcessRefreshTokenByPanelID.removeValue(forKey: panelID)
        panelsWithConfirmedNativeCWDSupport.remove(panelID)
        nativeCWDLastProcessFallbackPollAtByPanelID.removeValue(forKey: panelID)
    }

    func handleDesktopNotificationAction(
        action: GhosttyRuntimeAction,
        title: String,
        body: String,
        state: AppState
    ) -> Bool {
        let route = resolveDesktopNotificationRoute(
            action: action,
            title: title,
            state: state
        )
        return handleDesktopNotification(
            title: title,
            body: body,
            route: route,
            state: state
        )
    }

    func handleRuntimeMetadataAction(
        _ intent: GhosttyRuntimeAction.Intent,
        workspaceID: UUID,
        panelID: UUID,
        state: AppState
    ) -> Bool {
        switch intent {
        case .setTerminalTitle(let title):
            return handleTerminalMetadataUpdate(
                title: title,
                cwd: nil,
                allowLegacyCWDInference: prefersNativeCWDSignal(panelID: panelID) == false,
                workspaceID: workspaceID,
                panelID: panelID,
                state: state
            )

        case .setTerminalCWD(let cwd):
            if TerminalRuntimeRegistry.normalizedCWDValue(cwd) != nil {
                recordNativeCWDSignal(panelID: panelID)
            }
            return handleTerminalMetadataUpdate(
                title: nil,
                cwd: cwd,
                allowLegacyCWDInference: false,
                workspaceID: workspaceID,
                panelID: panelID,
                state: state
            )

        case .commandFinished(let exitCode):
            return handleCommandFinishedMetadataUpdate(
                exitCode: exitCode,
                workspaceID: workspaceID,
                panelID: panelID,
                state: state
            )

        default:
            return false
        }
    }

    func prefersNativeCWDSignal(panelID: UUID) -> Bool {
        panelsWithConfirmedNativeCWDSupport.contains(panelID)
    }

    func shouldRunProcessCWDFallbackPoll(panelID: UUID, now: Date = Date()) -> Bool {
        guard panelsWithConfirmedNativeCWDSupport.contains(panelID) == false else {
            return false
        }
        guard let lastPollAt = nativeCWDLastProcessFallbackPollAtByPanelID[panelID] else {
            return true
        }
        return now.timeIntervalSince(lastPollAt) >= Self.nativeCWDProcessFallbackPollInterval
    }

    func recordProcessCWDFallbackPoll(panelID: UUID, now: Date = Date()) {
        nativeCWDLastProcessFallbackPollAtByPanelID[panelID] = now
    }

    func snapshotChildPIDsForSurfaceCreation() -> Set<pid_t> {
        processWorkingDirectoryResolver.snapshotChildPIDs()
    }

    func registerChildPIDAfterSurfaceCreation(
        panelID: UUID,
        previousChildren: Set<pid_t>,
        expectedWorkingDirectory: String?
    ) {
        processWorkingDirectoryResolver.registerNewChild(
            panelID: panelID,
            previousChildren: previousChildren,
            expectedWorkingDirectory: expectedWorkingDirectory
        )
    }

    func reconcileSurfaceWorkingDirectory(panelID: UUID, workingDirectory: String?, source: String) {
        guard let normalizedWorkingDirectory = TerminalRuntimeRegistry.normalizedCWDValue(workingDirectory) else {
            return
        }

        let state = store.state
        guard let workspaceID = registry.workspaceID(containing: panelID, state: state),
              let workspace = state.workspacesByID[workspaceID],
              let panelState = workspace.panels[panelID],
              case .terminal(let terminalState) = panelState else {
            return
        }
        guard TerminalRuntimeRegistry.cwdValuesDiffer(normalizedWorkingDirectory, terminalState.cwd) else {
            return
        }

        let handled = store.send(
            .updateTerminalPanelMetadata(
                panelID: panelID,
                title: nil,
                cwd: normalizedWorkingDirectory
            )
        )
        if handled {
            ToasttyLog.debug(
                "Synchronized terminal cwd from Ghostty surface state",
                category: .terminal,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "panel_id": panelID.uuidString,
                    "source": source,
                    "cwd_sample": String(normalizedWorkingDirectory.prefix(120)),
                ]
            )
        } else {
            ToasttyLog.warning(
                "Reducer rejected terminal cwd sync from Ghostty surface state",
                category: .terminal,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "panel_id": panelID.uuidString,
                    "source": source,
                ]
            )
        }
    }

    func refreshWorkingDirectoryFromProcessIfNeeded(panelID: UUID, source: String) -> String? {
        guard prefersNativeCWDSignal(panelID: panelID) == false else {
            return nil
        }
        guard let processWorkingDirectory = resolvedWorkingDirectoryFromProcess(panelID: panelID),
              let normalizedWorkingDirectory = TerminalRuntimeRegistry.normalizedCWDValue(processWorkingDirectory) else {
            return nil
        }

        reconcileSurfaceWorkingDirectory(
            panelID: panelID,
            workingDirectory: normalizedWorkingDirectory,
            source: source
        )
        return normalizedWorkingDirectory
    }

    func requestImmediateWorkingDirectoryRefresh(panelID: UUID, source: String) {
        immediateProcessRefreshTaskByPanelID.removeValue(forKey: panelID)?.cancel()
        if let refreshedWorkingDirectory = refreshWorkingDirectoryFromProcessIfNeeded(
            panelID: panelID,
            source: source
        ) {
            ToasttyLog.debug(
                "Resolved terminal cwd from process immediately after surface creation",
                category: .terminal,
                metadata: [
                    "panel_id": panelID.uuidString,
                    "source": source,
                    "cwd_sample": String(refreshedWorkingDirectory.prefix(120)),
                ]
            )
            immediateProcessRefreshTokenByPanelID.removeValue(forKey: panelID)
            return
        }

        let refreshToken = UUID()
        immediateProcessRefreshTokenByPanelID[panelID] = refreshToken

        let retryDelays = Self.immediateProcessRefreshRetryDelaysNanoseconds
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var didResolveWorkingDirectory = false

            for (attempt, delay) in retryDelays.enumerated() {
                guard Task.isCancelled == false else { return }

                await self.processRefreshRetryDelay(delay)
                guard Task.isCancelled == false else { return }
                guard self.prefersNativeCWDSignal(panelID: panelID) == false else {
                    break
                }

                let attemptSource = "\(source)_retry_\(attempt + 1)"
                if let refreshedWorkingDirectory = self.refreshWorkingDirectoryFromProcessIfNeeded(
                    panelID: panelID,
                    source: attemptSource
                ) {
                    ToasttyLog.debug(
                        "Resolved terminal cwd from process immediately after surface creation",
                        category: .terminal,
                        metadata: [
                            "panel_id": panelID.uuidString,
                            "source": attemptSource,
                            "cwd_sample": String(refreshedWorkingDirectory.prefix(120)),
                        ]
                    )
                    didResolveWorkingDirectory = true
                    break
                }
            }

            if self.immediateProcessRefreshTokenByPanelID[panelID] == refreshToken {
                if !didResolveWorkingDirectory {
                    ToasttyLog.debug(
                        "Immediate terminal cwd refresh exhausted retries after surface creation",
                        category: .terminal,
                        metadata: [
                            "panel_id": panelID.uuidString,
                            "source": source,
                            "attempt_count": String(retryDelays.count + 1),
                        ]
                    )
                }
                self.immediateProcessRefreshTaskByPanelID.removeValue(forKey: panelID)
                self.immediateProcessRefreshTokenByPanelID.removeValue(forKey: panelID)
            }
        }

        immediateProcessRefreshTaskByPanelID[panelID] = task
    }

    private func recordNativeCWDSignal(panelID: UUID) {
        let isFirstSignal = panelsWithConfirmedNativeCWDSupport.insert(panelID).inserted
        nativeCWDLastProcessFallbackPollAtByPanelID.removeValue(forKey: panelID)
        if isFirstSignal {
            ToasttyLog.info(
                "Detected native Ghostty cwd callback for terminal panel; disabling process cwd fallback",
                category: .terminal,
                metadata: ["panel_id": panelID.uuidString]
            )
        }
    }

    private func resolveDesktopNotificationRoute(
        action: GhosttyRuntimeAction,
        title: String,
        state: AppState
    ) -> DesktopNotificationRoute {
        if let surfaceHandle = action.surfaceHandle {
            if let panelID = registry.panelID(forSurfaceHandle: surfaceHandle),
               let workspaceID = registry.workspaceID(containing: panelID, state: state) {
                return DesktopNotificationRoute(
                    workspaceID: workspaceID,
                    panelID: panelID,
                    source: "surface_handle"
                )
            }

            ToasttyLog.warning(
                "Desktop notification missing panel mapping for Ghostty surface handle",
                category: .notifications,
                metadata: ["surface_handle": String(surfaceHandle)]
            )
        }

        if let selection = state.selectedWorkspaceSelection() {
            let nonSelectedWorkspaceIDs = selection.window.workspaceIDs.filter { $0 != selection.workspaceID }
            if nonSelectedWorkspaceIDs.count == 1,
               let workspaceID = nonSelectedWorkspaceIDs.first,
               let workspace = state.workspacesByID[workspaceID],
               let panelID = resolvedActionPanelID(in: workspace) {
                return DesktopNotificationRoute(
                    workspaceID: workspaceID,
                    panelID: panelID,
                    source: "single_non_selected_workspace"
                )
            }
        }

        ToasttyLog.warning(
            "Desktop notification route unresolved",
            category: .notifications,
            metadata: [
                "title": title,
                "has_surface_handle": action.surfaceHandle == nil ? "false" : "true",
            ]
        )
        return DesktopNotificationRoute(
            workspaceID: nil,
            panelID: nil,
            source: "unresolved"
        )
    }

    private func resolvedWorkingDirectoryFromProcess(panelID: UUID) -> String? {
        if let resolveWorkingDirectoryFromProcessOverride {
            return resolveWorkingDirectoryFromProcessOverride(panelID)
        }
        return processWorkingDirectoryResolver.resolveWorkingDirectory(for: panelID)
    }

    private static func defaultProcessRefreshRetryDelay(_ nanoseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    private func handleDesktopNotification(
        title: String,
        body: String,
        route: DesktopNotificationRoute,
        state: AppState
    ) -> Bool {
        let workspaceID = route.workspaceID
        let panelID = route.panelID
        let notificationContext: DesktopNotificationContext
        if let workspaceID {
            notificationContext = desktopNotificationContext(
                workspaceID: workspaceID,
                panelID: panelID,
                state: state
            )
        } else {
            notificationContext = DesktopNotificationContext()
        }

        let appIsActive = NSApplication.shared.isActive
        let currentSelection = state.selectedWorkspaceSelection()
        let currentSelectedWorkspaceID = currentSelection?.workspaceID
        let panelIsFocused: Bool
        if let workspaceID,
           let panelID,
           currentSelectedWorkspaceID == workspaceID,
           let workspace = state.workspacesByID[workspaceID] {
            panelIsFocused = workspace.focusedPanelID == panelID
                && workspace.layoutTree.slotContaining(panelID: panelID) != nil
        } else {
            panelIsFocused = false
        }

        if appIsActive && panelIsFocused {
            var metadata: [String: String] = [
                "title": title,
                "route_source": route.source,
            ]
            if let workspaceID {
                metadata["workspace_id"] = workspaceID.uuidString
            }
            if let panelID {
                metadata["panel_id"] = panelID.uuidString
            }
            ToasttyLog.debug(
                "Suppressed desktop notification for focused panel",
                category: .notifications,
                metadata: metadata
            )
            return true
        }

        if appIsActive,
           workspaceID == nil,
           panelID == nil,
           let selection = currentSelection,
           selection.window.workspaceIDs.count == 1,
           let workspace = state.workspacesByID[selection.workspaceID],
           let resolvedPanelID = resolvedActionPanelID(in: workspace),
           workspace.focusedPanelID == resolvedPanelID,
           workspace.layoutTree.slotContaining(panelID: resolvedPanelID) != nil {
            ToasttyLog.debug(
                "Suppressed unresolved desktop notification for focused panel in single-workspace window",
                category: .notifications,
                metadata: ["title": title]
            )
            return true
        }

        if let workspaceID {
            _ = store.send(.recordDesktopNotification(workspaceID: workspaceID, panelID: panelID))
        } else {
            ToasttyLog.warning(
                "Skipped unread badge update because desktop notification route is unresolved",
                category: .notifications,
                metadata: ["title": title]
            )
        }

        Task {
            await SystemNotificationSender.send(
                title: title,
                body: body,
                workspaceID: workspaceID,
                panelID: panelID,
                context: notificationContext
            )
        }

        var metadata: [String: String] = [
            "title": title,
            "app_active": appIsActive ? "true" : "false",
            "route_source": route.source,
        ]
        if let workspaceID {
            metadata["workspace_id"] = workspaceID.uuidString
        }
        if let panelID {
            metadata["panel_id"] = panelID.uuidString
        }
        ToasttyLog.info(
            "Delivered desktop notification from Ghostty",
            category: .notifications,
            metadata: metadata
        )
        return true
    }

    private func desktopNotificationContext(
        workspaceID: UUID,
        panelID: UUID?,
        state: AppState
    ) -> DesktopNotificationContext {
        guard let workspace = state.workspacesByID[workspaceID] else {
            return DesktopNotificationContext()
        }
        return DesktopNotificationContext(
            workspaceTitle: workspace.title,
            panelLabel: panelID.flatMap { workspace.panels[$0]?.notificationLabel }
        )
    }

    private func handleTerminalMetadataUpdate(
        title: String?,
        cwd: String?,
        allowLegacyCWDInference: Bool,
        workspaceID: UUID,
        panelID: UUID,
        state: AppState
    ) -> Bool {
        guard let workspace = state.workspacesByID[workspaceID],
              let panelState = workspace.panels[panelID],
              case .terminal(let terminalState) = panelState else {
            ToasttyLog.debug(
                "Skipping terminal metadata update for non-terminal panel",
                category: .terminal,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "panel_id": panelID.uuidString,
                ]
            )
            return false
        }

        var normalizedTitle = TerminalRuntimeRegistry.normalizedMetadataValue(title)
        var normalizedCWD = TerminalRuntimeRegistry.normalizedCWDValue(cwd)
        let normalizedRestoreStartupCommand = normalizedRestoredStartupCommand(
            panelID: panelID,
            terminalState: terminalState
        )
        if shouldSuppressRestoredStartupCommandTitleUpdate(
            normalizedTitle: normalizedTitle,
            normalizedCWD: normalizedCWD,
            normalizedRestoreStartupCommand: normalizedRestoreStartupCommand
        ) {
            ToasttyLog.debug(
                "Suppressing restored profile startup-command title until authoritative runtime metadata arrives",
                category: .terminal,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "panel_id": panelID.uuidString,
                    "profile_id": terminalState.profileBinding?.profileID ?? "nil",
                ]
            )
            normalizedTitle = nil
        } else if normalizedCWD == nil,
                  normalizedTitle != nil,
                  normalizedRestoreStartupCommand != nil {
            registry.markRestoredPanelReceivedAuthoritativeMetadata(panelID: panelID)
        }
        var cwdSource = "explicit"
        if allowLegacyCWDInference,
           normalizedCWD == nil,
           let normalizedTitle {
            normalizedCWD = TerminalRuntimeRegistry.inferredCWDFromTitle(
                normalizedTitle,
                currentCWD: terminalState.cwd
            )
            if normalizedCWD != nil {
                cwdSource = "title_inference"
            }
        }
        if allowLegacyCWDInference,
           normalizedCWD == nil,
           cwd == nil,
           let normalizedTitle,
           normalizedTitle != terminalState.title,
           let visibleText = registry.automationReadVisibleText(panelID: panelID),
           let inferredCWD = TerminalRuntimeRegistry.inferredCWDFromVisibleTerminalText(
               visibleText,
               currentCWD: terminalState.cwd
           ) {
            normalizedCWD = inferredCWD
            cwdSource = "visible_text_inference"
        }
        if normalizedCWD == nil {
            cwdSource = "none"
        }

        var hasChanges = false
        if let normalizedTitle, normalizedTitle != terminalState.title {
            hasChanges = true
        }
        if let normalizedCWD,
           TerminalRuntimeRegistry.cwdValuesDiffer(normalizedCWD, terminalState.cwd) {
            hasChanges = true
        }

        guard hasChanges else {
            if normalizedCWD != nil {
                registry.markRestoredPanelReceivedAuthoritativeMetadata(panelID: panelID)
            }
            if normalizedTitle != nil || normalizedCWD != nil {
                ToasttyLog.debug(
                    "Ignoring terminal metadata update because values are unchanged",
                    category: .terminal,
                    metadata: [
                        "workspace_id": workspaceID.uuidString,
                        "panel_id": panelID.uuidString,
                        "title_present": normalizedTitle == nil ? "false" : "true",
                        "cwd_present": normalizedCWD == nil ? "false" : "true",
                        "cwd_source": cwdSource,
                    ]
                )
            }
            return true
        }

        let handled = store.send(
            .updateTerminalPanelMetadata(
                panelID: panelID,
                title: normalizedTitle,
                cwd: normalizedCWD
            )
        )
        if handled {
            if normalizedCWD != nil {
                registry.markRestoredPanelReceivedAuthoritativeMetadata(panelID: panelID)
            }
            let titleSample = normalizedTitle.map { String($0.prefix(80)) } ?? "nil"
            let cwdSample = normalizedCWD.map { String($0.prefix(80)) } ?? "nil"
            ToasttyLog.debug(
                "Applied terminal metadata update from Ghostty",
                category: .terminal,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "panel_id": panelID.uuidString,
                    "title_updated": normalizedTitle == nil ? "false" : "true",
                    "cwd_updated": normalizedCWD == nil ? "false" : "true",
                    "title_sample": titleSample,
                    "cwd_sample": cwdSample,
                    "cwd_source": cwdSource,
                ]
            )
        } else {
            ToasttyLog.warning(
                "Reducer rejected terminal metadata update from Ghostty",
                category: .terminal,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "panel_id": panelID.uuidString,
                    "title_updated": normalizedTitle == nil ? "false" : "true",
                    "cwd_updated": normalizedCWD == nil ? "false" : "true",
                ]
            )
        }
        return handled
    }

    private func shouldSuppressRestoredStartupCommandTitleUpdate(
        normalizedTitle: String?,
        normalizedCWD: String?,
        normalizedRestoreStartupCommand: String?
    ) -> Bool {
        guard let normalizedTitle else { return false }
        guard normalizedCWD == nil else { return false }
        guard let normalizedRestoreStartupCommand else { return false }
        return normalizedTitle == normalizedRestoreStartupCommand
    }

    private func normalizedRestoredStartupCommand(
        panelID: UUID,
        terminalState: TerminalPanelState
    ) -> String? {
        guard let startupCommand = registry.restoredProfileStartupCommand(
            panelID: panelID,
            terminalState: terminalState
        ) else {
            return nil
        }
        return TerminalRuntimeRegistry.normalizedMetadataValue(startupCommand)
    }

    private func handleCommandFinishedMetadataUpdate(
        exitCode: Int?,
        workspaceID: UUID,
        panelID: UUID,
        state: AppState
    ) -> Bool {
        guard prefersNativeCWDSignal(panelID: panelID) == false else {
            return true
        }
        guard let workspace = state.workspacesByID[workspaceID],
              let panelState = workspace.panels[panelID],
              case .terminal(let terminalState) = panelState else {
            return false
        }

        guard exitCode == nil || exitCode == 0 else {
            return true
        }

        guard let visibleText = registry.automationReadVisibleText(panelID: panelID),
              let inferredCWD = TerminalRuntimeRegistry.inferredCWDFromVisibleTerminalText(
                  visibleText,
                  currentCWD: terminalState.cwd
              ) else {
            return true
        }

        guard TerminalRuntimeRegistry.cwdValuesDiffer(inferredCWD, terminalState.cwd) else {
            return true
        }

        return handleTerminalMetadataUpdate(
            title: nil,
            cwd: inferredCWD,
            allowLegacyCWDInference: true,
            workspaceID: workspaceID,
            panelID: panelID,
            state: state
        )
    }

    private func resolvedActionPanelID(in workspace: WorkspaceState) -> UUID? {
        if let focusedPanelID = workspace.focusedPanelID,
           workspace.panels[focusedPanelID] != nil,
           workspace.layoutTree.slotContaining(panelID: focusedPanelID) != nil {
            return focusedPanelID
        }

        for leaf in workspace.layoutTree.allSlotInfos {
            let panelID = leaf.panelID
            if workspace.panels[panelID] != nil {
                return panelID
            }
        }

        return nil
    }
}
#endif
