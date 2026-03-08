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

    private static let nativeCWDSignalFreshnessInterval: TimeInterval = 120
    private static let nativeCWDProcessFallbackPollInterval: TimeInterval = 30

    private unowned let store: AppStore
    private unowned let registry: TerminalRuntimeRegistry
    private var nativeCWDLastSignalAtByPanelID: [UUID: Date] = [:]
    private var nativeCWDLastProcessFallbackPollAtByPanelID: [UUID: Date] = [:]
    private let processWorkingDirectoryResolver = TerminalProcessWorkingDirectoryResolver()

    init(store: AppStore, registry: TerminalRuntimeRegistry) {
        self.store = store
        self.registry = registry
    }

    func synchronizeLivePanels(_ livePanelIDs: Set<UUID>) {
        processWorkingDirectoryResolver.prune(panelIDs: livePanelIDs)
        nativeCWDLastSignalAtByPanelID = nativeCWDLastSignalAtByPanelID.filter { panelID, _ in
            livePanelIDs.contains(panelID)
        }
        nativeCWDLastProcessFallbackPollAtByPanelID = nativeCWDLastProcessFallbackPollAtByPanelID.filter { panelID, _ in
            livePanelIDs.contains(panelID)
        }
    }

    func invalidate(panelID: UUID) {
        processWorkingDirectoryResolver.invalidate(panelID: panelID)
        nativeCWDLastSignalAtByPanelID.removeValue(forKey: panelID)
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
            let now = Date()
            return handleTerminalMetadataUpdate(
                title: title,
                cwd: nil,
                allowLegacyCWDInference: prefersNativeCWDSignal(panelID: panelID, now: now) == false,
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

    func prefersNativeCWDSignal(panelID: UUID, now: Date = Date()) -> Bool {
        guard let lastSignalAt = nativeCWDLastSignalAtByPanelID[panelID] else {
            return false
        }
        return now.timeIntervalSince(lastSignalAt) <= Self.nativeCWDSignalFreshnessInterval
    }

    func shouldRunProcessCWDFallbackPoll(panelID: UUID, now: Date = Date()) -> Bool {
        guard nativeCWDLastSignalAtByPanelID[panelID] != nil else {
            return true
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
        expectedWorkingDirectory: String
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
        guard let processWorkingDirectory = processWorkingDirectoryResolver.resolveWorkingDirectory(for: panelID),
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

    private func recordNativeCWDSignal(panelID: UUID, now: Date = Date()) {
        let isFirstSignal = nativeCWDLastSignalAtByPanelID[panelID] == nil
        nativeCWDLastSignalAtByPanelID[panelID] = now
        nativeCWDLastProcessFallbackPollAtByPanelID[panelID] = now
        if isFirstSignal {
            ToasttyLog.info(
                "Detected native Ghostty cwd callback for terminal panel; process cwd polling will be treated as fallback",
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

        if let selectedWindowID = state.selectedWindowID,
           let selectedWindow = state.windows.first(where: { $0.id == selectedWindowID }) {
            let currentSelectedWorkspaceID = selectedWorkspaceID(state: state)
            let nonSelectedWorkspaceIDs = selectedWindow.workspaceIDs.filter { $0 != currentSelectedWorkspaceID }
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
        let currentSelectedWorkspaceID = selectedWorkspaceID(state: state)
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
           let selectedWorkspaceID = currentSelectedWorkspaceID,
           let selectedWindowID = state.selectedWindowID,
           let selectedWindow = state.windows.first(where: { $0.id == selectedWindowID }),
           selectedWindow.workspaceIDs.count == 1,
           let workspace = state.workspacesByID[selectedWorkspaceID],
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

        let normalizedTitle = TerminalRuntimeRegistry.normalizedMetadataValue(title)
        var normalizedCWD = TerminalRuntimeRegistry.normalizedCWDValue(cwd)
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

    private func selectedWorkspaceID(state: AppState) -> UUID? {
        guard let selectedWindowID = state.selectedWindowID,
              let selectedWindow = state.windows.first(where: { $0.id == selectedWindowID }) else {
            return nil
        }
        return selectedWindow.selectedWorkspaceID ?? selectedWindow.workspaceIDs.first
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
