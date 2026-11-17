#if TOASTTY_HAS_GHOSTTY_KIT
@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class TerminalWorkspaceMaintenanceServiceTests: XCTestCase {
    func testSynchronizePulsesSelectedTabPanelsWhenTabSelectionChanges() throws {
        let fixture = try makeMaintenanceFixture(state: try makeTwoTabFixtureState())
        let workspace = try XCTUnwrap(fixture.store.state.workspacesByID[fixture.workspaceID])
        let originalTabID = try XCTUnwrap(workspace.tabIDs.first)
        let originalTab = try XCTUnwrap(workspace.tab(id: originalTabID))
        let originalPanelID = try XCTUnwrap(originalTab.focusedPanelID)
        let initiallySelectedTabID = try XCTUnwrap(workspace.selectedTabID)
        let initiallySelectedTab = try XCTUnwrap(workspace.tab(id: initiallySelectedTabID))
        let initiallySelectedPanelID = try XCTUnwrap(initiallySelectedTab.focusedPanelID)

        fixture.service.synchronize(
            state: fixture.store.state,
            livePanelIDs: Set(fixture.panelIDs),
            removedPanelIDs: []
        )

        XCTAssertEqual(Set(fixture.pulseRecorder.panelIDs), [initiallySelectedPanelID])
        fixture.pulseRecorder.panelIDs.removeAll()

        XCTAssertTrue(
            fixture.store.send(.selectWorkspaceTab(workspaceID: fixture.workspaceID, tabID: originalTabID))
        )
        fixture.service.synchronize(
            state: fixture.store.state,
            livePanelIDs: Set(fixture.panelIDs),
            removedPanelIDs: []
        )

        XCTAssertEqual(Set(fixture.pulseRecorder.panelIDs), [initiallySelectedPanelID, originalPanelID])
    }

    func testSynchronizePulsesOutgoingAndIncomingPanelsWhenWorkspaceSelectionChanges() throws {
        let fixture = try makeMaintenanceFixture(state: try makeTwoWorkspaceFixtureState())
        let windowID = try XCTUnwrap(fixture.store.state.windows.first?.id)
        let initiallySelectedWorkspaceID = try XCTUnwrap(fixture.store.state.windows.first?.selectedWorkspaceID)
        let initiallySelectedWorkspace = try XCTUnwrap(
            fixture.store.state.workspacesByID[initiallySelectedWorkspaceID]
        )
        let initiallySelectedPanelID = try XCTUnwrap(initiallySelectedWorkspace.focusedPanelID)
        let originalWorkspaceID = try XCTUnwrap(
            fixture.store.state.windows.first?.workspaceIDs.first { $0 != initiallySelectedWorkspaceID }
        )
        let originalWorkspace = try XCTUnwrap(fixture.store.state.workspacesByID[originalWorkspaceID])
        let originalPanelID = try XCTUnwrap(originalWorkspace.focusedPanelID)

        fixture.service.synchronize(
            state: fixture.store.state,
            livePanelIDs: Set(fixture.panelIDs),
            removedPanelIDs: []
        )

        XCTAssertEqual(Set(fixture.pulseRecorder.panelIDs), [initiallySelectedPanelID])
        fixture.pulseRecorder.panelIDs.removeAll()

        XCTAssertTrue(
            fixture.store.send(.selectWorkspace(windowID: windowID, workspaceID: originalWorkspaceID))
        )
        fixture.service.synchronize(
            state: fixture.store.state,
            livePanelIDs: Set(fixture.panelIDs),
            removedPanelIDs: []
        )

        XCTAssertEqual(Set(fixture.pulseRecorder.panelIDs), [initiallySelectedPanelID, originalPanelID])
    }

    func testIdlePromptKeepsNewLaunchUntilShellStartsItsCommand() throws {
        let fixture = try makeLaunchFixture()
        let result = try fixture.launchService.launch(profileID: "codex")
        let panelID = result.panelID
        func activeSessionID() -> String? {
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(for: panelID)?.sessionID
        }

        // A slow shell still shows the prompt from before the typed command.
        for seconds in [1.6, 5, 10] {
            fixture.service.applyPromptState(
                .idleAtPrompt,
                panelID: panelID,
                at: fixture.launchedAt.addingTimeInterval(seconds)
            )
        }
        XCTAssertEqual(activeSessionID(), result.sessionID)

        // The shell starts the command, the agent runs, and then it exits.
        fixture.service.applyPromptState(.busy, panelID: panelID, at: fixture.launchedAt.addingTimeInterval(11))
        XCTAssertEqual(activeSessionID(), result.sessionID)
        fixture.service.applyPromptState(.idleAtPrompt, panelID: panelID, at: fixture.launchedAt.addingTimeInterval(12))
        XCTAssertNil(activeSessionID())
    }

    func testIdlePromptEndsLaunchWhoseCommandNeverStarts() throws {
        let fixture = try makeLaunchFixture()
        let result = try fixture.launchService.launch(profileID: "codex")
        let panelID = result.panelID
        let timeout = SessionRuntimeStore.managedLaunchCommandStartTimeout

        fixture.service.applyPromptState(
            .idleAtPrompt,
            panelID: panelID,
            at: fixture.launchedAt.addingTimeInterval(timeout - 0.5)
        )
        XCTAssertEqual(
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(for: panelID)?.sessionID,
            result.sessionID
        )

        fixture.service.applyPromptState(
            .idleAtPrompt,
            panelID: panelID,
            at: fixture.launchedAt.addingTimeInterval(timeout)
        )
        XCTAssertNil(fixture.sessionRuntimeStore.sessionRegistry.activeSession(for: panelID))
    }

    func testIdlePromptEndsSessionThatARunningAgentStarted() throws {
        let fixture = try makeLaunchFixture()
        let workspace = try XCTUnwrap(fixture.store.selectedWorkspace)
        let panelID = try XCTUnwrap(workspace.focusedPanelID)
        // A command the user typed starts its session from the running agent
        // process, so no typed launch command is pending.
        fixture.sessionRuntimeStore.startSession(
            sessionID: "sess-from-shim",
            agent: .claude,
            panelID: panelID,
            windowID: try XCTUnwrap(fixture.store.state.windows.first?.id),
            workspaceID: workspace.id,
            codexStatusTrackingSource: .externallyReported,
            cwd: nil,
            repoRoot: nil,
            at: fixture.launchedAt
        )

        fixture.service.applyPromptState(.idleAtPrompt, panelID: panelID, at: fixture.launchedAt.addingTimeInterval(1))
        XCTAssertNotNil(fixture.sessionRuntimeStore.sessionRegistry.activeSession(for: panelID))
        fixture.service.applyPromptState(.idleAtPrompt, panelID: panelID, at: fixture.launchedAt.addingTimeInterval(1.6))
        XCTAssertNil(fixture.sessionRuntimeStore.sessionRegistry.activeSession(for: panelID))
    }

    func testSessionThatReplacesAPendingLaunchDoesNotInheritItsWait() throws {
        let fixture = try makeLaunchFixture()
        let result = try fixture.launchService.launch(profileID: "codex")
        let panelID = result.panelID
        // The typed command never started. The user then runs an agent in the
        // same terminal, and that agent starts its own session.
        let replacedAt = fixture.launchedAt.addingTimeInterval(5)
        fixture.sessionRuntimeStore.startSession(
            sessionID: "sess-typed-by-user",
            agent: .claude,
            panelID: panelID,
            windowID: result.windowID,
            workspaceID: result.workspaceID,
            codexStatusTrackingSource: .externallyReported,
            cwd: nil,
            repoRoot: nil,
            at: replacedAt
        )
        XCTAssertEqual(
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(for: panelID)?.sessionID,
            "sess-typed-by-user"
        )

        fixture.service.applyPromptState(.idleAtPrompt, panelID: panelID, at: replacedAt.addingTimeInterval(1.6))
        XCTAssertNil(fixture.sessionRuntimeStore.sessionRegistry.activeSession(for: panelID))
    }

    func testIdlePromptKeepsRestoredLaunchWhoseCommandWasTypedBeforeTheFirstPrompt() throws {
        let fixture = try makeLaunchFixture()
        let workspace = try XCTUnwrap(fixture.store.selectedWorkspace)
        let panelID = try XCTUnwrap(workspace.focusedPanelID)
        fixture.sessionRuntimeStore.startSession(
            sessionID: "sess-restored",
            agent: .claude,
            panelID: panelID,
            windowID: try XCTUnwrap(fixture.store.state.windows.first?.id),
            workspaceID: workspace.id,
            codexStatusTrackingSource: .externallyReported,
            cwd: nil,
            repoRoot: nil,
            launchReason: .restore,
            at: fixture.launchedAt
        )
        let submittedAt = fixture.launchedAt.addingTimeInterval(5)
        fixture.sessionRuntimeStore.noteManagedLaunchCommandSubmitted(
            sessionID: "sess-restored",
            shellWasAtPrompt: false,
            at: submittedAt
        )
        func isActive() -> Bool {
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(for: panelID) != nil
        }

        // The shell is busy with its own startup, then shows its first prompt,
        // and only later starts the typed resume command.
        fixture.service.applyPromptState(.busy, panelID: panelID, at: submittedAt.addingTimeInterval(1))
        fixture.service.applyPromptState(.idleAtPrompt, panelID: panelID, at: submittedAt.addingTimeInterval(2))
        fixture.service.applyPromptState(.idleAtPrompt, panelID: panelID, at: submittedAt.addingTimeInterval(4))
        XCTAssertTrue(isActive())

        // The resume command runs, and the agent later exits.
        fixture.service.applyPromptState(.busy, panelID: panelID, at: submittedAt.addingTimeInterval(5))
        XCTAssertTrue(isActive())
        fixture.service.applyPromptState(.idleAtPrompt, panelID: panelID, at: submittedAt.addingTimeInterval(6))
        XCTAssertFalse(isActive())
    }
}

@MainActor
private func makeLaunchFixture() throws -> (
    store: AppStore,
    sessionRuntimeStore: SessionRuntimeStore,
    launchService: AgentLaunchService,
    service: TerminalWorkspaceMaintenanceService,
    launchedAt: Date,
    // The launch service holds its terminal router weakly.
    terminalRouter: TestTerminalCommandRouter
) {
    let store = AppStore(persistTerminalFontPreference: false)
    let sessionRuntimeStore = SessionRuntimeStore(sendSessionStatusNotification: { _, _, _, _, _ in })
    sessionRuntimeStore.bind(store: store)
    let terminalRouter = TestTerminalCommandRouter()
    terminalRouter.defaultPromptState = .idleAtPrompt
    let launchedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let launchService = AgentLaunchService(
        store: store,
        terminalCommandRouter: terminalRouter,
        sessionRuntimeStore: sessionRuntimeStore,
        agentCatalogProvider: TestAgentCatalogProvider(),
        nowProvider: { launchedAt },
        cliExecutablePathProvider: { "/bin/sh" },
        socketPathProvider: { "/tmp/toastty-tests.sock" },
        codexStatusTrackingSourceProvider: { .sessionLogFallback(reason: "test") },
        nativeSessionObserverRegistry: IdleNativeSessionObserver(),
        codexSkillsResolver: NoCodexSkillsResolver()
    )
    let registry = TerminalRuntimeRegistry()
    let service = TerminalWorkspaceMaintenanceService(
        store: store,
        metadataService: TerminalMetadataService(store: store, registry: registry),
        sessionLifecycleTracker: sessionRuntimeStore,
        controllerForPanelID: { _ in nil }
    )
    return (store, sessionRuntimeStore, launchService, service, launchedAt, terminalRouter)
}

@MainActor
private final class IdleNativeSessionObserver: ManagedAgentNativeSessionObserving {
    func startObservation(_: ManagedAgentNativeSessionObservationContext) {}
    func cancelObservation(sessionID _: String) {}
}

private final class NoCodexSkillsResolver: CodexManagedLaunchSkillsResolving, @unchecked Sendable {
    func resolve(
        request _: ManagedAgentLaunchRequest,
        workingDirectory _: String?
    ) -> CodexManagedLaunchSkillsDecision {
        CodexManagedLaunchSkillsDecision(configuration: nil, status: nil)
    }
}

@MainActor
private func makeMaintenanceFixture(state: AppState = .bootstrap()) throws -> (
    store: AppStore,
    service: TerminalWorkspaceMaintenanceService,
    workspaceID: UUID,
    panelIDs: [UUID],
    pulseRecorder: PulseRecorder
) {
    let store = AppStore(state: state, persistTerminalFontPreference: false)
    let registry = TerminalRuntimeRegistry()
    let metadataService = TerminalMetadataService(store: store, registry: registry)
    let workspace = try XCTUnwrap(store.selectedWorkspace)
    let workspaceID = workspace.id
    let panelIDs = workspace.allPanelsByID.keys.sorted { $0.uuidString < $1.uuidString }
    let pulseRecorder = PulseRecorder()
    let service = TerminalWorkspaceMaintenanceService(
        store: store,
        metadataService: metadataService,
        controllerForPanelID: { panelID in
            pulseRecorder.panelIDs.append(panelID)
            return nil
        },
        visibilityPulseScheduler: { pulse in
            pulse()
            pulse()
            return nil
        }
    )
    return (
        store,
        service,
        workspaceID,
        panelIDs,
        pulseRecorder
    )
}

@MainActor
private func makeTwoTabFixtureState() throws -> AppState {
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
private func makeTwoWorkspaceFixtureState() throws -> AppState {
    var state = AppState.bootstrap()
    let reducer = AppReducer()
    let windowID = try XCTUnwrap(state.windows.first?.id)
    XCTAssertTrue(
        reducer.send(.createWorkspace(windowID: windowID, title: "Second Workspace", activate: true), state: &state),
        "expected second workspace creation to succeed"
    )
    return state
}

@MainActor
private final class PulseRecorder {
    var panelIDs: [UUID] = []
}
#endif
