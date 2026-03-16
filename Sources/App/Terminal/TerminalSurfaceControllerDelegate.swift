import Foundation
#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit
#endif

@MainActor
protocol TerminalSurfaceControllerDelegate: AnyObject {
    func prepareImageFileDrop(from urls: [URL], targetPanelID: UUID) -> PreparedImageFileDrop?

    @discardableResult
    func handlePreparedImageFileDrop(_ drop: PreparedImageFileDrop) -> Bool

    #if TOASTTY_HAS_GHOSTTY_KIT
    func splitSourceSurfaceState(forNewPanelID panelID: UUID) -> TerminalSplitSourceSurfaceState
    func consumeSplitSource(forNewPanelID panelID: UUID)
    func surfaceLaunchConfiguration(for panelID: UUID) -> TerminalSurfaceLaunchConfiguration
    func markInitialSurfaceLaunchCompleted(for panelID: UUID)
    func registerSurfaceHandle(_ surface: ghostty_surface_t, for panelID: UUID)
    func unregisterSurfaceHandle(_ surface: ghostty_surface_t, for panelID: UUID)
    func surfaceCreationChildPIDSnapshot() -> Set<pid_t>
    func registerSurfaceChildPIDAfterCreation(
        panelID: UUID,
        previousChildren: Set<pid_t>,
        expectedWorkingDirectory: String?
    )
    func requestImmediateProcessWorkingDirectoryRefresh(
        panelID: UUID,
        source: String
    )
    #endif
}

#if TOASTTY_HAS_GHOSTTY_KIT
enum TerminalSplitSourceSurfaceState {
    case none
    case pending
    case ready(sourcePanelID: UUID, surface: ghostty_surface_t)
}
#endif
