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

    private weak var store: AppStore?
    private let metadataService: TerminalMetadataService
    private let activityInferenceService: TerminalActivityInferenceService
    private let containsController: (UUID) -> Bool
    private let controllerForPanelID: (UUID) -> TerminalSurfaceController?
    private let updatePanelDisplayTitleOverrides: ([UUID: String]) -> Void
    private let updateWorkspaceActivitySubtext: ([UUID: String]) -> Void
    private let visibilityPulseScheduler: VisibilityPulseScheduler
    private var previousVisibleWorkspaceSelection: VisibleWorkspaceSelection?
    private var visibilityPulseTask: Task<Void, Never>?
    private var processWorkingDirectoryRefreshTask: Task<Void, Never>?

    init(
        store: AppStore,
        metadataService: TerminalMetadataService,
        activityInferenceService: TerminalActivityInferenceService,
        containsController: @escaping (UUID) -> Bool,
        controllerForPanelID: @escaping (UUID) -> TerminalSurfaceController?,
        updatePanelDisplayTitleOverrides: @escaping ([UUID: String]) -> Void,
        updateWorkspaceActivitySubtext: @escaping ([UUID: String]) -> Void,
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
        self.activityInferenceService = activityInferenceService
        self.containsController = containsController
        self.controllerForPanelID = controllerForPanelID
        self.updatePanelDisplayTitleOverrides = updatePanelDisplayTitleOverrides
        self.updateWorkspaceActivitySubtext = updateWorkspaceActivitySubtext
        self.visibilityPulseScheduler = visibilityPulseScheduler
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
        pulseVisibleSurfacesIfSelectionChanged(state: state)
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
                guard containsController(panelID) else { continue }
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

        guard let currentVisibleSelection else {
            previousVisibleWorkspaceSelection = nil
            return
        }

        previousVisibleWorkspaceSelection = currentVisibleSelection
        scheduleVisibilityPulse(for: currentVisibleSelection.workspaceID)
    }

    private func scheduleVisibilityPulse(for workspaceID: UUID) {
        ToasttyLog.debug(
            "Scheduling Ghostty visibility refresh pulse after workspace/tab selection change",
            category: .ghostty,
            metadata: ["workspace_id": workspaceID.uuidString]
        )

        visibilityPulseTask = visibilityPulseScheduler { [weak self] in
            self?.pulseVisibleSurfaces(in: workspaceID)
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
            "Pulsing visible Ghostty surfaces after workspace/tab selection change",
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
