#if TOASTTY_HAS_GHOSTTY_KIT
@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class TerminalStoreActionCoordinatorTests: XCTestCase {
    func testSendSplitActionRegistersPendingSplitSourceForNewPanel() throws {
        let fixture = try makeStoreActionFixture()

        XCTAssertTrue(
            fixture.coordinator.sendSplitAction(
                workspaceID: fixture.workspaceID,
                action: .splitFocusedSlot(workspaceID: fixture.workspaceID, orientation: .horizontal)
            )
        )

        let workspace = try XCTUnwrap(fixture.store.selectedWorkspace)
        let newPanelIDs = Set(workspace.panels.keys).subtracting([fixture.sourcePanelID])
        let newPanelID = try XCTUnwrap(newPanelIDs.first)
        guard case .pending = fixture.controllerStore.splitSourceSurfaceState(for: newPanelID) else {
            XCTFail("expected pending split source registration for the new panel")
            return
        }
    }

    func testSendSplitActionRefreshesWorkingDirectoryBeforeProfileSplit() throws {
        var state = AppState.bootstrap()
        let workspaceID = try XCTUnwrap(state.selectedWorkspaceSelection()?.workspaceID)
        let sourcePanelID = try XCTUnwrap(state.selectedWorkspaceSelection()?.workspace.focusedPanelID)
        var workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
        workspace.panels[sourcePanelID] = .terminal(
            TerminalPanelState(
                title: "Terminal 1",
                shell: "zsh",
                cwd: "/tmp/stale"
            )
        )
        state.workspacesByID[workspaceID] = workspace

        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let metadataService = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { panelID in
                panelID == sourcePanelID ? "/tmp/refreshed" : nil
            },
            processRefreshRetryDelay: { _ in }
        )
        let controllerStore = TerminalControllerStore()
        let coordinator = TerminalStoreActionCoordinator(
            metadataService: metadataService,
            registerPendingSplitSourceIfNeeded: { workspaceID, previousState, nextState in
                controllerStore.registerPendingSplitSourceIfNeeded(
                    workspaceID: workspaceID,
                    previousState: previousState,
                    nextState: nextState
                )
            },
            armCloseTransitionViewportDeferral: { _, _ in },
            armFocusedPanelResizeTrace: { _, _ in },
            requestWorkspaceFocusRestore: { _ in }
        )
        coordinator.bind(store: store)

        XCTAssertTrue(
            coordinator.sendSplitAction(
                workspaceID: workspaceID,
                action: .splitFocusedSlotInDirectionWithTerminalProfile(
                    workspaceID: workspaceID,
                    direction: .right,
                    profileBinding: TerminalProfileBinding(profileID: "zmx")
                )
            )
        )

        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let newPanelID = try XCTUnwrap(updatedWorkspace.focusedPanelID)
        guard case .terminal(let newTerminalState) = updatedWorkspace.panels[newPanelID] else {
            return XCTFail("expected focused panel to remain terminal")
        }
        XCTAssertEqual(newTerminalState.profileBinding?.profileID, "zmx")
        XCTAssertEqual(newTerminalState.cwd, "/tmp/refreshed")
    }

    func testBindArmsCloseTransitionViewportDeferralWhenPanelCloses() throws {
        var armedWorkspaceIDs: [UUID] = []
        var armedPanelIDSets: [Set<UUID>] = []
        let fixture = try makeStoreActionFixture(
            armCloseTransitionViewportDeferral: { workspaceID, panelIDs in
                armedWorkspaceIDs.append(workspaceID)
                armedPanelIDSets.append(panelIDs)
            }
        )

        XCTAssertTrue(
            fixture.store.send(.splitFocusedSlot(workspaceID: fixture.workspaceID, orientation: .horizontal))
        )
        let panelToClose = try XCTUnwrap(fixture.store.selectedWorkspace?.focusedPanelID)

        XCTAssertTrue(fixture.store.send(.closePanel(panelID: panelToClose)))

        let workspace = try XCTUnwrap(fixture.store.selectedWorkspace)
        XCTAssertEqual(armedWorkspaceIDs, [fixture.workspaceID])
        XCTAssertEqual(armedPanelIDSets, [liveTerminalPanelIDs(in: workspace)])
    }

    func testBindRequestsFocusRestoreWhenSelectedWorkspaceFocusedModeToggles() throws {
        var restoredWorkspaceIDs: [UUID] = []
        var tracedPanels: [(workspaceID: UUID, panelID: UUID)] = []
        let fixture = try makeStoreActionFixture(
            armFocusedPanelResizeTrace: { workspaceID, panelID in
                tracedPanels.append((workspaceID, panelID))
            },
            requestWorkspaceFocusRestore: { workspaceID in
                restoredWorkspaceIDs.append(workspaceID)
            }
        )

        XCTAssertTrue(fixture.store.send(.toggleFocusedPanelMode(workspaceID: fixture.workspaceID)))
        XCTAssertEqual(restoredWorkspaceIDs, [fixture.workspaceID])
        XCTAssertEqual(tracedPanels.count, 1)
        XCTAssertEqual(tracedPanels.first?.workspaceID, fixture.workspaceID)
        XCTAssertEqual(tracedPanels.first?.panelID, fixture.sourcePanelID)
    }

    func testBindRequestsWorkspaceFocusRestoreWhenFocusedPanelIDIsNil() throws {
        let state = try stateWithNilFocusedPanelID()
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let metadataService = TerminalMetadataService(store: store, registry: registry)
        let controllerStore = TerminalControllerStore()
        var restoredWorkspaceIDs: [UUID] = []
        var tracedPanels: [(workspaceID: UUID, panelID: UUID)] = []
        let coordinator = TerminalStoreActionCoordinator(
            metadataService: metadataService,
            registerPendingSplitSourceIfNeeded: { workspaceID, previousState, nextState in
                controllerStore.registerPendingSplitSourceIfNeeded(
                    workspaceID: workspaceID,
                    previousState: previousState,
                    nextState: nextState
                )
            },
            armCloseTransitionViewportDeferral: { _, _ in },
            armFocusedPanelResizeTrace: { workspaceID, panelID in
                tracedPanels.append((workspaceID, panelID))
            },
            requestWorkspaceFocusRestore: { workspaceID in
                restoredWorkspaceIDs.append(workspaceID)
            }
        )
        coordinator.bind(store: store)

        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        XCTAssertTrue(store.send(.toggleFocusedPanelMode(workspaceID: workspaceID)))
        XCTAssertEqual(restoredWorkspaceIDs, [workspaceID])
        XCTAssertEqual(tracedPanels.count, 1)
        XCTAssertEqual(tracedPanels.first?.workspaceID, workspaceID)
        XCTAssertNotNil(tracedPanels.first?.panelID)
    }

    func testBindReplacesPreviousObserverRegistration() throws {
        var restoredWorkspaceIDs: [UUID] = []
        let fixture = try makeStoreActionFixture(
            requestWorkspaceFocusRestore: { workspaceID in
                restoredWorkspaceIDs.append(workspaceID)
            }
        )

        fixture.coordinator.bind(store: fixture.store)

        XCTAssertTrue(fixture.store.send(.toggleFocusedPanelMode(workspaceID: fixture.workspaceID)))
        XCTAssertEqual(restoredWorkspaceIDs, [fixture.workspaceID])
    }

    func testUnbindStopsObservingStoreActions() throws {
        var restoredWorkspaceIDs: [UUID] = []
        let fixture = try makeStoreActionFixture(
            requestWorkspaceFocusRestore: { workspaceID in
                restoredWorkspaceIDs.append(workspaceID)
            }
        )

        fixture.coordinator.unbind()

        XCTAssertTrue(fixture.store.send(.toggleFocusedPanelMode(workspaceID: fixture.workspaceID)))
        XCTAssertTrue(restoredWorkspaceIDs.isEmpty)
    }
}

@MainActor
private func makeStoreActionFixture(
    armCloseTransitionViewportDeferral: @escaping (UUID, Set<UUID>) -> Void = { _, _ in },
    armFocusedPanelResizeTrace: @escaping (UUID, UUID) -> Void = { _, _ in },
    requestWorkspaceFocusRestore: @escaping (UUID) -> Void = { _ in }
) throws -> (
    store: AppStore,
    coordinator: TerminalStoreActionCoordinator,
    controllerStore: TerminalControllerStore,
    workspaceID: UUID,
    sourcePanelID: UUID
) {
    let state = AppState.bootstrap()
    let store = AppStore(state: state, persistTerminalFontPreference: false)
    let registry = TerminalRuntimeRegistry()
    let metadataService = TerminalMetadataService(store: store, registry: registry)
    let controllerStore = TerminalControllerStore()
    let coordinator = TerminalStoreActionCoordinator(
        metadataService: metadataService,
        registerPendingSplitSourceIfNeeded: { workspaceID, previousState, nextState in
            controllerStore.registerPendingSplitSourceIfNeeded(
                workspaceID: workspaceID,
                previousState: previousState,
                nextState: nextState
            )
        },
        armCloseTransitionViewportDeferral: armCloseTransitionViewportDeferral,
        armFocusedPanelResizeTrace: armFocusedPanelResizeTrace,
        requestWorkspaceFocusRestore: requestWorkspaceFocusRestore
    )
    coordinator.bind(store: store)

    let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
    let sourcePanelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
    return (store, coordinator, controllerStore, workspaceID, sourcePanelID)
}

private func stateWithNilFocusedPanelID() throws -> AppState {
    var state = AppState.bootstrap()
    let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
    var workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
    workspace.focusedPanelID = nil
    state.workspacesByID[workspaceID] = workspace
    return state
}

private func liveTerminalPanelIDs(in workspace: WorkspaceState) -> Set<UUID> {
    workspace.layoutTree.allSlotInfos.reduce(into: Set<UUID>()) { panelIDs, slot in
        let panelID = slot.panelID
        guard let panelState = workspace.panels[panelID],
              case .terminal = panelState else {
            return
        }
        panelIDs.insert(panelID)
    }
}

#endif
