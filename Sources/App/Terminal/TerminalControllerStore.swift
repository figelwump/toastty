import Foundation
#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit
#endif

@MainActor
final class TerminalControllerStore {
    private var controllers: [UUID: TerminalSurfaceController] = [:]
    #if TOASTTY_HAS_GHOSTTY_KIT
    private var panelIDBySurfaceHandle: [UInt: UUID] = [:]
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

    #if TOASTTY_HAS_GHOSTTY_KIT
    func currentGhosttySurface(for panelID: UUID) -> ghostty_surface_t? {
        controllers[panelID]?.currentGhosttySurface()
    }

    func panelID(forSurfaceHandle surfaceHandle: UInt) -> UUID? {
        panelIDBySurfaceHandle[surfaceHandle]
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
    #endif
}
