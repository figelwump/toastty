#if TOASTTY_HAS_GHOSTTY_KIT
@testable import ToasttyApp
import Foundation
import GhosttyKit
import XCTest

@MainActor
final class TerminalControllerStoreTests: XCTestCase {
    func testInvalidateControllersRemovesMissingPanelsAndPrunesSurfaceMappings() {
        let store = TerminalControllerStore()
        let livePanelID = UUID()
        let removedPanelID = UUID()
        let delegate = TestTerminalSurfaceControllerDelegate()

        _ = store.controller(for: livePanelID, delegate: delegate)
        _ = store.controller(for: removedPanelID, delegate: delegate)

        let liveSurface = fakeSurfaceHandle(0x101)
        let removedSurface = fakeSurfaceHandle(0x202)
        store.register(surface: liveSurface, for: livePanelID)
        store.register(surface: removedSurface, for: removedPanelID)

        let removedPanelIDs = store.invalidateControllers(excluding: [livePanelID])

        XCTAssertEqual(removedPanelIDs, [removedPanelID])
        XCTAssertNotNil(store.existingController(for: livePanelID))
        XCTAssertNil(store.existingController(for: removedPanelID))
        XCTAssertEqual(store.panelID(forSurfaceHandle: UInt(bitPattern: liveSurface)), livePanelID)
        XCTAssertNil(store.panelID(forSurfaceHandle: UInt(bitPattern: removedSurface)))
    }

    func testUnregisterIgnoresStalePanelWhenSurfaceHandleIsReused() {
        let store = TerminalControllerStore()
        let firstPanelID = UUID()
        let secondPanelID = UUID()
        let sharedSurface = fakeSurfaceHandle(0x303)

        store.register(surface: sharedSurface, for: firstPanelID)
        store.register(surface: sharedSurface, for: secondPanelID)

        store.unregister(surface: sharedSurface, for: firstPanelID)

        XCTAssertEqual(store.panelID(forSurfaceHandle: UInt(bitPattern: sharedSurface)), secondPanelID)

        store.unregister(surface: sharedSurface, for: secondPanelID)

        XCTAssertNil(store.panelID(forSurfaceHandle: UInt(bitPattern: sharedSurface)))
    }
}

@MainActor
private final class TestTerminalSurfaceControllerDelegate: TerminalSurfaceControllerDelegate {
    func prepareImageFileDrop(from urls: [URL], targetPanelID: UUID) -> PreparedImageFileDrop? {
        _ = urls
        _ = targetPanelID
        return nil
    }

    func handlePreparedImageFileDrop(_ drop: PreparedImageFileDrop) -> Bool {
        _ = drop
        return false
    }

    func splitSourceSurfaceState(forNewPanelID panelID: UUID) -> TerminalSplitSourceSurfaceState {
        _ = panelID
        return .none
    }

    func consumeSplitSource(forNewPanelID panelID: UUID) {
        _ = panelID
    }

    func registerSurfaceHandle(_ surface: ghostty_surface_t, for panelID: UUID) {
        _ = surface
        _ = panelID
    }

    func unregisterSurfaceHandle(_ surface: ghostty_surface_t, for panelID: UUID) {
        _ = surface
        _ = panelID
    }

    func surfaceCreationChildPIDSnapshot() -> Set<pid_t> {
        []
    }

    func registerSurfaceChildPIDAfterCreation(
        panelID: UUID,
        previousChildren: Set<pid_t>,
        expectedWorkingDirectory: String
    ) {
        _ = panelID
        _ = previousChildren
        _ = expectedWorkingDirectory
    }

    func reconcileSurfaceWorkingDirectoryFromSurface(
        panelID: UUID,
        workingDirectory: String?,
        source: String
    ) {
        _ = panelID
        _ = workingDirectory
        _ = source
    }
}

private func fakeSurfaceHandle(_ rawValue: UInt) -> ghostty_surface_t {
    guard let surface = ghostty_surface_t(bitPattern: rawValue) else {
        fatalError("expected fake Ghostty surface handle")
    }
    return surface
}
#endif
