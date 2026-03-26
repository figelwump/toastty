#if TOASTTY_HAS_GHOSTTY_KIT
@testable import ToasttyApp
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

    func testCloseTransitionViewportDeferralKeepsPendingReplayArmedUntilTimeout() {
        let store = TerminalControllerStore()
        let panelID = UUID()
        let delegate = TestTerminalSurfaceControllerDelegate()
        let controller = store.controller(for: panelID, delegate: delegate)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let attachment = PanelHostAttachmentToken.next()
        let terminalState = TerminalPanelState(title: "Terminal", shell: "zsh", cwd: "/tmp")
        var observedViewportSize: CGSize?

        controller.setSkipCloseTransitionViewportReplayUpdateForTesting(true)
        controller.installCloseTransitionViewportReplayObserverForTesting { viewportSize, _ in
            observedViewportSize = viewportSize
        }
        controller.seedCloseTransitionViewportReplayStateForTesting(
            terminalState: terminalState,
            focused: true,
            fontPoints: AppState.defaultTerminalFontPoints,
            viewportSize: container.bounds.size,
            backingScaleFactor: 1,
            sourceContainer: container,
            attachment: attachment,
            lastPresentationViewportSize: container.bounds.size,
            lastPresentationBackingScaleFactor: 1
        )

        container.setFrameSize(CGSize(width: 320, height: 260))
        controller.armCloseTransitionViewportDeferral()
        controller.markCloseTransitionViewportUpdatePendingForTesting()
        controller.runCloseTransitionViewportReplayForTesting(forceTimeout: false)

        XCTAssertNil(observedViewportSize)
        XCTAssertTrue(controller.isCloseTransitionViewportDeferralArmed)
        XCTAssertTrue(controller.isCloseTransitionViewportUpdatePendingForTesting)
    }

    func testCloseTransitionViewportDeferralReplaysLatestViewportAtTimeoutAfterPendingUpdate() {
        let store = TerminalControllerStore()
        let panelID = UUID()
        let delegate = TestTerminalSurfaceControllerDelegate()
        let controller = store.controller(for: panelID, delegate: delegate)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let attachment = PanelHostAttachmentToken.next()
        let terminalState = TerminalPanelState(title: "Terminal", shell: "zsh", cwd: "/tmp")
        let finalViewportSize = CGSize(width: 320, height: 360)
        var observedViewportSize: CGSize?

        controller.setSkipCloseTransitionViewportReplayUpdateForTesting(true)
        controller.installCloseTransitionViewportReplayObserverForTesting { viewportSize, _ in
            observedViewportSize = viewportSize
        }
        controller.seedCloseTransitionViewportReplayStateForTesting(
            terminalState: terminalState,
            focused: true,
            fontPoints: AppState.defaultTerminalFontPoints,
            viewportSize: container.bounds.size,
            backingScaleFactor: 1,
            sourceContainer: container,
            attachment: attachment,
            lastPresentationViewportSize: container.bounds.size,
            lastPresentationBackingScaleFactor: 1
        )

        container.setFrameSize(CGSize(width: 320, height: 260))
        controller.armCloseTransitionViewportDeferral()
        controller.markCloseTransitionViewportUpdatePendingForTesting()
        container.setFrameSize(finalViewportSize)
        controller.runCloseTransitionViewportReplayForTesting(forceTimeout: true)

        XCTAssertEqual(observedViewportSize, finalViewportSize)
        XCTAssertFalse(controller.isCloseTransitionViewportDeferralArmed)
        XCTAssertFalse(controller.isCloseTransitionViewportUpdatePendingForTesting)
    }

    func testCloseTransitionViewportDeferralForcesReplayWhenContainerBoundsChangeWithoutPendingUpdate() {
        let store = TerminalControllerStore()
        let panelID = UUID()
        let delegate = TestTerminalSurfaceControllerDelegate()
        let controller = store.controller(for: panelID, delegate: delegate)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let attachment = PanelHostAttachmentToken.next()
        let terminalState = TerminalPanelState(title: "Terminal", shell: "zsh", cwd: "/tmp")
        let expectedViewportSize = CGSize(width: 320, height: 360)
        var observedViewportSize: CGSize?

        controller.setSkipCloseTransitionViewportReplayUpdateForTesting(true)
        controller.installCloseTransitionViewportReplayObserverForTesting { viewportSize, _ in
            observedViewportSize = viewportSize
        }
        controller.seedCloseTransitionViewportReplayStateForTesting(
            terminalState: terminalState,
            focused: true,
            fontPoints: AppState.defaultTerminalFontPoints,
            viewportSize: container.bounds.size,
            backingScaleFactor: 1,
            sourceContainer: container,
            attachment: attachment,
            lastPresentationViewportSize: container.bounds.size,
            lastPresentationBackingScaleFactor: 1
        )

        container.setFrameSize(expectedViewportSize)
        controller.armCloseTransitionViewportDeferral()
        controller.runCloseTransitionViewportReplayForTesting(forceTimeout: true)

        XCTAssertEqual(observedViewportSize, expectedViewportSize)
        XCTAssertFalse(controller.isCloseTransitionViewportDeferralArmed)
        XCTAssertFalse(controller.isCloseTransitionViewportUpdatePendingForTesting)
    }

    func testApplyGhosttyScrollbarPreferenceChangeUpdatesMountedControllers() throws {
        let store = TerminalControllerStore()
        let panelID = UUID()
        let delegate = TestTerminalSurfaceControllerDelegate()
        let controller = store.controller(for: panelID, delegate: delegate)
        let scrollView = controller.surfaceScrollViewForTesting
        let runtimeManager = GhosttyRuntimeManager.shared
        let originalConfigPath = ProcessInfo.processInfo.environment["TOASTTY_GHOSTTY_CONFIG_PATH"]
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configURL = temporaryDirectory.appendingPathComponent("ghostty-config")

        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer {
            if let originalConfigPath {
                setenv("TOASTTY_GHOSTTY_CONFIG_PATH", originalConfigPath, 1)
            } else {
                unsetenv("TOASTTY_GHOSTTY_CONFIG_PATH")
            }
            _ = runtimeManager.reloadConfiguration()
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        try "scrollbar = system\n".write(to: configURL, atomically: true, encoding: .utf8)
        setenv("TOASTTY_GHOSTTY_CONFIG_PATH", configURL.path, 1)
        XCTAssertTrue(runtimeManager.reloadConfiguration())

        controller.applyViewportState(
            TerminalViewportState(
                panelID: panelID,
                totalRows: 120,
                offsetRows: 60,
                visibleRows: 20
            )
        )
        scrollView.applyCellHeightPoints(10)
        store.applyGhosttyScrollbarPreferenceChange()
        XCTAssertTrue(scrollView.hasVerticalScroller)

        try "scrollbar = never\n".write(to: configURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(runtimeManager.reloadConfiguration())

        store.applyGhosttyScrollbarPreferenceChange()

        XCTAssertFalse(scrollView.hasVerticalScroller)
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

    func handleLocalInterruptKey(for panelID: UUID, kind: TerminalLocalInterruptKind) {
        _ = panelID
        _ = kind
    }

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
        expectedWorkingDirectory: String?
    ) {
        _ = panelID
        _ = previousChildren
        _ = expectedWorkingDirectory
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
