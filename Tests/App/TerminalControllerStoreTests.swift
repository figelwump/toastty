#if TOASTTY_HAS_GHOSTTY_KIT
@testable import ToasttyApp
import AppKit
import CoreState
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

    func testRegisterPendingSplitSourceTracksNewSplitPanelUntilConsumed() throws {
        let store = TerminalControllerStore()
        let (workspaceID, previousState, nextState, newPanelID, sourcePanelID) = try makeSplitTransition()

        store.registerPendingSplitSourceIfNeeded(
            workspaceID: workspaceID,
            previousState: previousState,
            nextState: nextState
        )

        switch store.splitSourceSurfaceState(for: newPanelID) {
        case .pending:
            break
        case .ready, .none:
            XCTFail("expected pending split source surface state before source surface is attached")
        }

        store.consumeSplitSource(for: newPanelID)

        switch store.splitSourceSurfaceState(for: newPanelID) {
        case .none:
            break
        case .pending, .ready:
            XCTFail("expected split source mapping to be cleared after consume")
        }

        XCTAssertNotEqual(newPanelID, sourcePanelID)
    }

    func testSynchronizeLivePanelsPrunesPendingSplitSourceMappingsForRemovedPanels() throws {
        let store = TerminalControllerStore()
        let (workspaceID, previousState, nextState, newPanelID, sourcePanelID) = try makeSplitTransition()

        store.registerPendingSplitSourceIfNeeded(
            workspaceID: workspaceID,
            previousState: previousState,
            nextState: nextState
        )
        _ = store.synchronizeLivePanels([sourcePanelID])

        switch store.splitSourceSurfaceState(for: newPanelID) {
        case .none:
            break
        case .pending, .ready:
            XCTFail("expected split source mapping to be pruned when new panel is no longer live")
        }
    }

    func testSynchronizeLivePanelsKeepsPendingSplitSourceMappingsWhilePanelsRemainLive() throws {
        let store = TerminalControllerStore()
        let (workspaceID, previousState, nextState, newPanelID, _) = try makeSplitTransition()

        store.registerPendingSplitSourceIfNeeded(
            workspaceID: workspaceID,
            previousState: previousState,
            nextState: nextState
        )
        let livePanelIDs = Set(try XCTUnwrap(nextState.workspacesByID[workspaceID]?.panels.keys))
        _ = store.synchronizeLivePanels(livePanelIDs)

        switch store.splitSourceSurfaceState(for: newPanelID) {
        case .pending:
            break
        case .none, .ready:
            XCTFail("expected split source mapping to remain pending while both panels are live")
        }
    }

    func testArmCloseTransitionViewportDeferralMarksLiveControllers() {
        let store = TerminalControllerStore()
        let livePanelID = UUID()
        let delegate = TestTerminalSurfaceControllerDelegate()
        let controller = store.controller(for: livePanelID, delegate: delegate)

        XCTAssertFalse(controller.isCloseTransitionViewportDeferralArmed)

        store.armCloseTransitionViewportDeferral(for: [livePanelID])

        XCTAssertTrue(controller.isCloseTransitionViewportDeferralArmed)
    }

    func testBackgroundTerminalAcceptsInputAfterViewportReturnsToItsLastSize() async throws {
        let store = TerminalControllerStore()
        let delegate = TestTerminalSurfaceControllerDelegate()
        let controller = store.controller(for: UUID(), delegate: delegate)
        defer { controller.invalidate() }

        let frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let container = NSView(frame: frame)
        window.contentView = container
        let attachment = PanelHostAttachmentToken.next()
        controller.attachHost(to: container, attachment: attachment)
        container.layoutSubtreeIfNeeded()

        let state = TerminalPanelHostState(cwd: NSTemporaryDirectory(), launchWorkingDirectory: nil)
        func updateViewport(_ size: CGSize) {
            controller.update(
                hostState: state,
                focused: false,
                fontPoints: 12,
                viewportSize: size,
                backingScaleFactor: 1,
                sourceContainer: container,
                attachment: attachment
            )
        }

        updateViewport(frame.size)
        updateViewport(frame.size)
        let surface = try XCTUnwrap(controller.currentGhosttySurface())
        let afterAttachmentSettles = Date(timeIntervalSinceNow: 1)
        XCTAssertTrue(controller.isReadyForAutomationInput(now: afterAttachmentSettles))

        updateViewport(CGSize(width: 1, height: 1))
        XCTAssertFalse(controller.isReadyForAutomationInput(now: afterAttachmentSettles))
        updateViewport(frame.size)
        XCTAssertFalse(controller.isReadyForAutomationInput(now: afterAttachmentSettles))

        // Background hosts may not get another layout callback at this size.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while !controller.isReadyForAutomationInput(now: afterAttachmentSettles), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(controller.isReadyForAutomationInput(now: afterAttachmentSettles))
        XCTAssertEqual(controller.currentGhosttySurface(), surface)
        XCTAssertFalse(window.isVisible)
    }
}

@MainActor
private final class TestTerminalSurfaceControllerDelegate: TerminalSurfaceControllerDelegate {
    func prepareFileDrop(from urls: [URL], targetPanelID: UUID) -> PreparedFileDrop? {
        _ = urls
        _ = targetPanelID
        return nil
    }

    func handlePreparedFileDrop(_ drop: PreparedFileDrop) -> Bool {
        _ = drop
        return false
    }

    func handleLocalInterruptKey(for panelID: UUID, kind: TerminalLocalInterruptKind) {
        _ = panelID
        _ = kind
    }

    func handleLocalInput(for panelID: UUID, kind: TerminalLocalInputKind) {}

    func splitSourceSurfaceState(forNewPanelID panelID: UUID) -> TerminalSplitSourceSurfaceState {
        _ = panelID
        return .none
    }

    func consumeSplitSource(forNewPanelID panelID: UUID) {
        _ = panelID
    }

    func surfaceLaunchConfiguration(for panelID: UUID) -> TerminalSurfaceLaunchConfiguration {
        _ = panelID
        return .empty
    }

    func markInitialSurfaceLaunchCompleted(for panelID: UUID) {
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
        expectedWorkingDirectory: String?,
        isRestoredLaunch: Bool
    ) {
        _ = panelID
        _ = previousChildren
        _ = expectedWorkingDirectory
        _ = isRestoredLaunch
    }

    func requestImmediateProcessWorkingDirectoryRefresh(
        panelID: UUID,
        source: String
    ) {
        _ = panelID
        _ = source
    }
}

private func fakeSurfaceHandle(_ rawValue: UInt) -> ghostty_surface_t {
    guard let surface = ghostty_surface_t(bitPattern: rawValue) else {
        fatalError("expected fake Ghostty surface handle")
    }
    return surface
}

@MainActor
private func makeSplitTransition() throws -> (
    workspaceID: UUID,
    previousState: AppState,
    nextState: AppState,
    newPanelID: UUID,
    sourcePanelID: UUID
) {
    let previousState = AppState.bootstrap()
    let reducer = AppReducer()
    let workspaceID = try XCTUnwrap(previousState.windows.first?.selectedWorkspaceID)
    let sourcePanelID = try XCTUnwrap(previousState.workspacesByID[workspaceID]?.focusedPanelID)
    var nextState = previousState

    XCTAssertTrue(
        reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal), state: &nextState),
        "expected split fixture creation to succeed"
    )

    let previousPanelIDs = Set(try XCTUnwrap(previousState.workspacesByID[workspaceID]?.panels.keys))
    let nextPanelIDs = Set(try XCTUnwrap(nextState.workspacesByID[workspaceID]?.panels.keys))
    let newPanelID = try XCTUnwrap(nextPanelIDs.subtracting(previousPanelIDs).first)
    return (workspaceID, previousState, nextState, newPanelID, sourcePanelID)
}
#endif
