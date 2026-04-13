#if TOASTTY_HAS_GHOSTTY_KIT
@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class TerminalMetadataServiceTests: XCTestCase {
    func testRestoredProfiledPaneSuppressesTransientTitleUntilLiveCWDArrives() async throws {
        let state = makeRestoredProfiledPanelState(profileID: "zmx")
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let profileProvider = TestTerminalProfileProvider(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach toastty.$TOASTTY_PANEL_ID"
                ),
            ]
        )
        registry.setTerminalProfileProvider(
            profileProvider,
            restoredTerminalPanelIDs: [panelID]
        )
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in nil },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalTitle("zmx attach toastty.$TOASTTY_PANEL_ID"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )

        let terminalState = try terminalState(panelID: panelID, state: store.state)
        XCTAssertEqual(terminalState.title, "Terminal 1")
        XCTAssertEqual(terminalState.cwd, "")
        try StateValidator.validate(store.state)
    }

    func testRestoredProfiledPaneAcceptsTitleUpdatesAfterLiveCWDArrives() async throws {
        let state = makeRestoredProfiledPanelState(profileID: "zmx")
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let profileProvider = TestTerminalProfileProvider(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach toastty.$TOASTTY_PANEL_ID"
                ),
            ]
        )
        registry.setTerminalProfileProvider(
            profileProvider,
            restoredTerminalPanelIDs: [panelID]
        )
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in nil },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalTitle("zmx attach toastty.$TOASTTY_PANEL_ID"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )
        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalCWD("/tmp/restored"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )
        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalTitle("bundle exec rspec"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )

        let terminalState = try terminalState(panelID: panelID, state: store.state)
        XCTAssertEqual(terminalState.cwd, "/tmp/restored")
        XCTAssertEqual(terminalState.title, "bundle exec rspec")
        try StateValidator.validate(store.state)
    }

    func testRestoredProfiledPaneSuppressesStartupCommandTitleAfterLiveCWDArrives() async throws {
        let state = makeRestoredProfiledPanelState(profileID: "zmx")
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let profileProvider = TestTerminalProfileProvider(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach toastty.$TOASTTY_PANEL_ID"
                ),
            ]
        )
        registry.setTerminalProfileProvider(
            profileProvider,
            restoredTerminalPanelIDs: [panelID]
        )
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in nil },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalCWD("/tmp/restored"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )
        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalTitle("/tmp/restored"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )
        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalTitle("zmx attach toastty.$TOASTTY_PANEL_ID"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )

        let terminalState = try terminalState(panelID: panelID, state: store.state)
        XCTAssertEqual(terminalState.cwd, "/tmp/restored")
        XCTAssertEqual(terminalState.title, "/tmp/restored")
        try StateValidator.validate(store.state)
    }

    func testLaunchedProfiledPaneSuppressesMatchingStartupCommandTitleBeforeInitialLaunchCompletion() async throws {
        let state = makeRestoredProfiledPanelState(profileID: "zmx")
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let profileProvider = TestTerminalProfileProvider(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach toastty.$TOASTTY_PANEL_ID"
                ),
            ]
        )
        registry.setTerminalProfileProvider(
            profileProvider,
            restoredTerminalPanelIDs: []
        )
        registry.bind(store: store)
        XCTAssertEqual(
            registry.surfaceLaunchConfiguration(for: panelID).initialInput,
            "zmx attach toastty.$TOASTTY_PANEL_ID"
        )
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in nil },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalTitle("zmx attach toastty.$TOASTTY_PANEL_ID"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )

        let terminalState = try terminalState(panelID: panelID, state: store.state)
        XCTAssertEqual(terminalState.title, "Terminal 1")
        XCTAssertEqual(terminalState.cwd, "")
        try StateValidator.validate(store.state)
    }

    func testLaunchedProfiledPaneDoesNotSuppressMeaningfulStartupCommandTitle() async throws {
        let state = makeRestoredProfiledPanelState(profileID: "dev")
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let profileProvider = TestTerminalProfileProvider(
            profiles: [
                TerminalProfile(
                    id: "dev",
                    displayName: "Dev",
                    badgeLabel: "DEV",
                    startupCommand: "npm run dev"
                ),
            ]
        )
        registry.setTerminalProfileProvider(
            profileProvider,
            restoredTerminalPanelIDs: []
        )
        registry.bind(store: store)
        XCTAssertEqual(
            registry.surfaceLaunchConfiguration(for: panelID).initialInput,
            "npm run dev"
        )
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in nil },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalTitle("npm run dev"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )

        let terminalState = try terminalState(panelID: panelID, state: store.state)
        XCTAssertEqual(terminalState.title, "npm run dev")
        XCTAssertEqual(terminalState.cwd, "")
        try StateValidator.validate(store.state)
    }

    func testNonRestoredProfiledPaneDoesNotSuppressMatchingStartupCommandTitle() async throws {
        let state = makeRestoredProfiledPanelState(profileID: "zmx")
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let profileProvider = TestTerminalProfileProvider(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach toastty.$TOASTTY_PANEL_ID"
                ),
            ]
        )
        registry.setTerminalProfileProvider(
            profileProvider,
            restoredTerminalPanelIDs: []
        )
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in nil },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalTitle("zmx attach toastty.$TOASTTY_PANEL_ID"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )

        let terminalState = try terminalState(panelID: panelID, state: store.state)
        XCTAssertEqual(terminalState.title, "zmx attach toastty.$TOASTTY_PANEL_ID")
        XCTAssertEqual(terminalState.cwd, "")
        try StateValidator.validate(store.state)
    }

    func testRestoredProfiledPaneStopsSuppressingAfterDifferentRuntimeTitleArrives() async throws {
        let state = makeRestoredProfiledPanelState(profileID: "zmx")
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let profileProvider = TestTerminalProfileProvider(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach toastty.$TOASTTY_PANEL_ID"
                ),
            ]
        )
        registry.setTerminalProfileProvider(
            profileProvider,
            restoredTerminalPanelIDs: [panelID]
        )
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in nil },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalTitle("bundle exec rspec"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )
        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalTitle("zmx attach toastty.$TOASTTY_PANEL_ID"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )

        let terminalState = try terminalState(panelID: panelID, state: store.state)
        XCTAssertEqual(terminalState.title, "zmx attach toastty.$TOASTTY_PANEL_ID")
        XCTAssertEqual(terminalState.cwd, "")
        try StateValidator.validate(store.state)
    }

    func testRestoredProfiledPaneSuppressesBootstrapNativeCWDAndProcessFallback() async throws {
        let state = makeRestoredProfiledPanelState(profileID: "zmx")
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let profileProvider = TestTerminalProfileProvider(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach toastty.$TOASTTY_PANEL_ID"
                ),
            ]
        )
        registry.setTerminalProfileProvider(
            profileProvider,
            restoredTerminalPanelIDs: [panelID]
        )
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in "/tmp/bootstrap-shell" },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalCWD("/tmp/bootstrap-shell"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )

        let restoredTerminalState = try terminalState(panelID: panelID, state: store.state)
        XCTAssertEqual(restoredTerminalState.cwd, "")
        XCTAssertEqual(restoredTerminalState.displayPanelLabel, "zsh")
        XCTAssertFalse(service.prefersNativeCWDSignal(panelID: panelID))
        XCTAssertNil(
            service.refreshWorkingDirectoryFromProcessIfNeeded(
                panelID: panelID,
                source: "process_poll"
            )
        )
        XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).cwd, "")
        try StateValidator.validate(store.state)
    }

    func testRestoredProfiledPaneIgnoresBlankNativeCWDWithoutDisablingFallback() async throws {
        let state = makeRestoredProfiledPanelState(profileID: "zmx")
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let profileProvider = TestTerminalProfileProvider(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach toastty.$TOASTTY_PANEL_ID"
                ),
            ]
        )
        registry.setTerminalProfileProvider(
            profileProvider,
            restoredTerminalPanelIDs: [panelID]
        )
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in "/tmp/bootstrap-shell" },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalCWD("/tmp/bootstrap-shell"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )
        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalCWD("   "),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )

        let terminalState = try terminalState(panelID: panelID, state: store.state)
        XCTAssertEqual(terminalState.cwd, "")
        XCTAssertFalse(service.prefersNativeCWDSignal(panelID: panelID))
        try StateValidator.validate(store.state)
    }

    func testRestoredProfiledPaneKeepsStartupWrapperTitleSuppressedAfterBootstrapCWDIsSuppressed() async throws {
        let state = makeRestoredProfiledPanelState(profileID: "zmx")
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let profileProvider = TestTerminalProfileProvider(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach toastty.$TOASTTY_PANEL_ID"
                ),
            ]
        )
        registry.setTerminalProfileProvider(
            profileProvider,
            restoredTerminalPanelIDs: [panelID]
        )
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in nil },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalCWD("/tmp/bootstrap-shell"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalTitle("zmx attach toastty.$TOASTTY_PANEL_ID"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )

        let ts = try terminalState(panelID: panelID, state: store.state)
        XCTAssertEqual(ts.title, "Terminal 1")
        XCTAssertEqual(ts.cwd, "")
        XCTAssertFalse(service.prefersNativeCWDSignal(panelID: panelID))
        try StateValidator.validate(store.state)
    }

    func testRestoredProfiledPaneInfersCWDFromTitleAfterBootstrapCWDIsSuppressed() async throws {
        let state = makeRestoredProfiledPanelState(profileID: "zmx")
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let profileProvider = TestTerminalProfileProvider(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach toastty.$TOASTTY_PANEL_ID"
                ),
            ]
        )
        registry.setTerminalProfileProvider(
            profileProvider,
            restoredTerminalPanelIDs: [panelID]
        )
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in nil },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalCWD("/tmp/bootstrap-shell"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )
        XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).cwd, "")
        XCTAssertFalse(service.prefersNativeCWDSignal(panelID: panelID))

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalTitle("/tmp/new-directory"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )

        let ts = try terminalState(panelID: panelID, state: store.state)
        XCTAssertEqual(ts.cwd, "/tmp/new-directory")
        try StateValidator.validate(store.state)
    }

    func testRestoredProfiledPaneUpdatesCWDFromTitleOnDirectoryChange() async throws {
        let state = makeRestoredProfiledPanelState(profileID: "zmx")
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let profileProvider = TestTerminalProfileProvider(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach toastty.$TOASTTY_PANEL_ID"
                ),
            ]
        )
        registry.setTerminalProfileProvider(
            profileProvider,
            restoredTerminalPanelIDs: [panelID]
        )
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in nil },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalCWD("/tmp/bootstrap-shell"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalTitle("/tmp/first-dir"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )
        XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).cwd, "/tmp/first-dir")

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalTitle("/tmp/second-dir"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )
        XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).cwd, "/tmp/second-dir")

        // Non-path title (e.g., running a command) should NOT update CWD.
        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalTitle("vim"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )
        XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).cwd, "/tmp/second-dir")

        try StateValidator.validate(store.state)
    }

    func testSplitInheritsCorrectedCWDFromRestoredProfiledPaneAfterTitleInference() async throws {
        let state = makeRestoredProfiledPanelState(profileID: "zmx")
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let profileProvider = TestTerminalProfileProvider(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach toastty.$TOASTTY_PANEL_ID"
                ),
            ]
        )
        registry.setTerminalProfileProvider(
            profileProvider,
            restoredTerminalPanelIDs: [panelID]
        )
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in nil },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalCWD("/tmp/bootstrap-shell"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )
        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalTitle("/tmp/corrected"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )

        let previousPanelIDs = Set(try XCTUnwrap(store.state.workspacesByID[workspaceID]?.panels.keys))
        XCTAssertTrue(store.send(.splitFocusedSlot(workspaceID: workspaceID, orientation: .horizontal)))
        let workspaceAfter = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let newPanelID = try XCTUnwrap(Set(workspaceAfter.panels.keys).subtracting(previousPanelIDs).first)
        guard case .terminal(let terminalState) = workspaceAfter.panels[newPanelID] else {
            XCTFail("expected split panel to be terminal")
            return
        }
        XCTAssertEqual(terminalState.cwd, "/tmp/corrected")
        try StateValidator.validate(store.state)
    }

    func testRestoredProfiledPaneAcceptsFirstRealNativeCWDAfterBootstrapCWDIsSuppressed() async throws {
        let state = makeRestoredProfiledPanelState(profileID: "zmx")
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let profileProvider = TestTerminalProfileProvider(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach toastty.$TOASTTY_PANEL_ID"
                ),
            ]
        )
        registry.setTerminalProfileProvider(
            profileProvider,
            restoredTerminalPanelIDs: [panelID]
        )
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in "/tmp/bootstrap-shell" },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalCWD("/tmp/bootstrap-shell"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )
        XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).cwd, "")
        XCTAssertFalse(service.prefersNativeCWDSignal(panelID: panelID))

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalCWD("/tmp/live-session"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )

        let terminalState = try terminalState(panelID: panelID, state: store.state)
        XCTAssertEqual(terminalState.cwd, "/tmp/live-session")
        XCTAssertTrue(service.prefersNativeCWDSignal(panelID: panelID))
        XCTAssertNil(
            service.refreshWorkingDirectoryFromProcessIfNeeded(
                panelID: panelID,
                source: "process_poll"
            )
        )
        try StateValidator.validate(store.state)
    }

    func testRestoredProfiledPaneAcceptsMatchingStartupNativeCWDWithoutSubstitution() async throws {
        let state = makeRestoredProfiledPanelState(profileID: "zmx")
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let profileProvider = TestTerminalProfileProvider(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach toastty.$TOASTTY_PANEL_ID"
                ),
            ]
        )
        registry.setTerminalProfileProvider(
            profileProvider,
            restoredTerminalPanelIDs: [panelID]
        )
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in "/tmp/process-fallback" },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalCWD("/tmp/restored"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )

        let terminalState = try terminalState(panelID: panelID, state: store.state)
        XCTAssertEqual(terminalState.cwd, "/tmp/restored")
        XCTAssertTrue(service.prefersNativeCWDSignal(panelID: panelID))
        XCTAssertNil(
            service.refreshWorkingDirectoryFromProcessIfNeeded(
                panelID: panelID,
                source: "process_poll"
            )
        )
        try StateValidator.validate(store.state)
    }

    func testRestoredUnprofiledPaneAcceptsNativeCWDWithoutSubstitution() async throws {
        let state = makeRestoredUnprofiledPanelState()
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in "/tmp/process-fallback" },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalCWD("/tmp/bootstrap-shell"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )

        let terminalState = try terminalState(panelID: panelID, state: store.state)
        XCTAssertEqual(terminalState.cwd, "/tmp/bootstrap-shell")
        XCTAssertTrue(service.prefersNativeCWDSignal(panelID: panelID))
        XCTAssertNil(
            service.refreshWorkingDirectoryFromProcessIfNeeded(
                panelID: panelID,
                source: "process_poll"
            )
        )
        try StateValidator.validate(store.state)
    }

    func testNativeGhosttyCWDDisablesProcessFallbackUpdates() async throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in "/tmp/wrong" },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalCWD("/tmp/native"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )

        XCTAssertTrue(service.prefersNativeCWDSignal(panelID: panelID))
        XCTAssertFalse(service.shouldRunProcessCWDFallbackPoll(panelID: panelID, now: .distantFuture))
        XCTAssertNil(
            service.refreshWorkingDirectoryFromProcessIfNeeded(
                panelID: panelID,
                source: "process_poll"
            )
        )
        XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).cwd, "/tmp/native")
        try StateValidator.validate(store.state)
    }

    func testRequestImmediateWorkingDirectoryRefreshDefersFirstAttemptOffCallerStack() async throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        XCTAssertTrue(
            store.send(.updateTerminalPanelMetadata(panelID: panelID, title: nil, cwd: "/tmp/stale"))
        )

        var resolveAttemptCount = 0
        let initialDeferralGate = AsyncGate()
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in
                resolveAttemptCount += 1
                return "/tmp/fresh"
            },
            initialProcessRefreshDeferral: {
                await initialDeferralGate.wait()
            },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        service.requestImmediateWorkingDirectoryRefresh(
            panelID: panelID,
            source: "surface_create_process"
        )

        XCTAssertEqual(resolveAttemptCount, 0)
        XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).cwd, "/tmp/stale")

        await initialDeferralGate.open()
        await waitUntil {
            resolveAttemptCount == 1 &&
                (try? terminalState(panelID: panelID, state: store.state).cwd) == "/tmp/fresh"
        }

        XCTAssertEqual(resolveAttemptCount, 1)
        XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).cwd, "/tmp/fresh")
        try StateValidator.validate(store.state)
    }

    func testImmediateProcessRefreshSkipsDeferredFirstAttemptAfterNativeGhosttyCWDSignal() async throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)

        var resolveAttemptCount = 0
        let initialDeferralGate = AsyncGate()
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in
                resolveAttemptCount += 1
                return "/tmp/process"
            },
            initialProcessRefreshDeferral: {
                await initialDeferralGate.wait()
            },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        service.requestImmediateWorkingDirectoryRefresh(
            panelID: panelID,
            source: "surface_create_process"
        )

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalCWD("/tmp/native"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )

        await initialDeferralGate.open()
        await settleMetadataTasks()

        XCTAssertEqual(resolveAttemptCount, 0)
        XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).cwd, "/tmp/native")
        XCTAssertTrue(service.prefersNativeCWDSignal(panelID: panelID))
        try StateValidator.validate(store.state)
    }

    func testImmediateProcessRefreshStopsRetryingAfterNativeGhosttyCWDSignal() async throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)

        var resolveAttemptCount = 0
        let delayGate = AsyncGate()
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in
                resolveAttemptCount += 1
                return nil
            },
            processRefreshRetryDelay: { _ in
                await delayGate.wait()
            }
        )

        service.requestImmediateWorkingDirectoryRefresh(
            panelID: panelID,
            source: "surface_create_process"
        )
        await waitUntil { resolveAttemptCount == 1 }

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalCWD("/tmp/native"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )

        await delayGate.open()
        await settleMetadataTasks()

        XCTAssertEqual(resolveAttemptCount, 1)
        XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).cwd, "/tmp/native")
        try StateValidator.validate(store.state)
    }

    func testRequestImmediateWorkingDirectoryRefreshRetriesUntilProcessResolverSucceeds() async throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        XCTAssertTrue(
            store.send(.updateTerminalPanelMetadata(panelID: panelID, title: nil, cwd: "/tmp/stale"))
        )

        var resolveAttemptCount = 0
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in
                resolveAttemptCount += 1
                return resolveAttemptCount >= 3 ? "/tmp/fresh" : nil
            },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        service.requestImmediateWorkingDirectoryRefresh(
            panelID: panelID,
            source: "surface_create_process"
        )
        await waitUntil {
            resolveAttemptCount == 3 &&
                (try? terminalState(panelID: panelID, state: store.state).cwd) == "/tmp/fresh"
        }

        XCTAssertEqual(resolveAttemptCount, 3)
        XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).cwd, "/tmp/fresh")
        try StateValidator.validate(store.state)
    }

    func testImmediateProcessRefreshDoesNotClobberRestoredTitleInferredCWD() throws {
        let state = makeRestoredUnprofiledPanelState()
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in "/tmp/other" },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalTitle("/tmp/restored"),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )
        XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).cwd, "/tmp/restored")
        XCTAssertFalse(service.prefersNativeCWDSignal(panelID: panelID))

        XCTAssertNil(
            service.refreshWorkingDirectoryFromProcessIfNeeded(
                panelID: panelID,
                source: "surface_create_process_retry_1"
            )
        )

        let restoredTerminalState = try terminalState(panelID: panelID, state: store.state)
        XCTAssertEqual(restoredTerminalState.cwd, "/tmp/restored")

        let snapshot = WorkspaceLayoutSnapshot(state: store.state)
        guard case .terminal(let terminalSnapshot) = snapshot.workspacesByID[workspaceID]?.panels[panelID] else {
            XCTFail("expected terminal snapshot")
            return
        }
        XCTAssertEqual(terminalSnapshot.launchWorkingDirectory, "/tmp/restored")
        try StateValidator.validate(store.state)
    }

    func testImmediateProcessRefreshAcceptsRestoredLaunchSeedWhenProcessCWDMatches() throws {
        let state = makeRestoredUnprofiledPanelState()
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in "/tmp/restored" },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).cwd, "")
        XCTAssertEqual(
            service.refreshWorkingDirectoryFromProcessIfNeeded(
                panelID: panelID,
                source: "surface_create_process_retry_1"
            ),
            "/tmp/restored"
        )
        XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).cwd, "/tmp/restored")
        try StateValidator.validate(store.state)
    }

    func testRequestImmediateWorkingDirectoryRefreshSuppressesRepeatedBootstrapCWDForRestoredProfiledPane() async throws {
        let state = makeRestoredProfiledPanelState(profileID: "zmx")
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let profileProvider = TestTerminalProfileProvider(
            profiles: [
                TerminalProfile(
                    id: "zmx",
                    displayName: "ZMX",
                    badgeLabel: "ZMX",
                    startupCommand: "zmx attach toastty.$TOASTTY_PANEL_ID"
                ),
            ]
        )
        registry.setTerminalProfileProvider(
            profileProvider,
            restoredTerminalPanelIDs: [panelID]
        )

        var resolveAttemptCount = 0
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in
                resolveAttemptCount += 1
                return "/tmp/bootstrap-shell"
            },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        service.requestImmediateWorkingDirectoryRefresh(
            panelID: panelID,
            source: "surface_create_process"
        )
        await waitUntil {
            resolveAttemptCount == TerminalMetadataService.immediateProcessRefreshAttemptCount
        }

        XCTAssertEqual(
            resolveAttemptCount,
            TerminalMetadataService.immediateProcessRefreshAttemptCount
        )
        XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).cwd, "")
        XCTAssertFalse(service.prefersNativeCWDSignal(panelID: panelID))
        XCTAssertTrue(service.shouldRunProcessCWDFallbackPoll(panelID: panelID, now: .distantFuture))
        try StateValidator.validate(store.state)
    }

    func testRequestImmediateWorkingDirectoryRefreshStopsAfterBoundedRetriesWithoutMutation() async throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        XCTAssertTrue(
            store.send(.updateTerminalPanelMetadata(panelID: panelID, title: nil, cwd: "/tmp/stale"))
        )

        var resolveAttemptCount = 0
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in
                resolveAttemptCount += 1
                return nil
            },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        service.requestImmediateWorkingDirectoryRefresh(
            panelID: panelID,
            source: "surface_create_process"
        )
        await waitUntil {
            resolveAttemptCount == TerminalMetadataService.immediateProcessRefreshAttemptCount
        }

        XCTAssertEqual(
            resolveAttemptCount,
            TerminalMetadataService.immediateProcessRefreshAttemptCount
        )
        XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).cwd, "/tmp/stale")
        try StateValidator.validate(store.state)
    }

    func testCommandFinishedStopsTrackedSession() async throws {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let panelID = try XCTUnwrap(store.selectedWorkspace?.focusedPanelID)
        let tracker = SessionLifecycleTrackerSpy()
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            sessionLifecycleTracker: tracker,
            resolveWorkingDirectoryFromProcessOverride: { _ in nil },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .commandFinished(exitCode: nil),
                workspaceID: workspaceID,
                panelID: panelID,
                state: store.state
            )
        )

        XCTAssertEqual(
            tracker.stopActiveCalls,
            [
                .init(
                    panelID: panelID,
                    reason: .ghosttyCommandFinished(exitCode: nil)
                ),
            ]
        )
        try StateValidator.validate(store.state)
    }

    func testDesktopNotificationIsSuppressedForManagedSessionPanel() throws {
        let state = try makeTwoWorkspaceState()
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let selection = try XCTUnwrap(store.state.selectedWorkspaceSelection())
        let managedWorkspaceID = try XCTUnwrap(selection.window.workspaceIDs.first { $0 != selection.workspaceID })
        let managedWorkspace = try XCTUnwrap(store.state.workspacesByID[managedWorkspaceID])
        let managedPanelID = try XCTUnwrap(managedWorkspace.focusedPanelID)
        let tracker = SessionLifecycleTrackerSpy()
        tracker.panelsUsingStatusNotifications = [managedPanelID]
        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            sessionLifecycleTracker: tracker,
            resolveWorkingDirectoryFromProcessOverride: { _ in nil },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        XCTAssertTrue(
            service.handleDesktopNotificationAction(
                action: GhosttyRuntimeAction(
                    surfaceHandle: nil,
                    intent: .desktopNotification(title: "Codex is ready", body: "Done")
                ),
                title: "Codex is ready",
                body: "Done",
                state: store.state
            )
        )

        let workspaceAfter = try XCTUnwrap(store.state.workspacesByID[managedWorkspaceID])
        XCTAssertTrue(workspaceAfter.unreadPanelIDs.isEmpty)
        try StateValidator.validate(store.state)
    }

    func testBackgroundTabTerminalMetadataUpdatesApplyWithoutSelectingTab() throws {
        let state = try makeTwoTabState()
        let store = AppStore(state: state, persistTerminalFontPreference: false)
        let registry = TerminalRuntimeRegistry()
        let workspaceID = try XCTUnwrap(store.selectedWorkspace?.id)
        let workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let backgroundTabID = try XCTUnwrap(workspace.tabIDs.first)
        let backgroundTab = try XCTUnwrap(workspace.tab(id: backgroundTabID))
        let backgroundPanelID = try XCTUnwrap(backgroundTab.focusedPanelID)
        let selectedTabID = try XCTUnwrap(workspace.selectedTabID)
        XCTAssertNotEqual(selectedTabID, backgroundTabID)

        let service = TerminalMetadataService(
            store: store,
            registry: registry,
            resolveWorkingDirectoryFromProcessOverride: { _ in nil },
            processRefreshRetryDelay: { _ in
                await Task.yield()
            }
        )

        service.reconcileSurfaceWorkingDirectory(
            panelID: backgroundPanelID,
            workingDirectory: "/tmp/background-tab",
            source: "test"
        )
        XCTAssertTrue(
            service.handleRuntimeMetadataAction(
                .setTerminalTitle("bundle exec rspec"),
                workspaceID: workspaceID,
                panelID: backgroundPanelID,
                state: store.state
            )
        )

        let terminalState = try terminalState(panelID: backgroundPanelID, state: store.state)
        let updatedWorkspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        XCTAssertEqual(updatedWorkspace.selectedTabID, selectedTabID)
        XCTAssertEqual(terminalState.cwd, "/tmp/background-tab")
        XCTAssertEqual(terminalState.title, "bundle exec rspec")
        try StateValidator.validate(store.state)
    }
}

@MainActor
private func terminalState(panelID: UUID, state: AppState) throws -> TerminalPanelState {
    let workspace = try XCTUnwrap(state.workspacesByID.values.first { $0.panelState(for: panelID) != nil })
    guard case .terminal(let terminalState) = workspace.panelState(for: panelID) else {
        XCTFail("expected terminal panel state")
        throw TerminalMetadataServiceTestError.expectedTerminalPanel
    }
    return terminalState
}

private func makeRestoredProfiledPanelState(profileID: String) -> AppState {
    var state = AppState.bootstrap()
    guard let workspaceID = state.windows.first?.selectedWorkspaceID,
          var workspace = state.workspacesByID[workspaceID],
          let panelID = workspace.focusedPanelID,
          case .terminal(var terminalState)? = workspace.panels[panelID] else {
        fatalError("expected bootstrap terminal panel")
    }

    terminalState.cwd = ""
    terminalState.launchWorkingDirectory = "/tmp/restored"
    terminalState.profileBinding = TerminalProfileBinding(profileID: profileID)
    workspace.panels[panelID] = .terminal(terminalState)
    state.workspacesByID[workspaceID] = workspace
    return state
}

private func makeRestoredUnprofiledPanelState() -> AppState {
    var state = AppState.bootstrap()
    guard let workspaceID = state.windows.first?.selectedWorkspaceID,
          var workspace = state.workspacesByID[workspaceID],
          let panelID = workspace.focusedPanelID,
          case .terminal(var terminalState)? = workspace.panels[panelID] else {
        fatalError("expected bootstrap terminal panel")
    }

    terminalState.cwd = ""
    terminalState.launchWorkingDirectory = "/tmp/restored"
    workspace.panels[panelID] = .terminal(terminalState)
    state.workspacesByID[workspaceID] = workspace
    return state
}

private func makeTwoWorkspaceState() throws -> AppState {
    var state = AppState.bootstrap()
    let reducer = AppReducer()
    let windowID = try XCTUnwrap(state.windows.first?.id)
    XCTAssertTrue(
        reducer.send(.createWorkspace(windowID: windowID, title: "Second Workspace"), state: &state),
        "expected second workspace creation to succeed"
    )
    return state
}

private func makeTwoTabState() throws -> AppState {
    var state = AppState.bootstrap()
    let reducer = AppReducer()
    let workspaceID = try XCTUnwrap(state.windows.first?.selectedWorkspaceID)
    XCTAssertTrue(
        reducer.send(.createWorkspaceTab(workspaceID: workspaceID, seed: nil), state: &state),
        "expected second tab creation to succeed"
    )
    return state
}

@MainActor
private func settleMetadataTasks(iterations: Int = 12) async {
    for _ in 0..<iterations {
        await Task.yield()
    }
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(Double(timeoutNanoseconds) / 1_000_000_000)
    while condition() == false && Date() < deadline {
        await Task.yield()
    }
}

actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard isOpen == false else { return }
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

@MainActor
private final class TestTerminalProfileProvider: TerminalProfileProviding {
    let catalog: TerminalProfileCatalog

    init(profiles: [TerminalProfile]) {
        catalog = TerminalProfileCatalog(profiles: profiles)
    }
}

private enum TerminalMetadataServiceTestError: Error {
    case expectedTerminalPanel
}

@MainActor
private final class SessionLifecycleTrackerSpy: TerminalSessionLifecycleTracking {
    struct StopActiveCall: Equatable {
        let panelID: UUID
        let reason: ManagedSessionStopReason
    }

    var panelsUsingStatusNotifications: Set<UUID> = []
    private(set) var stopActiveCalls: [StopActiveCall] = []

    func activeSessionUsesStatusNotifications(panelID: UUID) -> Bool {
        panelsUsingStatusNotifications.contains(panelID)
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
#endif
