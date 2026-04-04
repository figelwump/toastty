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
        let paneJournalFilePath = "/tmp/toastty-history/\(panelID.uuidString).journal"
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
        registry.setBaseLaunchEnvironmentProvider { requestedPanelID in
            [
                ToasttyLaunchContextEnvironment.paneJournalFileKey: "/tmp/toastty-history/\(requestedPanelID.uuidString).journal",
            ]
        }
        registry.bind(store: store)

        let launchConfiguration = registry.surfaceLaunchConfiguration(for: panelID)

        XCTAssertEqual(
            launchConfiguration.environmentVariables,
            [
                "TOASTTY_LAUNCH_REASON": "restore",
                "TOASTTY_PANEL_ID": panelID.uuidString,
                "TOASTTY_PANE_JOURNAL_FILE": paneJournalFilePath,
                "TOASTTY_TERMINAL_PROFILE_ID": "zmx",
            ]
        )
        XCTAssertEqual(
            launchConfiguration.initialInput,
            "zmx attach toastty.$TOASTTY_PANEL_ID"
        )
    }

    func testSurfaceLaunchConfigurationUsesRestoreReasonWithoutProfileBinding() throws {
        let workspaceID = UUID()
        let panelID = UUID()
        let slotID = UUID()
        let windowID = UUID()
        let paneJournalFilePath = "/tmp/toastty-history/\(panelID.uuidString).journal"
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
                    title: "Plain",
                    layoutTree: .slot(slotID: slotID, panelID: panelID),
                    panels: [
                        panelID: .terminal(
                            TerminalPanelState(
                                title: "Terminal 1",
                                shell: "zsh",
                                cwd: "/tmp"
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
        registry.setTerminalProfileProvider(
            TestTerminalProfileProvider(catalog: TerminalProfileCatalog(profiles: [])),
            restoredTerminalPanelIDs: [panelID]
        )
        registry.setBaseLaunchEnvironmentProvider { requestedPanelID in
            [
                ToasttyLaunchContextEnvironment.paneJournalFileKey: "/tmp/toastty-history/\(requestedPanelID.uuidString).journal",
            ]
        }
        registry.bind(store: store)

        let launchConfiguration = registry.surfaceLaunchConfiguration(for: panelID)

        XCTAssertEqual(
            launchConfiguration.environmentVariables,
            [
                ToasttyLaunchContextEnvironment.launchReasonKey: "restore",
                ToasttyLaunchContextEnvironment.paneJournalFileKey: paneJournalFilePath,
            ]
        )
        XCTAssertNil(launchConfiguration.initialInput)
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

        XCTAssertEqual(
            registry.surfaceLaunchConfiguration(for: panelID),
            TerminalSurfaceLaunchConfiguration(
                environmentVariables: [
                    ToasttyLaunchContextEnvironment.launchReasonKey: "create",
                ]
            )
        )
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

    func testOpenCommandClickLinkRoutesIntoTerminalPanelOwningWindow() throws {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 1200, height: 800),
                    workspaceIDs: [firstWorkspace.id],
                    selectedWorkspaceID: firstWorkspace.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 80, y: 80, width: 1200, height: 800),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspace.id: firstWorkspace,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: secondWindowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)
        let sourcePanelID = try XCTUnwrap(firstWorkspace.focusedPanelID)

        XCTAssertTrue(
            registry.openCommandClickLink(
                URL(string: "https://example.com/inside-terminal")!,
                useAlternatePlacement: false,
                from: sourcePanelID
            )
        )

        let firstWorkspaceAfter = try XCTUnwrap(store.state.workspacesByID[firstWorkspace.id])
        let secondWorkspaceAfter = try XCTUnwrap(store.state.workspacesByID[secondWorkspace.id])
        XCTAssertEqual(firstWorkspaceAfter.tabIDs.count, firstWorkspace.tabIDs.count + 1)
        XCTAssertEqual(secondWorkspaceAfter.panels.count, secondWorkspace.panels.count)
        XCTAssertEqual(secondWorkspaceAfter.tabIDs.count, secondWorkspace.tabIDs.count)

        let browserTabID = try XCTUnwrap(firstWorkspaceAfter.resolvedSelectedTabID)
        XCTAssertNotEqual(browserTabID, firstWorkspace.resolvedSelectedTabID)
        let browserTab = try XCTUnwrap(firstWorkspaceAfter.tabsByID[browserTabID])
        XCTAssertEqual(browserTab.panels.count, 1)
        let originalTabID = try XCTUnwrap(firstWorkspace.resolvedSelectedTabID)
        let originalTabAfter = try XCTUnwrap(firstWorkspaceAfter.tabsByID[originalTabID])
        XCTAssertEqual(originalTabAfter.panels.count, firstWorkspace.panels.count)

        guard let browserPanelID = browserTab.focusedPanelID,
              case .web(let webState) = browserTab.panels[browserPanelID] else {
            XCTFail("expected browser panel in source workspace")
            return
        }
        XCTAssertEqual(webState.definition, .browser)
        XCTAssertEqual(webState.initialURL, "https://example.com/inside-terminal")
        try StateValidator.validate(store.state)
    }

    func testAlternateOpenCommandClickLinkUsesConfiguredAlternatePlacement() throws {
        let workspace = WorkspaceState.bootstrap(title: "One")
        let windowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: windowID,
                    frame: CGRectCodable(x: 20, y: 20, width: 1200, height: 800),
                    workspaceIDs: [workspace.id],
                    selectedWorkspaceID: workspace.id
                ),
            ],
            workspacesByID: [workspace.id: workspace],
            selectedWindowID: windowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        store.setURLRoutingPreferences(
            URLRoutingPreferences(
                destination: .toasttyBrowser,
                browserPlacement: .newTab,
                alternateBrowserPlacement: .rootRight
            )
        )
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)
        let sourcePanelID = try XCTUnwrap(workspace.focusedPanelID)

        XCTAssertTrue(
            registry.openCommandClickLink(
                URL(string: "https://example.com/root-right")!,
                useAlternatePlacement: true,
                from: sourcePanelID
            )
        )

        let workspaceAfter = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertEqual(workspaceAfter.tabIDs.count, workspace.tabIDs.count)
        XCTAssertEqual(workspaceAfter.panels.count, workspace.panels.count + 1)
        let focusedPanelID = try XCTUnwrap(workspaceAfter.focusedPanelID)
        guard case .web(let webState) = workspaceAfter.panels[focusedPanelID] else {
            XCTFail("expected root-right browser panel in source workspace")
            return
        }
        XCTAssertEqual(webState.definition, .browser)
        XCTAssertEqual(webState.initialURL, "https://example.com/root-right")
        try StateValidator.validate(store.state)
    }

    func testFocusPanelForImageDropActivatesAppAndRoutesToTargetWindow() throws {
        let firstWorkspace = WorkspaceState.bootstrap(title: "One")
        let leftPanelID = UUID()
        let rightPanelID = UUID()
        let secondWorkspace = WorkspaceState(
            id: UUID(),
            title: "Two",
            layoutTree: .split(
                nodeID: UUID(),
                orientation: .horizontal,
                ratio: 0.5,
                first: .slot(slotID: UUID(), panelID: leftPanelID),
                second: .slot(slotID: UUID(), panelID: rightPanelID)
            ),
            panels: [
                leftPanelID: .terminal(TerminalPanelState(title: "Terminal 1", shell: "zsh", cwd: "/repo/left")),
                rightPanelID: .terminal(TerminalPanelState(title: "Terminal 2", shell: "zsh", cwd: "/repo/right")),
            ],
            focusedPanelID: leftPanelID
        )
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        var activatedWindowIDs: [UUID] = []
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: firstWindowID,
                        frame: CGRectCodable(x: 0, y: 0, width: 800, height: 600),
                        workspaceIDs: [firstWorkspace.id],
                        selectedWorkspaceID: firstWorkspace.id
                    ),
                    WindowState(
                        id: secondWindowID,
                        frame: CGRectCodable(x: 40, y: 40, width: 900, height: 700),
                        workspaceIDs: [secondWorkspace.id],
                        selectedWorkspaceID: secondWorkspace.id
                    ),
                ],
                workspacesByID: [
                    firstWorkspace.id: firstWorkspace,
                    secondWorkspace.id: secondWorkspace,
                ],
                selectedWindowID: firstWindowID
            ),
            persistTerminalFontPreference: false,
            windowActivationHandler: { activatedWindowIDs.append($0) }
        )
        let focusCoordinator = TerminalFocusCoordinator(
            maxAttempts: 1,
            retryDelayNanoseconds: 1,
            isApplicationActive: { false },
            shouldAvoidStealingKeyboardFocus: { false }
        )
        var appActivationCount = 0
        let registry = TerminalRuntimeRegistry(
            focusCoordinator: focusCoordinator,
            activateApp: { appActivationCount += 1 }
        )
        registry.bind(store: store)

        XCTAssertTrue(registry.focusPanelForImageDropIfPossible(rightPanelID))

        XCTAssertEqual(store.state.selectedWindowID, secondWindowID)
        XCTAssertEqual(activatedWindowIDs, [secondWindowID])
        XCTAssertEqual(appActivationCount, 1)
        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[secondWorkspace.id])
        XCTAssertEqual(updatedWorkspace.focusedPanelID, rightPanelID)
        XCTAssertNil(store.pendingPanelFlashRequest)
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
