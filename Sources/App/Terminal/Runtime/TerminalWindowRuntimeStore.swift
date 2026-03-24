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
        windowID: UUID,
        state: AppState?,
        delegate: any TerminalSurfaceControllerDelegate
    ) -> TerminalSurfaceController {
        if let existingControllerLocation = existingControllerLocation(for: panelID),
           let existingController = existingControllerLocation.runtime.existingController(for: panelID) {
            if existingControllerLocation.windowID == windowID,
               existingControllerLocation.runtime.workspaceID == workspaceID {
                return existingController
            }

            if workspaceOwnsPanel(
                workspaceID: workspaceID,
                panelID: panelID,
                state: state
            ) == false {
                return existingController
            }
        }

        terminalWorkspaceIDByPanelID[panelID] = workspaceID
        windowIDByWorkspaceID[workspaceID] = windowID
        let workspaceRuntime = runtime(for: workspaceID, windowID: windowID, state: state)
        if let existingController = workspaceRuntime.existingController(for: panelID) {
            return existingController
        }
        if let migratedController = migrateController(for: panelID, to: workspaceRuntime) {
            return migratedController
        }
        return workspaceRuntime.controller(for: panelID, delegate: delegate)
    }

    func existingController(for panelID: UUID) -> TerminalSurfaceController? {
        existingControllerLocation(for: panelID)?.runtime.existingController(for: panelID)
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

    func applyGhosttyScrollbarPreferenceChange() {
        for runtime in windowRuntimesByID.values {
            runtime.applyGhosttyScrollbarPreferenceChange()
        }
    }

    #if TOASTTY_HAS_GHOSTTY_KIT
    func registerPendingSplitSourceIfNeeded(
        workspaceID: UUID,
        previousState: AppState,
        nextState: AppState
    ) {
        guard let windowID = windowID(forWorkspaceID: workspaceID, state: nextState) else {
            preconditionFailure(
                "TerminalWindowRuntimeStore could not resolve a window runtime for split registration in workspace \(workspaceID)."
            )
        }
        runtime(for: workspaceID, windowID: windowID, state: nextState).registerPendingSplitSourceIfNeeded(
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

    func armCloseTransitionViewportDeferral(workspaceID: UUID, panelIDs: Set<UUID>) {
        existingRuntime(for: workspaceID)?.armCloseTransitionViewportDeferral(for: panelIDs)
    }

    #if DEBUG
    func registerSurfaceHandleForTesting(
        _ surface: ghostty_surface_t,
        for panelID: UUID,
        workspaceID: UUID,
        windowID: UUID,
        state: AppState
    ) {
        terminalWorkspaceIDByPanelID[panelID] = workspaceID
        windowIDByWorkspaceID[workspaceID] = windowID
        runtime(for: workspaceID, windowID: windowID, state: state).register(surface: surface, for: panelID)
    }
    #endif
    #endif

    private func runtime(for workspaceID: UUID, windowID: UUID, state: AppState?) -> TerminalWorkspaceRuntime {
        let windowRuntime = windowRuntime(for: workspaceID, requestedWindowID: windowID, state: state)
        if let existing = windowRuntime.existingRuntime(for: workspaceID) {
            return existing
        }
        return windowRuntime.runtime(for: workspaceID)
    }

    private func existingControllerLocation(
        for panelID: UUID
    ) -> (windowID: UUID, runtime: TerminalWorkspaceRuntime)? {
        if let workspaceID = terminalWorkspaceIDByPanelID[panelID],
           let windowID = windowIDByWorkspaceID[workspaceID],
           let runtime = existingRuntime(for: workspaceID) {
            return (windowID, runtime)
        }

        for (windowID, windowRuntime) in windowRuntimesByID {
            guard let runtime = windowRuntime.existingRuntime(containing: panelID) else { continue }
            terminalWorkspaceIDByPanelID[panelID] = runtime.workspaceID
            windowIDByWorkspaceID[runtime.workspaceID] = windowID
            return (windowID, runtime)
        }

        return nil
    }

    private func existingRuntime(containing panelID: UUID) -> TerminalWorkspaceRuntime? {
        existingControllerLocation(for: panelID)?.runtime
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

    private func windowRuntime(
        for workspaceID: UUID,
        requestedWindowID: UUID,
        state: AppState?
    ) -> TerminalWindowRuntime {
        let resolvedWindowID: UUID
        if workspaceOwnsWindowRuntime(workspaceID: workspaceID, windowID: requestedWindowID, state: state) {
            resolvedWindowID = requestedWindowID
        } else if let cachedWindowID = windowIDByWorkspaceID[workspaceID] {
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

    private func workspaceOwnsPanel(workspaceID: UUID, panelID: UUID, state: AppState?) -> Bool {
        guard let state,
              let workspace = state.workspacesByID[workspaceID],
              workspace.panels[panelID] != nil,
              workspace.layoutTree.slotContaining(panelID: panelID) != nil else {
            return false
        }
        return true
    }

    private func workspaceOwnsWindowRuntime(workspaceID: UUID, windowID: UUID, state: AppState?) -> Bool {
        guard let state else { return false }
        return state.windows.contains { window in
            window.id == windowID && window.workspaceIDs.contains(workspaceID)
        }
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
