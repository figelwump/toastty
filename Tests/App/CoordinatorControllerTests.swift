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
        /// The next delivery types the text but does not confirm Return.
        var nextSubmitIsUnconfirmed = false
        private let deliveryOverride = DeliveryOverride()

        /// Lets the closure the controller holds read a fixture setting.
        @MainActor
        final class DeliveryOverride {
            var result: (() -> TerminalInputDeliveryResult?)?
        }

        /// What Toastty ships as the coordinator's instructions; a test can
        /// change it, as an update of Toastty does. `nil` is an app that
        /// cannot read them.
        let instructions = CoordinatorFolderTests.Instructions()
        /// Where the controller saves the user's waiting messages, as the
        /// app does.
        let queueFileURL: URL

        /// `trustFolder` is the app's step that tells the agent that the
        /// coordinator's folder is trusted.
        init(
            readinessTimeout: Duration = .seconds(3),
            trustFolder: @escaping @MainActor (_ profileID: String, _ directory: String) async -> Void = { _, _ in }
        ) throws {
            let tasks = try TaskCoordinatorTests.Fixture()
            self.tasks = tasks
            directory = tasks.root.appendingPathComponent("runtime-home/coordinator", isDirectory: true)
            queueFileURL = tasks.root.appendingPathComponent("runtime-home/coordinator-queue.json")
            let folder = CoordinatorFolderTests.folder(at: directory, instructions: instructions)
            terminals.bind(sessionLifecycleTracker: tasks.sessionRuntimeStore)
            let terminals = terminals
            let deliveryOverride = deliveryOverride
            controller = CoordinatorController(
                store: tasks.store,
                sessionRuntimeStore: tasks.sessionRuntimeStore,
                launcher: tasks.launcher,
                directoryURL: directory,
                folder: folder,
                queueFileURL: queueFileURL,
                configLoader: { [unowned tasks] in
                    if let configError = tasks.configError { throw configError }
                    return tasks.config
                },
                trustFolder: trustFolder,
                deliverText: { text, panelID in
                    let result = terminals.sendTextResult(text, submit: true, panelID: panelID, focusPolicy: .preserveFirstResponder)
                    return result == .delivered ? (deliveryOverride.result?() ?? result) : result
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
            deliveryOverride.result = { [unowned self] in
                guard nextSubmitIsUnconfirmed else { return nil }
                nextSubmitIsUnconfirmed = false
                return .uncertain
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

    // MARK: - Folder trust

    /// What the trust step saw when it ran.
    @MainActor
    private final class TrustStep {
        weak var fixture: Fixture?
        var commandsSentBeforeTheWrite: Int?
    }

    @Test func aStartTellsClaudeCodeThatTheCoordinatorsFolderIsTrustedBeforeTheAgentRuns() async throws {
        // Claude Code's config file of a user who trusted their own
        // folders, in a home of this test.
        let home = try ClaudeFolderTrustTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appending(path: ".claude.json")
        try Data(#"{"numStartups": 3, "projects": {"/Users/someone/repos": {"hasTrustDialogAccepted": true}}}"#.utf8)
            .write(to: config)
        let environment = ["HOME": home.path]
        let step = TrustStep()
        let fixture = try Fixture(trustFolder: { [step] profileID, directory in
            // The app's step.
            await ClaudeFolderTrust.trustCoordinatorFolder(
                directory, profileID: profileID, profileArgv: [], environment: environment
            )
            step.commandsSentBeforeTheWrite = step.fixture?.tasks.router.sendAttemptCount
        })
        step.fixture = fixture

        try await fixture.controller.open()
        // The entry was there before the agent's command went to the
        // terminal, so the agent never asks.
        #expect(step.commandsSentBeforeTheWrite == 0)
        #expect(fixture.tasks.router.sendAttemptCount == 1)
        let folderKey = try #require(ClaudeFolderTrust.folderKey(for: fixture.directory))
        func document() throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        }
        // The coordinator's own folder and no other: not the folder above
        // it, and the user's entries are as they were.
        #expect(try document()["projects"] as? [String: [String: Bool]] == [
            "/Users/someone/repos": ["hasTrustDialogAccepted": true],
            folderKey: ["hasTrustDialogAccepted": true],
        ])
        #expect(try document()["numStartups"] as? Int == 3)

        // A restart finds the folder trusted and leaves the file alone.
        let text = try String(contentsOf: config, encoding: .utf8)
        try await fixture.controller.restart()
        #expect(try String(contentsOf: config, encoding: .utf8) == text)

        // Another agent has no such file to write.
        fixture.tasks.config.coordinator.agent = "codex"
        try Data(#"{"projects": {}}"#.utf8).write(to: config)
        try await fixture.controller.restart()
        #expect(try String(contentsOf: config, encoding: .utf8) == #"{"projects": {}}"#)
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

    /// Git in the agent's commands stops at the coordinator's folder, also
    /// when Restart starts the agent in a new terminal.
    @Test func everyStartPutsAGitCeilingAboveTheFolderOnTheAgentsCommand() async throws {
        let fixture = try Fixture()
        let ceiling = "GIT_CEILING_DIRECTORIES=\(fixture.directory.deletingLastPathComponent().path)"
        let first = try await fixture.openAtPrompt()
        let firstPanelID = try #require(first.location.panelID)
        #expect(try #require(fixture.tasks.router.sentTextByPanelID[firstPanelID]).contains(ceiling))

        let restarted = try await fixture.controller.restart()
        let newPanelID = try #require(restarted.location.panelID)
        #expect(newPanelID != firstPanelID)
        #expect(try #require(fixture.tasks.router.sentTextByPanelID[newPanelID]).contains(ceiling))
    }

    // MARK: - Policy

    /// The policy shows in the coordinator's right panel, from any workspace,
    /// and a second open shows the same panel.
    @Test func openPolicyShowsThePolicyFileInTheCoordinatorsRightPanel() async throws {
        let fixture = try Fixture()
        let opened = try await fixture.controller.open()
        let location = opened.location
        let policyPath = fixture.directory.appending(path: "policy.md").resolvingSymlinksInPath().path
        _ = fixture.store.selectWorkspace(windowID: location.windowID, workspaceID: fixture.tasks.workspaceID, preferringUnreadSessionPanelIn: nil)

        try fixture.controller.openPolicy()

        #expect(fixture.store.selectedWorkspaceID(in: location.windowID) == location.workspaceID)
        let workspace = try #require(fixture.store.state.workspacesByID[location.workspaceID])
        let documents = workspace.rightAuxPanel.tabIDs.compactMap { tabID -> (UUID, LocalDocumentState)? in
            guard let tab = workspace.rightAuxPanel.tabsByID[tabID],
                  case .web(let web) = tab.panelState,
                  let document = web.localDocument else { return nil }
            return (tab.panelID, document)
        }
        #expect(documents.map(\.1.filePath) == [policyPath])
        #expect(documents.first?.1.format == .markdown)
        #expect(workspace.rightAuxPanel.isVisible)
        // The coordinator's terminal stays where it was.
        #expect(workspace.allTerminalPanelIDs == [try #require(location.panelID)])

        try fixture.controller.openPolicy()
        let again = try #require(fixture.store.state.workspacesByID[location.workspaceID])
        #expect(again.rightAuxPanel.tabIDs.count == workspace.rightAuxPanel.tabIDs.count)
    }

    /// A policy the user deleted comes back with its headings, so the
    /// button always shows a file.
    @Test func openPolicyCreatesAMissingPolicy() async throws {
        let fixture = try Fixture()
        try await fixture.controller.open()
        let policyURL = fixture.directory.appending(path: "policy.md")
        try FileManager.default.removeItem(at: policyURL)

        try fixture.controller.openPolicy()

        #expect(try String(contentsOf: policyURL, encoding: .utf8) == CoordinatorFolder.policyTemplate)
    }

    @Test func openPolicyWithoutACoordinatorSaysSo() throws {
        let fixture = try Fixture()
        #expect(throws: CoordinatorError("There is no coordinator. Open Coordinator first.")) {
            try fixture.controller.openPolicy()
        }
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
        // The agent that ran keeps its terminal; the one made for the new
        // session is gone.
        #expect(fixture.store.state.coordinator == first.location)
        #expect(try fixture.session().sessionID == first.sessionID)
        #expect(try fixture.status().agentState == .running)
        let workspace = try #require(fixture.store.state.workspacesByID[first.location.workspaceID])
        #expect(workspace.allTerminalPanelIDs == [try #require(first.location.panelID)])
        #expect(workspace.tabIDs.count == 1)
    }

    @Test func closingAndReopeningDuringAStartGivesTheNewCoordinatorItsOwnAgent() async throws {
        let fixture = try Fixture(readinessTimeout: .seconds(2))
        // The first coordinator's terminal never gets ready.
        fixture.tasks.router.defaultPromptState = .unavailable
        let firstStart = Task { try await fixture.controller.open() }
        await fixture.waitUntil("the first start is under way") { fixture.controller.isStarting }
        let firstID = try #require(fixture.store.state.coordinatorWorkspaceID)
        #expect(fixture.store.send(.closeWorkspace(workspaceID: firstID)))
        #expect(fixture.controller.isStarting == false)

        fixture.tasks.router.defaultPromptState = .idleAtPrompt
        let second = try await fixture.controller.open()
        #expect(second.createdWorkspace)
        #expect(second.startedAgent)
        #expect(second.location.workspaceID != firstID)
        do {
            _ = try await firstStart.value
            Issue.record("the start of the closed coordinator should fail")
        } catch is CoordinatorError {}
        // The first start's end does not touch the second coordinator.
        let status = try fixture.status()
        #expect(status.agentState == .running)
        #expect(status.startFailure == nil)
        #expect(status.session?.sessionID == second.sessionID)
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

    @Test func anUnconfirmedSubmitHoldsTheNextEntryUntilATurnRuns() async throws {
        let fixture = try Fixture()
        try await fixture.openAtPrompt()
        // The text went in, but the terminal did not confirm Return. It is
        // not typed again, and nothing is typed after it.
        fixture.nextSubmitIsUnconfirmed = true
        #expect(try fixture.controller.send("one") == .sentUnconfirmed)
        #expect(try fixture.controller.send("two") == .queued(position: 1, hold: .awaitingTurn))
        await fixture.settle()
        #expect(fixture.typedTexts == ["one"])
        #expect(try fixture.status().hold == .awaitingTurn)

        // The user submits what is in the composer: after that turn, the
        // next entry goes in.
        try fixture.setStatus(.working)
        try fixture.setStatus(.idle)
        await fixture.waitUntil("the next entry is typed after the turn") { fixture.typedTexts == ["one", "two"] }
    }

    @Test func textSentDuringARestartWaitsForTheNewAgent() async throws {
        let fixture = try Fixture(readinessTimeout: .seconds(5))
        try await fixture.openAtPrompt()
        let oldPanelID = try #require(fixture.store.state.coordinator?.panelID)
        // The agent that runs is at an open prompt. The terminal for the new
        // session is not ready yet, so the restart waits.
        fixture.tasks.router.promptStateByPanelID[oldPanelID] = .idleAtPrompt
        fixture.tasks.router.defaultPromptState = .unavailable
        let restart = Task { try await fixture.controller.restart() }
        await fixture.waitUntil("the restart is under way") { fixture.controller.isStarting }

        // Text typed now would go to the agent that is about to end.
        #expect(try fixture.controller.send("a wake", queueWhenHeld: false) == .held(.agentStarting))
        #expect(try fixture.controller.send("a message") == .queued(position: 1, hold: .agentStarting))
        await fixture.settle()
        #expect(fixture.typedTexts.isEmpty)

        fixture.tasks.router.defaultPromptState = .idleAtPrompt
        let restarted = try await restart.value
        #expect(restarted.location.panelID != oldPanelID)
        try fixture.reportAgentStarted()
        await fixture.waitUntil("the message reaches the new agent") { fixture.typedTexts == ["a message"] }
        #expect(fixture.typed.first?.panelID == restarted.location.panelID)
    }

    @Test func closingTheCoordinatorsTerminalHoldsTheQueueUntilARestart() async throws {
        let fixture = try Fixture()
        let opened = try await fixture.openAtPrompt()
        let panelID = try #require(opened.location.panelID)
        // Another tab keeps the workspace open.
        #expect(fixture.store.send(.createBackgroundTerminalTab(
            workspaceID: opened.location.workspaceID, tabID: UUID(), panelID: UUID(), terminalCWD: fixture.directory.path
        )))
        try fixture.setStatus(.working)
        #expect(try fixture.controller.send("kept") == .queued(position: 1, hold: .busy))
        #expect(fixture.store.send(.closePanel(panelID: panelID)))

        var status = try fixture.status()
        #expect(status.location.panelID == nil)
        #expect(status.agentState == .notRunning)
        await fixture.waitUntil("the queue waits for an agent") { fixture.controller.hold == .noSession }
        #expect(fixture.typedTexts.isEmpty)

        let restarted = try await fixture.controller.restart()
        #expect(restarted.location.workspaceID == opened.location.workspaceID)
        try fixture.reportAgentStarted()
        await fixture.waitUntil("the entry reaches the new terminal") { fixture.typedTexts == ["kept"] }
        status = try fixture.status()
        #expect(status.location.panelID == restarted.location.panelID)
        #expect(fixture.typed.first?.panelID == restarted.location.panelID)
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
