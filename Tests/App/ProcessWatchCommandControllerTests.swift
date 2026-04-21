@testable import ToasttyApp
import CoreState
import XCTest

@MainActor
final class ProcessWatchCommandControllerTests: XCTestCase {
    func testCanWatchFocusedProcessWhenFocusedBusyTerminalHasNoManagedSession() throws {
        let fixture = try makeFixture()

        XCTAssertTrue(
            fixture.controller.canWatchFocusedProcess(preferredWindowID: fixture.windowID)
        )
    }

    func testCannotWatchFocusedProcessWhenPromptIsIdle() throws {
        let fixture = try makeFixture(promptStateResolver: { _ in .idleAtPrompt })

        XCTAssertFalse(
            fixture.controller.canWatchFocusedProcess(preferredWindowID: fixture.windowID)
        )
    }

    func testCannotWatchFocusedProcessWhenManagedSessionAlreadyOwnsPanel() throws {
        let fixture = try makeFixture()
        fixture.sessionRuntimeStore.startSession(
            sessionID: "existing-session",
            agent: .codex,
            panelID: fixture.panelID,
            windowID: fixture.windowID,
            workspaceID: fixture.workspaceID,
            cwd: nil,
            repoRoot: nil,
            at: Date(timeIntervalSinceReferenceDate: 10)
        )

        XCTAssertFalse(
            fixture.controller.canWatchFocusedProcess(preferredWindowID: fixture.windowID)
        )
    }

    func testWatchFocusedProcessStartsWorkingWatcherWithCapturedTitleAndNotifications() throws {
        let fixture = try makeFixture(
            terminalState: TerminalPanelState(
                title: "npm test",
                shell: "/bin/zsh",
                cwd: "/tmp/project"
            )
        )

        XCTAssertTrue(
            fixture.controller.watchFocusedProcess(preferredWindowID: fixture.windowID)
        )

        let record = try XCTUnwrap(
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(for: fixture.panelID)
        )
        XCTAssertEqual(record.agent, .processWatch)
        XCTAssertEqual(record.displayTitleOverride, "npm test")
        XCTAssertEqual(record.cwd, "/tmp/project")
        XCTAssertTrue(record.usesSessionStatusNotifications)
        XCTAssertEqual(
            record.status,
            SessionStatus(kind: .working, summary: "Working", detail: "Running")
        )

        let workspaceStatus = try XCTUnwrap(
            fixture.sessionRuntimeStore.sessionRegistry.workspaceStatuses(for: fixture.workspaceID).first
        )
        XCTAssertEqual(workspaceStatus.displayTitle, "npm test")
        XCTAssertEqual(workspaceStatus.status.kind, .working)
    }

    func testWatchFocusedProcessFallsBackToPanelLabelWhenTitleLooksLikePathContext() throws {
        let fixture = try makeFixture(
            terminalState: TerminalPanelState(
                title: "/tmp/project",
                shell: "/bin/zsh",
                cwd: "/tmp/project"
            )
        )

        XCTAssertTrue(
            fixture.controller.watchFocusedProcess(preferredWindowID: fixture.windowID)
        )

        let record = try XCTUnwrap(
            fixture.sessionRuntimeStore.sessionRegistry.activeSession(for: fixture.panelID)
        )
        XCTAssertEqual(record.displayTitleOverride, "tmp/project")
    }

    func testWatchFocusedProcessEnablesExpandedSessionSidebarWidthMode() throws {
        let fixture = try makeFixture()

        XCTAssertTrue(
            fixture.controller.watchFocusedProcess(preferredWindowID: fixture.windowID)
        )

        XCTAssertTrue(fixture.store.hasEverLaunchedAgent)
        XCTAssertEqual(
            AppWindowView.effectiveSidebarWidth(hasEverLaunchedAgent: fixture.store.hasEverLaunchedAgent),
            280
        )
    }
}

private extension ProcessWatchCommandControllerTests {
    struct Fixture {
        let store: AppStore
        let sessionRuntimeStore: SessionRuntimeStore
        let controller: ProcessWatchCommandController
        let windowID: UUID
        let workspaceID: UUID
        let panelID: UUID
    }

    func makeFixture(
        terminalState: TerminalPanelState = TerminalPanelState(
            title: "Terminal",
            shell: "/bin/zsh",
            cwd: "/tmp/project"
        ),
        promptStateResolver: @escaping (UUID) -> TerminalPromptState = { _ in .busy }
    ) throws -> Fixture {
        let store = AppStore(state: .bootstrap(), persistTerminalFontPreference: false)
        let windowID = try XCTUnwrap(store.state.windows.first?.id)
        let workspaceID = try XCTUnwrap(store.state.windows.first?.selectedWorkspaceID)
        let workspace = try XCTUnwrap(store.state.workspacesByID[workspaceID])
        let panelID = try XCTUnwrap(workspace.focusedPanelID)

        var nextState = store.state
        var updatedWorkspace = try XCTUnwrap(nextState.workspacesByID[workspaceID])
        updatedWorkspace.panels[panelID] = .terminal(terminalState)
        nextState.workspacesByID[workspaceID] = updatedWorkspace
        store.replaceState(nextState)

        let terminalRuntimeRegistry = TerminalRuntimeRegistry()
        terminalRuntimeRegistry.bind(store: store)
        let sessionRuntimeStore = SessionRuntimeStore()
        sessionRuntimeStore.bind(store: store)
        let controller = ProcessWatchCommandController(
            store: store,
            terminalRuntimeRegistry: terminalRuntimeRegistry,
            sessionRuntimeStore: sessionRuntimeStore,
            promptStateResolver: promptStateResolver
        )

        return Fixture(
            store: store,
            sessionRuntimeStore: sessionRuntimeStore,
            controller: controller,
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID
        )
    }
}
