import CoreState
import Dispatch
import Foundation
import Testing
@testable import ToasttyApp

/// Starting the coordinator in its hidden workspace and starting it again
/// after it exits: the real reducer and store, with the fake launcher and
/// sessions from the task tests in place of agents.
@MainActor
struct CoordinatorSessionControllerTests {
    @MainActor
    final class Fixture {
        let store = AppStore(persistTerminalFontPreference: false)
        let launcher = TaskStartWorkTests.FakeLauncher()
        let sessions = TaskStartWorkTests.FakeSessions()
        let directory: URL
        var config = TasksConfig()
        var clock = Date(timeIntervalSince1970: 1_792_800_000)
        var restorePending = false
        private(set) var controller: CoordinatorSessionController!

        init(stableRunDuration: TimeInterval = 60, maximumQuickExits: Int = 3, restoreGrace: Duration = .seconds(20)) {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("toastty-coordinator-\(UUID().uuidString)", isDirectory: true)
            launcher.sessions = sessions
            controller = CoordinatorSessionController(
                store: store,
                launcher: launcher,
                sessions: sessions,
                configLoader: { [unowned self] in config },
                files: CoordinatorFiles(directoryURL: directory),
                isRestorePending: { [unowned self] _ in restorePending },
                now: { [unowned self] in clock },
                relaunchDelay: .milliseconds(10),
                restoreGrace: restoreGrace,
                terminalReadinessTimeout: .milliseconds(200),
                stableRunDuration: stableRunDuration,
                maximumQuickExits: maximumQuickExits
            )
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }

        var coordinatorWorkspace: WorkspaceState? {
            store.state.coordinatorWorkspaceID.flatMap { store.state.workspacesByID[$0] }
        }

        func waitUntil(_ description: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while condition() == false {
                guard ContinuousClock.now < deadline else {
                    Issue.record("Timed out waiting until \(description)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        /// Ends the running session, as the agent exiting does, and lets the
        /// controller see it.
        func exitSession(_ sessionID: String, after seconds: TimeInterval) {
            clock = clock.addingTimeInterval(seconds)
            sessions.stop(sessionID)
            controller.reconcile()
        }
    }

    @Test
    func startsTheDefaultAgentInTheHiddenWorkspaceAndStartsAgainAfterItExits() async throws {
        let fixture = Fixture()
        let visibleWorkspaceIDs = fixture.store.state.windows[0].workspaceIDs
        fixture.controller.start()
        await fixture.waitUntil("the coordinator starts") { fixture.launcher.calls.count == 1 }

        let call = try #require(fixture.launcher.calls.first)
        let workspace = try #require(fixture.coordinatorWorkspace)
        #expect(call.profileID == "claude")
        #expect(call.workspaceID == workspace.id)
        #expect(call.cwd == fixture.directory.path)
        guard case .terminal(let terminal)? = workspace.panelState(for: call.panelID) else {
            Issue.record("The coordinator workspace has no terminal")
            return
        }
        #expect(terminal.cwd == fixture.directory.path)
        #expect(call.prompt == "Use the toastty-coordinator skill.")
        #expect(call.scopedWorkspaceIDs == nil)
        #expect(fixture.controller.status == .running(sessionID: "launched-1"))
        #expect(fixture.controller.panelID == call.panelID)
        let windowID = fixture.store.state.windows[0].id
        #expect(fixture.store.state.topLevelWorkspaceIDs(in: windowID) == visibleWorkspaceIDs)
        #expect(fixture.store.state.windows[0].selectedWorkspaceID == visibleWorkspaceIDs.first)
        #expect(FileManager.default.fileExists(atPath: fixture.controller.files.routingFileURL.path))

        // A long-running session that exits, as at a natural break, gets a
        // fresh session in the same terminal.
        fixture.exitSession("launched-1", after: 600)
        await fixture.waitUntil("the coordinator starts again") { fixture.launcher.calls.count == 2 }
        #expect(fixture.launcher.calls[1].panelID == call.panelID)
        #expect(fixture.controller.status == .running(sessionID: "launched-2"))
        #expect(fixture.store.state.workspacesByID.values.filter(\.isCoordinator).count == 1)
    }

    @Test
    func usesTheConfiguredAgentModelAndEffort() async throws {
        let fixture = Fixture()
        fixture.config.coordinator = TasksConfig.Coordinator(agent: "codex", model: "gpt-6.1-sol", effort: "high")
        fixture.controller.start()
        await fixture.waitUntil("the coordinator starts") { fixture.launcher.calls.count == 1 }
        let call = try #require(fixture.launcher.calls.first)
        #expect(call.profileID == "codex")
        #expect(call.model == "gpt-6.1-sol")
    }

    @Test
    func agentNoneLeavesTheCoordinatorOff() async throws {
        let fixture = Fixture()
        fixture.config.coordinator = TasksConfig.Coordinator(agent: nil)
        fixture.controller.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.launcher.calls.isEmpty)
        #expect(fixture.coordinatorWorkspace == nil)
        #expect(fixture.controller.status == .off)
    }

    @Test
    func anUnknownProfileFailsWithoutAWorkspace() async throws {
        let fixture = Fixture()
        fixture.config.coordinator = TasksConfig.Coordinator(agent: "gemini")
        fixture.controller.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.launcher.calls.isEmpty)
        #expect(fixture.coordinatorWorkspace == nil)
        guard case .failed(let reason) = fixture.controller.status else {
            Issue.record("expected a failure, got \(fixture.controller.status)")
            return
        }
        #expect(reason.contains("gemini"))
    }

    @Test
    func stopsAfterRepeatedShortRunsUntilConfigurationIsReloaded() async throws {
        let fixture = Fixture(stableRunDuration: 60, maximumQuickExits: 2)
        fixture.controller.start()
        await fixture.waitUntil("the first start") { fixture.launcher.calls.count == 1 }
        fixture.exitSession("launched-1", after: 1)
        await fixture.waitUntil("the second start") { fixture.launcher.calls.count == 2 }
        fixture.exitSession("launched-2", after: 1)

        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.launcher.calls.count == 2)
        guard case .failed = fixture.controller.status else {
            Issue.record("expected the coordinator to stop, got \(fixture.controller.status)")
            return
        }

        fixture.controller.reloadConfiguration()
        await fixture.waitUntil("the start after a reload") { fixture.launcher.calls.count == 3 }
    }

    /// A coordinator workspace saved by an earlier run, with the record
    /// its terminal resumes from.
    private func saveRestoredCoordinator(_ fixture: Fixture) -> (workspaceID: UUID, panelID: UUID) {
        let windowID = fixture.store.state.windows[0].id
        let workspaceID = UUID()
        let panelID = UUID()
        #expect(fixture.store.send(.createCoordinatorWorkspace(
            windowID: windowID,
            workspaceID: workspaceID,
            panelID: panelID,
            terminalCWD: "/Users/tester"
        )))
        #expect(fixture.store.send(.updateTerminalPanelResumeRecord(
            panelID: panelID,
            resumeRecord: ManagedAgentResumeRecord(
                agent: .claude,
                nativeSessionID: "native-1",
                sessionFilePath: "/tmp/claude-session.jsonl",
                cwd: "/Users/tester",
                capturedAt: fixture.clock
            )
        )))
        return (workspaceID, panelID)
    }

    @Test
    func aCoordinatorThatIsOffClosesItsSavedWorkspaceSoNothingResumes() async throws {
        let fixture = Fixture()
        _ = saveRestoredCoordinator(fixture)
        fixture.config.coordinator = TasksConfig.Coordinator(agent: nil)
        fixture.controller.start()
        #expect(fixture.coordinatorWorkspace == nil)
        #expect(fixture.launcher.calls.isEmpty)

        // A run that does not start the coordinator closes it too.
        let other = Fixture()
        _ = saveRestoredCoordinator(other)
        other.controller.closeSavedWorkspace()
        #expect(other.coordinatorWorkspace == nil)
    }

    @Test
    func aSlowRestoreIsNotRacedByAFreshLaunchAfterTheGrace() async throws {
        let fixture = Fixture(restoreGrace: .zero)
        _ = saveRestoredCoordinator(fixture)
        fixture.restorePending = true
        fixture.controller.start()
        try await Task.sleep(for: .milliseconds(80))
        #expect(fixture.launcher.calls.isEmpty)
        #expect(fixture.controller.status == .waitingForRestore)

        // The restore gave up without an agent: now a fresh one starts.
        fixture.restorePending = false
        await fixture.waitUntil("a fresh launch") { fixture.launcher.calls.count == 1 }
    }

    @Test
    func waitsForARestoredSessionInsteadOfTypingASecondAgent() async throws {
        let fixture = Fixture()
        let (workspaceID, panelID) = saveRestoredCoordinator(fixture)

        fixture.controller.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.launcher.calls.isEmpty)
        #expect(fixture.controller.status == .waitingForRestore)

        // The terminal resumes the agent; the controller follows it.
        fixture.sessions.sessions["restored"] = TaskSessionInfo(
            sessionID: "restored",
            agent: .claude,
            panelID: panelID,
            workspaceID: workspaceID,
            cwd: "/Users/tester",
            isActive: true,
            isInTurn: false
        )
        fixture.controller.reconcile()
        #expect(fixture.controller.status == .running(sessionID: "restored"))
        #expect(fixture.launcher.calls.isEmpty)
    }

    @Test
    func aClosedCoordinatorWorkspaceIsMadeAgain() async throws {
        let fixture = Fixture()
        fixture.controller.start()
        await fixture.waitUntil("the coordinator starts") { fixture.launcher.calls.count == 1 }
        let first = try #require(fixture.coordinatorWorkspace?.id)

        #expect(fixture.store.send(.closeWorkspace(workspaceID: first)))
        fixture.exitSession("launched-1", after: 600)
        await fixture.waitUntil("the coordinator starts again") { fixture.launcher.calls.count == 2 }
        let second = try #require(fixture.coordinatorWorkspace?.id)
        #expect(second != first)
        #expect(fixture.launcher.calls[1].workspaceID == second)
    }

    @Test
    func aCardAfterALineCutShortIsKept() throws {
        let fixture = Fixture()
        let files = fixture.controller.files
        try files.prepare()
        try Data(#"{"id":"cut"#.utf8).write(to: files.eventsFileURL)
        let event = CoordinatorEvent(at: fixture.clock, kind: .note, taskID: nil, text: "After a crash.", sessionID: nil)
        try files.append(event)
        #expect(files.events() == [event])
    }

    @Test
    func repliesWithTheSameSourceAreSavedOncePerTask() throws {
        let fixture = Fixture()
        let files = fixture.controller.files
        let taskID = UUID()
        let reply = CoordinatorEvent(
            at: fixture.clock, kind: .reply, taskID: taskID, text: "Use the feature branch.", sessionID: nil,
            threadRole: .userCoordinator, sourceID: "provider-event-1"
        )
        let duplicate = CoordinatorEvent(
            at: fixture.clock, kind: .reply, taskID: taskID, text: "Use the feature branch.", sessionID: nil,
            threadRole: .userCoordinator, sourceID: "provider-event-1"
        )
        let otherTask = CoordinatorEvent(
            at: fixture.clock, kind: .reply, taskID: UUID(), text: "Another task's reply.", sessionID: nil,
            threadRole: .userTask, sourceID: "provider-event-1"
        )
        let card = CoordinatorEvent(at: fixture.clock, kind: .note, taskID: nil, text: "A new card.", sessionID: nil)
        for event in [reply, duplicate, reply, otherTask, card, card] { try files.append(event) }
        #expect(files.events() == [reply, otherTask, card, card])
    }

    @Test
    func concurrentAppendsKeepOneSourceAndEveryUncorrelatedCard() throws {
        let fixture = Fixture()
        let files = fixture.controller.files
        let directoryURL = files.directoryURL
        let at = fixture.clock
        let taskID = UUID()
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            do {
                let writer = CoordinatorFiles(directoryURL: directoryURL)
                try writer.append(CoordinatorEvent(
                    at: at, kind: .reply, taskID: taskID, text: "The answer.", sessionID: nil,
                    threadRole: .userCoordinator, sourceID: "shared-provider-event"
                ))
                try writer.append(CoordinatorEvent(at: at, kind: .note, taskID: nil, text: "Card \(index)", sessionID: nil))
            } catch {
                Issue.record("Could not append a coordinator event: \(error)")
            }
        }
        let events = files.events()
        #expect(events.count == 17)
        #expect(events.filter { $0.sourceID == "shared-provider-event" }.count == 1)
        #expect(Set(events.filter { $0.sourceID == nil }.compactMap(\.text)) == Set((0..<16).map { "Card \($0)" }))
    }
}
