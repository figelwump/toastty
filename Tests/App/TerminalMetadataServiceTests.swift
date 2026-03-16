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

    func testRestoredProfiledPaneUsesRestoredLaunchWorkingDirectoryWhenStartupNativeCWDDiffers() async throws {
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

        let terminalState = try terminalState(panelID: panelID, state: store.state)
        XCTAssertEqual(terminalState.cwd, "/tmp/restored")
        XCTAssertEqual(terminalState.displayPanelLabel, "tmp/restored")
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
        await settleMetadataTasks()

        XCTAssertEqual(resolveAttemptCount, 3)
        XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).cwd, "/tmp/fresh")
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
        await settleMetadataTasks()

        XCTAssertEqual(
            resolveAttemptCount,
            TerminalMetadataService.immediateProcessRefreshAttemptCount
        )
        XCTAssertEqual(try terminalState(panelID: panelID, state: store.state).cwd, "/tmp/stale")
        try StateValidator.validate(store.state)
    }
}

@MainActor
private func terminalState(panelID: UUID, state: AppState) throws -> TerminalPanelState {
    let workspace = try XCTUnwrap(state.workspacesByID.values.first { $0.panels[panelID] != nil })
    guard case .terminal(let terminalState) = workspace.panels[panelID] else {
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
#endif
