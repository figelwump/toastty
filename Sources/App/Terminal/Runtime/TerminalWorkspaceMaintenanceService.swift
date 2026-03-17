#if TOASTTY_HAS_GHOSTTY_KIT
import CoreState
import Foundation

@MainActor
final class TerminalWorkspaceMaintenanceService {
    private weak var store: AppStore?
    private let metadataService: TerminalMetadataService
    private let activityInferenceService: TerminalActivityInferenceService
    private let containsController: (UUID) -> Bool
    private let controllerForPanelID: (UUID) -> TerminalSurfaceController?
    private let updatePanelDisplayTitleOverrides: ([UUID: String]) -> Void
    private let updateWorkspaceActivitySubtext: ([UUID: String]) -> Void
    private var previousSelectedWorkspaceID: UUID?
    private var visibilityPulseTask: Task<Void, Never>?
    private var processWorkingDirectoryRefreshTask: Task<Void, Never>?

    init(
        store: AppStore,
        metadataService: TerminalMetadataService,
        activityInferenceService: TerminalActivityInferenceService,
        containsController: @escaping (UUID) -> Bool,
        controllerForPanelID: @escaping (UUID) -> TerminalSurfaceController?,
        updatePanelDisplayTitleOverrides: @escaping ([UUID: String]) -> Void,
        updateWorkspaceActivitySubtext: @escaping ([UUID: String]) -> Void
    ) {
        self.store = store
        self.metadataService = metadataService
        self.activityInferenceService = activityInferenceService
        self.containsController = containsController
        self.controllerForPanelID = controllerForPanelID
        self.updatePanelDisplayTitleOverrides = updatePanelDisplayTitleOverrides
        self.updateWorkspaceActivitySubtext = updateWorkspaceActivitySubtext
    }

    deinit {
        visibilityPulseTask?.cancel()
        processWorkingDirectoryRefreshTask?.cancel()
    }

    func publishWorkspaceActivitySubtext() {
        updateWorkspaceActivitySubtext(activityInferenceService.workspaceActivitySubtextByID)
    }

    func publishPanelDisplayTitleOverrides() {
        updatePanelDisplayTitleOverrides(activityInferenceService.panelDisplayTitleOverrideByID)
    }

    func synchronize(
        state: AppState,
        livePanelIDs: Set<UUID>,
        removedPanelIDs: Set<UUID>
    ) {
        for panelID in removedPanelIDs {
            metadataService.invalidate(panelID: panelID)
            activityInferenceService.invalidate(panelID: panelID)
        }

        synchronizeLivePanels(
            livePanelIDs,
            liveWorkspaceIDs: Set(state.workspacesByID.keys)
        )
        pulseVisibleSurfacesIfWorkspaceSwitched(state: state)
    }

    func handleSurfaceUnregister(panelID: UUID) {
        metadataService.invalidate(panelID: panelID)
        activityInferenceService.invalidate(panelID: panelID)
        if let store = self.store {
            activityInferenceService.refreshWorkspaceActivitySubtext(
                liveWorkspaceIDs: Set(store.state.workspacesByID.keys)
            )
        }
        publishPanelDisplayTitleOverrides()
        publishWorkspaceActivitySubtext()
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

                self.refreshVisibleTerminalWorkingDirectoriesFromProcess(state: store.state)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func synchronizeLivePanels(_ livePanelIDs: Set<UUID>, liveWorkspaceIDs: Set<UUID>) {
        metadataService.synchronizeLivePanels(livePanelIDs)
        activityInferenceService.synchronizeLivePanels(
            livePanelIDs,
            liveWorkspaceIDs: liveWorkspaceIDs
        )
        publishPanelDisplayTitleOverrides()
        publishWorkspaceActivitySubtext()
    }

    private func refreshVisibleTerminalWorkingDirectoriesFromProcess(state: AppState) {
        refreshSelectedWorkspaceTerminalMetadataFromProcess(state: state)

        let selectedPanelWorkspaceIDs = trackedSelectedWorkspaceVisibleTerminalPanelIDs(state: state)
        let backgroundPanelWorkspaceIDs = trackedBackgroundTerminalPanelIDs(state: state)
        activityInferenceService.refreshVisibleTextInference(
            state: state,
            selectedPanelWorkspaceIDs: selectedPanelWorkspaceIDs,
            backgroundPanelWorkspaceIDs: backgroundPanelWorkspaceIDs
        )
        publishPanelDisplayTitleOverrides()
        publishWorkspaceActivitySubtext()
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

    private func trackedSelectedWorkspaceVisibleTerminalPanelIDs(state: AppState) -> [UUID: UUID] {
        guard let selection = state.selectedWorkspaceSelection() else {
            return [:]
        }

        var workspaceByPanelID: [UUID: UUID] = [:]
        for panelID in visibleTerminalPanelIDs(in: selection.workspace) {
            guard containsController(panelID) else { continue }
            workspaceByPanelID[panelID] = selection.workspaceID
        }
        return workspaceByPanelID
    }

    private func trackedBackgroundTerminalPanelIDs(state: AppState) -> [UUID: UUID] {
        let selectedWorkspaceID = state.selectedWorkspaceSelection()?.workspaceID
        var workspaceByPanelID: [UUID: UUID] = [:]
        for workspace in state.workspacesByID.values where workspace.id != selectedWorkspaceID {
            for (panelID, panelState) in workspace.panels {
                guard case .terminal = panelState else { continue }
                guard containsController(panelID) else { continue }
                workspaceByPanelID[panelID] = workspace.id
            }
        }
        return workspaceByPanelID
    }

    private func pulseVisibleSurfacesIfWorkspaceSwitched(state: AppState) {
        let currentSelectedWorkspaceID = state.selectedWorkspaceSelection()?.workspaceID
        guard currentSelectedWorkspaceID != previousSelectedWorkspaceID else { return }

        visibilityPulseTask?.cancel()
        visibilityPulseTask = nil

        guard let currentSelectedWorkspaceID else {
            previousSelectedWorkspaceID = nil
            return
        }

        guard state.workspacesByID[currentSelectedWorkspaceID] != nil else {
            // Do not consume the transition until workspace data is available.
            return
        }

        previousSelectedWorkspaceID = currentSelectedWorkspaceID
        scheduleVisibilityPulse(for: currentSelectedWorkspaceID)
    }

    private func scheduleVisibilityPulse(for workspaceID: UUID) {
        ToasttyLog.debug(
            "Scheduling Ghostty visibility refresh pulse after workspace switch",
            category: .ghostty,
            metadata: ["workspace_id": workspaceID.uuidString]
        )

        visibilityPulseTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Defer pulses so SwiftUI/NSViewRepresentable attachment and layout can settle.
            await Task.yield()
            guard Task.isCancelled == false else { return }
            self.pulseVisibleSurfaces(in: workspaceID)

            await Task.yield()
            guard Task.isCancelled == false else { return }
            self.pulseVisibleSurfaces(in: workspaceID)
        }
    }

    private func pulseVisibleSurfaces(in workspaceID: UUID) {
        guard let store else { return }
        let currentState = store.state
        guard currentState.selectedWorkspaceSelection()?.workspaceID == workspaceID,
              let workspace = currentState.workspacesByID[workspaceID] else {
            return
        }

        let panelIDs = visibleTerminalPanelIDs(in: workspace)
        guard panelIDs.isEmpty == false else { return }
        ToasttyLog.debug(
            "Pulsing visible Ghostty surfaces after workspace switch",
            category: .ghostty,
            metadata: [
                "workspace_id": workspaceID.uuidString,
                "panel_count": String(panelIDs.count),
            ]
        )
        for panelID in panelIDs {
            ToasttyLog.debug(
                "Pulsing Ghostty surface refresh for workspace-selected panel",
                category: .ghostty,
                metadata: [
                    "workspace_id": workspaceID.uuidString,
                    "panel_id": panelID.uuidString,
                ]
            )
            controllerForPanelID(panelID)?.pulseVisibilityRefresh()
        }
    }

    private func visibleTerminalPanelIDs(in workspace: WorkspaceState) -> Set<UUID> {
        var panelIDs: Set<UUID> = []
        for leaf in workspace.layoutTree.allSlotInfos {
            let panelID = leaf.panelID
            guard let panelState = workspace.panels[panelID],
                  case .terminal = panelState else {
                continue
            }
            panelIDs.insert(panelID)
        }
        return panelIDs
    }
}
#endif
