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
        updateWorkspaceActivitySubtext: @escaping ([UUID: String]) -> Void
    ) {
        self.store = store
        self.metadataService = metadataService
        self.activityInferenceService = activityInferenceService
        self.containsController = containsController
        self.controllerForPanelID = controllerForPanelID
        self.updateWorkspaceActivitySubtext = updateWorkspaceActivitySubtext
    }

    deinit {
        visibilityPulseTask?.cancel()
        processWorkingDirectoryRefreshTask?.cancel()
    }

    func publishWorkspaceActivitySubtext() {
        updateWorkspaceActivitySubtext(activityInferenceService.workspaceActivitySubtextByID)
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
        publishWorkspaceActivitySubtext()
    }

    private func refreshSelectedWorkspaceTerminalMetadataFromProcess(state: AppState) {
        guard let selectedWorkspaceID = selectedWorkspaceID(state: state),
              let workspace = state.workspacesByID[selectedWorkspaceID] else {
            return
        }

        let panelIDs = visibleTerminalPanelIDs(in: workspace)
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
        guard let selectedWorkspaceID = selectedWorkspaceID(state: state),
              let workspace = state.workspacesByID[selectedWorkspaceID] else {
            return [:]
        }

        var workspaceByPanelID: [UUID: UUID] = [:]
        for panelID in visibleTerminalPanelIDs(in: workspace) {
            guard containsController(panelID) else { continue }
            workspaceByPanelID[panelID] = selectedWorkspaceID
        }
        return workspaceByPanelID
    }

    private func trackedBackgroundTerminalPanelIDs(state: AppState) -> [UUID: UUID] {
        let selectedWorkspaceID = selectedWorkspaceID(state: state)
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
        let currentSelectedWorkspaceID = selectedWorkspaceID(state: state)
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
        guard selectedWorkspaceID(state: currentState) == workspaceID,
              let workspace = currentState.workspacesByID[workspaceID] else {
            return
        }

        let panelIDs = visibleTerminalPanelIDs(in: workspace)
        guard panelIDs.isEmpty == false else { return }
        for panelID in panelIDs {
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

    private func selectedWorkspaceID(state: AppState) -> UUID? {
        guard let selectedWindowID = state.selectedWindowID,
              let selectedWindow = state.windows.first(where: { $0.id == selectedWindowID }) else {
            return nil
        }
        return selectedWindow.selectedWorkspaceID ?? selectedWindow.workspaceIDs.first
    }
}
#endif
