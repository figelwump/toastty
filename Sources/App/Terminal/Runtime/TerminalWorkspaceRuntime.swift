import CoreState
import Foundation
#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit
#endif

@MainActor
final class TerminalWorkspaceRuntime {
    let workspaceID: UUID
    private let controllerStore = TerminalControllerStore()

    init(workspaceID: UUID) {
        self.workspaceID = workspaceID
    }

    func controller(
        for panelID: UUID,
        delegate: any TerminalSurfaceControllerDelegate
    ) -> TerminalSurfaceController {
        controllerStore.controller(for: panelID, delegate: delegate)
    }

    func existingController(for panelID: UUID) -> TerminalSurfaceController? {
        controllerStore.existingController(for: panelID)
    }

    func containsController(for panelID: UUID) -> Bool {
        controllerStore.containsController(for: panelID)
    }

    func takeController(for panelID: UUID) -> TerminalControllerStore.TransferredController? {
        controllerStore.takeController(for: panelID)
    }

    func adoptController(
        _ transferredController: TerminalControllerStore.TransferredController,
        for panelID: UUID
    ) -> TerminalSurfaceController {
        controllerStore.adoptController(transferredController, for: panelID)
        return transferredController.controller
    }

    @discardableResult
    func synchronizeLivePanels(_ livePanelIDs: Set<UUID>) -> Set<UUID> {
        #if TOASTTY_HAS_GHOSTTY_KIT
        controllerStore.synchronizeLivePanels(livePanelIDs)
        #else
        controllerStore.invalidateControllers(excluding: livePanelIDs)
        #endif
    }

    func synchronizeGhosttySurfaceFocusFromApplicationState() {
        #if TOASTTY_HAS_GHOSTTY_KIT
        controllerStore.synchronizeGhosttySurfaceFocusFromApplicationState()
        #endif
    }

    func applyGhosttyGlobalFontChange(from previousPoints: Double, to nextPoints: Double) {
        #if TOASTTY_HAS_GHOSTTY_KIT
        controllerStore.applyGhosttyGlobalFontChange(from: previousPoints, to: nextPoints)
        #else
        _ = previousPoints
        _ = nextPoints
        #endif
    }

    func applyGhosttyScrollbarPreferenceChange() {
        #if TOASTTY_HAS_GHOSTTY_KIT
        controllerStore.applyGhosttyScrollbarPreferenceChange()
        #endif
    }

    #if TOASTTY_HAS_GHOSTTY_KIT
    func registerPendingSplitSourceIfNeeded(previousState: AppState, nextState: AppState) {
        controllerStore.registerPendingSplitSourceIfNeeded(
            workspaceID: workspaceID,
            previousState: previousState,
            nextState: nextState
        )
    }

    func splitSourceSurfaceState(for newPanelID: UUID) -> TerminalSplitSourceSurfaceState {
        controllerStore.splitSourceSurfaceState(for: newPanelID)
    }

    func consumeSplitSource(for newPanelID: UUID) {
        controllerStore.consumeSplitSource(for: newPanelID)
    }

    func panelID(forSurfaceHandle surfaceHandle: UInt) -> UUID? {
        controllerStore.panelID(forSurfaceHandle: surfaceHandle)
    }

    func register(surface: ghostty_surface_t, for panelID: UUID) {
        controllerStore.register(surface: surface, for: panelID)
    }

    func unregister(surface: ghostty_surface_t, for panelID: UUID) {
        controllerStore.unregister(surface: surface, for: panelID)
    }

    func armCloseTransitionViewportDeferral(for panelIDs: Set<UUID>) {
        controllerStore.armCloseTransitionViewportDeferral(for: panelIDs)
    }
    #endif
}
