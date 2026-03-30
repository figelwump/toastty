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

    func testAppTargetStartSearchOpensSearchWithoutChangingFocus() async throws {
        try await MainActor.run {
            let state = AppState.bootstrap()
            let (store, registry) = makeStoreAndRegistry(state: state)
            let focusedPanelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)

            let handled = registry.handleGhosttyRuntimeAction(
                GhosttyRuntimeAction(surfaceHandle: nil, intent: .startSearch(needle: ""))
            )

            XCTAssertTrue(handled)
            XCTAssertEqual(store.selectedWorkspace?.focusedPanelID, focusedPanelID)
            XCTAssertEqual(
                registry.searchState(for: focusedPanelID),
                TerminalSearchState(
                    isPresented: true,
                    needle: "",
                    total: nil,
                    selected: nil,
                    focusRequestID: registry.searchState(for: focusedPanelID)?.focusRequestID ?? UUID()
                )
            )
            try StateValidator.validate(store.state)
        }
    }

    func testSurfaceTargetSearchCallbacksUpdateResolvedPanelWithoutChangingFocus() async throws {
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
            let surface = fakeSurfaceHandle(0x505)
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

            XCTAssertTrue(
                registry.handleGhosttyRuntimeAction(
                    GhosttyRuntimeAction(
                        surfaceHandle: UInt(bitPattern: surface),
                        intent: .startSearch(needle: "")
                    )
                )
            )
            XCTAssertTrue(
                registry.handleGhosttyRuntimeAction(
                    GhosttyRuntimeAction(
                        surfaceHandle: UInt(bitPattern: surface),
                        intent: .searchTotal(5)
                    )
                )
            )
            XCTAssertTrue(
                registry.handleGhosttyRuntimeAction(
                    GhosttyRuntimeAction(
                        surfaceHandle: UInt(bitPattern: surface),
                        intent: .searchSelected(2)
                    )
                )
            )

            let workspaceAfter = try XCTUnwrap(store.selectedWorkspace)
            XCTAssertEqual(workspaceAfter.focusedPanelID, initiallyFocusedPanelID)
            let searchState = try XCTUnwrap(registry.searchState(for: targetPanelID))
            XCTAssertTrue(searchState.isPresented)
            XCTAssertEqual(searchState.needle, "")
            XCTAssertEqual(searchState.total, 5)
            XCTAssertEqual(searchState.selected, 2)
            try StateValidator.validate(store.state)
        }
    }

    func testSurfaceTargetEndSearchClearsResolvedPanelSearchState() async throws {
        try await MainActor.run {
            let state = try makeSplitState()
            let (store, registry) = makeStoreAndRegistry(state: state)
            let workspaceBefore = try XCTUnwrap(store.selectedWorkspace)
            let windowID = try XCTUnwrap(store.selectedWindow?.id)
            let targetPanelID = try XCTUnwrap(workspaceBefore.panels.keys.first)
            let surface = fakeSurfaceHandle(0x606)
            registry.registerSurfaceHandleForTesting(
                surface,
                for: targetPanelID,
                workspaceID: workspaceBefore.id,
                windowID: windowID,
                state: store.state
            )

            defer {
                registry.unregisterSurfaceHandle(surface, for: targetPanelID)
            }

            XCTAssertTrue(
                registry.handleGhosttyRuntimeAction(
                    GhosttyRuntimeAction(
                        surfaceHandle: UInt(bitPattern: surface),
                        intent: .startSearch(needle: "")
                    )
                )
            )
            XCTAssertNotNil(registry.searchState(for: targetPanelID))

            XCTAssertTrue(
                registry.handleGhosttyRuntimeAction(
                    GhosttyRuntimeAction(
                        surfaceHandle: UInt(bitPattern: surface),
                        intent: .endSearch
                    )
                )
            )

            XCTAssertNil(registry.searchState(for: targetPanelID))
            try StateValidator.validate(store.state)
        }
    }

    func testClosingPanelPrunesSearchState() async throws {
        try await MainActor.run {
            let state = try makeSplitState()
            let (store, registry) = makeStoreAndRegistry(state: state)
            let workspace = try XCTUnwrap(store.selectedWorkspace)
            let focusedPanelID = try XCTUnwrap(workspace.focusedPanelID)
            let targetPanelID = try XCTUnwrap(
                workspace.panels.keys.first(where: { $0 != focusedPanelID })
            )

            XCTAssertTrue(
                registry.handleSearchRuntimeAction(
                    .startSearch(needle: ""),
                    panelID: targetPanelID
                )
            )
            XCTAssertNotNil(registry.searchState(for: targetPanelID))

            XCTAssertTrue(store.send(.closePanel(panelID: targetPanelID)))

            XCTAssertNil(registry.searchState(for: targetPanelID))
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

    func testClosePanelClosesExitedPanelInBackgroundTabWithoutChangingSelectedTab() async throws {
        try await MainActor.run {
            var state = AppState.bootstrap()
            let reducer = AppReducer()
            let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)

            XCTAssertTrue(reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state))

            let workspaceWithTwoTabs = try XCTUnwrap(state.workspacesByID[workspaceID])
            let originalTabID = try XCTUnwrap(workspaceWithTwoTabs.tabIDs.first)
            let backgroundTabID = try XCTUnwrap(workspaceWithTwoTabs.tabIDs.last)
            let backgroundTab = try XCTUnwrap(workspaceWithTwoTabs.tab(id: backgroundTabID))
            let backgroundPanelToClose = try XCTUnwrap(backgroundTab.focusedPanelID)

            XCTAssertTrue(reducer.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: originalTabID), state: &state))

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
                    workspaceID: workspaceID,
                    panelID: backgroundPanelToClose,
                    state: store.state,
                    store: store
                )
            )

            withExtendedLifetime(focusedPanelCommandController) {
                let closeResult = focusedPanelCommandController.closePanel(panelID: backgroundPanelToClose)

                XCTAssertEqual(closeResult, .closed)
                let updatedWorkspace = try? XCTUnwrap(store.state.workspacesByID[workspaceID])
                XCTAssertEqual(updatedWorkspace?.selectedTabID, originalTabID)
                XCTAssertNil(updatedWorkspace?.tab(id: backgroundTabID))
                XCTAssertNil(updatedWorkspace?.panelState(for: backgroundPanelToClose))
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
