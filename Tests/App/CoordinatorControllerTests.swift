import CoreState
import Foundation
import Testing
@testable import ToasttyApp

/// The coordinator through the real reducer, store, session store and agent
/// launcher, with a fake terminal in place of Ghostty. Text reaches the
/// session store through a real terminal registry, as in the app.
@MainActor
struct CoordinatorControllerTests {
    @MainActor
    final class Fixture {
        let tasks: TaskCoordinatorTests.Fixture
        let terminals = TerminalRuntimeRegistry()
        let directory: URL
        let controller: CoordinatorController
        /// What the controller typed, in order.
        private(set) var typed: [(text: String, panelID: UUID)] = []
        var typingSucceeds = true

        init(readinessTimeout: Duration = .seconds(3)) throws {
            let tasks = try TaskCoordinatorTests.Fixture()
            self.tasks = tasks
            directory = tasks.root.appendingPathComponent("runtime-home/coordinator", isDirectory: true)
            terminals.bind(sessionLifecycleTracker: tasks.sessionRuntimeStore)
            let terminals = terminals
            controller = CoordinatorController(
                store: tasks.store,
                sessionRuntimeStore: tasks.sessionRuntimeStore,
                launcher: tasks.launcher,
                directoryURL: directory,
                configLoader: { [unowned tasks] in
                    if let configError = tasks.configError { throw configError }
                    return tasks.config
                },
                deliverText: { text, panelID in
                    terminals.sendTextResult(text, submit: true, panelID: panelID, focusPolicy: .preserveFirstResponder)
                },
                promptState: { [unowned tasks] panelID in tasks.router.promptState(panelID: panelID) },
                terminalReadinessTimeout: readinessTimeout
            )
            tasks.coordinator.coordinatorController = controller
            terminals.setAutomationSendTextHandlerForTesting { [unowned self] text, submit, panelID, _ in
                guard typingSucceeds else { return false }
                #expect(submit)
                typed.append((text, panelID))
                return true
            }
        }

        var store: AppStore { tasks.store }
        var sessions: SessionRuntimeStore { tasks.sessionRuntimeStore }
        var typedTexts: [String] { typed.map(\.text) }

        func status() throws -> CoordinatorController.Status {
            try #require(controller.status)
        }

        func session() throws -> SessionRecord {
            try #require(controller.session)
        }

        /// The agent's own start report, as Claude's SessionStart hook sends it.
        func reportAgentStarted() throws {
            let session = try session()
            #expect(sessions.confirmNativeSessionBinding(
                managedSessionID: session.sessionID,
                panelID: session.panelID,
                record: ManagedAgentResumeRecord(
                    agent: session.agent,
                    nativeSessionID: "native-\(UUID().uuidString)",
                    sessionFilePath: tasks.root.appendingPathComponent("transcript-\(session.sessionID).jsonl").path,
                    cwd: directory.path,
                    capturedAt: Date()
                )
            ))
        }

        func setStatus(_ kind: SessionStatusKind) throws {
            sessions.updateStatus(
                sessionID: try session().sessionID,
                status: SessionStatus(kind: kind, summary: kind.rawValue),
                at: Date()
            )
        }

        /// Opens the coordinator and brings its agent to its first prompt.
        @discardableResult
        func openAtPrompt() async throws -> CoordinatorController.StartResult {
            let result = try await controller.open()
            try reportAgentStarted()
            return result
        }

        func waitUntil(_ description: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
            await tasks.waitUntil(description, timeout: timeout, condition)
        }

        /// Long enough for a queued entry to go in, were the prompt open.
        func settle() async {
            try? await Task.sleep(for: .seconds(CoordinatorSendGate.promptSettleInterval + 0.4))
        }
    }

    // MARK: - Open

    @Test func openCreatesTheWorkspaceOnceSelectsItAndStartsTheAgent() async throws {
        let fixture = try Fixture()
        #expect(fixture.controller.status == nil)
        let projectID = fixture.tasks.workspaceID

        let first = try await fixture.controller.open()
        #expect(first.createdWorkspace)
        #expect(first.startedAgent)
        let location = first.location
        let panelID = try #require(location.panelID)
        let workspace = try #require(fixture.store.state.workspacesByID[location.workspaceID])
        #expect(workspace.isCoordinator)
        #expect(workspace.title == "Coordinator")
        // Pinned outside the project cards, selected, in its own folder.
        #expect(fixture.store.state.topLevelWorkspaceIDs(in: location.windowID) == [projectID])
        #expect(fixture.store.selectedWorkspaceID(in: location.windowID) == location.workspaceID)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: fixture.directory.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        guard case .terminal(let terminal)? = workspace.panelState(for: panelID) else {
            Issue.record("the coordinator's panel is not a terminal")
            return
        }
        #expect(terminal.cwd == fixture.directory.path)
        // The agent runs in that terminal, with no first message.
        let session = try fixture.session()
        #expect(session.sessionID == first.sessionID)
        #expect(session.panelID == panelID)
        #expect(session.agent == .claude)
        #expect(try fixture.status().agentState == .running)
        let command = try #require(fixture.tasks.router.sentTextByPanelID[panelID])
        #expect(command.contains("/bin/claude"))
        #expect(command.contains("--model") == false)
        #expect(fixture.tasks.router.sendAttemptCount == 1)

        // A second call only selects.
        _ = fixture.store.selectWorkspace(windowID: location.windowID, workspaceID: projectID, preferringUnreadSessionPanelIn: nil)
        let second = try await fixture.controller.open()
        #expect(second.createdWorkspace == false)
        #expect(second.startedAgent == false)
        #expect(second.sessionID == session.sessionID)
        #expect(second.location == location)
        #expect(fixture.store.selectedWorkspaceID(in: location.windowID) == location.workspaceID)
        #expect(fixture.store.state.workspacesByID.values.filter(\.isCoordinator).count == 1)
        #expect(fixture.tasks.router.sendAttemptCount == 1)
    }

    @Test func openWithoutSelectLeavesTheSelectionAlone() async throws {
        let fixture = try Fixture()
        let result = try await fixture.controller.open(select: false)
        #expect(result.startedAgent)
        #expect(fixture.store.selectedWorkspaceID(in: result.location.windowID) == fixture.tasks.workspaceID)
    }

    @Test func theAgentModelAndEffortComeFromTheCoordinatorTable() async throws {
        let fixture = try Fixture()
        // The task defaults name another agent; the coordinator ignores them.
        fixture.tasks.config.defaults.agent = "codex"
        fixture.tasks.config.coordinator = TasksConfig.Coordinator(agent: "claude", model: "claude-opus-5-5", effort: "high")
        let result = try await fixture.controller.open()
        let panelID = try #require(result.location.panelID)
        let command = try #require(fixture.tasks.router.sentTextByPanelID[panelID])
        #expect(command.contains("/bin/claude"))
        #expect(command.contains("--model claude-opus-5-5"))
        #expect(command.contains("--effort high"))
    }

    @Test func aStartThatFailsKeepsTheWorkspaceAndSaysWhy() async throws {
        let fixture = try Fixture()
        fixture.tasks.config.coordinator = TasksConfig.Coordinator(agent: "nobody")
        do {
            try await fixture.controller.open()
            Issue.record("expected the start to fail")
        } catch let error as CoordinatorError {
            #expect(error.message.contains("nobody"))
        }
        var status = try fixture.status()
        #expect(status.agentState == .notRunning)
        #expect(status.startFailure?.contains("nobody") == true)
        #expect(fixture.store.state.workspacesByID.values.filter(\.isCoordinator).count == 1)

        // With the setting fixed, the same workspace gets its agent.
        fixture.tasks.config.coordinator = TasksConfig.Coordinator()
        let result = try await fixture.controller.open()
        #expect(result.createdWorkspace == false)
        #expect(result.startedAgent)
        status = try fixture.status()
        #expect(status.agentState == .running)
        #expect(status.startFailure == nil)
    }

    @Test func openStartsTheAgentAgainAfterItExited() async throws {
        let fixture = try Fixture()
        let first = try await fixture.controller.open()
        let panelID = try #require(first.location.panelID)
        // The agent exits; its terminal is back at the shell prompt.
        #expect(fixture.sessions.handleCommandFinished(panelID: panelID, exitCode: 0, at: Date()))
        #expect(try fixture.status().agentState == .notRunning)
        #expect(try fixture.status().session == nil)

        let second = try await fixture.controller.open()
        #expect(second.startedAgent)
        #expect(second.createdWorkspace == false)
        #expect(second.location == first.location)
        #expect(second.sessionID != first.sessionID)
        #expect(try fixture.session().panelID == panelID)
    }

    @Test func openLeavesATerminalThatIsBusyWithSomethingElse() async throws {
        let fixture = try Fixture(readinessTimeout: .milliseconds(300))
        let first = try await fixture.controller.open()
        let panelID = try #require(first.location.panelID)
        fixture.sessions.stopSessionForPanel(panelID: panelID, at: Date())
        // Something the user started runs there now.
        fixture.tasks.router.promptStateByPanelID[panelID] = .busy
        let attempts = fixture.tasks.router.sendAttemptCount

        do {
            try await fixture.controller.open()
            Issue.record("expected the start to fail")
        } catch let error as CoordinatorError {
            #expect(error.message.contains("busy"))
        }
        #expect(fixture.tasks.router.sendAttemptCount == attempts)
        #expect(fixture.store.state.coordinator == first.location)
        #expect(try fixture.status().startFailure?.contains("Restart Coordinator") == true)

        // Restart is the explicit way out: a new terminal, the old one closed.
        let restarted = try await fixture.controller.restart()
        let newPanelID = try #require(restarted.location.panelID)
        #expect(newPanelID != panelID)
        #expect(fixture.store.state.workspacesByID[first.location.workspaceID]?.panelState(for: panelID) == nil)
        #expect(try fixture.session().panelID == newPanelID)
    }

    @Test func openWaitsForTheResumeAfterARelaunchInsteadOfStartingASecondAgent() async throws {
        let fixture = try Fixture()
        let first = try await fixture.controller.open()
        let panelID = try #require(first.location.panelID)
        // As after a relaunch: no session runs, the terminal has a
        // conversation to resume, and its surface is not up yet.
        fixture.sessions.stopSessionForPanel(panelID: panelID, at: Date())
        #expect(fixture.store.send(.updateTerminalPanelResumeRecord(
            panelID: panelID,
            resumeRecord: ManagedAgentResumeRecord(
                agent: .claude, nativeSessionID: "native-1", sessionFilePath: "/tmp/native-1.jsonl",
                cwd: fixture.directory.path, capturedAt: Date()
            )
        )))
        fixture.tasks.router.promptStateByPanelID[panelID] = .unavailable
        let attempts = fixture.tasks.router.sendAttemptCount

        #expect(try fixture.status().agentState == .starting)
        let opened = try await fixture.controller.open()
        #expect(opened.startedAgent == false)
        #expect(opened.location == first.location)
        #expect(fixture.tasks.router.sendAttemptCount == attempts)
        // A message waits for the resumed agent.
        #expect(try fixture.controller.send("after relaunch") == .queued(position: 1, hold: .noSession))

        // Restart does not wait: a new terminal, and the old one closes with
        // its pending resume.
        let restarted = try await fixture.controller.restart()
        #expect(restarted.location.panelID != panelID)
        #expect(fixture.store.state.workspacesByID[first.location.workspaceID]?.panelState(for: panelID) == nil)
        try fixture.reportAgentStarted()
        await fixture.waitUntil("the message reaches the restarted agent") { fixture.typedTexts == ["after relaunch"] }

        // A terminal that is up with a record but no session did not resume;
        // Open starts the agent there.
        let newPanelID = try #require(restarted.location.panelID)
        #expect(fixture.sessions.handleCommandFinished(panelID: newPanelID, exitCode: 0, at: Date()))
        #expect(fixture.store.send(.updateTerminalPanelResumeRecord(
            panelID: newPanelID,
            resumeRecord: ManagedAgentResumeRecord(
                agent: .claude, nativeSessionID: "native-2", sessionFilePath: "/tmp/native-2.jsonl",
                cwd: fixture.directory.path, capturedAt: Date()
            )
        )))
        #expect(try fixture.status().agentState == .notRunning)
        #expect(try await fixture.controller.open().startedAgent)
    }

    // MARK: - Restart

    @Test func restartAfterTheAgentExitedStartsAFreshSessionInTheSameTerminal() async throws {
        let fixture = try Fixture()
        let first = try await fixture.controller.open()
        let panelID = try #require(first.location.panelID)
        #expect(fixture.sessions.handleCommandFinished(panelID: panelID, exitCode: 1, at: Date()))

        let restarted = try await fixture.controller.restart()
        #expect(restarted.startedAgent)
        #expect(restarted.createdWorkspace == false)
        #expect(restarted.location == first.location)
        #expect(restarted.sessionID != first.sessionID)
        #expect(try fixture.status().agentState == .running)
        #expect(fixture.store.state.workspacesByID[first.location.workspaceID]?.tabIDs.count == 1)
    }

    @Test func restartWhileTheAgentRunsEndsItAndUsesANewTerminalInTheSameWorkspace() async throws {
        let fixture = try Fixture()
        let first = try await fixture.controller.open()
        let oldPanelID = try #require(first.location.panelID)
        let oldSessionID = try #require(first.sessionID)

        let restarted = try await fixture.controller.restart()
        let newPanelID = try #require(restarted.location.panelID)
        #expect(restarted.location.workspaceID == first.location.workspaceID)
        #expect(newPanelID != oldPanelID)
        #expect(restarted.sessionID != oldSessionID)
        // The old terminal and its session are gone; one terminal remains.
        let workspace = try #require(fixture.store.state.workspacesByID[first.location.workspaceID])
        #expect(workspace.panelState(for: oldPanelID) == nil)
        #expect(workspace.allTerminalPanelIDs == [newPanelID])
        #expect(workspace.tabID(containingPanelID: newPanelID) == workspace.resolvedSelectedTabID)
        #expect(fixture.sessions.sessionRegistry.activeSession(sessionID: oldSessionID) == nil)
        #expect(try fixture.session().panelID == newPanelID)
        #expect(fixture.store.state.workspacesByID.values.filter(\.isCoordinator).count == 1)
        guard case .terminal(let terminal)? = workspace.panelState(for: newPanelID) else {
            Issue.record("the new panel is not a terminal")
            return
        }
        #expect(terminal.cwd == fixture.directory.path)
    }

    @Test func restartWithAnUnknownAgentLeavesTheRunningAgentAlone() async throws {
        let fixture = try Fixture()
        let first = try await fixture.controller.open()
        fixture.tasks.config.coordinator = TasksConfig.Coordinator(agent: "nobody")
        do {
            try await fixture.controller.restart()
            Issue.record("expected the restart to fail")
        } catch let error as CoordinatorError {
            #expect(error.message.contains("nobody"))
        }
        #expect(fixture.store.state.coordinator == first.location)
        #expect(try fixture.session().sessionID == first.sessionID)
        #expect(try fixture.status().agentState == .running)
    }

    @Test func restartMakesTheCoordinatorWhenThereIsNone() async throws {
        let fixture = try Fixture()
        let restarted = try await fixture.controller.restart()
        #expect(restarted.createdWorkspace)
        #expect(restarted.startedAgent)
        // Restart does not take the selection.
        #expect(fixture.store.selectedWorkspaceID(in: restarted.location.windowID) == fixture.tasks.workspaceID)
    }

    // MARK: - Send

    @Test func sendTypesAtAnOpenPromptAsProgrammaticInput() async throws {
        let fixture = try Fixture()
        try await fixture.openAtPrompt()
        let panelID = try #require(fixture.store.state.coordinator?.panelID)

        #expect(try fixture.controller.send("  Two tasks changed stage.\n") == .sent)
        #expect(fixture.typedTexts == ["Two tasks changed stage."])
        #expect(fixture.typed.first?.panelID == panelID)
        #expect(try fixture.status().queuedCount == 0)
        // Typed by Toastty, not by the user.
        #expect(fixture.sessions.lastLocalInputAt(panelID: panelID) != nil)
        #expect(fixture.sessions.lastUserInputAt(panelID: panelID) == nil)
    }

    @Test func sendWaitsWhileTheAgentWorksThenTypesOneEntryForEachPromptInOrder() async throws {
        let fixture = try Fixture()
        try await fixture.openAtPrompt()
        try fixture.setStatus(.working)

        #expect(try fixture.controller.send("first") == .queued(position: 1, hold: .busy))
        #expect(try fixture.controller.send("second") == .queued(position: 2, hold: .busy))
        #expect(try fixture.controller.send("third") == .queued(position: 3, hold: .busy))
        #expect(fixture.typedTexts.isEmpty)
        #expect(try fixture.status().hold == .busy)

        // An approval prompt is not an open prompt.
        try fixture.setStatus(.needsApproval)
        await fixture.settle()
        #expect(fixture.typedTexts.isEmpty)

        // The turn ends: the first entry goes in after the settle time, and
        // only that one.
        try fixture.setStatus(.idle)
        #expect(fixture.typedTexts.isEmpty)
        await fixture.waitUntil("the first entry is typed") { fixture.typedTexts == ["first"] }
        await fixture.settle()
        #expect(fixture.typedTexts == ["first"])
        #expect(try fixture.status().queuedCount == 2)
        #expect(try fixture.status().hold == .awaitingTurn)

        // Each next entry waits for the turn the one before it started.
        try fixture.setStatus(.working)
        await fixture.settle()
        #expect(fixture.typedTexts == ["first"])
        try fixture.setStatus(.ready)
        await fixture.waitUntil("the second entry is typed") { fixture.typedTexts == ["first", "second"] }
        try fixture.setStatus(.working)
        try fixture.setStatus(.idle)
        await fixture.waitUntil("the third entry is typed") { fixture.typedTexts == ["first", "second", "third"] }
        #expect(try fixture.status().queuedCount == 0)
        #expect(try fixture.status().hold == nil)
    }

    @Test func sendNeverTypesOverTheUsersDraft() async throws {
        let fixture = try Fixture()
        try await fixture.openAtPrompt()
        let panelID = try #require(fixture.store.state.coordinator?.panelID)

        // The user types in the coordinator's terminal and has not sent it.
        fixture.terminals.handleLocalInput(for: panelID, kind: .key)
        #expect(try fixture.controller.send("wake") == .queued(position: 1, hold: .userDraft))
        await fixture.settle()
        #expect(fixture.typedTexts.isEmpty)
        #expect(try fixture.status().hold == .userDraft)

        // They send their message: that turn runs, then the entry goes in.
        try fixture.setStatus(.working)
        try fixture.setStatus(.idle)
        await fixture.waitUntil("the entry is typed after the user's turn") { fixture.typedTexts == ["wake"] }

        // Text typed during a turn is still in the composer when it ends.
        try fixture.setStatus(.working)
        fixture.terminals.handleLocalInput(for: panelID, kind: .paste)
        try fixture.setStatus(.idle)
        #expect(try fixture.controller.send("second wake") == .queued(position: 1, hold: .settling))
        await fixture.settle()
        #expect(fixture.typedTexts == ["wake"])
        #expect(try fixture.status().hold == .userDraft)
    }

    @Test func sendWithNoAgentWaitsForOpenAndForTheAgentToReportItsStart() async throws {
        let fixture = try Fixture()
        let first = try await fixture.controller.open()
        let panelID = try #require(first.location.panelID)
        #expect(fixture.sessions.handleCommandFinished(panelID: panelID, exitCode: 0, at: Date()))

        #expect(try fixture.controller.send("while you were out") == .queued(position: 1, hold: .noSession))
        #expect(try fixture.status().queuedCount == 1)

        // Open starts the agent. Its process is not up yet, so nothing is
        // typed into the shell that launches it.
        try await fixture.controller.open()
        await fixture.settle()
        #expect(fixture.typedTexts.isEmpty)
        #expect(try fixture.status().hold == .agentStarting)

        try fixture.reportAgentStarted()
        await fixture.waitUntil("the entry is typed once the agent is up") { fixture.typedTexts == ["while you were out"] }
        #expect(fixture.typed.first?.panelID == panelID)
    }

    @Test func theQueueSurvivesARestartAndGoesToTheNewSession() async throws {
        let fixture = try Fixture()
        try await fixture.openAtPrompt()
        let oldPanelID = try #require(fixture.store.state.coordinator?.panelID)
        try fixture.setStatus(.working)
        #expect(try fixture.controller.send("one") == .queued(position: 1, hold: .busy))
        #expect(try fixture.controller.send("two") == .queued(position: 2, hold: .busy))

        let restarted = try await fixture.controller.restart()
        let newPanelID = try #require(restarted.location.panelID)
        #expect(newPanelID != oldPanelID)
        #expect(try fixture.status().queuedCount == 2)
        try fixture.reportAgentStarted()
        await fixture.waitUntil("the first entry reaches the new session") { fixture.typedTexts == ["one"] }
        #expect(fixture.typed.first?.panelID == newPanelID)
        try fixture.setStatus(.working)
        try fixture.setStatus(.idle)
        await fixture.waitUntil("the second entry follows") { fixture.typedTexts == ["one", "two"] }
        #expect(fixture.typed.allSatisfy { $0.panelID == newPanelID })
    }

    @Test func aTerminalThatRefusesTheTextKeepsTheEntry() async throws {
        let fixture = try Fixture()
        try await fixture.openAtPrompt()
        fixture.typingSucceeds = false
        #expect(try fixture.controller.send("later") == .queued(position: 1, hold: .terminalUnavailable))
        fixture.typingSucceeds = true
        await fixture.waitUntil("the entry is typed when the terminal takes it") { fixture.typedTexts == ["later"] }
    }

    @Test func sendRefusesWhatItCannotKeep() async throws {
        let fixture = try Fixture()
        func expectError(_ mention: String, _ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
            do {
                try fixture.controller.send(text)
                Issue.record("expected an error", sourceLocation: sourceLocation)
            } catch let error as CoordinatorError {
                #expect(error.message.contains(mention), sourceLocation: sourceLocation)
            } catch {
                Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
            }
        }
        expectError("no coordinator", "hello")

        try await fixture.openAtPrompt()
        expectError("empty", " \n ")
        try fixture.setStatus(.working)
        for index in 0..<CoordinatorController.maximumQueuedEntries {
            #expect(try fixture.controller.send("entry \(index)") == .queued(position: index + 1, hold: .busy))
        }
        expectError("50 messages", "one too many")

        // Closing the workspace removes the coordinator and its queue.
        let workspaceID = try #require(fixture.store.state.coordinatorWorkspaceID)
        #expect(fixture.store.send(.closeWorkspace(workspaceID: workspaceID)))
        #expect(fixture.controller.status == nil)
        expectError("no coordinator", "hello")
        try await fixture.openAtPrompt()
        #expect(try fixture.status().queuedCount == 0)
        #expect(fixture.typedTexts.isEmpty)
    }
}
