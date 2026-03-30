import Foundation

@MainActor
final class TerminalWindowRuntime {
    let windowID: UUID
    private var workspaceRuntimesByID: [UUID: TerminalWorkspaceRuntime] = [:]

    init(windowID: UUID) {
        self.windowID = windowID
    }

    var isEmpty: Bool {
        workspaceRuntimesByID.isEmpty
    }

    func runtime(for workspaceID: UUID) -> TerminalWorkspaceRuntime {
        if let existing = workspaceRuntimesByID[workspaceID] {
            return existing
        }

        let created = TerminalWorkspaceRuntime(workspaceID: workspaceID)
        workspaceRuntimesByID[workspaceID] = created
        return created
    }

    func existingRuntime(for workspaceID: UUID) -> TerminalWorkspaceRuntime? {
        workspaceRuntimesByID[workspaceID]
    }

    func existingRuntime(containing panelID: UUID) -> TerminalWorkspaceRuntime? {
        for runtime in workspaceRuntimesByID.values where runtime.containsController(for: panelID) {
            return runtime
        }
        return nil
    }

    @discardableResult
    func synchronize(
        livePanelIDsByWorkspaceID: [UUID: Set<UUID>],
        retainedPanelIDsByWorkspaceID: [UUID: Set<UUID>] = [:]
    ) -> Set<UUID> {
        var removedPanelIDs: Set<UUID> = []
        let liveWorkspaceIDs = Set(livePanelIDsByWorkspaceID.keys)

        for workspaceID in Array(workspaceRuntimesByID.keys) {
            guard let runtime = workspaceRuntimesByID[workspaceID] else { continue }
            let retainedPanelIDs = retainedPanelIDsByWorkspaceID[workspaceID] ?? []
            var livePanelIDs = livePanelIDsByWorkspaceID[workspaceID] ?? []
            livePanelIDs.formUnion(retainedPanelIDs)

            removedPanelIDs.formUnion(runtime.synchronizeLivePanels(livePanelIDs))
            if liveWorkspaceIDs.contains(workspaceID) == false && retainedPanelIDs.isEmpty {
                workspaceRuntimesByID.removeValue(forKey: workspaceID)
            }
        }

        return removedPanelIDs
    }

    func synchronizeGhosttySurfaceFocusFromApplicationState() {
        for runtime in workspaceRuntimesByID.values {
            runtime.synchronizeGhosttySurfaceFocusFromApplicationState()
        }
    }

    @discardableResult
    func resetTrackedGhosttyModifiersForApplicationDeactivation() -> Int {
        workspaceRuntimesByID.values.reduce(into: 0) { result, runtime in
            result += runtime.resetTrackedGhosttyModifiersForApplicationDeactivation()
        }
    }

    func applyGhosttyGlobalFontChange(from previousPoints: Double, to nextPoints: Double) {
        for runtime in workspaceRuntimesByID.values {
            runtime.applyGhosttyGlobalFontChange(from: previousPoints, to: nextPoints)
        }
    }

    #if TOASTTY_HAS_GHOSTTY_KIT
    func panelID(forSurfaceHandle surfaceHandle: UInt) -> UUID? {
        for runtime in workspaceRuntimesByID.values {
            if let panelID = runtime.panelID(forSurfaceHandle: surfaceHandle) {
                return panelID
            }
        }
        return nil
    }
    #endif

    func takeController(for panelID: UUID) -> TerminalControllerStore.TransferredController? {
        for runtime in workspaceRuntimesByID.values {
            if let transferredController = runtime.takeController(for: panelID) {
                return transferredController
            }
        }
        return nil
    }
}
