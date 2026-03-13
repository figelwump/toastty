import CoreState
import Foundation

@MainActor
struct TerminalWindowRuntimeContext {
    let windowID: UUID
    private let runtimeRegistry: TerminalRuntimeRegistry

    init(windowID: UUID, runtimeRegistry: TerminalRuntimeRegistry) {
        self.windowID = windowID
        self.runtimeRegistry = runtimeRegistry
    }

    @discardableResult
    func splitFocusedSlot(workspaceID: UUID, orientation: SplitOrientation) -> Bool {
        runtimeRegistry.splitFocusedSlot(workspaceID: workspaceID, orientation: orientation)
    }

    // Workspace IDs are globally unique, so controller lookup is the only path
    // that needs the hosting window identity to preserve runtime ownership.
    func controller(for panelID: UUID, workspaceID: UUID) -> TerminalSurfaceController {
        runtimeRegistry.controller(for: panelID, workspaceID: workspaceID, windowID: windowID)
    }

    func scheduleWorkspaceFocusRestore(workspaceID: UUID, avoidStealingKeyboardFocus: Bool = true) {
        runtimeRegistry.scheduleWorkspaceFocusRestore(
            workspaceID: workspaceID,
            avoidStealingKeyboardFocus: avoidStealingKeyboardFocus
        )
    }

}
