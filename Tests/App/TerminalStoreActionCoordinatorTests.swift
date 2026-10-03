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

    func testSendExplicitBackgroundSplitRefreshesAndInheritsFromSourceInUnselectedTab() throws {
        let background = try makeBackgroundSplitState()
        var refreshedPanelIDs: [UUID] = []
        let fixture = try makeStoreActionFixture(
            state: background.state,
            resolveWorkingDirectoryFromProcessOverride: { panelID in
                refreshedPanelIDs.append(panelID)
                return "/tmp/refreshed-source"
            }
        )
        let selectedTabID = fixture.store.selectedWorkspace?.resolvedSelectedTabID
        let selectedWindowID = fixture.store.state.selectedWindowID

        XCTAssertTrue(
            fixture.coordinator.sendSplitAction(
                workspaceID: fixture.workspaceID,
                action: .splitPanel(
                    workspaceID: fixture.workspaceID,
                    tabID: background.tabID,
                    panelID: background.sourcePanelID,
                    direction: .right,
                    profileBinding: nil,
                    activate: false
                )
            )
        )

        let workspace = try XCTUnwrap(fixture.store.state.workspacesByID[fixture.workspaceID])
        let previousWorkspace = try XCTUnwrap(background.state.workspacesByID[fixture.workspaceID])
        let backgroundTab = try XCTUnwrap(workspace.tabsByID[background.tabID])
        let newPanelID = try XCTUnwrap(
            Set(workspace.allPanelsByID.keys).subtracting(previousWorkspace.allPanelsByID.keys).first
        )
        guard case .terminal(let newTerminalState) = backgroundTab.panels[newPanelID],
              case .terminal(let sourceTerminalState) = backgroundTab.panels[background.sourcePanelID] else {
            return XCTFail("expected source and split panels to remain terminal")
        }
        XCTAssertEqual(refreshedPanelIDs, [background.sourcePanelID])
        XCTAssertEqual(sourceTerminalState.cwd, "/tmp/refreshed-source")
        XCTAssertEqual(newTerminalState.cwd, "/tmp/refreshed-source")
        XCTAssertEqual(workspace.resolvedSelectedTabID, selectedTabID)
        XCTAssertEqual(workspace.focusedPanelID, fixture.sourcePanelID)
        XCTAssertEqual(backgroundTab.focusedPanelID, background.focusedPanelID)
        XCTAssertEqual(fixture.store.state.selectedWindowID, selectedWindowID)
        XCTAssertTrue(fixture.store.navigationHistory.entries.isEmpty)

        _ = fixture.controllerStore.synchronizeLivePanels([background.sourcePanelID, newPanelID])
        guard case .pending = fixture.controllerStore.splitSourceSurfaceState(for: newPanelID) else {
            return XCTFail("expected inheritance to retain the explicit source panel")
        }
    }

    func testSendExplicitProfileSplitRefreshesSourceWithoutGhosttyInheritance() throws {
        let background = try makeBackgroundSplitState()
        var refreshedPanelIDs: [UUID] = []
        let fixture = try makeStoreActionFixture(
            state: background.state,
            resolveWorkingDirectoryFromProcessOverride: { panelID in
                refreshedPanelIDs.append(panelID)
                return "/tmp/refreshed-source"
            }
        )

        XCTAssertTrue(
            fixture.coordinator.sendSplitAction(
                workspaceID: fixture.workspaceID,
                action: .splitPanel(
                    workspaceID: fixture.workspaceID,
                    tabID: background.tabID,
                    panelID: background.sourcePanelID,
                    direction: .right,
                    profileBinding: TerminalProfileBinding(profileID: "zmx"),
                    activate: false
                )
            )
        )

        let workspace = try XCTUnwrap(fixture.store.state.workspacesByID[fixture.workspaceID])
        let previousWorkspace = try XCTUnwrap(background.state.workspacesByID[fixture.workspaceID])
        let newPanelID = try XCTUnwrap(
            Set(workspace.allPanelsByID.keys).subtracting(previousWorkspace.allPanelsByID.keys).first
        )
        guard case .terminal(let newTerminalState) = workspace.panelState(for: newPanelID) else {
            return XCTFail("expected profile split to create a terminal")
        }
        XCTAssertEqual(refreshedPanelIDs, [background.sourcePanelID])
        XCTAssertEqual(newTerminalState.cwd, "/tmp/refreshed-source")
        XCTAssertEqual(newTerminalState.profileBinding?.profileID, "zmx")
        guard case .none = fixture.controllerStore.splitSourceSurfaceState(for: newPanelID) else {
            return XCTFail("expected profile split to bypass Ghostty source inheritance")
        }
    }

    func testSendExplicitSplitRejectsMismatchedTabWithoutRefreshingSource() throws {
        let background = try makeBackgroundSplitState()
        var refreshedPanelIDs: [UUID] = []
        let fixture = try makeStoreActionFixture(
            state: background.state,
            resolveWorkingDirectoryFromProcessOverride: { panelID in
                refreshedPanelIDs.append(panelID)
                return "/tmp/refreshed-source"
            }
        )
        let selectedTabID = try XCTUnwrap(fixture.store.selectedWorkspace?.resolvedSelectedTabID)

        XCTAssertFalse(
            fixture.coordinator.sendSplitAction(
                workspaceID: fixture.workspaceID,
                action: .splitPanel(
                    workspaceID: fixture.workspaceID,
                    tabID: selectedTabID,
                    panelID: background.sourcePanelID,
                    direction: .right,
                    profileBinding: nil,
                    activate: false
                )
            )
        )

        XCTAssertTrue(refreshedPanelIDs.isEmpty)
        XCTAssertEqual(fixture.store.state, background.state)
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
            registerPendingSplitSourceIfNeeded: { workspaceID, previousState, nextState, sourcePanelID in
                controllerStore.registerPendingSplitSourceIfNeeded(
                    workspaceID: workspaceID,
                    previousState: previousState,
                    nextState: nextState,
                    sourcePanelID: sourcePanelID
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
            registerPendingSplitSourceIfNeeded: { workspaceID, previousState, nextState, sourcePanelID in
                controllerStore.registerPendingSplitSourceIfNeeded(
                    workspaceID: workspaceID,
                    previousState: previousState,
                    nextState: nextState,
                    sourcePanelID: sourcePanelID
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
    state: AppState = AppState.bootstrap(),
    resolveWorkingDirectoryFromProcessOverride: ((UUID) -> String?)? = nil,
    armCloseTransitionViewportDeferral: @escaping (UUID, Set<UUID>) -> Void = { _, _ in },
    armFocusedPanelResizeTrace: @escaping (UUID, UUID) -> Void = { _, _ in },
    requestWorkspaceFocusRestore: @escaping (UUID) -> Void = { _ in }
) throws -> (
    store: AppStore,
    registry: TerminalRuntimeRegistry,
    coordinator: TerminalStoreActionCoordinator,
    controllerStore: TerminalControllerStore,
    workspaceID: UUID,
    sourcePanelID: UUID
) {
    let store = AppStore(state: state, persistTerminalFontPreference: false)
    // The fixture retains the registry because the metadata service holds it weakly.
    let registry = TerminalRuntimeRegistry()
    let metadataService = TerminalMetadataService(
        store: store,
        registry: registry,
        resolveWorkingDirectoryFromProcessOverride: resolveWorkingDirectoryFromProcessOverride,
        processRefreshRetryDelay: { _ in }
    )
    let controllerStore = TerminalControllerStore()
    let coordinator = TerminalStoreActionCoordinator(
        metadataService: metadataService,
        registerPendingSplitSourceIfNeeded: { workspaceID, previousState, nextState, sourcePanelID in
            controllerStore.registerPendingSplitSourceIfNeeded(
                workspaceID: workspaceID,
                previousState: previousState,
                nextState: nextState,
                sourcePanelID: sourcePanelID
            )
        },
        armCloseTransitionViewportDeferral: armCloseTransitionViewportDeferral,
        armFocusedPanelResizeTrace: armFocusedPanelResizeTrace,
        requestWorkspaceFocusRestore: requestWorkspaceFocusRestore
    )
    coordinator.bind(store: store)

    let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
    let sourcePanelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
    return (store, registry, coordinator, controllerStore, workspaceID, sourcePanelID)
}

private func makeBackgroundSplitState() throws -> (
    state: AppState,
    tabID: UUID,
    sourcePanelID: UUID,
    focusedPanelID: UUID
) {
    var state = AppState.bootstrap()
    let workspaceID = try XCTUnwrap(state.selectedWorkspaceSelection()?.workspaceID)
    var workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
    let sourcePanelID = UUID()
    let focusedPanelID = UUID()
    let backgroundTab = WorkspaceTabState(
        id: UUID(),
        layoutTree: .split(
            nodeID: UUID(),
            orientation: .horizontal,
            ratio: 0.5,
            first: .slot(slotID: UUID(), panelID: sourcePanelID),
            second: .slot(slotID: UUID(), panelID: focusedPanelID)
        ),
        panels: [
            sourcePanelID: .terminal(TerminalPanelState(title: "Source", shell: "zsh", cwd: "/tmp/source-stale")),
            focusedPanelID: .terminal(TerminalPanelState(title: "Focused", shell: "zsh", cwd: "/tmp/focused")),
        ],
        focusedPanelID: focusedPanelID
    )
    workspace.appendTab(backgroundTab, select: false)
    state.workspacesByID[workspaceID] = workspace
    return (state, backgroundTab.id, sourcePanelID, focusedPanelID)
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
