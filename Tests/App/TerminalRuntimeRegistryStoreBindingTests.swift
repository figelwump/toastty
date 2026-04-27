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
        XCTAssertEqual(firstWorkspaceAfter.tabIDs.count, firstWorkspace.tabIDs.count)
        XCTAssertEqual(firstWorkspaceAfter.panels.count, firstWorkspace.panels.count)
        XCTAssertEqual(firstWorkspaceAfter.rightAuxPanel.tabIDs.count, 1)
        XCTAssertEqual(secondWorkspaceAfter.panels.count, secondWorkspace.panels.count)
        XCTAssertEqual(secondWorkspaceAfter.tabIDs.count, secondWorkspace.tabIDs.count)

        let rightPanelTab = try XCTUnwrap(firstWorkspaceAfter.rightAuxPanel.activeTab)
        guard case .web(let webState) = rightPanelTab.panelState else {
            XCTFail("expected right-panel browser panel in source workspace")
            return
        }
        XCTAssertEqual(webState.definition, .browser)
        XCTAssertEqual(webState.initialURL, "https://example.com/inside-terminal")
        try StateValidator.validate(store.state)
    }

    func testAlternateOpenCommandClickLinkUsesConfiguredAlternateNewTabPlacement() throws {
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
                browserPlacement: .rightPanel,
                alternateBrowserPlacement: .newTab
            )
        )
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)
        let sourcePanelID = try XCTUnwrap(workspace.focusedPanelID)

        XCTAssertTrue(
            registry.openCommandClickLink(
                URL(string: "https://example.com/new-tab")!,
                useAlternatePlacement: true,
                from: sourcePanelID
            )
        )

        let workspaceAfter = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertEqual(workspaceAfter.tabIDs.count, workspace.tabIDs.count + 1)
        let selectedTabID = try XCTUnwrap(workspaceAfter.resolvedSelectedTabID)
        let selectedTab = try XCTUnwrap(workspaceAfter.tabsByID[selectedTabID])
        let panelID = try XCTUnwrap(selectedTab.focusedPanelID)
        guard case .web(let webState) = selectedTab.panels[panelID] else {
            XCTFail("expected browser panel in new tab")
            return
        }
        XCTAssertEqual(webState.definition, .browser)
        XCTAssertEqual(webState.initialURL, "https://example.com/new-tab")
        try StateValidator.validate(store.state)
    }

    func testOpenCommandClickMarkdownRelativePathOpensMarkdownInRightPanelInTerminalOwningWindow() throws {
        let fixture = try makeMarkdownFixture()
        let firstWorkspace = WorkspaceState(
            id: UUID(),
            title: "One",
            layoutTree: .slot(slotID: UUID(), panelID: UUID()),
            panels: [:],
            focusedPanelID: nil
        )
        let firstPanelID = try XCTUnwrap(firstWorkspace.layoutTree.allSlotInfos.first?.panelID)
        let firstWorkspaceWithTerminal = WorkspaceState(
            id: firstWorkspace.id,
            title: firstWorkspace.title,
            layoutTree: firstWorkspace.layoutTree,
            panels: [
                firstPanelID: .terminal(
                    TerminalPanelState(
                        title: "Terminal 1",
                        shell: "zsh",
                        cwd: fixture.rootPath
                    )
                ),
            ],
            focusedPanelID: firstPanelID
        )
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 1200, height: 800),
                    workspaceIDs: [firstWorkspaceWithTerminal.id],
                    selectedWorkspaceID: firstWorkspaceWithTerminal.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 80, y: 80, width: 1200, height: 800),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspaceWithTerminal.id: firstWorkspaceWithTerminal,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: secondWindowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)

        XCTAssertTrue(
            registry.openCommandClickLink(
                try XCTUnwrap(URL(string: "docs/command-palette.md")),
                useAlternatePlacement: false,
                from: firstPanelID
            )
        )

        let firstWorkspaceAfter = try XCTUnwrap(store.state.workspacesByID[firstWorkspaceWithTerminal.id])
        let secondWorkspaceAfter = try XCTUnwrap(store.state.workspacesByID[secondWorkspace.id])
        XCTAssertEqual(firstWorkspaceAfter.tabIDs.count, firstWorkspaceWithTerminal.tabIDs.count)
        XCTAssertEqual(firstWorkspaceAfter.panels.count, firstWorkspaceWithTerminal.panels.count)
        XCTAssertEqual(firstWorkspaceAfter.rightAuxPanel.tabIDs.count, 1)
        XCTAssertEqual(secondWorkspaceAfter.tabIDs.count, secondWorkspace.tabIDs.count)

        let rightPanelTab = try XCTUnwrap(firstWorkspaceAfter.rightAuxPanel.activeTab)
        guard case .web(let webState) = rightPanelTab.panelState else {
            XCTFail("expected right-panel local document panel in source workspace")
            return
        }

        XCTAssertEqual(webState.definition, .localDocument)
        XCTAssertEqual(webState.filePath, fixture.markdownPath)
        XCTAssertEqual(webState.title, "command-palette.md")
        try StateValidator.validate(store.state)
    }

    func testOpenCommandClickMarkdownRelativePathUsesConfiguredLocalDocumentPlacement() throws {
        let fixture = try makeMarkdownFixture()
        var state = AppState.bootstrap()
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        var workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
        let sourcePanelID = try XCTUnwrap(workspace.focusedPanelID)

        guard case .terminal(var terminalState) = workspace.panels[sourcePanelID] else {
            XCTFail("expected bootstrap focused panel to be terminal")
            return
        }
        terminalState.cwd = fixture.rootPath
        workspace.panels[sourcePanelID] = .terminal(terminalState)
        state.workspacesByID[workspaceID] = workspace

        let store = AppStore(state: state, persistTerminalFontPreference: false)
        store.setLocalDocumentRoutingPreferences(
            LocalDocumentRoutingPreferences(
                openingPlacement: .newTab,
                alternateOpeningPlacement: .rightPanel
            )
        )
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)

        XCTAssertTrue(
            registry.openCommandClickLink(
                try XCTUnwrap(URL(string: "docs/command-palette.md")),
                useAlternatePlacement: false,
                from: sourcePanelID
            )
        )

        let workspaceAfter = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspaceAfter.tabIDs.count, workspace.tabIDs.count + 1)
        XCTAssertEqual(workspaceAfter.rightAuxPanel.tabIDs.count, 0)
        let selectedTabID = try XCTUnwrap(workspaceAfter.resolvedSelectedTabID)
        let selectedTab = try XCTUnwrap(workspaceAfter.tab(id: selectedTabID))
        let panelID = try XCTUnwrap(selectedTab.focusedPanelID)
        guard case .web(let webState) = selectedTab.panels[panelID] else {
            XCTFail("expected configured local document placement to open a new tab")
            return
        }

        XCTAssertEqual(webState.definition, .localDocument)
        XCTAssertEqual(webState.filePath, fixture.markdownPath)
        try StateValidator.validate(store.state)
    }

    func testOpenCommandClickYamlRelativePathOpensLocalDocumentInRightPanelInTerminalOwningWindow() throws {
        let fixture = try makeMarkdownFixture(
            fileName: "config.yaml",
            content: "version: 1\nmode: smoke\n"
        )
        let firstWorkspace = WorkspaceState(
            id: UUID(),
            title: "One",
            layoutTree: .slot(slotID: UUID(), panelID: UUID()),
            panels: [:],
            focusedPanelID: nil
        )
        let firstPanelID = try XCTUnwrap(firstWorkspace.layoutTree.allSlotInfos.first?.panelID)
        let firstWorkspaceWithTerminal = WorkspaceState(
            id: firstWorkspace.id,
            title: firstWorkspace.title,
            layoutTree: firstWorkspace.layoutTree,
            panels: [
                firstPanelID: .terminal(
                    TerminalPanelState(
                        title: "Terminal 1",
                        shell: "zsh",
                        cwd: fixture.rootPath
                    )
                ),
            ],
            focusedPanelID: firstPanelID
        )
        let secondWorkspace = WorkspaceState.bootstrap(title: "Two")
        let firstWindowID = UUID()
        let secondWindowID = UUID()
        let state = AppState(
            windows: [
                WindowState(
                    id: firstWindowID,
                    frame: CGRectCodable(x: 0, y: 0, width: 1200, height: 800),
                    workspaceIDs: [firstWorkspaceWithTerminal.id],
                    selectedWorkspaceID: firstWorkspaceWithTerminal.id
                ),
                WindowState(
                    id: secondWindowID,
                    frame: CGRectCodable(x: 80, y: 80, width: 1200, height: 800),
                    workspaceIDs: [secondWorkspace.id],
                    selectedWorkspaceID: secondWorkspace.id
                ),
            ],
            workspacesByID: [
                firstWorkspaceWithTerminal.id: firstWorkspaceWithTerminal,
                secondWorkspace.id: secondWorkspace,
            ],
            selectedWindowID: secondWindowID
        )
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)

        XCTAssertTrue(
            registry.openCommandClickLink(
                try XCTUnwrap(URL(string: "docs/config.yaml")),
                useAlternatePlacement: false,
                from: firstPanelID
            )
        )

        let workspaceAfter = try XCTUnwrap(store.state.workspacesByID[firstWorkspaceWithTerminal.id])
        XCTAssertEqual(workspaceAfter.tabIDs.count, firstWorkspaceWithTerminal.tabIDs.count)
        XCTAssertEqual(workspaceAfter.panels.count, firstWorkspaceWithTerminal.panels.count)
        XCTAssertEqual(workspaceAfter.rightAuxPanel.tabIDs.count, 1)
        let rightPanelTab = try XCTUnwrap(workspaceAfter.rightAuxPanel.activeTab)
        guard case .web(let webState) = rightPanelTab.panelState else {
            XCTFail("expected right-panel local document panel in source workspace")
            return
        }

        XCTAssertEqual(webState.definition, .localDocument)
        XCTAssertEqual(webState.filePath, fixture.markdownPath)
        XCTAssertEqual(webState.localDocument?.format, .yaml)
        try StateValidator.validate(store.state)
    }

    func testOpenCommandClickDirectoryRelativePathCreatesRightSplitTerminal() throws {
        let fixture = try makeDirectoryFixture()
        var state = AppState.bootstrap()
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        var workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
        let sourcePanelID = try XCTUnwrap(workspace.focusedPanelID)

        guard case .terminal(var terminalState) = workspace.panels[sourcePanelID] else {
            XCTFail("expected bootstrap focused panel to be terminal")
            return
        }
        terminalState.cwd = fixture.rootPath
        workspace.panels[sourcePanelID] = .terminal(terminalState)
        state.workspacesByID[workspaceID] = workspace

        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)

        XCTAssertTrue(
            registry.openCommandClickLink(
                try XCTUnwrap(URL(string: "docs/worktrees/demo")),
                useAlternatePlacement: false,
                from: sourcePanelID
            )
        )

        let workspaceAfter = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspaceAfter.tabIDs.count, workspace.tabIDs.count)
        XCTAssertEqual(workspaceAfter.panels.count, workspace.panels.count + 1)

        guard case .split(_, let orientation, _, _, _) = workspaceAfter.layoutTree else {
            XCTFail("expected split root after directory command-click")
            return
        }
        XCTAssertEqual(orientation, .horizontal)

        let focusedPanelID = try XCTUnwrap(workspaceAfter.focusedPanelID)
        guard case .terminal(let newTerminalState) = workspaceAfter.panels[focusedPanelID] else {
            XCTFail("expected focused split panel to be terminal")
            return
        }
        XCTAssertEqual(newTerminalState.cwd, fixture.directoryPath)
        try StateValidator.validate(store.state)
    }

    func testOpenCommandClickMalformedAbsoluteDirectoryPathRecoversLocalDirectory() throws {
        let fixture = try makeDirectoryFixture()
        var state = AppState.bootstrap()
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        var workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
        let sourcePanelID = try XCTUnwrap(workspace.focusedPanelID)

        guard case .terminal(var terminalState) = workspace.panels[sourcePanelID] else {
            XCTFail("expected bootstrap focused panel to be terminal")
            return
        }
        terminalState.cwd = fixture.rootPath
        workspace.panels[sourcePanelID] = .terminal(terminalState)
        state.workspacesByID[workspaceID] = workspace

        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)

        XCTAssertTrue(
            registry.openCommandClickLink(
                try XCTUnwrap(URL(string: "\(fixture.directoryPath) on branch experiment/markdown-as-code.")),
                useAlternatePlacement: false,
                from: sourcePanelID
            )
        )

        let workspaceAfter = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let focusedPanelID = try XCTUnwrap(workspaceAfter.focusedPanelID)
        guard case .terminal(let newTerminalState) = workspaceAfter.panels[focusedPanelID] else {
            XCTFail("expected focused split panel to be terminal")
            return
        }
        XCTAssertEqual(newTerminalState.cwd, fixture.directoryPath)
        try StateValidator.validate(store.state)
    }

    func testAlternateOpenCommandClickDirectoryRelativePathCreatesDownSplitTerminal() throws {
        let fixture = try makeDirectoryFixture()
        var state = AppState.bootstrap()
        let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
        var workspace = try XCTUnwrap(state.workspacesByID[workspaceID])
        let sourcePanelID = try XCTUnwrap(workspace.focusedPanelID)

        guard case .terminal(var terminalState) = workspace.panels[sourcePanelID] else {
            XCTFail("expected bootstrap focused panel to be terminal")
            return
        }
        terminalState.cwd = fixture.rootPath
        workspace.panels[sourcePanelID] = .terminal(terminalState)
        state.workspacesByID[workspaceID] = workspace

        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)

        XCTAssertTrue(
            registry.openCommandClickLink(
                try XCTUnwrap(URL(string: "docs/worktrees/demo")),
                useAlternatePlacement: true,
                from: sourcePanelID
            )
        )

        let workspaceAfter = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(workspaceAfter.tabIDs.count, workspace.tabIDs.count)
        XCTAssertEqual(workspaceAfter.panels.count, workspace.panels.count + 1)

        guard case .split(_, let orientation, _, _, _) = workspaceAfter.layoutTree else {
            XCTFail("expected split root after alternate directory command-click")
            return
        }
        XCTAssertEqual(orientation, .vertical)

        let focusedPanelID = try XCTUnwrap(workspaceAfter.focusedPanelID)
        guard case .terminal(let newTerminalState) = workspaceAfter.panels[focusedPanelID] else {
            XCTFail("expected focused split panel to be terminal")
            return
        }
        XCTAssertEqual(newTerminalState.cwd, fixture.directoryPath)
        try StateValidator.validate(store.state)
    }

    func testAlternateOpenCommandClickMarkdownFileURLUsesNewTabPlacement() throws {
        let fixture = try makeMarkdownFixture()
        let workspace = WorkspaceState(
            id: UUID(),
            title: "One",
            layoutTree: .slot(slotID: UUID(), panelID: UUID()),
            panels: [:],
            focusedPanelID: nil
        )
        let sourcePanelID = try XCTUnwrap(workspace.layoutTree.allSlotInfos.first?.panelID)
        let workspaceWithTerminal = WorkspaceState(
            id: workspace.id,
            title: workspace.title,
            layoutTree: workspace.layoutTree,
            panels: [
                sourcePanelID: .terminal(
                    TerminalPanelState(
                        title: "Terminal 1",
                        shell: "zsh",
                        cwd: fixture.rootPath
                    )
                ),
            ],
            focusedPanelID: sourcePanelID
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 20, y: 20, width: 1200, height: 800),
                        workspaceIDs: [workspaceWithTerminal.id],
                        selectedWorkspaceID: workspaceWithTerminal.id
                    ),
                ],
                workspacesByID: [workspaceWithTerminal.id: workspaceWithTerminal],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)

        XCTAssertTrue(
            registry.openCommandClickLink(
                fixture.markdownURL,
                useAlternatePlacement: true,
                from: sourcePanelID
            )
        )

        let workspaceAfter = try XCTUnwrap(store.state.workspacesByID[workspaceWithTerminal.id])
        XCTAssertEqual(workspaceAfter.tabIDs.count, workspaceWithTerminal.tabIDs.count + 1)
        let selectedTabID = try XCTUnwrap(workspaceAfter.resolvedSelectedTabID)
        let selectedTab = try XCTUnwrap(workspaceAfter.tabsByID[selectedTabID])
        let panelID = try XCTUnwrap(selectedTab.focusedPanelID)
        guard case .web(let webState) = selectedTab.panels[panelID] else {
            XCTFail("expected local document panel in new tab")
            return
        }

        XCTAssertEqual(webState.definition, .localDocument)
        XCTAssertEqual(webState.filePath, fixture.markdownPath)
        try StateValidator.validate(store.state)
    }

    func testOpenCommandClickMalformedAbsoluteMarkdownPathRecoversLocalDocument() throws {
        let fixture = try makeMarkdownFixture(fileName: "toastty-markdown-as-code.md")
        let workspace = WorkspaceState(
            id: UUID(),
            title: "One",
            layoutTree: .slot(slotID: UUID(), panelID: UUID()),
            panels: [:],
            focusedPanelID: nil
        )
        let sourcePanelID = try XCTUnwrap(workspace.layoutTree.allSlotInfos.first?.panelID)
        let workspaceWithTerminal = WorkspaceState(
            id: workspace.id,
            title: workspace.title,
            layoutTree: workspace.layoutTree,
            panels: [
                sourcePanelID: .terminal(
                    TerminalPanelState(
                        title: "Terminal 1",
                        shell: "zsh",
                        cwd: fixture.rootPath
                    )
                ),
            ],
            focusedPanelID: sourcePanelID
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 20, y: 20, width: 1200, height: 800),
                        workspaceIDs: [workspaceWithTerminal.id],
                        selectedWorkspaceID: workspaceWithTerminal.id
                    ),
                ],
                workspacesByID: [workspaceWithTerminal.id: workspaceWithTerminal],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)

        XCTAssertTrue(
            registry.openCommandClickLink(
                try XCTUnwrap(URL(string: "\(fixture.markdownPath) on branch experiment/markdown-as-code.")),
                useAlternatePlacement: false,
                from: sourcePanelID
            )
        )

        let workspaceAfter = try XCTUnwrap(store.state.workspacesByID[workspaceWithTerminal.id])
        XCTAssertEqual(workspaceAfter.tabIDs.count, workspaceWithTerminal.tabIDs.count)
        XCTAssertEqual(workspaceAfter.panels.count, workspaceWithTerminal.panels.count)
        XCTAssertEqual(workspaceAfter.rightAuxPanel.tabIDs.count, 1)
        let rightPanelTab = try XCTUnwrap(workspaceAfter.rightAuxPanel.activeTab)
        guard case .web(let webState) = rightPanelTab.panelState else {
            XCTFail("expected right-panel local document panel in source workspace")
            return
        }

        XCTAssertEqual(webState.definition, .localDocument)
        XCTAssertEqual(webState.filePath, fixture.markdownPath)
        try StateValidator.validate(store.state)
    }

    func testAlternateOpenCommandClickMarkdownKeepsExistingPanelDedupeBehavior() throws {
        let fixture = try makeMarkdownFixture()
        let workspace = WorkspaceState(
            id: UUID(),
            title: "One",
            layoutTree: .slot(slotID: UUID(), panelID: UUID()),
            panels: [:],
            focusedPanelID: nil
        )
        let sourcePanelID = try XCTUnwrap(workspace.layoutTree.allSlotInfos.first?.panelID)
        let workspaceWithTerminal = WorkspaceState(
            id: workspace.id,
            title: workspace.title,
            layoutTree: workspace.layoutTree,
            panels: [
                sourcePanelID: .terminal(
                    TerminalPanelState(
                        title: "Terminal 1",
                        shell: "zsh",
                        cwd: fixture.rootPath
                    )
                ),
            ],
            focusedPanelID: sourcePanelID
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 20, y: 20, width: 1200, height: 800),
                        workspaceIDs: [workspaceWithTerminal.id],
                        selectedWorkspaceID: workspaceWithTerminal.id
                    ),
                ],
                workspacesByID: [workspaceWithTerminal.id: workspaceWithTerminal],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )
        XCTAssertTrue(
            store.createLocalDocumentPanelFromCommand(
                preferredWindowID: windowID,
                request: LocalDocumentPanelCreateRequest(
                    filePath: fixture.markdownPath,
                    placementOverride: .newTab
                )
            )
        )
        let workspaceAfterInitialOpen = try XCTUnwrap(store.state.workspacesByID[workspaceWithTerminal.id])
        let markdownTabID = try XCTUnwrap(workspaceAfterInitialOpen.resolvedSelectedTabID)
        let markdownPanelID = try XCTUnwrap(workspaceAfterInitialOpen.tab(id: markdownTabID)?.focusedPanelID)
        let originalTabID = try XCTUnwrap(workspaceAfterInitialOpen.tabIDs.first)
        XCTAssertTrue(store.send(.selectWorkspaceTab(workspaceID: workspaceWithTerminal.id, tabID: originalTabID)))

        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)

        XCTAssertTrue(
            registry.openCommandClickLink(
                try XCTUnwrap(URL(string: "docs/command-palette.md")),
                useAlternatePlacement: true,
                from: sourcePanelID
            )
        )

        let workspaceAfterDedupedOpen = try XCTUnwrap(store.state.workspacesByID[workspaceWithTerminal.id])
        XCTAssertEqual(workspaceAfterDedupedOpen.tabIDs.count, workspaceAfterInitialOpen.tabIDs.count)
        XCTAssertEqual(workspaceAfterDedupedOpen.resolvedSelectedTabID, markdownTabID)
        XCTAssertEqual(workspaceAfterDedupedOpen.focusedPanelID, markdownPanelID)
        try StateValidator.validate(store.state)
    }

    func testOpenCommandClickMarkdownLineRevealQueuesPendingRevealForCreatedPanelRuntime() throws {
        let fixture = try makeMarkdownFixture()
        let workspace = WorkspaceState(
            id: UUID(),
            title: "One",
            layoutTree: .slot(slotID: UUID(), panelID: UUID()),
            panels: [:],
            focusedPanelID: nil
        )
        let sourcePanelID = try XCTUnwrap(workspace.layoutTree.allSlotInfos.first?.panelID)
        let workspaceWithTerminal = WorkspaceState(
            id: workspace.id,
            title: workspace.title,
            layoutTree: workspace.layoutTree,
            panels: [
                sourcePanelID: .terminal(
                    TerminalPanelState(
                        title: "Terminal 1",
                        shell: "zsh",
                        cwd: fixture.rootPath
                    )
                ),
            ],
            focusedPanelID: sourcePanelID
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 20, y: 20, width: 1200, height: 800),
                        workspaceIDs: [workspaceWithTerminal.id],
                        selectedWorkspaceID: workspaceWithTerminal.id
                    ),
                ],
                workspacesByID: [workspaceWithTerminal.id: workspaceWithTerminal],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )
        let registry = TerminalRuntimeRegistry()
        let webPanelRuntimeRegistry = WebPanelRuntimeRegistry()
        registry.bind(store: store)
        registry.bind(webPanelRuntimeRegistry: webPanelRuntimeRegistry)
        webPanelRuntimeRegistry.bind(store: store)

        XCTAssertTrue(
            registry.openCommandClickLink(
                try XCTUnwrap(URL(string: "docs/command-palette.md:17")),
                useAlternatePlacement: false,
                from: sourcePanelID
            )
        )

        let workspaceAfter = try XCTUnwrap(store.state.workspacesByID[workspaceWithTerminal.id])
        let panelID = try XCTUnwrap(workspaceAfter.rightAuxPanel.activePanelID)
        let runtime = webPanelRuntimeRegistry.localDocumentRuntime(for: panelID)

        XCTAssertEqual(runtime.automationState().pendingRevealLine, 17)
        try StateValidator.validate(store.state)
    }

    func testOpenCommandClickAbsoluteMarkdownLineRevealQueuesPendingRevealForCreatedPanelRuntime() throws {
        let fixture = try makeMarkdownFixture()
        let workspace = WorkspaceState(
            id: UUID(),
            title: "One",
            layoutTree: .slot(slotID: UUID(), panelID: UUID()),
            panels: [:],
            focusedPanelID: nil
        )
        let sourcePanelID = try XCTUnwrap(workspace.layoutTree.allSlotInfos.first?.panelID)
        let workspaceWithTerminal = WorkspaceState(
            id: workspace.id,
            title: workspace.title,
            layoutTree: workspace.layoutTree,
            panels: [
                sourcePanelID: .terminal(
                    TerminalPanelState(
                        title: "Terminal 1",
                        shell: "zsh",
                        cwd: fixture.rootPath
                    )
                ),
            ],
            focusedPanelID: sourcePanelID
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 20, y: 20, width: 1200, height: 800),
                        workspaceIDs: [workspaceWithTerminal.id],
                        selectedWorkspaceID: workspaceWithTerminal.id
                    ),
                ],
                workspacesByID: [workspaceWithTerminal.id: workspaceWithTerminal],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )
        let registry = TerminalRuntimeRegistry()
        let webPanelRuntimeRegistry = WebPanelRuntimeRegistry()
        registry.bind(store: store)
        registry.bind(webPanelRuntimeRegistry: webPanelRuntimeRegistry)
        webPanelRuntimeRegistry.bind(store: store)

        XCTAssertTrue(
            registry.openCommandClickLink(
                try XCTUnwrap(URL(string: "\(fixture.markdownPath):17")),
                useAlternatePlacement: false,
                from: sourcePanelID
            )
        )

        let workspaceAfter = try XCTUnwrap(store.state.workspacesByID[workspaceWithTerminal.id])
        let panelID = try XCTUnwrap(workspaceAfter.rightAuxPanel.activePanelID)
        let runtime = webPanelRuntimeRegistry.localDocumentRuntime(for: panelID)

        XCTAssertEqual(runtime.automationState().pendingRevealLine, 17)
        try StateValidator.validate(store.state)
    }

    func testOpenCommandClickRecoversNestedRelativeChildPathForLocalDocumentReveal() throws {
        let fixture = try makeNestedChildDocumentFixture()
        let workspace = WorkspaceState(
            id: UUID(),
            title: "One",
            layoutTree: .slot(slotID: UUID(), panelID: UUID()),
            panels: [:],
            focusedPanelID: nil
        )
        let sourcePanelID = try XCTUnwrap(workspace.layoutTree.allSlotInfos.first?.panelID)
        let workspaceWithTerminal = WorkspaceState(
            id: workspace.id,
            title: workspace.title,
            layoutTree: workspace.layoutTree,
            panels: [
                sourcePanelID: .terminal(
                    TerminalPanelState(
                        title: "Terminal 1",
                        shell: "zsh",
                        cwd: fixture.rootPath
                    )
                ),
            ],
            focusedPanelID: sourcePanelID
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 20, y: 20, width: 1200, height: 800),
                        workspaceIDs: [workspaceWithTerminal.id],
                        selectedWorkspaceID: workspaceWithTerminal.id
                    ),
                ],
                workspacesByID: [workspaceWithTerminal.id: workspaceWithTerminal],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )
        let registry = TerminalRuntimeRegistry()
        let webPanelRuntimeRegistry = WebPanelRuntimeRegistry()
        registry.bind(store: store)
        registry.bind(webPanelRuntimeRegistry: webPanelRuntimeRegistry)
        webPanelRuntimeRegistry.bind(store: store)

        XCTAssertTrue(
            registry.openCommandClickLink(
                try XCTUnwrap(URL(string: "Sources/App/TerminalHostView.swift:89")),
                useAlternatePlacement: false,
                from: sourcePanelID
            )
        )

        let workspaceAfter = try XCTUnwrap(store.state.workspacesByID[workspaceWithTerminal.id])
        let panelID = try XCTUnwrap(workspaceAfter.rightAuxPanel.activePanelID)
        guard case .web(let webState)? = workspaceAfter.rightAuxPanel.panelState(for: panelID) else {
            XCTFail("expected recovered nested-child link to open a right-panel local document")
            return
        }

        XCTAssertEqual(webState.filePath, fixture.documentPath)
        XCTAssertEqual(
            webPanelRuntimeRegistry.localDocumentRuntime(for: panelID).automationState().pendingRevealLine,
            89
        )
        try StateValidator.validate(store.state)
    }

    func testOpenCommandClickUnresolvedRelativeLocalDocumentPathDoesNotCreatePanel() throws {
        let fixture = try makeMarkdownFixture()
        let workspace = WorkspaceState(
            id: UUID(),
            title: "One",
            layoutTree: .slot(slotID: UUID(), panelID: UUID()),
            panels: [:],
            focusedPanelID: nil
        )
        let sourcePanelID = try XCTUnwrap(workspace.layoutTree.allSlotInfos.first?.panelID)
        let workspaceWithTerminal = WorkspaceState(
            id: workspace.id,
            title: workspace.title,
            layoutTree: workspace.layoutTree,
            panels: [
                sourcePanelID: .terminal(
                    TerminalPanelState(
                        title: "Terminal 1",
                        shell: "zsh",
                        cwd: fixture.rootPath
                    )
                ),
            ],
            focusedPanelID: sourcePanelID
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 20, y: 20, width: 1200, height: 800),
                        workspaceIDs: [workspaceWithTerminal.id],
                        selectedWorkspaceID: workspaceWithTerminal.id
                    ),
                ],
                workspacesByID: [workspaceWithTerminal.id: workspaceWithTerminal],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )
        var presentedAlert: (
            windowID: UUID?,
            url: URL,
            issue: LocalFileLinkResolver.UnresolvedLocalDocumentIssue
        )?
        let registry = TerminalRuntimeRegistry(
            presentLocalDocumentLinkAlert: { windowID, url, issue in
                presentedAlert = (windowID, url, issue)
            }
        )
        registry.bind(store: store)

        let missingURL = try XCTUnwrap(URL(string: "docs/missing-plan.md:17"))

        XCTAssertFalse(
            registry.openCommandClickLink(
                missingURL,
                useAlternatePlacement: false,
                from: sourcePanelID
            )
        )

        let workspaceAfter = try XCTUnwrap(store.state.workspacesByID[workspaceWithTerminal.id])
        XCTAssertEqual(workspaceAfter.tabIDs.count, workspaceWithTerminal.tabIDs.count)
        XCTAssertEqual(workspaceAfter.focusedPanelID, sourcePanelID)
        XCTAssertEqual(presentedAlert?.windowID, windowID)
        XCTAssertEqual(presentedAlert?.url, missingURL)
        XCTAssertEqual(presentedAlert?.issue, .fileNotFound)
        try StateValidator.validate(store.state)
    }

    func testOpenCommandClickInvalidLineNumberShowsAlertWithoutCreatingPanel() throws {
        let fixture = try makeMarkdownFixture()
        let workspace = WorkspaceState(
            id: UUID(),
            title: "One",
            layoutTree: .slot(slotID: UUID(), panelID: UUID()),
            panels: [:],
            focusedPanelID: nil
        )
        let sourcePanelID = try XCTUnwrap(workspace.layoutTree.allSlotInfos.first?.panelID)
        let workspaceWithTerminal = WorkspaceState(
            id: workspace.id,
            title: workspace.title,
            layoutTree: workspace.layoutTree,
            panels: [
                sourcePanelID: .terminal(
                    TerminalPanelState(
                        title: "Terminal 1",
                        shell: "zsh",
                        cwd: fixture.rootPath
                    )
                ),
            ],
            focusedPanelID: sourcePanelID
        )
        let windowID = UUID()
        let store = AppStore(
            state: AppState(
                windows: [
                    WindowState(
                        id: windowID,
                        frame: CGRectCodable(x: 20, y: 20, width: 1200, height: 800),
                        workspaceIDs: [workspaceWithTerminal.id],
                        selectedWorkspaceID: workspaceWithTerminal.id
                    ),
                ],
                workspacesByID: [workspaceWithTerminal.id: workspaceWithTerminal],
                selectedWindowID: windowID
            ),
            persistTerminalFontPreference: false
        )
        var presentedAlert: (
            windowID: UUID?,
            url: URL,
            issue: LocalFileLinkResolver.UnresolvedLocalDocumentIssue
        )?
        let registry = TerminalRuntimeRegistry(
            presentLocalDocumentLinkAlert: { windowID, url, issue in
                presentedAlert = (windowID, url, issue)
            }
        )
        registry.bind(store: store)
        let invalidLineURL = try XCTUnwrap(URL(string: "docs/command-palette.md:0"))

        XCTAssertFalse(
            registry.openCommandClickLink(
                invalidLineURL,
                useAlternatePlacement: false,
                from: sourcePanelID
            )
        )

        let workspaceAfter = try XCTUnwrap(store.state.workspacesByID[workspaceWithTerminal.id])
        XCTAssertEqual(workspaceAfter.tabIDs.count, workspaceWithTerminal.tabIDs.count)
        XCTAssertEqual(workspaceAfter.focusedPanelID, sourcePanelID)
        XCTAssertEqual(presentedAlert?.windowID, windowID)
        XCTAssertEqual(presentedAlert?.url, invalidLineURL)
        XCTAssertEqual(presentedAlert?.issue, .invalidLineNumber)
        try StateValidator.validate(store.state)
    }

    func testOpenSearchSelectionURLUsesConfiguredURLPlacement() throws {
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
                browserPlacement: .rightPanel,
                alternateBrowserPlacement: .newTab
            )
        )
        let registry = TerminalRuntimeRegistry()
        registry.bind(store: store)
        let sourcePanelID = try XCTUnwrap(workspace.focusedPanelID)

        XCTAssertTrue(
            registry.openSearchSelectionURL(
                URL(string: "https://www.google.com/search?q=toastty")!,
                from: sourcePanelID
            )
        )

        let workspaceAfter = try XCTUnwrap(store.state.workspacesByID[workspace.id])
        XCTAssertEqual(workspaceAfter.tabIDs.count, workspace.tabIDs.count)
        XCTAssertEqual(workspaceAfter.rightAuxPanel.tabIDs.count, 1)
        let rightPanelTab = try XCTUnwrap(workspaceAfter.rightAuxPanel.activeTab)
        guard case .web(let webState) = rightPanelTab.panelState else {
            XCTFail("expected search selection to open in a right-panel Toastty browser")
            return
        }
        XCTAssertEqual(webState.definition, .browser)
        XCTAssertEqual(webState.initialURL, "https://www.google.com/search?q=toastty")
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
    func testDecodedProcessExecutablePathUsesExactReportedByteCount() {
        let path = "/opt/homebrew/bin/fish"
        let pathBuffer = Array(path.utf8CString)

        XCTAssertEqual(
            TerminalProcessWorkingDirectoryResolver.decodedProcessExecutablePath(
                from: pathBuffer,
                byteCount: path.utf8.count
            ),
            path
        )
    }

    func testDecodedProcessExecutablePathReturnsNilWhenReportedByteCountIsZero() {
        XCTAssertNil(
            TerminalProcessWorkingDirectoryResolver.decodedProcessExecutablePath(
                from: [0],
                byteCount: 0
            )
        )
    }

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

private extension TerminalRuntimeRegistryStoreBindingTests {
    func makeMarkdownFixture(
        fileName: String = "command-palette.md",
        content: String = "# Command Palette\n"
    ) throws -> (rootPath: String, markdownPath: String, markdownURL: URL) {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-registry-markdown-link-tests-\(UUID().uuidString)", isDirectory: true)
        let docsURL = rootURL.appendingPathComponent("docs", isDirectory: true)
        let markdownURL = docsURL.appendingPathComponent(fileName, isDirectory: false)

        try fileManager.createDirectory(at: docsURL, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: markdownURL)
        addTeardownBlock {
            try? fileManager.removeItem(at: rootURL)
        }

        return (
            rootPath: rootURL.standardizedFileURL.resolvingSymlinksInPath().path,
            markdownPath: markdownURL.standardizedFileURL.resolvingSymlinksInPath().path,
            markdownURL: markdownURL
        )
    }

    func makeNestedChildDocumentFixture() throws -> (rootPath: String, documentPath: String) {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-registry-nested-child-link-tests-\(UUID().uuidString)", isDirectory: true)
        let documentURL = rootURL
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("App", isDirectory: true)
            .appendingPathComponent("Terminal", isDirectory: true)
            .appendingPathComponent("TerminalHostView.swift", isDirectory: false)

        try fileManager.createDirectory(at: documentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("struct TerminalHostView {}\n".utf8).write(to: documentURL)
        addTeardownBlock {
            try? fileManager.removeItem(at: rootURL)
        }

        return (
            rootPath: rootURL.standardizedFileURL.resolvingSymlinksInPath().path,
            documentPath: documentURL.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }

    func makeDirectoryFixture() throws -> (rootPath: String, directoryPath: String) {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("toastty-registry-directory-link-tests-\(UUID().uuidString)", isDirectory: true)
        let directoryURL = rootURL
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent("demo", isDirectory: true)

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? fileManager.removeItem(at: rootURL)
        }

        return (
            rootPath: rootURL.standardizedFileURL.resolvingSymlinksInPath().path,
            directoryPath: directoryURL.standardizedFileURL.path
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
        promptState: TerminalPromptState,
        at now: Date
    ) -> Bool {
        _ = panelID
        _ = visibleText
        _ = promptState
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

    func handleCommandFinished(panelID: UUID, exitCode: Int?, at now: Date) -> Bool {
        _ = now
        stopActiveCalls.append(
            .init(
                panelID: panelID,
                reason: .ghosttyCommandFinished(exitCode: exitCode)
            )
        )
        return true
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
