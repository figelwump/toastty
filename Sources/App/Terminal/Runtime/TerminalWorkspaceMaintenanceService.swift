#if TOASTTY_HAS_GHOSTTY_KIT
import CoreState
import Foundation

@MainActor
final class TerminalWorkspaceMaintenanceService {
    typealias VisibilityPulseScheduler = (@escaping @MainActor () -> Void) -> Task<Void, Never>?

    private struct VisibleWorkspaceSelection: Equatable {
        let workspaceID: UUID
        let tabID: UUID
    }

    private static let sessionAutoStopPromptGraceInterval: TimeInterval = 1.5

    private weak var store: AppStore?
    private let metadataService: TerminalMetadataService
    private var sessionLifecycleTracker: (any TerminalSessionLifecycleTracking)?
    private let controllerForPanelID: (UUID) -> TerminalSurfaceController?
    private let visibilityPulseScheduler: VisibilityPulseScheduler
    private var previousVisibleWorkspaceSelection: VisibleWorkspaceSelection?
    private var visibilityPulseTask: Task<Void, Never>?
    private var processWorkingDirectoryRefreshTask: Task<Void, Never>?

    init(
        store: AppStore,
        metadataService: TerminalMetadataService,
        sessionLifecycleTracker: (any TerminalSessionLifecycleTracking)? = nil,
        controllerForPanelID: @escaping (UUID) -> TerminalSurfaceController?,
        visibilityPulseScheduler: @escaping VisibilityPulseScheduler = { pulse in
            Task { @MainActor in
                // Defer pulses so SwiftUI/NSViewRepresentable attachment and layout can settle.
                await Task.yield()
                guard Task.isCancelled == false else { return }
                pulse()

                await Task.yield()
                guard Task.isCancelled == false else { return }
                pulse()
            }
        }
    ) {
        self.store = store
        self.metadataService = metadataService
        self.sessionLifecycleTracker = sessionLifecycleTracker
        self.controllerForPanelID = controllerForPanelID
        self.visibilityPulseScheduler = visibilityPulseScheduler
    }

    deinit {
        visibilityPulseTask?.cancel()
        processWorkingDirectoryRefreshTask?.cancel()
    }

    func bind(sessionLifecycleTracker: (any TerminalSessionLifecycleTracking)?) {
        self.sessionLifecycleTracker = sessionLifecycleTracker
    }

    func synchronize(
        state: AppState,
        livePanelIDs: Set<UUID>,
        removedPanelIDs: Set<UUID>
    ) {
        for panelID in removedPanelIDs {
            metadataService.invalidate(panelID: panelID)
        }

        synchronizeLivePanels(livePanelIDs)
        pulseVisibleSurfacesIfSelectionChanged(state: state)
    }

    func handleSurfaceUnregister(panelID: UUID) {
        metadataService.invalidate(panelID: panelID)
    }

    func startProcessWorkingDirectoryRefreshLoopIfNeeded() {
        guard processWorkingDirectoryRefreshTask == nil else { return }
        processWorkingDirectoryRefreshTask = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                guard let self else { return }
                guard let store = self.store else {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }

                self.refreshTrackedTerminalMaintenance(state: store.state)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func synchronizeLivePanels(_ livePanelIDs: Set<UUID>) {
        metadataService.synchronizeLivePanels(livePanelIDs)
    }

    private func refreshTrackedTerminalMaintenance(state: AppState) {
        refreshSelectedWorkspaceTerminalMetadataFromProcess(state: state)
        refreshTrackedPanelSessions(state: state)
    }

    private func refreshSelectedWorkspaceTerminalMetadataFromProcess(state: AppState) {
        guard let selection = state.selectedWorkspaceSelection() else {
            return
        }

        let panelIDs = visibleTerminalPanelIDs(in: selection.workspace)
        guard panelIDs.isEmpty == false else { return }
        let now = Date()
        for panelID in panelIDs {
            if metadataService.shouldRunProcessCWDFallbackPoll(panelID: panelID, now: now) {
                metadataService.recordProcessCWDFallbackPoll(panelID: panelID, now: now)
                _ = metadataService.refreshWorkingDirectoryFromProcessIfNeeded(
                    panelID: panelID,
                    source: "process_poll"
                )
            }
        }
    }

    private func refreshTrackedPanelSessions(state: AppState) {
        let now = Date()
        let selectedPanelWorkspaceIDs = trackedSelectedWorkspaceVisibleTerminalPanelIDs(state: state)
        let backgroundPanelWorkspaceIDs = trackedBackgroundTerminalPanelIDs(state: state)

        for (panelID, workspaceID) in selectedPanelWorkspaceIDs {
            refreshTrackedPanelSession(
                panelID: panelID,
                workspaceID: workspaceID,
                state: state,
                now: now
            )
        }

        for (panelID, workspaceID) in backgroundPanelWorkspaceIDs {
            refreshTrackedPanelSession(
                panelID: panelID,
                workspaceID: workspaceID,
                state: state,
                now: now
            )
        }
    }

    private func refreshTrackedPanelSession(
        panelID: UUID,
        workspaceID: UUID,
        state: AppState,
        now: Date
    ) {
        guard let workspace = state.workspacesByID[workspaceID],
              let panelState = workspace.panelState(for: panelID),
              case .terminal = panelState,
              let controller = controllerForPanelID(panelID) else {
            return
        }

        let promptState = GhosttySurfaceSemanticState.promptState(for: controller.currentGhosttySurface())
        if let visibleText = controller.automationReadVisibleText() {
            _ = sessionLifecycleTracker?.refreshManagedSessionStatusFromVisibleTextIfNeeded(
                panelID: panelID,
                visibleText: visibleText,
                promptState: promptState,
                at: now
            )
        }

        guard promptState == .idleAtPrompt else {
            return
        }

        _ = sessionLifecycleTracker?.stopSessionForPanelIfOlderThan(
            panelID: panelID,
            minimumRuntime: Self.sessionAutoStopPromptGraceInterval,
            reason: .idleAtPrompt,
            at: now
        )
    }

    private func trackedSelectedWorkspaceVisibleTerminalPanelIDs(state: AppState) -> [UUID: UUID] {
        guard let selection = state.selectedWorkspaceSelection() else {
            return [:]
        }

        var workspaceByPanelID: [UUID: UUID] = [:]
        for panelID in visibleTerminalPanelIDs(in: selection.workspace) {
            guard controllerForPanelID(panelID) != nil else { continue }
            workspaceByPanelID[panelID] = selection.workspaceID
        }
        return workspaceByPanelID
    }

    private func trackedBackgroundTerminalPanelIDs(state: AppState) -> [UUID: UUID] {
        var workspaceByPanelID: [UUID: UUID] = [:]
        let selectedSelection = state.selectedWorkspaceSelection()
        let selectedWorkspaceID = selectedSelection?.workspaceID
        let selectedWorkspaceVisiblePanelIDs = selectedSelection.map { visibleTerminalPanelIDs(in: $0.workspace) } ?? []

        for workspace in state.workspacesByID.values {
            let backgroundPanelIDs: Set<UUID>
            if workspace.id == selectedWorkspaceID {
                backgroundPanelIDs = workspace.allTerminalPanelIDs.subtracting(selectedWorkspaceVisiblePanelIDs)
            } else {
                backgroundPanelIDs = workspace.allTerminalPanelIDs
            }

            for panelID in backgroundPanelIDs {
                guard controllerForPanelID(panelID) != nil else { continue }
                workspaceByPanelID[panelID] = workspace.id
            }
        }
        return workspaceByPanelID
    }

    private func pulseVisibleSurfacesIfSelectionChanged(state: AppState) {
        let currentVisibleSelection = resolvedVisibleWorkspaceSelection(state: state)
        guard currentVisibleSelection != previousVisibleWorkspaceSelection else { return }

        visibilityPulseTask?.cancel()
        visibilityPulseTask = nil
        let previousVisibleSelection = previousVisibleWorkspaceSelection
        previousVisibleWorkspaceSelection = currentVisibleSelection
        guard previousVisibleSelection != nil || currentVisibleSelection != nil else {
            return
        }

        scheduleVisibilityPulse(
            previousSelection: previousVisibleSelection,
            currentSelection: currentVisibleSelection
        )
    }

    private func scheduleVisibilityPulse(
        previousSelection: VisibleWorkspaceSelection?,
        currentSelection: VisibleWorkspaceSelection?
    ) {
        let workspaceIDs = Set(
            [previousSelection?.workspaceID, currentSelection?.workspaceID].compactMap(\.self)
        )
        ToasttyLog.debug(
            "Scheduling Ghostty visibility refresh pulse after workspace/tab selection change",
            category: .ghostty,
            metadata: ["workspace_ids": workspaceIDs.map(\.uuidString).sorted().joined(separator: ",")]
        )

        visibilityPulseTask = visibilityPulseScheduler { [weak self] in
            self?.pulseVisibleSurfaces(
                previousSelection: previousSelection,
                currentSelection: currentSelection
            )
        }
    }

    private func pulseVisibleSurfaces(
        previousSelection: VisibleWorkspaceSelection?,
        currentSelection: VisibleWorkspaceSelection?
    ) {
        guard let store else { return }
        let currentState = store.state
        let panelIDs = pulsedTerminalPanelIDs(
            state: currentState,
            previousSelection: previousSelection,
            currentSelection: currentSelection
        )
        guard panelIDs.isEmpty == false else { return }
        ToasttyLog.debug(
            "Pulsing Ghostty surfaces after workspace/tab selection change",
            category: .ghostty,
            metadata: [
                "panel_count": String(panelIDs.count),
                "workspace_ids": Set(
                    [previousSelection?.workspaceID, currentSelection?.workspaceID].compactMap(\.self)
                )
                .map(\.uuidString)
                .sorted()
                .joined(separator: ","),
            ]
        )
        for panelID in panelIDs {
            ToasttyLog.debug(
                "Pulsing Ghostty surface refresh for selection-adjacent panel",
                category: .ghostty,
                metadata: [
                    "panel_id": panelID.uuidString,
                ]
            )
            controllerForPanelID(panelID)?.pulseVisibilityRefresh()
        }
    }

    private func resolvedVisibleWorkspaceSelection(state: AppState) -> VisibleWorkspaceSelection? {
        guard let selection = state.selectedWorkspaceSelection(),
              let tabID = selection.workspace.resolvedSelectedTabID else {
            return nil
        }
        return VisibleWorkspaceSelection(
            workspaceID: selection.workspaceID,
            tabID: tabID
        )
    }

    private func visibleTerminalPanelIDs(in workspace: WorkspaceState) -> Set<UUID> {
        guard let tab = workspace.selectedTab else {
            return []
        }
        return visibleTerminalPanelIDs(in: tab)
    }

    private func pulsedTerminalPanelIDs(
        state: AppState,
        previousSelection: VisibleWorkspaceSelection?,
        currentSelection: VisibleWorkspaceSelection?
    ) -> Set<UUID> {
        visibleTerminalPanelIDs(selection: previousSelection, state: state).union(
            visibleTerminalPanelIDs(selection: currentSelection, state: state)
        )
    }

    private func visibleTerminalPanelIDs(
        selection: VisibleWorkspaceSelection?,
        state: AppState
    ) -> Set<UUID> {
        guard let selection,
              let workspace = state.workspacesByID[selection.workspaceID],
              let tab = workspace.tab(id: selection.tabID) else {
            return []
        }
        return visibleTerminalPanelIDs(in: tab)
    }

    private func visibleTerminalPanelIDs(in tab: WorkspaceTabState) -> Set<UUID> {
        var panelIDs: Set<UUID> = []
        for leaf in tab.layoutTree.allSlotInfos {
            let panelID = leaf.panelID
            guard let panelState = tab.panels[panelID],
                  case .terminal = panelState else {
                continue
            }
            panelIDs.insert(panelID)
        }
        return panelIDs
    }
}
#endif
