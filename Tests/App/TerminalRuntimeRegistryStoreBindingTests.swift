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

    func testFocusedPanelModeToggleDoesNotArmViewportBottomAlignment() throws {
        let state = AppState.bootstrap()
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)

        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let windowID = try XCTUnwrap(store.selectedWindow?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let controller = registry.controller(for: panelID, workspaceID: workspaceID, windowID: windowID)
        controller.updateScrollbarState(TerminalScrollbarState(total: 120, offset: 90, visibleLength: 30))

        XCTAssertFalse(controller.isFocusedPanelViewportBottomAlignmentPending)

        XCTAssertTrue(store.send(.toggleFocusedPanelMode(workspaceID: workspaceID)))

        XCTAssertFalse(controller.isFocusedPanelViewportBottomAlignmentPending)
    }

    func testSurfaceLaunchConfigurationUsesProfileBindingAndRestoreReason() throws {
        let workspaceID = UUID()
        let panelID = UUID()
        let slotID = UUID()
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 1200, height: 800),
                    workspaceIDs: [workspaceID],
                    selectedWorkspaceID: workspaceID
                ),
            ],
            workspacesByID: [
                workspaceID: WorkspaceState(
                    id: workspaceID,
                    title: "Profiled",
                    layoutTree: .slot(slotID: slotID, panelID: panelID),
                    panels: [
                        panelID: .terminal(
                            TerminalPanelState(
                                title: "Terminal 1",
                                shell: "zsh",
                                cwd: "/tmp",
                                profileBinding: TerminalProfileBinding(profileID: "zmx")
                            )
                        ),
                    ],
                    focusedPanelID: panelID
                ),
            ],
            selectedWindowID: windowID,
            configuredTerminalFontPoints: nil,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let profileProvider = TestTerminalProfileProvider(
            catalog: TerminalProfileCatalog(
                profiles: [
                    TerminalProfile(
                        id: "zmx",
                        displayName: "ZMX",
                        badgeLabel: "ZMX",
                        startupCommand: "zmx attach toastty.$TOASTTY_PANEL_ID"
                    ),
                ]
            )
        )
        registry.setTerminalProfileProvider(profileProvider, restoredTerminalPanelIDs: [panelID])
        registry.bind(store: store)

        let launchConfiguration = registry.surfaceLaunchConfiguration(for: panelID)

        XCTAssertEqual(
            launchConfiguration.environmentVariables,
            [
                "TOASTTY_LAUNCH_REASON": "restore",
                "TOASTTY_PANEL_ID": panelID.uuidString,
                "TOASTTY_TERMINAL_PROFILE_ID": "zmx",
            ]
        )
        XCTAssertEqual(
            launchConfiguration.initialInput,
            "zmx attach toastty.$TOASTTY_PANEL_ID"
        )
    }

    func testMarkInitialSurfaceLaunchCompletedSuppressesRepeatProfileLaunch() throws {
        let workspaceID = UUID()
        let panelID = UUID()
        let slotID = UUID()
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 1200, height: 800),
                    workspaceIDs: [workspaceID],
                    selectedWorkspaceID: workspaceID
                ),
            ],
            workspacesByID: [
                workspaceID: WorkspaceState(
                    id: workspaceID,
                    title: "Profiled",
                    layoutTree: .slot(slotID: slotID, panelID: panelID),
                    panels: [
                        panelID: .terminal(
                            TerminalPanelState(
                                title: "Terminal 1",
                                shell: "zsh",
                                cwd: "/tmp",
                                profileBinding: TerminalProfileBinding(profileID: "zmx")
                            )
                        ),
                    ],
                    focusedPanelID: panelID
                ),
            ],
            selectedWindowID: windowID,
            configuredTerminalFontPoints: nil,
            globalTerminalFontPoints: AppState.defaultTerminalFontPoints
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let profileProvider = TestTerminalProfileProvider(
            catalog: TerminalProfileCatalog(
                profiles: [
                    TerminalProfile(
                        id: "zmx",
                        displayName: "ZMX",
                        badgeLabel: "ZMX",
                        startupCommand: "zmx attach toastty.$TOASTTY_PANEL_ID"
                    ),
                ]
            )
        )
        registry.setTerminalProfileProvider(profileProvider, restoredTerminalPanelIDs: [panelID])
        registry.bind(store: store)

        XCTAssertFalse(registry.surfaceLaunchConfiguration(for: panelID).isEmpty)

        registry.markInitialSurfaceLaunchCompleted(for: panelID)

        XCTAssertEqual(registry.surfaceLaunchConfiguration(for: panelID), .empty)
    }
}

final class TerminalProcessWorkingDirectoryResolverSelectionTests: XCTestCase {
    func testDeferredRegistrationCandidateIndexAssignsByPendingOrderWhenCountsMatch() {
        let firstPanelID = UUID()
        let secondPanelID = UUID()
        let thirdPanelID = UUID()

        XCTAssertEqual(
            TerminalProcessWorkingDirectoryResolver.deferredRegistrationCandidateIndex(
                panelID: firstPanelID,
                pendingPanelIDsByOrder: [firstPanelID, secondPanelID, thirdPanelID],
                candidateCount: 3
            ),
            0
        )
        XCTAssertEqual(
            TerminalProcessWorkingDirectoryResolver.deferredRegistrationCandidateIndex(
                panelID: secondPanelID,
                pendingPanelIDsByOrder: [firstPanelID, secondPanelID, thirdPanelID],
                candidateCount: 3
            ),
            1
        )
        XCTAssertEqual(
            TerminalProcessWorkingDirectoryResolver.deferredRegistrationCandidateIndex(
                panelID: thirdPanelID,
                pendingPanelIDsByOrder: [firstPanelID, secondPanelID, thirdPanelID],
                candidateCount: 3
            ),
            2
        )
    }

    func testDeferredRegistrationCandidateIndexReturnsNilWhenCandidateCountDoesNotMatchPendingPanels() {
        let firstPanelID = UUID()
        let secondPanelID = UUID()

        XCTAssertNil(
            TerminalProcessWorkingDirectoryResolver.deferredRegistrationCandidateIndex(
                panelID: firstPanelID,
                pendingPanelIDsByOrder: [firstPanelID, secondPanelID],
                candidateCount: 1
            )
        )
        XCTAssertNil(
            TerminalProcessWorkingDirectoryResolver.deferredRegistrationCandidateIndex(
                panelID: firstPanelID,
                pendingPanelIDsByOrder: [firstPanelID],
                candidateCount: 2
            )
        )
    }
}

@MainActor
private final class TestTerminalProfileProvider: TerminalProfileProviding {
    let catalog: TerminalProfileCatalog

    init(catalog: TerminalProfileCatalog) {
        self.catalog = catalog
    }
}
#endif
