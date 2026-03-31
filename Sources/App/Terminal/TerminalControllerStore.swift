import CoreState
import Foundation
#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit
#endif

@MainActor
final class TerminalControllerStore {
    struct TransferredController {
        let controller: TerminalSurfaceController
        #if TOASTTY_HAS_GHOSTTY_KIT
        let surfaceHandle: UInt?
        #endif
    }

    private var controllers: [UUID: TerminalSurfaceController] = [:]
    #if TOASTTY_HAS_GHOSTTY_KIT
    private var panelIDBySurfaceHandle: [UInt: UUID] = [:]
    private var pendingSplitSourcePanelByNewPanelID: [UUID: UUID] = [:]
    #endif

    func controller(
        for panelID: UUID,
        delegate: any TerminalSurfaceControllerDelegate
    ) -> TerminalSurfaceController {
        if let existing = controllers[panelID] {
            return existing
        }

        let created = TerminalSurfaceController(panelID: panelID, delegate: delegate)
        controllers[panelID] = created
        return created
    }

    func existingController(for panelID: UUID) -> TerminalSurfaceController? {
        controllers[panelID]
    }

    func containsController(for panelID: UUID) -> Bool {
        controllers[panelID] != nil
    }

    func takeController(for panelID: UUID) -> TransferredController? {
        guard let controller = controllers.removeValue(forKey: panelID) else {
            return nil
        }

        #if TOASTTY_HAS_GHOSTTY_KIT
        let surfaceHandle = controller.currentGhosttySurface().map { UInt(bitPattern: $0) }
        if let surfaceHandle {
            panelIDBySurfaceHandle.removeValue(forKey: surfaceHandle)
        }
        return TransferredController(controller: controller, surfaceHandle: surfaceHandle)
        #else
        return TransferredController(controller: controller)
        #endif
    }

    func adoptController(_ transferredController: TransferredController, for panelID: UUID) {
        controllers[panelID] = transferredController.controller
        #if TOASTTY_HAS_GHOSTTY_KIT
        if let surfaceHandle = transferredController.surfaceHandle {
            panelIDBySurfaceHandle[surfaceHandle] = panelID
        }
        #endif
    }

    func forEachController(_ body: (TerminalSurfaceController) -> Void) {
        for controller in Array(controllers.values) {
            body(controller)
        }
    }

    @discardableResult
    func invalidateControllers(excluding livePanelIDs: Set<UUID>) -> Set<UUID> {
        let removedPanelIDs = Set(controllers.keys).subtracting(livePanelIDs)
        guard removedPanelIDs.isEmpty == false else {
            return []
        }

        for panelID in removedPanelIDs {
            controllers[panelID]?.invalidate()
            controllers.removeValue(forKey: panelID)
        }
        #if TOASTTY_HAS_GHOSTTY_KIT
        panelIDBySurfaceHandle = panelIDBySurfaceHandle.filter { livePanelIDs.contains($0.value) }
        #endif
        return removedPanelIDs
    }

    @discardableResult
    func cancelTrackedGhosttyMouseInteractionForLayoutTransition() -> Int {
        var releasedButtonCount = 0
        forEachController { controller in
            releasedButtonCount += controller.cancelTrackedGhosttyMouseInteractionForLayoutTransition()
        }
        return releasedButtonCount
    }

    #if TOASTTY_HAS_GHOSTTY_KIT
    @discardableResult
    func synchronizeLivePanels(_ livePanelIDs: Set<UUID>) -> Set<UUID> {
        let removedPanelIDs = invalidateControllers(excluding: livePanelIDs)
        pendingSplitSourcePanelByNewPanelID = pendingSplitSourcePanelByNewPanelID.filter {
            livePanelIDs.contains($0.key) && livePanelIDs.contains($0.value)
        }
        return removedPanelIDs
    }

    func synchronizeGhosttySurfaceFocusFromApplicationState() {
        forEachController { controller in
            controller.synchronizeGhosttySurfaceFocusFromApplicationState()
        }
    }

    @discardableResult
    func resetTrackedGhosttyModifiersForApplicationDeactivation() -> Int {
        var releasedModifierKeyCount = 0
        forEachController { controller in
            releasedModifierKeyCount += controller.resetTrackedGhosttyModifiersForApplicationDeactivation()
        }
        return releasedModifierKeyCount
    }

    func applyGhosttyGlobalFontChange(from previousPoints: Double, to nextPoints: Double) {
        guard previousPoints != nextPoints else { return }
        forEachController { controller in
            controller.applyGhosttyGlobalFontChange(from: previousPoints, to: nextPoints)
        }
    }

    func currentGhosttySurface(for panelID: UUID) -> ghostty_surface_t? {
        controllers[panelID]?.currentGhosttySurface()
    }

    func panelID(forSurfaceHandle surfaceHandle: UInt) -> UUID? {
        panelIDBySurfaceHandle[surfaceHandle]
    }

    func registerPendingSplitSourceIfNeeded(
        workspaceID: UUID,
        previousState: AppState,
        nextState: AppState
    ) {
        guard let previousWorkspace = previousState.workspacesByID[workspaceID],
              let nextWorkspace = nextState.workspacesByID[workspaceID],
              let sourcePanelID = Self.resolveSplitSourcePanelID(in: previousWorkspace) else {
            return
        }

        let createdPanelIDs = Set(nextWorkspace.panels.keys).subtracting(previousWorkspace.panels.keys)
        guard createdPanelIDs.count == 1,
              let newPanelID = createdPanelIDs.first,
              case .terminal = nextWorkspace.panels[newPanelID],
              case .terminal = nextWorkspace.panels[sourcePanelID] else {
            return
        }

        pendingSplitSourcePanelByNewPanelID[newPanelID] = sourcePanelID
        ToasttyLog.debug(
            "Registered split source panel for Ghostty surface inheritance",
            category: .terminal,
            metadata: [
                "workspace_id": workspaceID.uuidString,
                "source_panel_id": sourcePanelID.uuidString,
                "new_panel_id": newPanelID.uuidString,
            ]
        )
    }

    func splitSourceSurfaceState(for newPanelID: UUID) -> TerminalSplitSourceSurfaceState {
        guard let sourcePanelID = pendingSplitSourcePanelByNewPanelID[newPanelID] else {
            return .none
        }
        guard let sourceSurface = currentGhosttySurface(for: sourcePanelID) else {
            return .pending
        }
        return .ready(sourcePanelID: sourcePanelID, surface: sourceSurface)
    }

    func consumeSplitSource(for newPanelID: UUID) {
        pendingSplitSourcePanelByNewPanelID.removeValue(forKey: newPanelID)
    }

    func register(surface: ghostty_surface_t, for panelID: UUID) {
        panelIDBySurfaceHandle[UInt(bitPattern: surface)] = panelID
    }

    func unregister(surface: ghostty_surface_t, for panelID: UUID) {
        let key = UInt(bitPattern: surface)
        if panelIDBySurfaceHandle[key] == panelID {
            panelIDBySurfaceHandle.removeValue(forKey: key)
        }
    }

    func armCloseTransitionViewportDeferral(for panelIDs: Set<UUID>) {
        guard panelIDs.isEmpty == false else { return }
        for panelID in panelIDs {
            controllers[panelID]?.armCloseTransitionViewportDeferral()
        }
    }

    private static func resolveSplitSourcePanelID(in workspace: WorkspaceState) -> UUID? {
        if let focusedPanelID = workspace.focusedPanelID,
           workspace.layoutTree.slotContaining(panelID: focusedPanelID) != nil,
           let focusedPanelState = workspace.panels[focusedPanelID],
           focusedPanelState.kind == .terminal {
            return focusedPanelID
        }

        for leaf in workspace.layoutTree.allSlotInfos {
            let panelID = leaf.panelID
            guard workspace.layoutTree.slotContaining(panelID: panelID) != nil,
                  let panelState = workspace.panels[panelID] else {
                continue
            }
            if panelState.kind == .terminal {
                return panelID
            }
        }
        return nil
    }
    #endif
}
