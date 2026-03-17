#if TOASTTY_HAS_GHOSTTY_KIT
@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class TerminalRuntimeRegistryStoreBindingTests: XCTestCase {
    func testBindSynchronizesControllersAfterStateReplacement() throws {
        let initialState = AppState.bootstrap()
        let store = AppStore(state: initialState, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)

        let initialWorkspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let initialWindowID = try XCTUnwrap(store.selectedWindow?.id)
        let initialPanelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        _ = registry.controller(
            for: initialPanelID,
            workspaceID: initialWorkspaceID,
            windowID: initialWindowID
        )

        store.replaceState(.bootstrap())

        let removedSnapshot = registry.automationRenderSnapshot(panelID: initialPanelID)
        XCTAssertFalse(removedSnapshot.controllerExists)
    }

    func testBindingSessionLifecycleTrackerAfterStoreBindingUpdatesMetadataHandling() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)

        let tracker = SessionLifecycleTrackerSpy()
        registry.bind(sessionLifecycleTracker: tracker)

        let handled = registry.handleGhosttyRuntimeAction(
            GhosttyRuntimeAction(surfaceHandle: nil, intent: .commandFinished(exitCode: nil))
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(tracker.stopActiveCalls.count, 1)
        XCTAssertEqual(tracker.stopActiveCalls.first, store.selectedWorkspace?.focusedPanelID)
    }
}

@MainActor
private final class SessionLifecycleTrackerSpy: TerminalSessionLifecycleTracking {
    private(set) var stopActiveCalls: [UUID] = []

    func handleLocalInterruptForPanelIfActive(
        panelID: UUID,
        kind: TerminalLocalInterruptKind,
        at now: Date
    ) -> Bool {
        _ = panelID
        _ = kind
        _ = now
        return false
    }

    func stopSessionForPanelIfActive(panelID: UUID, at now: Date) -> Bool {
        _ = now
        stopActiveCalls.append(panelID)
        return true
    }

    func stopSessionForPanelIfOlderThan(panelID: UUID, minimumRuntime: TimeInterval, at now: Date) -> Bool {
        _ = panelID
        _ = minimumRuntime
        _ = now
        return false
    }
}
#endif
