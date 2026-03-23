#if TOASTTY_HAS_GHOSTTY_KIT
@testable import ToasttyApp
import CoreState
import Foundation
import GhosttyKit
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

    func testSurfaceTargetTitleMetadataActionUpdatesResolvedPanel() async throws {
        try await MainActor.run {
            let state = try makeSplitState()
            let (store, registry) = makeStoreAndRegistry(state: state)
            let workspaceBefore = try XCTUnwrap(store.selectedWorkspace)
            let windowID = try XCTUnwrap(store.selectedWindow?.id)
            let workspaceID = workspaceBefore.id
            let initiallyFocusedPanelID = try XCTUnwrap(workspaceBefore.focusedPanelID)
            let targetPanelID = try XCTUnwrap(
                workspaceBefore.panels.keys.first(where: { $0 != initiallyFocusedPanelID })
            )
            let surface = fakeSurfaceHandle(0x404)
            registry.registerSurfaceHandleForTesting(
                surface,
                for: targetPanelID,
                workspaceID: workspaceID,
                windowID: windowID,
                state: store.state
            )

            defer {
                registry.unregisterSurfaceHandle(surface, for: targetPanelID)
            }

            let handled = registry.handleGhosttyRuntimeAction(
                GhosttyRuntimeAction(
                    surfaceHandle: UInt(bitPattern: surface),
                    intent: .setTerminalTitle("Background Task")
                )
            )

            XCTAssertTrue(handled)
            XCTAssertEqual(registry.panelID(forSurfaceHandle: UInt(bitPattern: surface)), targetPanelID)

            let workspaceAfter = try XCTUnwrap(store.selectedWorkspace)
            XCTAssertEqual(workspaceAfter.focusedPanelID, initiallyFocusedPanelID)
            guard case .terminal(let terminalState) = workspaceAfter.panels[targetPanelID] else {
                XCTFail("expected resolved panel to remain terminal")
                return
            }
            XCTAssertEqual(terminalState.title, "Background Task")
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

    func testClosePanelClosesExitedNonFocusedPanelWithoutConfirmation() async throws {
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
            let workspace = try XCTUnwrap(store.selectedWorkspace)
            let panelIDToKeepFocused = try XCTUnwrap(workspace.focusedPanelID)
            let panelIDToClose = try XCTUnwrap(workspace.panels.keys.first { $0 != panelIDToKeepFocused })
            let workspaceID = workspace.id
            let panelCountBeforeClose = try XCTUnwrap(store.selectedWorkspace?.panels.count)

            XCTAssertTrue(
                registry.handleRuntimeMetadataAction(
                    .showChildExited(exitCode: 0),
                    workspaceID: workspaceID,
                    panelID: panelIDToClose,
                    state: store.state,
                    store: store
                )
            )

            withExtendedLifetime(focusedPanelCommandController) {
                let closeResult = focusedPanelCommandController.closePanel(panelID: panelIDToClose)

                XCTAssertEqual(closeResult, .closed)
                guard let workspaceAfterClose = try? XCTUnwrap(store.selectedWorkspace) else {
                    XCTFail("expected selected workspace after close")
                    return
                }
                XCTAssertEqual(workspaceAfterClose.panels.count, panelCountBeforeClose - 1)
                XCTAssertNil(workspaceAfterClose.panels[panelIDToClose])
                XCTAssertEqual(workspaceAfterClose.focusedPanelID, panelIDToKeepFocused)
            }
            try StateValidator.validate(store.state)
        }
    }

    func testClosePanelShortcutHandlerForwardsPanelID() async throws {
        try await MainActor.run {
            let (_, registry) = makeStoreAndRegistry(state: AppState.bootstrap())
            let panelID = UUID()
            var handledPanelID: UUID?
            registry.setClosePanelShortcutHandler { routedPanelID in
                handledPanelID = routedPanelID
                return true
            }

            let handled = registry.handleClosePanelShortcut(panelID)

            XCTAssertTrue(handled)
            XCTAssertEqual(handledPanelID, panelID)
        }
    }

    func testClosePanelShortcutHandlerReturnsFalseWhenUnset() async throws {
        try await MainActor.run {
            let (_, registry) = makeStoreAndRegistry(state: AppState.bootstrap())

            XCTAssertFalse(registry.handleClosePanelShortcut(UUID()))
        }
    }

    func testClosePanelClosesExitedPanelInBackgroundWorkspaceWithoutChangingSelection() async throws {
        try await MainActor.run {
            var state = AppState.bootstrap()
            let reducer = AppReducer()
            let windowID = try XCTUnwrap(state.windows.first?.id)
            let backgroundWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)

            XCTAssertTrue(
                reducer.send(.splitFocusedSlot(workspaceID: backgroundWorkspaceID, orientation: .horizontal), state: &state)
            )
            let backgroundWorkspacePanelToClose = try XCTUnwrap(
                state.workspacesByID[backgroundWorkspaceID]?.focusedPanelID
            )

            XCTAssertTrue(reducer.send(.createWorkspace(windowID: windowID, title: "Second Workspace"), state: &state))
            let selectedWorkspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
            XCTAssertNotEqual(selectedWorkspaceID, backgroundWorkspaceID)
            let selectedWorkspaceFocusedPanelID = try XCTUnwrap(
                state.workspacesByID[selectedWorkspaceID]?.focusedPanelID
            )

            let store = AppStore(state: state, persistTerminalFontPreference: false)
            let registry = TerminalRuntimeRegistry()
            registry.bind(store: store)
            let focusedPanelCommandController = FocusedPanelCommandController(
                store: store,
                runtimeRegistry: registry,
                slotFocusRestoreCoordinator: SlotFocusRestoreCoordinator()
            )

            XCTAssertTrue(
                registry.handleRuntimeMetadataAction(
                    .showChildExited(exitCode: 0),
                    workspaceID: backgroundWorkspaceID,
                    panelID: backgroundWorkspacePanelToClose,
                    state: store.state,
                    store: store
                )
            )

            withExtendedLifetime(focusedPanelCommandController) {
                let closeResult = focusedPanelCommandController.closePanel(panelID: backgroundWorkspacePanelToClose)

                XCTAssertEqual(closeResult, .closed)
                let selectedWorkspaceAfterClose = try? XCTUnwrap(store.selectedWorkspace)
                XCTAssertEqual(selectedWorkspaceAfterClose?.id, selectedWorkspaceID)
                XCTAssertEqual(selectedWorkspaceAfterClose?.focusedPanelID, selectedWorkspaceFocusedPanelID)
                XCTAssertNil(store.state.workspacesByID[backgroundWorkspaceID]?.panels[backgroundWorkspacePanelToClose])
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

private func fakeSurfaceHandle(_ rawValue: UInt) -> ghostty_surface_t {
    guard let surface = ghostty_surface_t(bitPattern: rawValue) else {
        fatalError("expected fake Ghostty surface handle")
    }
    return surface
}
#endif
