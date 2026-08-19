import CoreState
import Foundation
import Testing
@testable import ToasttyApp

@MainActor
struct SessionRuntimeStoreAgentHookTests {
    private struct Fixture {
        let runner: ControlledHookRunner
        let dispatcher: AgentHookDispatcher
        let sessionStore: SessionRuntimeStore
        let scriptPath: String
    }

    private static func makeFixture(
        socketPath: String = "/tmp/toastty-hook-tests.sock",
        cliExecutablePath: String? = "/tmp/toastty-hook-tests-cli",
        isApplicationActive: @escaping @MainActor () -> Bool = { false }
    ) throws -> Fixture {
        let runner = ControlledHookRunner()
        let scriptURL = try AgentHookTestSupport.makeTemporaryExecutableScript()
        let dispatcher = AgentHookDispatcher(
            socketPath: socketPath,
            cliExecutablePath: cliExecutablePath,
            scriptPath: scriptURL.path,
            runner: runner
        )
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { _, _, _, _, _ in },
            isApplicationActive: isApplicationActive,
            agentHookDispatcher: dispatcher
        )
        return Fixture(
            runner: runner,
            dispatcher: dispatcher,
            sessionStore: sessionStore,
            scriptPath: scriptURL.path
        )
    }

    private static func recordedEvents(
        _ runner: ControlledHookRunner
    ) async throws -> [(event: String, sessionID: String)] {
        try await runner.requests.map { request in
            let payload = try AgentHookTestSupport.decodeHookPayload(request)
            return (
                event: try #require(payload["event"] as? String),
                sessionID: try #require(payload["sessionID"] as? String)
            )
        }
    }

    private static let baseDate = Date(timeIntervalSince1970: 1_786_000_000)

    // MARK: - Lifecycle events

    @Test
    func startSessionEmitsSessionStartWithManagedReasonByDefault() async throws {
        let fixture = try Self.makeFixture()
        fixture.sessionStore.startSession(
            sessionID: "sess-start",
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: Self.baseDate
        )

        await AgentHookTestSupport.waitForRequestCount(fixture.runner, expected: 1)
        let request = try #require(await fixture.runner.requests.first)
        let payload = try AgentHookTestSupport.decodeHookPayload(request)

        #expect(payload["event"] as? String == "session-start")
        #expect(payload["launchReason"] as? String == "managed")
        #expect(payload["previousStatus"] is NSNull)
        #expect(payload["newStatus"] is NSNull)
        #expect(payload["cwd"] as? String == "/repo")
    }

    @Test
    func restoredStartCarriesRestoreLaunchReason() async throws {
        let fixture = try Self.makeFixture()
        fixture.sessionStore.startSession(
            sessionID: "sess-restored",
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            launchReason: .restore,
            at: Self.baseDate
        )

        await AgentHookTestSupport.waitForRequestCount(fixture.runner, expected: 1)
        let request = try #require(await fixture.runner.requests.first)
        let payload = try AgentHookTestSupport.decodeHookPayload(request)

        #expect(payload["event"] as? String == "session-start")
        #expect(payload["launchReason"] as? String == "restore")
    }

    @Test
    func startProcessWatchEmitsExactlyOneSessionStartWithProcessWatchReason() async throws {
        let fixture = try Self.makeFixture()
        fixture.sessionStore.startProcessWatch(
            sessionID: "sess-watch",
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            displayTitleOverride: "make build",
            cwd: "/repo",
            repoRoot: "/repo",
            at: Self.baseDate
        )

        await AgentHookTestSupport.waitForRequestCount(fixture.runner, expected: 1)
        await settleNotificationTasks()

        let events = try await Self.recordedEvents(fixture.runner)
        #expect(events.map(\.event) == ["session-start"])
        let payload = try AgentHookTestSupport.decodeHookPayload(
            try #require(await fixture.runner.requests.first)
        )
        #expect(payload["launchReason"] as? String == "process-watch")
        #expect(payload["agent"] as? String == "process-watch")
    }

    @Test
    func successfulProcessWatchCompletionEmitsStatusThenStopAndKeepsCompletedRow() async throws {
        let fixture = try Self.makeFixture()
        let panelID = UUID()
        fixture.sessionStore.startProcessWatch(
            sessionID: "sess-watch-success",
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            displayTitleOverride: "make build",
            cwd: "/repo",
            repoRoot: "/repo",
            at: Self.baseDate
        )

        #expect(fixture.sessionStore.handleCommandFinished(
            panelID: panelID,
            exitCode: 0,
            at: Self.baseDate.addingTimeInterval(1)
        ))
        await AgentHookTestSupport.waitForRequestCount(fixture.runner, expected: 3)

        let events = try await Self.recordedEvents(fixture.runner)
        #expect(events.map(\.event) == ["session-start", "turn-complete", "session-stop"])
        #expect(fixture.sessionStore.sessionRegistry.activeSession(for: panelID)?.status?.kind == .ready)
        let stopPayload = try AgentHookTestSupport.decodeHookPayload(
            try #require(await fixture.runner.requests.last)
        )
        #expect(stopPayload["previousStatus"] as? String == "ready")
    }

    @Test
    func failedProcessWatchCompletionEmitsErrorThenStopExactlyOnce() async throws {
        let fixture = try Self.makeFixture()
        let panelID = UUID()
        fixture.sessionStore.startProcessWatch(
            sessionID: "sess-watch-failure",
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            displayTitleOverride: "make build",
            cwd: "/repo",
            repoRoot: "/repo",
            at: Self.baseDate
        )

        #expect(fixture.sessionStore.handleCommandFinished(
            panelID: panelID,
            exitCode: 2,
            at: Self.baseDate.addingTimeInterval(1)
        ))
        // A repeated completion signal must not emit a second stop.
        #expect(fixture.sessionStore.handleCommandFinished(
            panelID: panelID,
            exitCode: 2,
            at: Self.baseDate.addingTimeInterval(2)
        ))
        // The completed row remains active for UI purposes, but a later status
        // update must not deliver a hook event after session-stop.
        fixture.sessionStore.updateStatus(
            sessionID: "sess-watch-failure",
            status: SessionStatus(kind: .ready, summary: "Late update"),
            at: Self.baseDate.addingTimeInterval(3)
        )
        await AgentHookTestSupport.waitForRequestCount(fixture.runner, expected: 3)
        await settleNotificationTasks()

        let events = try await Self.recordedEvents(fixture.runner)
        #expect(events.map(\.event) == ["session-start", "session-error", "session-stop"])
        #expect(fixture.sessionStore.sessionRegistry.activeSession(for: panelID)?.status?.kind == .ready)
    }

    @Test
    func processWatchIdlePromptCompletionAlsoEndsHookLifecycle() async throws {
        let fixture = try Self.makeFixture()
        let panelID = UUID()
        fixture.sessionStore.startProcessWatch(
            sessionID: "sess-watch-idle-prompt",
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            displayTitleOverride: "make build",
            cwd: "/repo",
            repoRoot: "/repo",
            at: Self.baseDate
        )

        #expect(fixture.sessionStore.stopSessionForPanelIfOlderThan(
            panelID: panelID,
            minimumRuntime: 0,
            reason: .idleAtPrompt,
            at: Self.baseDate.addingTimeInterval(1)
        ))
        await AgentHookTestSupport.waitForRequestCount(fixture.runner, expected: 3)

        let events = try await Self.recordedEvents(fixture.runner)
        #expect(events.map(\.event) == ["session-start", "turn-complete", "session-stop"])
        #expect(fixture.sessionStore.sessionRegistry.activeSession(for: panelID)?.status?.kind == .ready)
    }

    @Test
    func injectedSocketAndCLIPathsReachTheHookEnvironmentUnchanged() async throws {
        let fixture = try Self.makeFixture(
            socketPath: "/tmp/injected-instance.sock",
            cliExecutablePath: "/tmp/injected-instance-cli"
        )
        fixture.sessionStore.startSession(
            sessionID: "sess-paths",
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: Self.baseDate
        )

        await AgentHookTestSupport.waitForRequestCount(fixture.runner, expected: 1)
        let request = try #require(await fixture.runner.requests.first)

        #expect(request.environmentOverlay["TOASTTY_SOCKET_PATH"] == "/tmp/injected-instance.sock")
        #expect(request.environmentOverlay["TOASTTY_CLI_PATH"] == "/tmp/injected-instance-cli")
    }

    // MARK: - Status transitions

    @Test
    func statusTransitionsEmitActionableEventsAndDeduplicateByAcceptedKind() async throws {
        let fixture = try Self.makeFixture()
        let sessionID = "sess-transitions"
        var now = Self.baseDate
        fixture.sessionStore.startSession(
            sessionID: sessionID,
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: now
        )

        func advance(_ kind: SessionStatusKind) {
            now = now.addingTimeInterval(1)
            fixture.sessionStore.updateStatus(
                sessionID: sessionID,
                status: SessionStatus(kind: kind, summary: "Status"),
                at: now
            )
        }

        advance(.idle)
        advance(.working)
        advance(.ready)          // turn-complete
        advance(.ready)          // duplicate: nothing
        advance(.needsApproval)  // needs-approval
        advance(.needsApproval)  // duplicate: nothing
        advance(.ready)          // turn-complete (dedup is by kind, not event)
        advance(.error)          // session-error
        advance(.ready)          // turn-complete
        advance(.working)
        advance(.working)        // duplicate: nothing

        await AgentHookTestSupport.waitForRequestCount(fixture.runner, expected: 6)
        await settleNotificationTasks()

        let events = try await Self.recordedEvents(fixture.runner)
        #expect(events.map(\.event) == [
            "session-start",
            "turn-complete",
            "needs-approval",
            "turn-complete",
            "session-error",
            "turn-complete",
        ])
    }

    @Test
    func turnCompletePayloadCarriesPreviousAndNewStatus() async throws {
        let fixture = try Self.makeFixture()
        let sessionID = "sess-payload"
        fixture.sessionStore.startSession(
            sessionID: sessionID,
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: Self.baseDate
        )
        fixture.sessionStore.updateStatus(
            sessionID: sessionID,
            status: SessionStatus(kind: .working, summary: "Working"),
            at: Self.baseDate.addingTimeInterval(1)
        )
        fixture.sessionStore.updateStatus(
            sessionID: sessionID,
            status: SessionStatus(kind: .ready, summary: "Ready"),
            at: Self.baseDate.addingTimeInterval(2)
        )

        await AgentHookTestSupport.waitForRequestCount(fixture.runner, expected: 2)
        let request = try #require(await fixture.runner.requests.last)
        let payload = try AgentHookTestSupport.decodeHookPayload(request)

        #expect(payload["event"] as? String == "turn-complete")
        #expect(payload["previousStatus"] as? String == "working")
        #expect(payload["newStatus"] as? String == "ready")
        #expect(payload["launchReason"] is NSNull)
    }

    @Test
    func focusedPanelReadyCollapseStillEmitsTurnComplete() async throws {
        let appStore = AppStore(state: makeTwoPanelAppState(), persistTerminalFontPreference: false)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let focusedPanelID = try #require(selection.workspace.focusedPanelID)
        let runner = ControlledHookRunner()
        let scriptURL = try AgentHookTestSupport.makeTemporaryExecutableScript()
        let dispatcher = AgentHookDispatcher(
            socketPath: "/tmp/toastty-hook-tests.sock",
            cliExecutablePath: nil,
            scriptPath: scriptURL.path,
            runner: runner
        )
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { _, _, _, _, _ in },
            isApplicationActive: { true },
            agentHookDispatcher: dispatcher
        )
        sessionStore.bind(store: appStore)
        let sessionID = "sess-focused"
        sessionStore.startSession(
            sessionID: sessionID,
            agent: .codex,
            panelID: focusedPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            usesSessionStatusNotifications: true,
            cwd: "/repo",
            repoRoot: "/repo",
            at: Self.baseDate
        )
        sessionStore.updateStatus(
            sessionID: sessionID,
            status: SessionStatus(kind: .working, summary: "Working"),
            at: Self.baseDate.addingTimeInterval(1)
        )
        sessionStore.updateStatus(
            sessionID: sessionID,
            status: SessionStatus(kind: .ready, summary: "Ready"),
            at: Self.baseDate.addingTimeInterval(2)
        )

        // Stored status collapsed to idle for the focused panel, but the hook
        // still observes the requested reconciled `ready`.
        #expect(sessionStore.sessionRegistry.sessionsByID[sessionID]?.status?.kind == .idle)
        await AgentHookTestSupport.waitForRequestCount(runner, expected: 2)
        let events = try await Self.recordedEvents(runner)
        #expect(events.map(\.event) == ["session-start", "turn-complete"])
    }

    @Test
    func waitingOnChildrenDefersTurnCompleteUntilProjectionClearsThenFiresOnce() async throws {
        let fixture = try Self.makeFixture()
        let sessionID = "sess-children"
        fixture.sessionStore.startSession(
            sessionID: sessionID,
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: Self.baseDate
        )
        #expect(fixture.sessionStore.updateBackgroundActivity(
            sessionID: sessionID,
            activity: SessionBackgroundActivity(
                id: "child-1",
                kind: .childAgent,
                displayName: "child agent",
                startedAt: Self.baseDate.addingTimeInterval(1),
                lastUpdatedAt: Self.baseDate.addingTimeInterval(1)
            ),
            at: Self.baseDate.addingTimeInterval(1)
        ))
        fixture.sessionStore.updateStatus(
            sessionID: sessionID,
            status: SessionStatus(kind: .ready, summary: "Ready"),
            at: Self.baseDate.addingTimeInterval(2)
        )
        await AgentHookTestSupport.waitForRequestCount(fixture.runner, expected: 1)
        await settleNotificationTasks()

        // Held: the session still projects as waiting on children.
        var events = try await Self.recordedEvents(fixture.runner)
        #expect(events.map(\.event) == ["session-start"])

        #expect(fixture.sessionStore.finishBackgroundActivity(
            sessionID: sessionID,
            activityID: "child-1",
            at: Self.baseDate.addingTimeInterval(3)
        ))
        await settleNotificationTasks()

        // Still held: the resume-grace projection has not cleared yet.
        events = try await Self.recordedEvents(fixture.runner)
        #expect(events.map(\.event) == ["session-start"])

        // Any registry publication after the grace expires releases the held
        // event exactly once.
        fixture.sessionStore.updateFiles(
            sessionID: sessionID,
            files: ["README.md"],
            cwd: nil,
            repoRoot: nil,
            at: Self.baseDate.addingTimeInterval(3 + SessionRegistry.resumeProjectionGraceInterval + 1)
        )
        await AgentHookTestSupport.waitForRequestCount(fixture.runner, expected: 2)
        await settleNotificationTasks()

        events = try await Self.recordedEvents(fixture.runner)
        #expect(events.map(\.event) == ["session-start", "turn-complete"])

        // A duplicate ready afterwards does not emit again.
        fixture.sessionStore.updateStatus(
            sessionID: sessionID,
            status: SessionStatus(kind: .ready, summary: "Ready"),
            at: Self.baseDate.addingTimeInterval(30)
        )
        await settleNotificationTasks()
        events = try await Self.recordedEvents(fixture.runner)
        #expect(events.map(\.event) == ["session-start", "turn-complete"])
    }

    @Test
    func heldReadyIsCancelledByLaterNonReadyTransition() async throws {
        let fixture = try Self.makeFixture()
        let sessionID = "sess-cancel"
        fixture.sessionStore.startSession(
            sessionID: sessionID,
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: Self.baseDate
        )
        #expect(fixture.sessionStore.updateBackgroundActivity(
            sessionID: sessionID,
            activity: SessionBackgroundActivity(
                id: "child-1",
                kind: .childAgent,
                startedAt: Self.baseDate.addingTimeInterval(1),
                lastUpdatedAt: Self.baseDate.addingTimeInterval(1)
            ),
            at: Self.baseDate.addingTimeInterval(1)
        ))
        fixture.sessionStore.updateStatus(
            sessionID: sessionID,
            status: SessionStatus(kind: .ready, summary: "Ready"),
            at: Self.baseDate.addingTimeInterval(2)
        )
        // The next turn starts before the child finishes: the held ready must
        // be discarded, not emitted later.
        fixture.sessionStore.updateStatus(
            sessionID: sessionID,
            status: SessionStatus(kind: .working, summary: "Working"),
            at: Self.baseDate.addingTimeInterval(3)
        )
        #expect(fixture.sessionStore.finishBackgroundActivity(
            sessionID: sessionID,
            activityID: "child-1",
            at: Self.baseDate.addingTimeInterval(4)
        ))
        fixture.sessionStore.updateFiles(
            sessionID: sessionID,
            files: ["README.md"],
            cwd: nil,
            repoRoot: nil,
            at: Self.baseDate.addingTimeInterval(4 + SessionRegistry.resumeProjectionGraceInterval + 1)
        )
        await AgentHookTestSupport.waitForRequestCount(fixture.runner, expected: 1)
        await settleNotificationTasks()

        let events = try await Self.recordedEvents(fixture.runner)
        #expect(events.map(\.event) == ["session-start"])
    }

    // MARK: - Teardown

    @Test
    func explicitStopEmitsExactlyOneSessionStopAndNothingAfter() async throws {
        let fixture = try Self.makeFixture()
        let sessionID = "sess-stop"
        fixture.sessionStore.startSession(
            sessionID: sessionID,
            agent: .codex,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: Self.baseDate
        )
        fixture.sessionStore.stopSession(sessionID: sessionID, at: Self.baseDate.addingTimeInterval(1))
        // Repeated stops and post-stop statuses must not emit.
        fixture.sessionStore.stopSession(sessionID: sessionID, at: Self.baseDate.addingTimeInterval(2))
        fixture.sessionStore.updateStatus(
            sessionID: sessionID,
            status: SessionStatus(kind: .ready, summary: "Ready"),
            at: Self.baseDate.addingTimeInterval(3)
        )

        await AgentHookTestSupport.waitForRequestCount(fixture.runner, expected: 2)
        await settleNotificationTasks()

        let events = try await Self.recordedEvents(fixture.runner)
        #expect(events.map(\.event) == ["session-start", "session-stop"])
    }

    @Test
    func panelBasedStopEmitsExactlyOneSessionStop() async throws {
        let fixture = try Self.makeFixture()
        let panelID = UUID()
        fixture.sessionStore.startSession(
            sessionID: "sess-panel-stop",
            agent: .codex,
            panelID: panelID,
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: Self.baseDate
        )
        fixture.sessionStore.stopSessionForPanel(panelID: panelID, at: Self.baseDate.addingTimeInterval(1))
        fixture.sessionStore.stopSessionForPanel(panelID: panelID, at: Self.baseDate.addingTimeInterval(2))

        await AgentHookTestSupport.waitForRequestCount(fixture.runner, expected: 2)
        await settleNotificationTasks()

        let events = try await Self.recordedEvents(fixture.runner)
        #expect(events.map(\.event) == ["session-start", "session-stop"])
    }

    @Test
    func panelRemovalTeardownEmitsExactlyOneSessionStop() async throws {
        let appStore = AppStore(state: makeTwoPanelAppState(), persistTerminalFontPreference: false)
        let selection = try #require(appStore.state.selectedWorkspaceSelection())
        let backgroundPanelID = try #require(selection.workspace.layoutTree.allSlotInfos.map(\.panelID).first {
            $0 != selection.workspace.focusedPanelID
        })
        let runner = ControlledHookRunner()
        let scriptURL = try AgentHookTestSupport.makeTemporaryExecutableScript()
        let dispatcher = AgentHookDispatcher(
            socketPath: "/tmp/toastty-hook-tests.sock",
            cliExecutablePath: nil,
            scriptPath: scriptURL.path,
            runner: runner
        )
        let sessionStore = SessionRuntimeStore(
            sendSessionStatusNotification: { _, _, _, _, _ in },
            isApplicationActive: { false },
            agentHookDispatcher: dispatcher
        )
        sessionStore.bind(store: appStore)
        sessionStore.startSession(
            sessionID: "sess-removal",
            agent: .codex,
            panelID: backgroundPanelID,
            windowID: selection.windowID,
            workspaceID: selection.workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: Self.baseDate
        )

        #expect(appStore.send(.closePanel(panelID: backgroundPanelID)))

        await AgentHookTestSupport.waitForRequestCount(runner, expected: 2)
        await settleNotificationTasks()

        let events = try await Self.recordedEvents(runner)
        #expect(events.map(\.event) == ["session-start", "session-stop"])
        #expect(sessionStore.sessionRegistry.activeSession(for: backgroundPanelID) == nil)
    }

    @Test
    func heldReadyIsCancelledByTeardownAndStopStillEmits() async throws {
        let fixture = try Self.makeFixture()
        let sessionID = "sess-held-teardown"
        fixture.sessionStore.startSession(
            sessionID: sessionID,
            agent: .claude,
            panelID: UUID(),
            windowID: UUID(),
            workspaceID: UUID(),
            cwd: "/repo",
            repoRoot: "/repo",
            at: Self.baseDate
        )
        #expect(fixture.sessionStore.updateBackgroundActivity(
            sessionID: sessionID,
            activity: SessionBackgroundActivity(
                id: "child-1",
                kind: .childAgent,
                startedAt: Self.baseDate.addingTimeInterval(1),
                lastUpdatedAt: Self.baseDate.addingTimeInterval(1)
            ),
            at: Self.baseDate.addingTimeInterval(1)
        ))
        fixture.sessionStore.updateStatus(
            sessionID: sessionID,
            status: SessionStatus(kind: .ready, summary: "Ready"),
            at: Self.baseDate.addingTimeInterval(2)
        )
        fixture.sessionStore.stopSession(sessionID: sessionID, at: Self.baseDate.addingTimeInterval(3))

        await AgentHookTestSupport.waitForRequestCount(fixture.runner, expected: 2)
        await settleNotificationTasks()

        let events = try await Self.recordedEvents(fixture.runner)
        #expect(events.map(\.event) == ["session-start", "session-stop"])
    }

    @Test
    func replacementLaunchOnSamePanelStopsTheDisplacedSessionFirst() async throws {
        let fixture = try Self.makeFixture()
        let panelID = UUID()
        let windowID = UUID()
        let workspaceID = UUID()
        fixture.sessionStore.startSession(
            sessionID: "sess-old",
            agent: .codex,
            panelID: panelID,
            windowID: windowID,
            workspaceID: workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: Self.baseDate
        )
        fixture.sessionStore.startSession(
            sessionID: "sess-new",
            agent: .claude,
            panelID: panelID,
            windowID: windowID,
            workspaceID: workspaceID,
            cwd: "/repo",
            repoRoot: "/repo",
            at: Self.baseDate.addingTimeInterval(1)
        )

        await AgentHookTestSupport.waitForRequestCount(fixture.runner, expected: 3)
        await settleNotificationTasks()

        // Cross-session drain order is unspecified; per-session order is the
        // contract.
        let events = try await Self.recordedEvents(fixture.runner)
        #expect(events.filter { $0.sessionID == "sess-old" }.map(\.event) == [
            "session-start",
            "session-stop",
        ])
        #expect(events.filter { $0.sessionID == "sess-new" }.map(\.event) == ["session-start"])
    }
}
