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
        XCTAssertEqual(
            tracker.stopActiveCalls.first,
            .init(
                panelID: try XCTUnwrap(store.selectedWorkspace?.focusedPanelID),
                reason: .ghosttyCommandFinished(exitCode: nil)
            )
        )
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
            configuredTerminalFontPoints: nil
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
            configuredTerminalFontPoints: nil
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

    func testActivatePanelIfNeededFocusesResolvedPanel() throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)

        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let originalPanelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)

        XCTAssertTrue(store.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal)))

        let splitFocusedPanelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        XCTAssertNotEqual(splitFocusedPanelID, originalPanelID)

        XCTAssertTrue(registry.activatePanelIfNeeded(originalPanelID))
        XCTAssertEqual(store.selectedWorkspace?.focusedPanelID, originalPanelID)
    }

    func testReleaseInactiveSearchFieldFocusClearsBackgroundSearchFieldFocus() {
        let registry = TerminalRuntimeRegistry()
        let searchPanelID = UUID()
        let activePanelID = UUID()

        registry.setSearchFieldFocused(true, panelID: searchPanelID)

        XCTAssertTrue(registry.releaseInactiveSearchFieldFocus(activePanelID: activePanelID))
        XCTAssertFalse(registry.isSearchFieldFocused(panelID: searchPanelID))
        XCTAssertFalse(registry.isSearchFieldFocused(panelID: activePanelID))
    }

    func testReleaseInactiveSearchFieldFocusKeepsActiveSearchFieldFocus() {
        let registry = TerminalRuntimeRegistry()
        let searchPanelID = UUID()

        registry.setSearchFieldFocused(true, panelID: searchPanelID)

        XCTAssertFalse(registry.releaseInactiveSearchFieldFocus(activePanelID: searchPanelID))
        XCTAssertTrue(registry.isSearchFieldFocused(panelID: searchPanelID))
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

    func testPreferredRegistrationCandidateIndexUsesExpectedWorkingDirectoryMatch() {
        XCTAssertEqual(
            TerminalProcessWorkingDirectoryResolver.preferredRegistrationCandidateIndex(
                expectedWorkingDirectory: "/tmp/restored-one",
                candidateWorkingDirectories: ["/tmp/restored-two", "/tmp/restored-one"],
                candidateLoginPIDs: [101, 202],
                preferNewestWhenAmbiguous: true
            ),
            1
        )
    }

    func testPreferredRegistrationCandidateIndexReturnsNilWhenSingleCandidateDoesNotMatchExpectedWorkingDirectory() {
        XCTAssertNil(
            TerminalProcessWorkingDirectoryResolver.preferredRegistrationCandidateIndex(
                expectedWorkingDirectory: "/tmp/restored-one",
                candidateWorkingDirectories: ["/tmp/restored-two"],
                candidateLoginPIDs: [101],
                preferNewestWhenAmbiguous: true
            )
        )
    }

    func testPreferredRegistrationCandidateIndexReturnsNilWhenNoCandidateMatchesExpectedWorkingDirectoryEvenIfNewestFallbackWouldNormallyApply() {
        XCTAssertNil(
            TerminalProcessWorkingDirectoryResolver.preferredRegistrationCandidateIndex(
                expectedWorkingDirectory: "/tmp/restored-one",
                candidateWorkingDirectories: ["/tmp/restored-two", "/tmp/restored-three"],
                candidateLoginPIDs: [101, 202],
                preferNewestWhenAmbiguous: true
            )
        )
    }

    func testPreferredRegistrationCandidateIndexFallsBackToNewestCandidateWhenExpectedWorkingDirectoryIsMissing() {
        XCTAssertEqual(
            TerminalProcessWorkingDirectoryResolver.preferredRegistrationCandidateIndex(
                expectedWorkingDirectory: nil,
                candidateWorkingDirectories: ["/tmp/one", "/tmp/two"],
                candidateLoginPIDs: [101, 202],
                preferNewestWhenAmbiguous: true
            ),
            1
        )
    }

    func testPreferredRegistrationCandidateIndexKeepsDeterministicNewestFallbackWhenExpectedWorkingDirectoryMatchesMultipleCandidates() {
        XCTAssertEqual(
            TerminalProcessWorkingDirectoryResolver.preferredRegistrationCandidateIndex(
                expectedWorkingDirectory: "/tmp/shared",
                candidateWorkingDirectories: ["/tmp/shared", "/tmp/shared"],
                candidateLoginPIDs: [101, 202],
                preferNewestWhenAmbiguous: true
            ),
            1
        )
    }

    func testPreferredRegistrationCandidateIndexReturnsNilWhenFallbackDisabledAndNoCandidateMatchesExpectedWorkingDirectory() {
        XCTAssertNil(
            TerminalProcessWorkingDirectoryResolver.preferredRegistrationCandidateIndex(
                expectedWorkingDirectory: "/tmp/restored-one",
                candidateWorkingDirectories: ["/tmp/restored-two"],
                candidateLoginPIDs: [101],
                preferNewestWhenAmbiguous: true,
                allowUnmatchedFallback: false
            )
        )
    }

    func testPreferredRegistrationCandidateIndexReturnsNilWhenFallbackDisabledAndCandidatesHaveNoReadableCWD() {
        XCTAssertNil(
            TerminalProcessWorkingDirectoryResolver.preferredRegistrationCandidateIndex(
                expectedWorkingDirectory: "/tmp/restored-one",
                candidateWorkingDirectories: [nil, nil],
                candidateLoginPIDs: [101, 202],
                preferNewestWhenAmbiguous: true,
                allowUnmatchedFallback: false
            )
        )
    }
}

@MainActor
private final class SessionLifecycleTrackerSpy: TerminalSessionLifecycleTracking {
    struct StopActiveCall: Equatable {
        let panelID: UUID
        let reason: ManagedSessionStopReason
    }

    private(set) var stopActiveCalls: [StopActiveCall] = []

    func activeSessionUsesStatusNotifications(panelID: UUID) -> Bool {
        _ = panelID
        return false
    }

    func refreshManagedSessionStatusFromVisibleTextIfNeeded(
        panelID: UUID,
        visibleText: String,
        at now: Date
    ) -> Bool {
        _ = panelID
        _ = visibleText
        _ = now
        return false
    }

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

    func stopSessionForPanelIfActive(
        panelID: UUID,
        reason: ManagedSessionStopReason,
        at now: Date
    ) -> Bool {
        _ = now
        stopActiveCalls.append(.init(panelID: panelID, reason: reason))
        return true
    }

    func stopSessionForPanelIfOlderThan(
        panelID: UUID,
        minimumRuntime: TimeInterval,
        reason: ManagedSessionStopReason,
        at now: Date
    ) -> Bool {
        _ = panelID
        _ = minimumRuntime
        _ = reason
        _ = now
        return false
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
