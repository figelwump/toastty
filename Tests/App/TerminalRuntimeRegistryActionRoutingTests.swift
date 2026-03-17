#if TOASTTY_HAS_GHOSTTY_KIT
@testable import ToasttyApp
import CoreState
import Foundation
import XCTest

final class TerminalRuntimeRegistryActionRoutingTests: XCTestCase {
    func testAppTargetSplitActionRoutesToSelectedWorkspace() async throws {
        try await MainActor.run {
            let state = AppState.bootstrap()
            let (store, registry) = makeStoreAndRegistry(state: state)
            let workspaceBefore = try XCTUnwrap(store.selectedWorkspace)
            let previouslyFocusedPanelID = try XCTUnwrap(workspaceBefore.focusedPanelID)

            let handled = registry.handleGhosttyRuntimeAction(
                GhosttyRuntimeAction(surfaceHandle: nil, intent: .split(.right))
            )

            XCTAssertTrue(handled)
            let workspaceAfter = try XCTUnwrap(store.selectedWorkspace)
            XCTAssertEqual(workspaceAfter.panels.count, workspaceBefore.panels.count + 1)
            let newlyFocusedPanelID = try XCTUnwrap(workspaceAfter.focusedPanelID)
            XCTAssertNotEqual(newlyFocusedPanelID, previouslyFocusedPanelID)

            guard case .split(_, let orientation, _, _, _) = workspaceAfter.layoutTree else {
                XCTFail("expected split root after routed split action")
                return
            }
            XCTAssertEqual(orientation, .horizontal)
            try StateValidator.validate(store.state)
        }
    }

    func testAppTargetFocusActionMovesToNextPane() async throws {
        try await MainActor.run {
            let state = try makeSplitState()
            let (store, registry) = makeStoreAndRegistry(state: state)
            let initiallyFocusedPanelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)

            let handled = registry.handleGhosttyRuntimeAction(
                GhosttyRuntimeAction(surfaceHandle: nil, intent: .focus(.next))
            )

            XCTAssertTrue(handled)
            let focusedPanelIDAfterMove = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
            XCTAssertNotEqual(focusedPanelIDAfterMove, initiallyFocusedPanelID)
            try StateValidator.validate(store.state)
        }
    }

    func testAppTargetEqualizeActionUsesReducerEqualization() async throws {
        try await MainActor.run {
            let state = try makeSplitState(rootRatio: 0.2)
            let (store, registry) = makeStoreAndRegistry(state: state)

            let handled = registry.handleGhosttyRuntimeAction(
                GhosttyRuntimeAction(surfaceHandle: nil, intent: .equalizeSplits)
            )

            XCTAssertTrue(handled)
            let workspaceAfter = try XCTUnwrap(store.selectedWorkspace)
            guard case .split(_, _, let ratio, _, _) = workspaceAfter.layoutTree else {
                XCTFail("expected split root after equalize action")
                return
            }
            XCTAssertEqual(ratio, 0.5, accuracy: 0.0001)
            try StateValidator.validate(store.state)
        }
    }

    func testAppTargetToggleFocusedPanelModeUpdatesSelectedWorkspace() async throws {
        try await MainActor.run {
            let state = try makeSplitState()
            let (store, registry) = makeStoreAndRegistry(state: state)
            XCTAssertFalse(store.selectedWorkspace?.focusedPanelModeActive ?? true)

            let handled = registry.handleGhosttyRuntimeAction(
                GhosttyRuntimeAction(surfaceHandle: nil, intent: .toggleFocusedPanelMode)
            )

            XCTAssertTrue(handled)
            XCTAssertTrue(store.selectedWorkspace?.focusedPanelModeActive ?? false)
            try StateValidator.validate(store.state)
        }
    }

    func testAppTargetTitleMetadataActionUpdatesFocusedPanelWithoutChangingFocus() async throws {
        try await MainActor.run {
            let state = AppState.bootstrap()
            let (store, registry) = makeStoreAndRegistry(state: state)
            let focusedPanelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)

            let handled = registry.handleGhosttyRuntimeAction(
                GhosttyRuntimeAction(surfaceHandle: nil, intent: .setTerminalTitle("Build Logs"))
            )

            XCTAssertTrue(handled)
            let workspaceAfter = try XCTUnwrap(store.selectedWorkspace)
            XCTAssertEqual(workspaceAfter.focusedPanelID, focusedPanelID)
            guard case .terminal(let terminalState) = workspaceAfter.panels[focusedPanelID] else {
                XCTFail("expected focused panel to remain terminal")
                return
            }
            XCTAssertEqual(terminalState.title, "Build Logs")
            try StateValidator.validate(store.state)
        }
    }

    func testAppTargetCWDMetadataActionUpdatesFocusedPanelWithoutChangingFocus() async throws {
        try await MainActor.run {
            let state = AppState.bootstrap()
            let (store, registry) = makeStoreAndRegistry(state: state)
            let focusedPanelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)

            let handled = registry.handleGhosttyRuntimeAction(
                GhosttyRuntimeAction(surfaceHandle: nil, intent: .setTerminalCWD("/tmp/toastty/runtime-router"))
            )

            XCTAssertTrue(handled)
            let workspaceAfter = try XCTUnwrap(store.selectedWorkspace)
            XCTAssertEqual(workspaceAfter.focusedPanelID, focusedPanelID)
            guard case .terminal(let terminalState) = workspaceAfter.panels[focusedPanelID] else {
                XCTFail("expected focused panel to remain terminal")
                return
            }
            XCTAssertEqual(terminalState.cwd, "/tmp/toastty/runtime-router")
            try StateValidator.validate(store.state)
        }
    }

    func testAppTargetCWDMetadataActionNormalizesFileURL() async throws {
        try await MainActor.run {
            let state = AppState.bootstrap()
            let (store, registry) = makeStoreAndRegistry(state: state)
            let focusedPanelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)

            let handled = registry.handleGhosttyRuntimeAction(
                GhosttyRuntimeAction(surfaceHandle: nil, intent: .setTerminalCWD("  file:///tmp/toastty/runtime-router  "))
            )

            XCTAssertTrue(handled)
            let workspaceAfter = try XCTUnwrap(store.selectedWorkspace)
            XCTAssertEqual(workspaceAfter.focusedPanelID, focusedPanelID)
            guard case .terminal(let terminalState) = workspaceAfter.panels[focusedPanelID] else {
                XCTFail("expected focused panel to remain terminal")
                return
            }
            XCTAssertEqual(terminalState.cwd, "/tmp/toastty/runtime-router")
            try StateValidator.validate(store.state)
        }
    }

    func testChildExitedMetadataMakesPanelSafeToCloseWithoutController() async throws {
        try await MainActor.run {
            let state = AppState.bootstrap()
            let (store, registry) = makeStoreAndRegistry(state: state)
            let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
            let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)

            let handled = registry.handleRuntimeMetadataAction(
                .showChildExited(exitCode: 0),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state,
                store: store
            )

            XCTAssertTrue(handled)
            let assessment = try XCTUnwrap(registry.terminalCloseConfirmationAssessment(panelID: panelID))
            XCTAssertFalse(assessment.requiresConfirmation)
            XCTAssertNil(assessment.runningCommand)
        }
    }

    func testCloseSurfaceRequestClosesFocusedExitedPanelViaFocusedPanelController() async throws {
        try await MainActor.run {
            let state = try makeSplitState()
            let store = AppStore(state: state, persistTerminalFontPreference: false)
            let registry = TerminalRuntimeRegistry()
            registry.bind(store: store)
            let focusedPanelCommandController = FocusedPanelCommandController(
                store: store,
                runtimeRegistry: registry,
                slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
            )
            let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
            let panelIDToClose = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
            let panelCountBeforeClose = try XCTUnwrap(store.selectedWorkspace?.panels.count)

            withExtendedLifetime(focusedPanelCommandController) {
                XCTAssertTrue(
                    registry.handleRuntimeMetadataAction(
                        .showChildExited(exitCode: 0),
                        workspaceID: workspaceID,
                        panelID: panelIDToClose,
                        state: store.state,
                        store: store
                    )
                )

                let handled = registry.handleGhosttyCloseSurfaceRequest(false)

                XCTAssertTrue(handled)
                guard let workspaceAfterClose = try? XCTUnwrap(store.selectedWorkspace) else {
                    XCTFail("expected selected workspace after close")
                    return
                }
                XCTAssertEqual(workspaceAfterClose.panels.count, panelCountBeforeClose - 1)
                XCTAssertNil(workspaceAfterClose.panels[panelIDToClose])
            }
            try StateValidator.validate(store.state)
        }
    }
}

@MainActor
private func makeStoreAndRegistry(state: AppState) -> (AppStore, TerminalRuntimeRegistry) {
    let store = AppStore(state: state, persistTerminalFontPreference: false)
    let registry = TerminalRuntimeRegistry()
    registry.bind(store: store)
    return (store, registry)
}

@MainActor
private func makeSplitState(rootRatio: Double = 0.5) throws -> AppState {
    var state = AppState.bootstrap()
    let reducer = AppReducer()
    let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)

    XCTAssertTrue(
        reducer.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal), state: &state),
        "expected split fixture creation to succeed"
    )

    guard rootRatio != 0.5 else {
        return state
    }

    var workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
    guard case .split(let nodeID, let orientation, _, let first, let second) = workspace.layoutTree else {
        XCTFail("expected split root when adjusting ratio for fixture")
        return state
    }
    workspace.layoutTree = .split(
        nodeID: nodeID,
        orientation: orientation,
        ratio: rootRatio,
        first: first,
        second: second
    )
    state.workspacesByID[workspaceID] = workspace
    return state
}
#endif
