import CoreState
import Foundation
#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit
#endif

@MainActor
final class TerminalWindowRuntimeStore {
    private var windowRuntimesByID: [UUID: TerminalWindowRuntime] = [:]
    private var windowIDByWorkspaceID: [UUID: UUID] = [:]
    private var terminalWorkspaceIDByPanelID: [UUID: UUID] = [:]

    func controller(
        for panelID: UUID,
        workspaceID: UUID,
        state: AppState?,
        delegate: any TerminalSurfaceControllerDelegate
    ) -> TerminalSurfaceController {
        if let existingRuntime = existingRuntime(containing: panelID),
           let existingController = existingRuntime.existingController(for: panelID),
           existingRuntime.workspaceID == workspaceID {
            return existingController
        }

        terminalWorkspaceIDByPanelID[panelID] = workspaceID
        let workspaceRuntime = runtime(for: workspaceID, state: state)
        if let existingController = workspaceRuntime.existingController(for: panelID) {
            return existingController
        }
        if let migratedController = migrateController(for: panelID, to: workspaceRuntime) {
            return migratedController
        }
        return workspaceRuntime.controller(for: panelID, delegate: delegate)
    }

    func existingController(for panelID: UUID) -> TerminalSurfaceController? {
        existingRuntime(containing: panelID)?.existingController(for: panelID)
    }

    func containsController(for panelID: UUID) -> Bool {
        existingController(for: panelID) != nil
    }

    @discardableResult
    func synchronize(with state: AppState) -> Set<UUID> {
        let previousWindowIDByWorkspaceID = windowIDByWorkspaceID
        let previousTerminalWorkspaceIDByPanelID = terminalWorkspaceIDByPanelID
        let livePanelIDsByWorkspaceID = liveTerminalPanelIDsByWorkspaceID(in: state)
        windowIDByWorkspaceID = windowIDsByWorkspaceID(in: state)
        terminalWorkspaceIDByPanelID = livePanelIDsByWorkspaceID.reduce(into: [:]) { result, entry in
            let (workspaceID, panelIDs) = entry
            for panelID in panelIDs {
                result[panelID] = workspaceID
            }
        }
        let migratedPanelIDsBySourceWorkspaceID = migratedPanelIDsBySourceWorkspace(
            previousPanelWorkspaceIDs: previousTerminalWorkspaceIDByPanelID,
            nextPanelWorkspaceIDs: terminalWorkspaceIDByPanelID
        )
        let livePanelIDsByWindowAndWorkspaceID = panelIDsByWindowAndWorkspace(
            panelIDsByWorkspaceID: livePanelIDsByWorkspaceID,
            windowIDsByWorkspaceID: windowIDByWorkspaceID
        )
        let retainedPanelIDsByWindowAndWorkspaceID = panelIDsByWindowAndWorkspace(
            panelIDsByWorkspaceID: migratedPanelIDsBySourceWorkspaceID,
            windowIDsByWorkspaceID: previousWindowIDByWorkspaceID
        )

        var removedPanelIDs: Set<UUID> = []
        for windowID in Array(windowRuntimesByID.keys) {
            guard let runtime = windowRuntimesByID[windowID] else { continue }
            removedPanelIDs.formUnion(
                runtime.synchronize(
                    livePanelIDsByWorkspaceID: livePanelIDsByWindowAndWorkspaceID[windowID] ?? [:],
                    retainedPanelIDsByWorkspaceID: retainedPanelIDsByWindowAndWorkspaceID[windowID] ?? [:]
                )
            )
            if runtime.isEmpty {
                windowRuntimesByID.removeValue(forKey: windowID)
            }
        }

        return removedPanelIDs
    }

    func synchronizeGhosttySurfaceFocusFromApplicationState() {
        for runtime in windowRuntimesByID.values {
            runtime.synchronizeGhosttySurfaceFocusFromApplicationState()
        }
    }

    func applyGhosttyGlobalFontChange(from previousPoints: Double, to nextPoints: Double) {
        for runtime in windowRuntimesByID.values {
            runtime.applyGhosttyGlobalFontChange(from: previousPoints, to: nextPoints)
        }
    }

    #if TOASTTY_HAS_GHOSTTY_KIT
    func registerPendingSplitSourceIfNeeded(
        workspaceID: UUID,
        previousState: AppState,
        nextState: AppState
    ) {
        runtime(for: workspaceID, state: nextState).registerPendingSplitSourceIfNeeded(
            previousState: previousState,
            nextState: nextState
        )
    }

    func splitSourceSurfaceState(for newPanelID: UUID) -> TerminalSplitSourceSurfaceState {
        existingRuntime(containing: newPanelID)?.splitSourceSurfaceState(for: newPanelID) ?? .none
    }

    func consumeSplitSource(for newPanelID: UUID) {
        existingRuntime(containing: newPanelID)?.consumeSplitSource(for: newPanelID)
    }

    func panelID(forSurfaceHandle surfaceHandle: UInt) -> UUID? {
        for runtime in windowRuntimesByID.values {
            if let panelID = runtime.panelID(forSurfaceHandle: surfaceHandle) {
                return panelID
            }
        }
        return nil
    }

    func register(surface: ghostty_surface_t, for panelID: UUID) {
        existingRuntime(containing: panelID)?.register(surface: surface, for: panelID)
    }

    func unregister(surface: ghostty_surface_t, for panelID: UUID) {
        existingRuntime(containing: panelID)?.unregister(surface: surface, for: panelID)
    }
    #endif

    private func runtime(for workspaceID: UUID, state: AppState?) -> TerminalWorkspaceRuntime {
        let windowRuntime = windowRuntime(for: workspaceID, state: state)
        if let existing = windowRuntime.existingRuntime(for: workspaceID) {
            return existing
        }
        return windowRuntime.runtime(for: workspaceID)
    }

    private func existingRuntime(containing panelID: UUID) -> TerminalWorkspaceRuntime? {
        if let workspaceID = terminalWorkspaceIDByPanelID[panelID],
           let runtime = existingRuntime(for: workspaceID) {
            return runtime
        }

        for (windowID, windowRuntime) in windowRuntimesByID {
            guard let runtime = windowRuntime.existingRuntime(containing: panelID) else { continue }
            terminalWorkspaceIDByPanelID[panelID] = runtime.workspaceID
            windowIDByWorkspaceID[runtime.workspaceID] = windowID
            return runtime
        }

        return nil
    }

    private func existingRuntime(for workspaceID: UUID) -> TerminalWorkspaceRuntime? {
        if let windowID = windowIDByWorkspaceID[workspaceID],
           let windowRuntime = windowRuntimesByID[windowID] {
            return windowRuntime.existingRuntime(for: workspaceID)
        }
        return nil
    }

    private func migrateController(
        for panelID: UUID,
        to targetRuntime: TerminalWorkspaceRuntime
    ) -> TerminalSurfaceController? {
        for windowRuntime in windowRuntimesByID.values {
            guard let transferredController = windowRuntime.takeController(for: panelID) else {
                continue
            }
            return targetRuntime.adoptController(transferredController, for: panelID)
        }

        return nil
    }

    private func windowRuntime(for workspaceID: UUID, state: AppState?) -> TerminalWindowRuntime {
        let resolvedWindowID: UUID
        if let cachedWindowID = windowIDByWorkspaceID[workspaceID] {
            resolvedWindowID = cachedWindowID
        } else if let state,
                  let stateWindowID = windowID(forWorkspaceID: workspaceID, state: state) {
            resolvedWindowID = stateWindowID
        } else {
            preconditionFailure(
                "TerminalWindowRuntimeStore could not resolve a window runtime for workspace \(workspaceID)."
            )
        }

        windowIDByWorkspaceID[workspaceID] = resolvedWindowID
        if let existing = windowRuntimesByID[resolvedWindowID] {
            return existing
        }

        let created = TerminalWindowRuntime(windowID: resolvedWindowID)
        windowRuntimesByID[resolvedWindowID] = created
        return created
    }

    private func liveTerminalPanelIDsByWorkspaceID(in state: AppState) -> [UUID: Set<UUID>] {
        state.workspacesByID.reduce(into: [:]) { result, entry in
            let (workspaceID, workspace) = entry
            let panelIDs = workspace.panels.reduce(into: Set<UUID>()) { ids, panelEntry in
                let (panelID, panelState) = panelEntry
                if case .terminal = panelState {
                    ids.insert(panelID)
                }
            }
            result[workspaceID] = panelIDs
        }
    }

    private func windowIDsByWorkspaceID(in state: AppState) -> [UUID: UUID] {
        state.windows.reduce(into: [:]) { result, window in
            for workspaceID in window.workspaceIDs where state.workspacesByID[workspaceID] != nil {
                result[workspaceID] = window.id
            }
        }
    }

    private func panelIDsByWindowAndWorkspace(
        panelIDsByWorkspaceID: [UUID: Set<UUID>],
        windowIDsByWorkspaceID: [UUID: UUID]
    ) -> [UUID: [UUID: Set<UUID>]] {
        panelIDsByWorkspaceID.reduce(into: [:]) { result, entry in
            let (workspaceID, panelIDs) = entry
            guard let windowID = windowIDsByWorkspaceID[workspaceID] else { return }
            result[windowID, default: [:]][workspaceID] = panelIDs
        }
    }

    private func migratedPanelIDsBySourceWorkspace(
        previousPanelWorkspaceIDs: [UUID: UUID],
        nextPanelWorkspaceIDs: [UUID: UUID]
    ) -> [UUID: Set<UUID>] {
        nextPanelWorkspaceIDs.reduce(into: [:]) { result, entry in
            let (panelID, nextWorkspaceID) = entry
            guard let previousWorkspaceID = previousPanelWorkspaceIDs[panelID],
                  previousWorkspaceID != nextWorkspaceID else {
                return
            }
            result[previousWorkspaceID, default: []].insert(panelID)
        }
    }

    private func windowID(forWorkspaceID workspaceID: UUID, state: AppState) -> UUID? {
        state.windows.first(where: { $0.workspaceIDs.contains(workspaceID) })?.id
    }
}
